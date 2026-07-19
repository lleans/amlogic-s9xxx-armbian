#!/usr/bin/env bash
# driver-injection/8821au/lib/package.sh
#
# Pure filesystem operations for injecting a compiled RTL8821AU .ko into an
# ophub kernel "modules-<kernel_name>.tar.gz" package. No network access, no
# compilation - safe to source and unit test with fixture tarballs.
set -euo pipefail

# kernel_name_from_modules_tarball <path>
# Prints the kernel version encoded in a "modules-<kernel_name>.tar.gz" filename.
kernel_name_from_modules_tarball() {
    local path="${1}"
    local base
    base="$(basename "${path}")"
    base="${base#modules-}"
    base="${base%.tar.gz}"
    echo "${base}"
}

# extract_modules_tarball <tarball_path> <dest_dir>
# modules-*.tar.gz is packed from inside ".../modules/lib/modules" (its root
# IS the kernel version directory - see packit_kernel() in
# armbian_compile_kernel.sh) - re-nest it under lib/modules/ on extraction so
# depmod -b sees the layout it expects: dest_dir/lib/modules/<kernel_name>/...
extract_modules_tarball() {
    local tarball="${1}" dest="${2}"
    mkdir -p "${dest}/lib/modules"
    tar -xzf "${tarball}" -C "${dest}/lib/modules"
}

# extract_header_tarball <tarball_path> <dest_dir>
# header-*.tar.gz is packed directly from the kernel source/build tree root -
# extract flat; dest_dir itself is what KSRC should point at.
extract_header_tarball() {
    local tarball="${1}" dest="${2}"
    mkdir -p "${dest}"
    tar -xzf "${tarball}" -C "${dest}"
}

# inject_module <extract_root> <kernel_name> <ko_path>
# Copies a compiled .ko into the extracted modules tree and adds an autoload
# entry, matching the modules.d convention already used in this project's
# kernel packages.
inject_module() {
    local extract_root="${1}" kernel_name="${2}" ko_path="${3}"
    local driver_dir="${extract_root}/lib/modules/${kernel_name}/kernel/drivers/net/wireless"
    local modules_d_dir="${extract_root}/lib/modules/${kernel_name}/modules.d"

    [[ -f "${ko_path}" ]] || { echo "inject_module: missing .ko at ${ko_path}" >&2; return 1; }

    mkdir -p "${driver_dir}" "${modules_d_dir}"
    cp -f "${ko_path}" "${driver_dir}/8821au.ko"
    echo "8821au" > "${modules_d_dir}/rtl8821au.conf"
}

# refresh_depmod <extract_root> <kernel_name>
# Regenerates modules.dep/alias maps for the extracted tree directly - no
# chroot or loop-mount needed, since depmod -b targets a plain directory.
refresh_depmod() {
    local extract_root="${1}" kernel_name="${2}"
    depmod -b "${extract_root}" "${kernel_name}"
}

# repackage_modules_tarball <extract_root> <kernel_name> <tarball_path>
# Re-tars the (now mutated) modules tree back into tarball_path, matching
# upstream's own packing convention exactly: tar root = the kernel version
# directory itself, no lib/modules/ prefix inside the archive.
repackage_modules_tarball() {
    local extract_root="${1}" kernel_name="${2}" tarball_path="${3}"
    tar -czf "${tarball_path}" -C "${extract_root}/lib/modules" "${kernel_name}"
}
