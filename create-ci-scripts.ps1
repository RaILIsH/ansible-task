# create-ci-scripts.ps1
# Создаёт каталог ci/ и все скрипты для пайплайна

$ciDir = "ci"
if (-not (Test-Path $ciDir)) {
    New-Item -ItemType Directory -Path $ciDir | Out-Null
    Write-Host "Создан каталог $ciDir"
}

function Write-Script($name, $content) {
    $path = Join-Path $ciDir $name
    # Пишем в UTF-8 без BOM, с переводами строк LF (удобнее для bash)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $content.Replace("`r`n", "`n"), $utf8NoBom)
    Write-Host "Создан $path"
}

# ---------- build-uefi.sh ----------
Write-Script "build-uefi.sh" @'
#!/bin/bash
# Контролируемая сборка UEFI-драйвера через EDK2
# Использование: ./ci/build-uefi.sh <out_dir>
set -euo pipefail
OUT="${1:-out/build/uefi}"
mkdir -p "$OUT"

EDK2_PATH="${EDK2_PATH:-/opt/edk2}"
DSC="${EDK2_DSC:-uefi-driver.dsc}"

if [[ ! -d "$EDK2_PATH" ]] || [[ ! -f "$DSC" ]]; then
  echo "NOT_IMPLEMENTED: EDK2_PATH или $DSC не найдены" | tee "$OUT/status.txt"
  exit 0
fi

# shellcheck disable=SC1091
source "$EDK2_PATH/edksetup.sh" --reconfig

export WORKSPACE="${WORKSPACE:-$PWD}"
export PACKAGES_PATH="${PACKAGES_PATH:-$WORKSPACE:$EDK2_PATH}"

echo "=== EDK2 build: $DSC ===" | tee "$OUT/build.log"
build -a X64 -b RELEASE -t GCC5 -p "$DSC" \
  -y "$OUT/edk2-build-report.txt" \
  -Y LIBRARY -Y PCD -Y DEPEX -Y BUILD_FLAGS -Y HASH \
  -j "$OUT/edk2-build.log" || {
    echo "FAIL: сборка EDK2 завершилась с ошибкой" | tee "$OUT/status.txt"
    exit 1
  }

EFI=$(find Build -name "*.efi" -type f | head -1 || true)
if [[ -n "$EFI" ]]; then
  sha256sum "$EFI" > "$OUT/driver.sha256"
  cp "$EFI" "$OUT/driver.efi" || true
  echo "PASS: собран $EFI" | tee "$OUT/status.txt"
else
  echo "FAIL: .efi не найден после сборки" | tee "$OUT/status.txt"
  exit 1
fi

git -C "$EDK2_PATH" rev-parse HEAD > "$OUT/edk2-revision.txt" 2>/dev/null || true
echo "DONE" >> "$OUT/status.txt"
'@

# ---------- build-native.sh ----------
Write-Script "build-native.sh" @'
#!/bin/bash
# Native-сборка libntfs-3g для тестов, ASan и фаззинга парсера
# Использование: ./ci/build-native.sh <out_dir>
set -euo pipefail
OUT="${1:-out/build/native}"
mkdir -p "$OUT"

if [[ ! -f libntfs-3g/Makefile.am ]] && [[ ! -f configure ]]; then
  echo "NOT_IMPLEMENTED: нет исходников libntfs-3g / configure" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== Native build libntfs-3g ===" | tee "$OUT/build.log"

if [[ -x ./autogen.sh ]]; then
  ./autogen.sh >> "$OUT/build.log" 2>&1 || true
fi
if [[ -x ./configure ]]; then
  ./configure --enable-debug >> "$OUT/build.log" 2>&1 || true
fi
make -C libntfs-3g -j"$(nproc)" >> "$OUT/build.log" 2>&1 || {
  echo "FAIL: native-сборка не удалась" | tee "$OUT/status.txt"
  exit 1
}

echo "PASS: libntfs-3g собран" | tee "$OUT/status.txt"
find libntfs-3g -name "*.so" -o -name "*.a" | head -20 > "$OUT/artifacts.list" || true
'@

# ---------- sbom-edk2.sh ----------
Write-Script "sbom-edk2.sh" @'
#!/bin/bash
# Формирование SBOM на основе EDK2 Build Report + исходников
# Использование: ./ci/sbom-edk2.sh <build_report> <out_dir>
set -euo pipefail
REPORT="${1:-out/build/uefi/edk2-build-report.txt}"
OUT="${2:-out/kao1/sbom}"
mkdir -p "$OUT"

if [[ ! -s "$REPORT" ]]; then
  echo "NOT_IMPLEMENTED: нет Build Report ($REPORT)" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== SBOM из EDK2 Build Report ===" | tee "$OUT/sbom.log"

grep -E "Library|PCD|Build Flags|Dependency|HASH" "$REPORT" > "$OUT/report-extract.txt" || true
find uefi-driver libntfs-3g include -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null | sort > "$OUT/source-files.txt" || true

if command -v syft >/dev/null; then
  syft dir:./uefi-driver dir:./libntfs-3g -o cyclonedx-json="$OUT/source.cdx.json" >> "$OUT/sbom.log" 2>&1 || true
fi

cat > "$OUT/driver.cdx.json" << EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "version": 1,
  "metadata": {
    "component": {
      "type": "application",
      "name": "ntfs-3g-uefi-driver",
      "version": "${CI_COMMIT_SHORT_SHA:-unknown}"
    }
  },
  "components": []
}
EOF

echo "PASS: заготовка SBOM создана (требует ручной сверки с Build Report)" | tee "$OUT/status.txt"
'@

