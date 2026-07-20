#!/usr/bin/env bash
# driver-injection/8821au/inject-driver.test.sh
#
# End-to-end DRY_RUN test of inject-driver.sh's orchestration (no real
# compilation - build_driver() short-circuits when DRY_RUN=1). Builds a
# fixture matching the actual published artifact: a single
# "<kernel_version>.tar.gz" wrapping a "<kernel_version>/" directory with
# the individual boot-/modules-/header-*.tar.gz files and a sha256sums
# file (see compile_selection() in armbian_compile_kernel.sh). Needs
# depmod, so run inside a Linux container:
#   docker run --rm -v "$PWD":/work -w /work ubuntu:24.04 bash -c \
#     "apt-get update -qq && apt-get install -y -qq kmod git curl && bash driver-injection/8821au/inject-driver.test.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT

KERNEL_NAME="6.12.34-test"
OUTPUT_DIR="${FIXTURE_DIR}/compile-kernel-output"
mkdir -p "${OUTPUT_DIR}"

build_combined_fixture() {
    local dest_dir="${1}" out_tarball_name="${2}"
    local version_dir="${FIXTURE_DIR}/combined-src/${KERNEL_NAME}"
    rm -rf "${FIXTURE_DIR}/combined-src"
    mkdir -p "${version_dir}"

    local modules_src="${FIXTURE_DIR}/modules-src"
    rm -rf "${modules_src}"
    mkdir -p "${modules_src}/${KERNEL_NAME}/kernel/drivers/net/wifi"
    echo "existing module" > "${modules_src}/${KERNEL_NAME}/kernel/drivers/net/wifi/placeholder.ko"
    ( cd "${modules_src}" && tar -czf "${version_dir}/modules-${KERNEL_NAME}.tar.gz" "${KERNEL_NAME}" )

    local header_src="${FIXTURE_DIR}/header-src"
    rm -rf "${header_src}"
    mkdir -p "${header_src}"
    echo "fake kernel source tree" > "${header_src}/Makefile"
    ( cd "${header_src}" && tar -czf "${version_dir}/header-${KERNEL_NAME}.tar.gz" . )

    ( cd "${version_dir}" && sha256sum ./*.tar.gz > sha256sums )
    ( cd "${FIXTURE_DIR}/combined-src" && tar -czf "${dest_dir}/${out_tarball_name}" "${KERNEL_NAME}" )
}

build_combined_fixture "${OUTPUT_DIR}" "${KERNEL_NAME}.tar.gz"
# A deb-*.tar.gz sibling must be ignored by the main() loop, matching
# upstream's own convention of publishing both alongside each other.
echo "fake deb bundle" > "${FIXTURE_DIR}/deb-payload"
tar -czf "${OUTPUT_DIR}/deb-${KERNEL_NAME}.tar.gz" -C "${FIXTURE_DIR}" deb-payload

echo "test: inject-driver.sh with DRY_RUN=1 injects a placeholder module end-to-end"
KERNEL_OUTPUT_DIR="${OUTPUT_DIR}" DRY_RUN=1 bash "${SCRIPT_DIR}/inject-driver.sh"

VERIFY_UNWRAP="${FIXTURE_DIR}/verify-unwrap"
mkdir -p "${VERIFY_UNWRAP}"
tar -xzf "${OUTPUT_DIR}/${KERNEL_NAME}.tar.gz" -C "${VERIFY_UNWRAP}"
VERIFY_VERSION_DIR="${VERIFY_UNWRAP}/${KERNEL_NAME}"

[[ -f "${VERIFY_VERSION_DIR}/modules-${KERNEL_NAME}.tar.gz" ]] || { echo "FAIL: nested modules tarball missing from repackaged combined tarball"; exit 1; }
[[ -f "${OUTPUT_DIR}/deb-${KERNEL_NAME}.tar.gz" ]] || { echo "FAIL: sibling deb-*.tar.gz was unexpectedly touched"; exit 1; }

( cd "${VERIFY_VERSION_DIR}" && sha256sum -c sha256sums --quiet ) || { echo "FAIL: repackaged sha256sums do not verify"; exit 1; }

VERIFY_MODULES="${FIXTURE_DIR}/verify-modules"
mkdir -p "${VERIFY_MODULES}/lib/modules"
tar -xzf "${VERIFY_VERSION_DIR}/modules-${KERNEL_NAME}.tar.gz" -C "${VERIFY_MODULES}/lib/modules"

[[ -f "${VERIFY_MODULES}/lib/modules/${KERNEL_NAME}/kernel/drivers/net/wireless/8821au.ko" ]] || { echo "FAIL: 8821au.ko missing from repackaged modules tarball"; exit 1; }
[[ -f "${VERIFY_MODULES}/lib/modules/${KERNEL_NAME}/kernel/drivers/net/wifi/placeholder.ko" ]] || { echo "FAIL: pre-existing module was lost during injection"; exit 1; }
grep -q "kernel/drivers/net/wireless/8821au.ko" "${VERIFY_MODULES}/lib/modules/${KERNEL_NAME}/modules.dep" || { echo "FAIL: modules.dep missing entry"; exit 1; }

echo "test: inject-driver.sh fails clearly when no <kernel_version>.tar.gz exist"
EMPTY_DIR="${FIXTURE_DIR}/empty-output"
mkdir -p "${EMPTY_DIR}"
if KERNEL_OUTPUT_DIR="${EMPTY_DIR}" DRY_RUN=1 bash "${SCRIPT_DIR}/inject-driver.sh" 2>/dev/null; then
    echo "FAIL: expected non-zero exit when no combined tarballs are present"
    exit 1
fi

echo "test: inject-driver.sh fails clearly when a combined tarball has no nested header tarball"
MISMATCHED_DIR="${FIXTURE_DIR}/mismatched-output"
mkdir -p "${MISMATCHED_DIR}/mismatched-src/${KERNEL_NAME}"
( cd "${FIXTURE_DIR}/combined-src/${KERNEL_NAME}" && cp modules-${KERNEL_NAME}.tar.gz "${MISMATCHED_DIR}/mismatched-src/${KERNEL_NAME}/" )
# Deliberately omit header-<kernel_name>.tar.gz from the nested version dir.
( cd "${MISMATCHED_DIR}/mismatched-src" && tar -czf "${MISMATCHED_DIR}/${KERNEL_NAME}.tar.gz" "${KERNEL_NAME}" )
if KERNEL_OUTPUT_DIR="${MISMATCHED_DIR}" DRY_RUN=1 bash "${SCRIPT_DIR}/inject-driver.sh" 2>/dev/null; then
    echo "FAIL: expected non-zero exit when the nested header tarball is missing"
    exit 1
fi

echo "All inject-driver.sh tests passed."
