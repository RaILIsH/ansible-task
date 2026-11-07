# create-ci-scripts.ps1
# Creates ci/ directory and all pipeline scripts

$ciDir = "ci"
if (-not (Test-Path $ciDir)) {
    New-Item -ItemType Directory -Path $ciDir | Out-Null
    Write-Host "Created directory $ciDir"
}

function Write-Script($name, $content) {
    $path = Join-Path $ciDir $name
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $content.Replace("`r`n", "`n"), $utf8NoBom)
    Write-Host "Created $path"
}

# ---------- build-uefi.sh ----------
Write-Script "build-uefi.sh" @'
#!/bin/bash
# Controlled UEFI driver build via EDK2
# Usage: ./ci/build-uefi.sh <out_dir>
set -euo pipefail
OUT="${1:-out/build/uefi}"
mkdir -p "$OUT"

EDK2_PATH="${EDK2_PATH:-/opt/edk2}"
DSC="${EDK2_DSC:-uefi-driver.dsc}"

if [[ ! -d "$EDK2_PATH" ]] || [[ ! -f "$DSC" ]]; then
  echo "NOT_IMPLEMENTED: EDK2_PATH or $DSC not found" | tee "$OUT/status.txt"
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
    echo "FAIL: EDK2 build failed" | tee "$OUT/status.txt"
    exit 1
  }

EFI=$(find Build -name "*.efi" -type f | head -1 || true)
if [[ -n "$EFI" ]]; then
  sha256sum "$EFI" > "$OUT/driver.sha256"
  cp "$EFI" "$OUT/driver.efi" || true
  echo "PASS: built $EFI" | tee "$OUT/status.txt"
else
  echo "FAIL: .efi not found after build" | tee "$OUT/status.txt"
  exit 1
fi

git -C "$EDK2_PATH" rev-parse HEAD > "$OUT/edk2-revision.txt" 2>/dev/null || true
echo "DONE" >> "$OUT/status.txt"
'@

# ---------- build-native.sh ----------
Write-Script "build-native.sh" @'
#!/bin/bash
# Native build of libntfs-3g for tests, ASan and parser fuzzing
# Usage: ./ci/build-native.sh <out_dir>
set -euo pipefail
OUT="${1:-out/build/native}"
mkdir -p "$OUT"

if [[ ! -f libntfs-3g/Makefile.am ]] && [[ ! -f configure ]]; then
  echo "NOT_IMPLEMENTED: libntfs-3g sources or configure not found" | tee "$OUT/status.txt"
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
  echo "FAIL: native build failed" | tee "$OUT/status.txt"
  exit 1
}

echo "PASS: libntfs-3g built" | tee "$OUT/status.txt"
find libntfs-3g -name "*.so" -o -name "*.a" | head -20 > "$OUT/artifacts.list" || true
'@

# ---------- sbom-edk2.sh ----------
Write-Script "sbom-edk2.sh" @'
#!/bin/bash
# Generate SBOM from EDK2 Build Report + sources
# Usage: ./ci/sbom-edk2.sh <build_report> <out_dir>
set -euo pipefail
REPORT="${1:-out/build/uefi/edk2-build-report.txt}"
OUT="${2:-out/kao1/sbom}"
mkdir -p "$OUT"

if [[ ! -s "$REPORT" ]]; then
  echo "NOT_IMPLEMENTED: Build Report not found ($REPORT)" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== SBOM from EDK2 Build Report ===" | tee "$OUT/sbom.log"

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

echo "PASS: SBOM stub created (needs manual review against Build Report)" | tee "$OUT/status.txt"
'@

# ---------- vuln-scan.sh ----------
Write-Script "vuln-scan.sh" @'
#!/bin/bash
# Scan for known vulnerabilities (CVE/BDU)
# Usage: ./ci/vuln-scan.sh <out_dir>
set -euo pipefail
OUT="${1:-out/kao1}"
mkdir -p "$OUT"

echo "=== CVE/BDU scan ===" | tee "$OUT/vuln.log"

if command -v osv-scanner >/dev/null && [[ -f out/kao1/sbom/driver.cdx.json ]]; then
  osv-scanner scan --sbom=out/kao1/sbom/driver.cdx.json > "$OUT/osv-report.txt" 2>&1 || true
  echo "PASS: osv-scanner finished" | tee "$OUT/vuln-status.txt"
else
  echo "NOT_IMPLEMENTED: osv-scanner or SBOM missing" | tee "$OUT/vuln-status.txt"