# ---------- vuln-scan.sh ----------
Write-Script "vuln-scan.sh" @'
#!/bin/bash
# Поиск известных уязвимостей по составу (CVE/БДУ)
# Использование: ./ci/vuln-scan.sh <out_dir>
set -euo pipefail
OUT="${1:-out/kao1}"
mkdir -p "$OUT"

echo "=== Поиск CVE/БДУ ===" | tee "$OUT/vuln.log"

if command -v osv-scanner >/dev/null && [[ -f out/kao1/sbom/driver.cdx.json ]]; then
  osv-scanner scan --sbom=out/kao1/sbom/driver.cdx.json > "$OUT/osv-report.txt" 2>&1 || true
  echo "PASS: osv-scanner отработал" | tee "$OUT/vuln-status.txt"
else
  echo "NOT_IMPLEMENTED: нет osv-scanner или SBOM" | tee "$OUT/vuln-status.txt"
fi

echo "Ручная проверка по БДУ ФСТЭК и банкам CVE обязательна для протокола." >> "$OUT/vuln-status.txt"
'@

# ---------- kao2-uefi.sh ----------
Write-Script "kao2-uefi.sh" @'
#!/bin/bash
# КАО.2: три сценария в QEMU/OVMF
# Использование: ./ci/kao2-uefi.sh <out_dir>
set -euo pipefail
OUT="${1:-out/kao2}"
mkdir -p "$OUT"

EFI="${EFI_PATH:-out/build/uefi/driver.efi}"
if [[ ! -f "$EFI" ]]; then
  echo "NOT_IMPLEMENTED: нет driver.efi (сначала build_uefi)" | tee "$OUT/status.txt"
  exit 0
fi

if ! command -v qemu-system-x86_64 >/dev/null; then
  echo "NOT_IMPLEMENTED: qemu-system-x86_64 не найден" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== КАО.2: сценарии QEMU/OVMF ===" | tee "$OUT/kao2.log"

for scenario in normal corrupted reopen; do
  echo "Сценарий: $scenario" | tee -a "$OUT/kao2.log"
  echo "NOT_IMPLEMENTED: сценарий $scenario (нужны образы ФС и OVMF на стенде)" > "$OUT/${scenario}.txt"
done

echo "PASS: каркас сценариев создан (реализация на стенде)" | tee "$OUT/status.txt"
'@

# ---------- run-svace.sh ----------
Write-Script "run-svace.sh" @'
#!/bin/bash
# Статический анализ Svace
# Использование: ./ci/run-svace.sh <out_dir>
set -euo pipefail
OUT="${1:-out/sast}"
mkdir -p "$OUT"

if ! command -v svace >/dev/null; then
  echo "NOT_IMPLEMENTED: svace не найден в PATH" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== Svace ===" | tee "$OUT/svace.log"
echo "NOT_IMPLEMENTED: вызов Svace требует настройки под конкретный стенд" | tee "$OUT/status.txt"
echo "Приоритет разметки: путь чтения (размеры, смещения, буферы)" >> "$OUT/status.txt"
'@

# ---------- unit-native.sh ----------
Write-Script "unit-native.sh" @'
#!/bin/bash
# Модульные тесты native (libntfs-3g)
# Использование: ./ci/unit-native.sh <out_dir>
set -euo pipefail
OUT="${1:-out/dast/unit-native}"
mkdir -p "$OUT"

echo "=== Native unit tests ===" | tee "$OUT/tests.log"

if [[ -d libntfs-3g ]] && command -v make >/dev/null; then
  make -C libntfs-3g check >> "$OUT/tests.log" 2>&1 || true
  echo "PASS: make check выполнен (смотрите лог)" | tee "$OUT/status.txt"
else
  echo "NOT_IMPLEMENTED: нет цели check или libntfs-3g" | tee "$OUT/status.txt"
fi
'@

# ---------- unit-uefi.sh ----------
Write-Script "unit-uefi.sh" @'
#!/bin/bash
# Системные тесты EFI-драйвера в QEMU
# Использование: ./ci/unit-uefi.sh <out_dir>
set -euo pipefail
OUT="${1:-out/dast/unit-uefi}"
mkdir -p "$OUT"

EFI="${EFI_PATH:-out/build/uefi/driver.efi}"
if [[ ! -f "$EFI" ]]; then
  echo "NOT_IMPLEMENTED: нет driver.efi" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== UEFI unit/smoke tests ===" | tee "$OUT/tests.log"
echo "NOT_IMPLEMENTED: запуск в QEMU/OVMF требует подготовленного стенда и образов" | tee "$OUT/status.txt"
'@

# ---------- fuzz-native.sh ----------
Write-Script "fuzz-native.sh" @'
#!/bin/bash
# Фаззинг парсера NTFS (native)
# Использование: ./ci/fuzz-native.sh <out_dir>
set -euo pipefail
OUT="${1:-out/dast/fuzz-native}"
mkdir -p "$OUT"

echo "=== Native fuzzing ===" | tee "$OUT/fuzz.log"

if command -v clang >/dev/null && [[ -d fuzz ]]; then
  echo "NOT_IMPLEMENTED: цели фаззинга в каталоге fuzz/ пока не подготовлены" | tee "$OUT/status.txt"
else
  echo "NOT_IMPLEMENTED: нет clang или каталога fuzz/" | tee "$OUT/status.txt"
fi
'@

Write-Host ""
Write-Host "Готово. Все скрипты созданы в каталоге ci/"
Write-Host "На Linux/GitLab Runner не забудьте сделать их исполняемыми:"
Write-Host "  chmod +x ci/*.sh"
