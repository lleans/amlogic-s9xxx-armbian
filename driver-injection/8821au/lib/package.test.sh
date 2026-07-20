#!/usr/bin/env bash
# driver-injection/8821au/lib/package.test.sh
#
# Local fixture test for lib/package.sh. Builds a fake modules-*.tar.gz +
# header-*.tar.gz pair matching the exact layout armbian_compile_kernel.sh
# actually produces, injects a placeholder .ko, and verifies depmod picks
# it up and the tarball comes back out correctly shaped.
#
# depmod isn't available on macOS - run this inside a Linux container:
#   docker run --rm -v "$PWD":/work -w /work ubuntu:24.04 bash -c \
#     "apt-get update -qq && apt-get install -y -qq kmod && bash driver-injection/8821au/lib/package.test.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/package.sh"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT

KERNEL_NAME="6.12.34-test"
FAKE_MODULES_SRC="${FIXTURE_DIR}/fake-modules-src"
FAKE_HEADER_SRC="${FIXTURE_DIR}/fake-header-src"

# modules-*.tar.gz is tarred from inside ".../modules/lib/modules", so its
# root IS the kernel version directory - reproduce that exactly.
mkdir -p "${FAKE_MODULES_SRC}/${KERNEL_NAME}/kernel/drivers/net/wifi"
echo "existing module" > "${FAKE_MODULES_SRC}/${KERNEL_NAME}/kernel/drivers/net/wifi/placeholder.ko"
( cd "${FAKE_MODULES_SRC}" && tar -czf "${FIXTURE_DIR}/modules-${KERNEL_NAME}.tar.gz" "${KERNEL_NAME}" )

mkdir -p "${FAKE_HEADER_SRC}"
echo "fake kernel source tree" > "${FAKE_HEADER_SRC}/Makefile"
( cd "${FAKE_HEADER_SRC}" && tar -czf "${FIXTURE_DIR}/header-${KERNEL_NAME}.tar.gz" . )

FAKE_KO="${FIXTURE_DIR}/8821au.ko"
echo "fake compiled module (not a real ELF)" > "${FAKE_KO}"

EXTRACT_ROOT="${FIXTURE_DIR}/extract"

echo "test: kernel_name_from_modules_tarball"
name="$(kernel_name_from_modules_tarball "${FIXTURE_DIR}/modules-${KERNEL_NAME}.tar.gz")"
[[ "${name}" == "${KERNEL_NAME}" ]] || { echo "FAIL: expected ${KERNEL_NAME}, got ${name}"; exit 1; }
echo "  ok"

echo "test: extract_modules_tarball reconstructs lib/modules layout"
extract_modules_tarball "${FIXTURE_DIR}/modules-${KERNEL_NAME}.tar.gz" "${EXTRACT_ROOT}"
[[ -f "${EXTRACT_ROOT}/lib/modules/${KERNEL_NAME}/kernel/drivers/net/wifi/placeholder.ko" ]] || { echo "FAIL: existing module missing after extraction"; exit 1; }
echo "  ok"

echo "test: extract_header_tarball extracts flat (dest_dir IS the source tree root)"
HEADER_EXTRACT="${FIXTURE_DIR}/header-extract"
extract_header_tarball "${FIXTURE_DIR}/header-${KERNEL_NAME}.tar.gz" "${HEADER_EXTRACT}"
[[ -f "${HEADER_EXTRACT}/Makefile" ]] || { echo "FAIL: expected Makefile directly under dest_dir, not nested"; exit 1; }
echo "  ok"

echo "test: inject_module places the .ko and modules.d entry"
inject_module "${EXTRACT_ROOT}" "${KERNEL_NAME}" "${FAKE_KO}"
[[ -f "${EXTRACT_ROOT}/lib/modules/${KERNEL_NAME}/kernel/drivers/net/wireless/8821au.ko" ]] || { echo "FAIL: 8821au.ko not injected"; exit 1; }
[[ "$(cat "${EXTRACT_ROOT}/lib/modules/${KERNEL_NAME}/modules.d/rtl8821au.conf")" == "8821au" ]] || { echo "FAIL: modules.d autoload entry wrong"; exit 1; }
echo "  ok"