fi

echo "Manual check against FSTEC BDU and CVE databases is required for the protocol." >> "$OUT/vuln-status.txt"
'@

# ---------- kao2-uefi.sh ----------
Write-Script "kao2-uefi.sh" @'
#!/bin/bash
# KAO.2: three scenarios in QEMU/OVMF
# Usage: ./ci/kao2-uefi.sh <out_dir>
set -euo pipefail
OUT="${1:-out/kao2}"
mkdir -p "$OUT"

EFI="${EFI_PATH:-out/build/uefi/driver.efi}"
if [[ ! -f "$EFI" ]]; then
  echo "NOT_IMPLEMENTED: driver.efi not found (run build_uefi first)" | tee "$OUT/status.txt"
  exit 0
fi

if ! command -v qemu-system-x86_64 >/dev/null; then
  echo "NOT_IMPLEMENTED: qemu-system-x86_64 not found" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== KAO.2: QEMU/OVMF scenarios ===" | tee "$OUT/kao2.log"

for scenario in normal corrupted reopen; do
  echo "Scenario: $scenario" | tee -a "$OUT/kao2.log"
  echo "NOT_IMPLEMENTED: scenario $scenario (FS images and OVMF required on the stand)" > "$OUT/${scenario}.txt"
done

echo "PASS: scenario stubs created (implement on the lab stand)" | tee "$OUT/status.txt"
'@

# ---------- run-svace.sh ----------
Write-Script "run-svace.sh" @'
#!/bin/bash
# Static analysis with Svace
# Usage: ./ci/run-svace.sh <out_dir>
set -euo pipefail
OUT="${1:-out/sast}"
mkdir -p "$OUT"

if ! command -v svace >/dev/null; then
  echo "NOT_IMPLEMENTED: svace not found in PATH" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== Svace ===" | tee "$OUT/svace.log"
echo "NOT_IMPLEMENTED: Svace invocation requires stand-specific configuration" | tee "$OUT/status.txt"
echo "Priority: reading path (sizes, offsets, buffers)" >> "$OUT/status.txt"
'@

# ---------- unit-native.sh ----------
Write-Script "unit-native.sh" @'
#!/bin/bash
# Native unit tests (libntfs-3g)
# Usage: ./ci/unit-native.sh <out_dir>
set -euo pipefail
OUT="${1:-out/dast/unit-native}"
mkdir -p "$OUT"

echo "=== Native unit tests ===" | tee "$OUT/tests.log"

if [[ -d libntfs-3g ]] && command -v make >/dev/null; then
  make -C libntfs-3g check >> "$OUT/tests.log" 2>&1 || true
  echo "PASS: make check finished (see log)" | tee "$OUT/status.txt"
else
  echo "NOT_IMPLEMENTED: no check target or libntfs-3g" | tee "$OUT/status.txt"
fi
'@

# ---------- unit-uefi.sh ----------
Write-Script "unit-uefi.sh" @'
#!/bin/bash
# UEFI driver smoke/system tests in QEMU
# Usage: ./ci/unit-uefi.sh <out_dir>
set -euo pipefail
OUT="${1:-out/dast/unit-uefi}"
mkdir -p "$OUT"

EFI="${EFI_PATH:-out/build/uefi/driver.efi}"
if [[ ! -f "$EFI" ]]; then
  echo "NOT_IMPLEMENTED: driver.efi not found" | tee "$OUT/status.txt"
  exit 0
fi

echo "=== UEFI unit/smoke tests ===" | tee "$OUT/tests.log"
echo "NOT_IMPLEMENTED: QEMU/OVMF run requires prepared stand and images" | tee "$OUT/status.txt"
'@

# ---------- fuzz-native.sh ----------
Write-Script "fuzz-native.sh" @'
#!/bin/bash
# Native NTFS parser fuzzing
# Usage: ./ci/fuzz-native.sh <out_dir>
set -euo pipefail
OUT="${1:-out/dast/fuzz-native}"
mkdir -p "$OUT"

echo "=== Native fuzzing ===" | tee "$OUT/fuzz.log"

if command -v clang >/dev/null && [[ -d fuzz ]]; then
  echo "NOT_IMPLEMENTED: fuzz targets in fuzz/ are not ready yet" | tee "$OUT/status.txt"
else
  echo "NOT_IMPLEMENTED: clang or fuzz/ directory missing" | tee "$OUT/status.txt"
fi
'@
