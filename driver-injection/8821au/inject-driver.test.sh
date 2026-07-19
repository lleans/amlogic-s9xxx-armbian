#!/usr/bin/env bash
# driver-injection/8821au/inject-driver.test.sh
#
# End-to-end DRY_RUN test of inject-driver.sh's orchestration (no real
# compilation - build_driver() short-circuits when DRY_RUN=1). Needs depmod,
# so run inside a Linux container:
#   docker run --rm -v "$PWD":/work -w /work ubuntu:24.04 bash -c \
#     "apt-get update -qq && apt-get install -y -qq kmod git curl && bash driver-injection/8821au/inject-driver.test.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT

KERNEL_NAME="6.12.34-test"
OUTPUT_DIR="${FIXTURE_DIR}/compile-kernel-output"
mkdir -p "${OUTPUT_DIR}"

MODULES_SRC_ROOT="${FIXTURE_DIR}/modules-src"
mkdir -p "${MODULES_SRC_ROOT}/${KERNEL_NAME}/kernel/drivers/net/wifi"
echo "existing module" > "${MODULES_SRC_ROOT}/${KERNEL_NAME}/kernel/drivers/net/wifi/placeholder.ko"
( cd "${MODULES_SRC_ROOT}" && tar -czf "${OUTPUT_DIR}/modules-${KERNEL_NAME}.tar.gz" "${KERNEL_NAME}" )

HEADER_SRC="${FIXTURE_DIR}/header-src"
mkdir -p "${HEADER_SRC}"
echo "fake kernel source tree" > "${HEADER_SRC}/Makefile"
( cd "${HEADER_SRC}" && tar -czf "${OUTPUT_DIR}/header-${KERNEL_NAME}.tar.gz" . )

echo "test: inject-driver.sh with DRY_RUN=1 injects a placeholder module end-to-end"
KERNEL_OUTPUT_DIR="${OUTPUT_DIR}" DRY_RUN=1 bash "${SCRIPT_DIR}/inject-driver.sh"

VERIFY_DIR="${FIXTURE_DIR}/verify"
mkdir -p "${VERIFY_DIR}/lib/modules"
tar -xzf "${OUTPUT_DIR}/modules-${KERNEL_NAME}.tar.gz" -C "${VERIFY_DIR}/lib/modules"

[[ -f "${VERIFY_DIR}/lib/modules/${KERNEL_NAME}/kernel/drivers/net/wireless/8821au.ko" ]] || { echo "FAIL: 8821au.ko missing from repackaged tarball"; exit 1; }
[[ -f "${VERIFY_DIR}/lib/modules/${KERNEL_NAME}/kernel/drivers/net/wifi/placeholder.ko" ]] || { echo "FAIL: pre-existing module was lost during injection"; exit 1; }
grep -q "kernel/drivers/net/wireless/8821au.ko" "${VERIFY_DIR}/lib/modules/${KERNEL_NAME}/modules.dep" || { echo "FAIL: modules.dep missing entry"; exit 1; }

echo "test: inject-driver.sh fails clearly when no modules-*.tar.gz exist"
EMPTY_DIR="${FIXTURE_DIR}/empty-output"
mkdir -p "${EMPTY_DIR}"
if KERNEL_OUTPUT_DIR="${EMPTY_DIR}" DRY_RUN=1 bash "${SCRIPT_DIR}/inject-driver.sh" 2>/dev/null; then
    echo "FAIL: expected non-zero exit when no modules tarballs are present"
    exit 1
fi

echo "test: inject-driver.sh fails clearly when a modules tarball has no matching header tarball"
MISMATCHED_DIR="${FIXTURE_DIR}/mismatched-output"
mkdir -p "${MISMATCHED_DIR}"
cp "${OUTPUT_DIR}/modules-${KERNEL_NAME}.tar.gz" "${MISMATCHED_DIR}/"
# Deliberately omit header-<kernel_name>.tar.gz from MISMATCHED_DIR.
if KERNEL_OUTPUT_DIR="${MISMATCHED_DIR}" DRY_RUN=1 bash "${SCRIPT_DIR}/inject-driver.sh" 2>/dev/null; then
    echo "FAIL: expected non-zero exit when the matching header tarball is missing"
    exit 1
fi

echo "All inject-driver.sh tests passed."
