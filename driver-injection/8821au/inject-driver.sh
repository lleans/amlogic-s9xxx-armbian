#!/usr/bin/env bash
# driver-injection/8821au/inject-driver.sh
#
# Bakes the RTL8821AU Wi-Fi driver into the kernel package produced by
# "ophub/amlogic-s9xxx-armbian@main" (build_target: kernel). Run this as a
# step immediately after that action, before uploading to Releases.
#
# The action publishes one "<kernel_version>.tar.gz" per compiled kernel,
# wrapping a "<kernel_version>/" directory that holds the individual
# boot-/modules-/header-/dtb-*.tar.gz files plus a sha256sums file (see
# compile_selection() in armbian_compile_kernel.sh). This script unwraps
# that combined tarball, injects the driver into the nested modules
# tarball, regenerates sha256sums, and re-wraps it in place.
#
# Env vars:
#   KERNEL_OUTPUT_DIR  Directory containing "<kernel_version>.tar.gz" files.
#                       Must be set to the action's own
#                       ${{ env.PACKAGED_OUTPUTPATH }} (an absolute path
#                       under github.action_path, NOT github.workspace -
#                       the compile happens inside the action's own
#                       checkout, not the caller's).
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

# process_kernel <combined_tarball_path>
process_kernel() {
    local combined_tarball="${1}"
    local kernel_name unwrap_dir version_dir modules_tarball header_tarball
    local extract_dir header_dir ko_path

    kernel_name="$(basename "${combined_tarball}" .tar.gz)"
    log "Processing kernel ${kernel_name}"

    unwrap_dir="${WORK_DIR}/${kernel_name}/unwrap"
    extract_combined_tarball "${combined_tarball}" "${unwrap_dir}"

    version_dir="${unwrap_dir}/${kernel_name}"
    [[ -d "${version_dir}" ]] || die "Combined tarball ${combined_tarball} did not contain a ${kernel_name}/ directory"

    modules_tarball="${version_dir}/modules-${kernel_name}.tar.gz"
    header_tarball="${version_dir}/header-${kernel_name}.tar.gz"
    [[ -f "${modules_tarball}" ]] || die "No modules-${kernel_name}.tar.gz inside ${combined_tarball}"
    [[ -f "${header_tarball}" ]] || die "No header-${kernel_name}.tar.gz inside ${combined_tarball}"

    extract_dir="${WORK_DIR}/${kernel_name}/modules"
    header_dir="${WORK_DIR}/${kernel_name}/header"
    ko_path="${WORK_DIR}/${kernel_name}/8821au.ko"

    extract_modules_tarball "${modules_tarball}" "${extract_dir}"
    extract_header_tarball "${header_tarball}" "${header_dir}"

    build_driver "${kernel_name}" "${header_dir}" "${ko_path}"
    inject_module "${extract_dir}" "${kernel_name}" "${ko_path}"
    refresh_depmod "${extract_dir}" "${kernel_name}"
    repackage_modules_tarball "${extract_dir}" "${kernel_name}" "${modules_tarball}"

    regenerate_combined_sha256sums "${version_dir}"
    repackage_combined_tarball "${unwrap_dir}" "${kernel_name}" "${combined_tarball}"

    log "Injected 8821au driver into ${combined_tarball}"
}

main() {
    [[ -d "${KERNEL_OUTPUT_DIR}" ]] || die "KERNEL_OUTPUT_DIR not found: ${KERNEL_OUTPUT_DIR}"

    local found=0
    for combined_tarball in "${KERNEL_OUTPUT_DIR}"/*.tar.gz; do
        [[ -f "${combined_tarball}" ]] || continue
        [[ "$(basename "${combined_tarball}")" == deb-* ]] && continue
        found=1
        process_kernel "${combined_tarball}"
    done

    [[ "${found}" -eq 1 ]] || die "No <kernel_version>.tar.gz found in ${KERNEL_OUTPUT_DIR}"
}

main "$@"
