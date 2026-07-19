#!/usr/bin/env bash
# driver-injection/8821au/inject-driver.sh
#
# Bakes the RTL8821AU Wi-Fi driver into the kernel modules package produced
# by "ophub/amlogic-s9xxx-armbian@main" (build_target: kernel). Run this as
# a step immediately after that action, before uploading the kernel
# packages to Releases.
#
# Env vars:
#   KERNEL_OUTPUT_DIR  Directory containing header-*.tar.gz / modules-*.tar.gz
#                       (default: compile-kernel/output)
#   DRIVER_REPO         Driver source repository
#   TOOLCHAIN_URL       Cross toolchain tarball URL
#   TOOLCHAIN_DIR       Where to cache/extract the toolchain
#   DRY_RUN             If "1", skip the actual clone/compile and use a
#                       placeholder .ko instead (for local testing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/package.sh
source "${SCRIPT_DIR}/lib/package.sh"

KERNEL_OUTPUT_DIR="${KERNEL_OUTPUT_DIR:-compile-kernel/output}"
DRIVER_REPO="${DRIVER_REPO:-https://github.com/morrownr/8821au-20210708}"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-https://github.com/ophub/kernel/releases/download/dev/arm-gnu-toolchain-15.3.rel1-aarch64-aarch64-none-linux-gnu.tar.xz}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-/usr/local/toolchain}"
DRY_RUN="${DRY_RUN:-0}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

log() { echo "[inject-driver] $*"; }
die() { echo "[inject-driver] ERROR: $*" >&2; exit 1; }

setup_toolchain() {
    local archive_name toolchain_root
    archive_name="$(basename "${TOOLCHAIN_URL}")"
    toolchain_root="${TOOLCHAIN_DIR}/${archive_name%.tar.xz}"

    if [[ -d "${toolchain_root}" ]]; then
        log "Toolchain already present at ${toolchain_root}"
    else
        log "Downloading toolchain from ${TOOLCHAIN_URL}"
        mkdir -p "${TOOLCHAIN_DIR}"
        curl -fsSL "${TOOLCHAIN_URL}" -o "${TOOLCHAIN_DIR}/${archive_name}"
        tar -Jxf "${TOOLCHAIN_DIR}/${archive_name}" -C "${TOOLCHAIN_DIR}"
        rm -f "${TOOLCHAIN_DIR}/${archive_name}"
    fi
    echo "${toolchain_root}"
}

# build_driver <kernel_name> <ksrc_dir> <out_ko_path>
build_driver() {
    local kernel_name="${1}" ksrc="${2}" out_ko="${3}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        log "DRY_RUN=1: writing placeholder .ko instead of compiling"
        printf 'dry-run placeholder module\n' > "${out_ko}"
        return 0
    fi

    local toolchain_root
    toolchain_root="$(setup_toolchain)"

    local src_dir="${WORK_DIR}/8821au-src-${kernel_name}"
    log "Cloning ${DRIVER_REPO}"
    git clone --depth=1 "${DRIVER_REPO}" "${src_dir}"

    # ARCH/CROSS_COMPILE/KVER/KSRC must be passed as make command-line
    # arguments, not exported env vars: the driver's own Makefile assigns
    # KSRC with ":=" internally, which only a command-line argument (not an
    # environment variable) can override.
    (
        cd "${src_dir}"
        make ARCH=arm64 \
             CROSS_COMPILE="${toolchain_root}/bin/aarch64-none-linux-gnu-" \
             KVER="${kernel_name}" \
             KSRC="${ksrc}" \
             -j"$(nproc)"
    )

    [[ -f "${src_dir}/8821au.ko" ]] || die "Build finished but 8821au.ko was not produced"
    cp -f "${src_dir}/8821au.ko" "${out_ko}"
}

# process_kernel <modules_tarball_path>
process_kernel() {
    local modules_tarball="${1}"
    local kernel_name header_tarball extract_dir header_dir ko_path

    kernel_name="$(kernel_name_from_modules_tarball "${modules_tarball}")"
    header_tarball="$(dirname "${modules_tarball}")/header-${kernel_name}.tar.gz"
    [[ -f "${header_tarball}" ]] || die "No matching header tarball for ${kernel_name} (expected ${header_tarball})"

    log "Processing kernel ${kernel_name}"

    extract_dir="${WORK_DIR}/${kernel_name}/modules"
    header_dir="${WORK_DIR}/${kernel_name}/header"
    ko_path="${WORK_DIR}/${kernel_name}/8821au.ko"

    extract_modules_tarball "${modules_tarball}" "${extract_dir}"
    extract_header_tarball "${header_tarball}" "${header_dir}"

    build_driver "${kernel_name}" "${header_dir}" "${ko_path}"
    inject_module "${extract_dir}" "${kernel_name}" "${ko_path}"
    refresh_depmod "${extract_dir}" "${kernel_name}"
    repackage_modules_tarball "${extract_dir}" "${kernel_name}" "${modules_tarball}"

    log "Injected 8821au driver into ${modules_tarball}"
}

main() {
    [[ -d "${KERNEL_OUTPUT_DIR}" ]] || die "KERNEL_OUTPUT_DIR not found: ${KERNEL_OUTPUT_DIR}"

    local found=0
    for modules_tarball in "${KERNEL_OUTPUT_DIR}"/modules-*.tar.gz; do
        [[ -f "${modules_tarball}" ]] || continue
        found=1
        process_kernel "${modules_tarball}"
    done

    [[ "${found}" -eq 1 ]] || die "No modules-*.tar.gz found in ${KERNEL_OUTPUT_DIR}"
}

main "$@"