echo "test: refresh_depmod records the injected module"
refresh_depmod "${EXTRACT_ROOT}" "${KERNEL_NAME}"
grep -q "kernel/drivers/net/wireless/8821au.ko" "${EXTRACT_ROOT}/lib/modules/${KERNEL_NAME}/modules.dep" || { echo "FAIL: modules.dep missing 8821au entry"; exit 1; }
echo "  ok"

echo "test: repackage_modules_tarball rebuilds a tarball rooted at the kernel name"
REPACKAGED="${FIXTURE_DIR}/modules-${KERNEL_NAME}.repackaged.tar.gz"
repackage_modules_tarball "${EXTRACT_ROOT}" "${KERNEL_NAME}" "${REPACKAGED}"
[[ -f "${REPACKAGED}" ]] || { echo "FAIL: repackaged tarball missing"; exit 1; }
tar -tzf "${REPACKAGED}" | grep -q "^${KERNEL_NAME}/kernel/drivers/net/wireless/8821au.ko$" || { echo "FAIL: repackaged tarball missing injected module at expected path"; exit 1; }
echo "  ok"

echo "test: extract_combined_tarball unwraps the published <kernel_version>.tar.gz"
COMBINED_SRC="${FIXTURE_DIR}/combined-src/${KERNEL_NAME}"
mkdir -p "${COMBINED_SRC}"
cp "${FIXTURE_DIR}/modules-${KERNEL_NAME}.tar.gz" "${FIXTURE_DIR}/header-${KERNEL_NAME}.tar.gz" "${COMBINED_SRC}/"
( cd "${COMBINED_SRC}" && sha256sum ./*.tar.gz > sha256sums )
( cd "${FIXTURE_DIR}/combined-src" && tar -czf "${FIXTURE_DIR}/${KERNEL_NAME}.tar.gz" "${KERNEL_NAME}" )

COMBINED_UNWRAP="${FIXTURE_DIR}/combined-unwrap"
extract_combined_tarball "${FIXTURE_DIR}/${KERNEL_NAME}.tar.gz" "${COMBINED_UNWRAP}"
[[ -f "${COMBINED_UNWRAP}/${KERNEL_NAME}/modules-${KERNEL_NAME}.tar.gz" ]] || { echo "FAIL: modules tarball missing after combined-tarball extraction"; exit 1; }
[[ -f "${COMBINED_UNWRAP}/${KERNEL_NAME}/sha256sums" ]] || { echo "FAIL: sha256sums missing after combined-tarball extraction"; exit 1; }
echo "  ok"

echo "test: regenerate_combined_sha256sums recomputes sums matching the directory contents"
echo "tampered" >> "${COMBINED_UNWRAP}/${KERNEL_NAME}/modules-${KERNEL_NAME}.tar.gz" 2>/dev/null || true
regenerate_combined_sha256sums "${COMBINED_UNWRAP}/${KERNEL_NAME}"
( cd "${COMBINED_UNWRAP}/${KERNEL_NAME}" && sha256sum -c sha256sums --quiet ) || { echo "FAIL: regenerated sha256sums do not verify"; exit 1; }
echo "  ok"

echo "test: repackage_combined_tarball rebuilds a tarball rooted at the kernel version"
REPACKAGED_COMBINED="${FIXTURE_DIR}/${KERNEL_NAME}.repackaged.tar.gz"
repackage_combined_tarball "${COMBINED_UNWRAP}" "${KERNEL_NAME}" "${REPACKAGED_COMBINED}"
tar -tzf "${REPACKAGED_COMBINED}" | grep -q "^${KERNEL_NAME}/modules-${KERNEL_NAME}.tar.gz$" || { echo "FAIL: repackaged combined tarball missing nested modules tarball"; exit 1; }
echo "  ok"

echo "All package.sh tests passed."
