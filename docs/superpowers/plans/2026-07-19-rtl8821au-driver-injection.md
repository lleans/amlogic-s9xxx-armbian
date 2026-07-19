# RTL8821AU Driver Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake the RTL8821AU Wi-Fi driver into a custom kernel package (published to this repo's own GitHub Releases), then build the final Armbian image against that kernel package, so the driver survives future `armbian-update` runs on the device — all without modifying a single file this project's upstream owns.

**Architecture:** Two new GitHub Actions workflows plus one new script. Stage 1 (`compile-kernel-with-wifi.yml`) compiles a kernel via the upstream `ophub/amlogic-s9xxx-armbian@main` action, then a new script (`inject-driver.sh`) extracts the produced `modules-*.tar.gz`, cross-compiles `8821au.ko` against the matching `header-*.tar.gz`, injects it, regenerates `modules.dep` with `depmod -b`, and re-packages the tarball before it's uploaded to this repo's Releases. Stage 2 (`build-armbian-with-wifi.yml`) downloads ophub's own latest published base image and rebuilds it via the same upstream action, pointed at this repo as `kernel_repo`, producing the final image.

**Tech Stack:** Bash (`set -euo pipefail`), GitHub Actions (`ophub/amlogic-s9xxx-armbian@main`, `ophub/upload-to-releases@main`), `depmod`/`tar`/cross-gcc toolchain, Docker (`ubuntu:24.04` + `kmod`) for local verification since `depmod` isn't available on macOS, `rhysd/actionlint` (via Docker) for workflow YAML validation.

## Global Constraints

- No existing file this project's upstream owns may ever be modified — every deliverable in this plan is a new file. (spec: Goals/Non-goals)
- Do not run `git add`/`git commit` at any point — leave everything as uncommitted working-tree changes. (explicit user instruction)
- The kernel version used to compile the driver and the kernel version shipped in the final image must always be identical — achieved by having Stage 1 inject the driver into the exact same run's own output, never by independently re-resolving a version. (spec: Goals)
- `kernel_repo` for the OS-image build stage must point at this repo (`${{ github.repository }}`), never the stock `ophub/kernel` — this is what makes the driver survive `armbian-update` on the device. (spec: Problem)
- Board, OS release, and kernel family must be `workflow_dispatch` inputs with sensible defaults (board `s905x`, release `trixie`, kernel family `6.12.y`), not hardcoded. (spec: Goals; user confirmation)
- No full Armbian-from-source compile — the OS-image stage downloads ophub's already-published base image instead of cloning `armbian/build` and running `compile.sh`. (spec: Goals)

---

## File Structure

```
upstream/  (working directory — this repo)
├── driver-injection/
│   └── 8821au/
│       ├── lib/
│       │   ├── package.sh          # Task 1 — pure tarball/depmod operations, no network
│       │   └── package.test.sh     # Task 1 — local fixture test for package.sh
│       ├── inject-driver.sh        # Task 2 — orchestrator: toolchain, clone, build, calls package.sh
│       └── inject-driver.test.sh   # Task 2 — end-to-end DRY_RUN fixture test
└── .github/
    └── workflows/
        ├── compile-kernel-with-wifi.yml   # Task 3 — Stage 1
        └── build-armbian-with-wifi.yml    # Task 4 — Stage 2
```

- `lib/package.sh` is split out from `inject-driver.sh` because it's the part that can be fully unit-tested locally (pure filesystem operations); `inject-driver.sh` layers network/compilation on top and is only testable end-to-end via its `DRY_RUN` escape hatch.
- Both `.test.sh` files ship alongside the code they test (not in a separate `tests/` tree) — this project has no existing test directory convention to follow, and colocated tests are easiest to find given the small number of files.

### Verified facts this plan's code depends on

Confirmed directly from `compile-kernel/tools/script/armbian_compile_kernel.sh`'s `packit_kernel()` function before writing any code below — do not re-derive, use as given:

- `modules-<kernel_name>.tar.gz` is created by `cd .../modules/lib/modules && tar -czf modules-<kernel_name>.tar.gz *` — its root is the kernel-version directory itself (e.g. `6.12.34-ophub/...`), **not** `lib/modules/6.12.34-ophub/...`. Code that extracts or repackages this tarball must re-nest/un-nest the `lib/modules/` prefix manually; `depmod -b <root> <version>` requires `<root>/lib/modules/<version>/...` to exist on disk.
- `header-<kernel_name>.tar.gz` is created by `cd .../header && tar -czf header-<kernel_name>.tar.gz *` — its root is the kernel source/build tree directly. The extraction directory itself is what `KSRC` should point at (no `usr/src/linux-headers-*` nesting inside this tarball format).
- Confirmed via a real Docker run: `depmod -b <root> <version>` exits `0` even against a non-ELF placeholder file, only printing warnings to stderr, and still writes a `modules.dep` entry for it. This is what makes the local fixture tests below possible without a real compiled `.ko`.
- The driver's own `Makefile` (`8821au-20210708/Makefile`) sets `KSRC := /lib/modules/$(KVER)/build` using `:=`, which environment-exported `KSRC` cannot override — GNU Make command-line variable arguments (`make KSRC=...`) always win over in-Makefile assignments, so `ARCH`, `CROSS_COMPILE`, `KVER`, and `KSRC` must be passed as `make` arguments, not `export`ed.

---

### Task 1: Packaging library (`lib/package.sh`)

**Files:**
- Create: `driver-injection/8821au/lib/package.sh`
- Create: `driver-injection/8821au/lib/package.test.sh`

**Interfaces:**
- Produces (consumed by Task 2):
  - `kernel_name_from_modules_tarball(path) -> stdout: kernel_name`
  - `extract_modules_tarball(tarball_path, dest_dir)` — after this call, `dest_dir/lib/modules/<kernel_name>/...` exists.
  - `extract_header_tarball(tarball_path, dest_dir)` — after this call, `dest_dir` itself contains the kernel source/build tree (this is what `KSRC` should point at).
  - `inject_module(extract_root, kernel_name, ko_path)` — copies `ko_path` to `extract_root/lib/modules/<kernel_name>/kernel/drivers/net/wireless/8821au.ko` and writes `extract_root/lib/modules/<kernel_name>/modules.d/rtl8821au.conf` containing `8821au`.
  - `refresh_depmod(extract_root, kernel_name)` — runs `depmod -b extract_root kernel_name`.
  - `repackage_modules_tarball(extract_root, kernel_name, tarball_path)` — writes `tarball_path` rooted at `kernel_name/...` (matching upstream's own packing convention).

- [ ] **Step 1: Write the failing test**

Create `driver-injection/8821au/lib/package.test.sh`:

```bash
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

echo "All package.sh tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
docker run --rm -v "/Users/lleans/Documents/untitled folder/upstream:/work" -w /work ubuntu:24.04 bash -c \
  "apt-get update -qq && apt-get install -y -qq kmod && bash driver-injection/8821au/lib/package.test.sh"
```
Expected: FAIL — `package.sh: No such file or directory` (the `source` line fails, since `package.sh` doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `driver-injection/8821au/lib/package.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
docker run --rm -v "/Users/lleans/Documents/untitled folder/upstream:/work" -w /work ubuntu:24.04 bash -c \
  "apt-get update -qq && apt-get install -y -qq kmod && bash driver-injection/8821au/lib/package.test.sh"
```
Expected: PASS — output ends with `All package.sh tests passed.`

- [ ] **Step 5: Syntax-check both files**

Run: `bash -n driver-injection/8821au/lib/package.sh && bash -n driver-injection/8821au/lib/package.test.sh`
Expected: no output, exit code `0`.

- [ ] **Step 6: Confirm nothing is committed**

Run: `git status --short driver-injection/`
Expected: both new files listed with `??` (untracked). Do **not** run `git add` or `git commit`.

---

### Task 2: Driver build orchestrator (`inject-driver.sh`)

**Files:**
- Create: `driver-injection/8821au/inject-driver.sh`
- Create: `driver-injection/8821au/inject-driver.test.sh`

**Interfaces:**
- Consumes (from Task 1): `driver-injection/8821au/lib/package.sh` — all five functions listed in Task 1's Interfaces block.
- Produces (consumed by Task 3): a script invocable as `KERNEL_OUTPUT_DIR=<dir> bash driver-injection/8821au/inject-driver.sh`, which mutates every `modules-*.tar.gz` in `KERNEL_OUTPUT_DIR` in place to include the compiled driver. Supports `DRY_RUN=1` to skip real compilation (writes a placeholder file instead) for local/offline testing. Exits non-zero on any failure (missing header tarball, failed clone/build, no modules tarballs found at all).

- [ ] **Step 1: Write the failing test**

Create `driver-injection/8821au/inject-driver.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
docker run --rm -v "/Users/lleans/Documents/untitled folder/upstream:/work" -w /work ubuntu:24.04 bash -c \
  "apt-get update -qq && apt-get install -y -qq kmod git curl && bash driver-injection/8821au/inject-driver.test.sh"
```
Expected: FAIL — `inject-driver.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `driver-injection/8821au/inject-driver.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
docker run --rm -v "/Users/lleans/Documents/untitled folder/upstream:/work" -w /work ubuntu:24.04 bash -c \
  "apt-get update -qq && apt-get install -y -qq kmod git curl && bash driver-injection/8821au/inject-driver.test.sh"
```
Expected: PASS — output ends with `All inject-driver.sh tests passed.`

- [ ] **Step 5: Syntax-check both files**

Run: `bash -n driver-injection/8821au/inject-driver.sh && bash -n driver-injection/8821au/inject-driver.test.sh`
Expected: no output, exit code `0`.

- [ ] **Step 6: Confirm nothing is committed**

Run: `git status --short driver-injection/`
Expected: new files listed with `??`. Do **not** run `git add` or `git commit`.

---

### Task 3: Stage 1 workflow (`compile-kernel-with-wifi.yml`)

**Files:**
- Create: `.github/workflows/compile-kernel-with-wifi.yml`

**Interfaces:**
- Consumes (from Task 2): `driver-injection/8821au/inject-driver.sh`, invoked with `KERNEL_OUTPUT_DIR=compile-kernel/output` (its default — no override needed).
- Produces (consumed by Task 4): a GitHub Release on this repo tagged `kernel_<kernel_usage>` (default `kernel_stable`) containing `header-*.tar.gz` / `boot-*.tar.gz` / `dtb-*.tar.gz` / `modules-*.tar.gz` (the last one mutated by Task 2's script), which Task 4's workflow references via `kernel_repo: ${{ github.repository }}`.

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/compile-kernel-with-wifi.yml`:

```yaml
#==========================================================================
# Description: Compile a kernel with the RTL8821AU Wi-Fi driver baked in
#
# New, isolated addition — does not modify any upstream workflow. See
# docs/superpowers/specs/2026-07-19-rtl8821au-driver-injection-design.md
#==========================================================================

name: Compile kernel with Wi-Fi driver

on:
  workflow_dispatch:
    inputs:
      kernel_source:
        description: "Kernel source code repository."
        required: false
        default: "unifreq"
        type: string
      kernel_version:
        description: "Kernel version (family, e.g. 6.12.y)."
        required: false
        default: "6.12.y"
        type: string
      kernel_auto:
        description: "Automatically use the latest version in the series."
        required: false
        default: true
        type: boolean
      kernel_usage:
        description: "Tag suffix for the published kernel release."
        required: false
        default: "stable"
        type: choice
        options:
          - stable
          - flippy
          - beta
      kernel_toolchain:
        description: "Kernel compilation toolchain."
        required: false
        default: "gcc"
        type: string
  schedule:
    - cron: "0 18 * * 0"

concurrency:
  group: compile-kernel-with-wifi
  cancel-in-progress: false

permissions:
  contents: write

env:
  TZ: Etc/UTC

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Compile kernel
        uses: ophub/amlogic-s9xxx-armbian@main
        with:
          build_target: kernel
          kernel_source: ${{ inputs.kernel_source || 'unifreq' }}
          kernel_version: ${{ inputs.kernel_version || '6.12.y' }}
          kernel_auto: ${{ inputs.kernel_auto == false && 'false' || 'true' }}
          kernel_toolchain: ${{ inputs.kernel_toolchain || 'gcc' }}

      - name: Inject RTL8821AU driver into kernel modules package
        run: |
          chmod +x driver-injection/8821au/inject-driver.sh
          KERNEL_OUTPUT_DIR=compile-kernel/output driver-injection/8821au/inject-driver.sh

      - name: Upload kernel packages to Release
        uses: ophub/upload-to-releases@main
        with:
          tag: kernel_${{ inputs.kernel_usage || 'stable' }}
          artifacts: ${{ env.PACKAGED_OUTPUTPATH }}/*
          allow_updates: true
          remove_artifacts: false
          replaces_artifacts: true
          make_latest: false
          gh_token: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: Run actionlint against the new workflow**

Run:
```bash
docker run --rm -v "/Users/lleans/Documents/untitled folder/upstream:/repo" rhysd/actionlint:latest -color "/repo/.github/workflows/compile-kernel-with-wifi.yml"
```
Expected: either no output (clean) or only `shellcheck`-style `info`/`warning` lines (matching the noise level already present in upstream's own workflows — confirmed during design research). Any `error`-level finding must be fixed before continuing.

- [ ] **Step 3: Fix any actionlint findings, then re-run Step 2 until clean of errors**

- [ ] **Step 4: Manual checklist review against the design spec**

Confirm each of the following by reading the file:
- [ ] `build_target: kernel` step comes before the `inject-driver.sh` step, which comes before the upload step (ordering matches the data-flow diagram in the design spec).
- [ ] The upload tag is `kernel_<kernel_usage>` — matches the convention `rebuild`'s own `download_kernel()` expects (`kernel_${key}` where `key` is `kernel_usage`).
- [ ] `kernel_auto`, `kernel_version`, `kernel_usage`, `kernel_toolchain` are all `workflow_dispatch` inputs, not hardcoded, satisfying "board/release/kernel family configurable."
- [ ] `schedule.cron` is present (cron-schedulable, matching the existing project convention).
- [ ] `permissions.contents: write` is present (required for `upload-to-releases`).

- [ ] **Step 5: Confirm nothing is committed**

Run: `git status --short .github/workflows/`
Expected: `compile-kernel-with-wifi.yml` listed with `??`. Do **not** run `git add` or `git commit`.

---

### Task 4: Stage 2 workflow (`build-armbian-with-wifi.yml`)

**Files:**
- Create: `.github/workflows/build-armbian-with-wifi.yml`

**Interfaces:**
- Consumes (from Task 3): this repo's own Releases tagged `kernel_<kernel_usage>`, referenced via `kernel_repo: ${{ github.repository }}` — no direct file/function dependency, only the published release artifacts.
- Produces: the final Armbian `.img.gz` for the configured board/release, uploaded to this repo's Releases.

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/build-armbian-with-wifi.yml`:

```yaml
#==========================================================================
# Description: Build the Armbian OS image using the custom kernel from
# compile-kernel-with-wifi.yml (RTL8821AU driver baked in)
#
# New, isolated addition — does not modify any upstream workflow. See
# docs/superpowers/specs/2026-07-19-rtl8821au-driver-injection-design.md
#==========================================================================

name: Build Armbian with Wi-Fi driver

on:
  workflow_dispatch:
    inputs:
      set_release:
        description: "OS release."
        required: false
        default: "trixie"
        type: choice
        options:
          - trixie
          - bookworm
          - resolute
          - noble
      armbian_board:
        description: "Target device board."
        required: false
        default: "s905x"
        type: string
      armbian_kernel:
        description: "Kernel version (family, e.g. 6.12.y)."
        required: false
        default: "6.12.y"
        type: string
      kernel_usage:
        description: "Tag suffix the custom kernel was published under."
        required: false
        default: "stable"
        type: choice
        options:
          - stable
          - flippy
          - beta
      armbian_fstype:
        description: "Armbian rootfs type."
        required: false
        default: "ext4"
        type: choice
        options:
          - ext4
          - btrfs
      builder_name:
        description: "Armbian builder signature."
        required: false
        default: "ophub"
        type: string
  schedule:
    - cron: "0 20 * * 0"
  workflow_run:
    workflows: ["Compile kernel with Wi-Fi driver"]
    types:
      - completed

concurrency:
  group: build-armbian-with-wifi
  cancel-in-progress: false

permissions:
  contents: write

env:
  TZ: Etc/UTC

jobs:
  build:
    if: ${{ github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Download latest Armbian base image from ophub
        id: down
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SET_RELEASE: ${{ inputs.set_release || 'trixie' }}
        run: |
          mkdir -p build/output/images

          latest_asset=$(curl -fsSL \
              -H "Accept: application/vnd.github+json" \
              -H "Authorization: Bearer ${GH_TOKEN}" \
              "https://api.github.com/repos/ophub/amlogic-s9xxx-armbian/releases?per_page=30" | \
              jq -r --arg RTK "Armbian_${SET_RELEASE}_arm64_" \
              --arg BOARD "-trunk_" \
              '[.[] | select(.tag_name | contains($RTK))] |
              map(.assets[] | select(.name | contains($BOARD) and endswith(".img.gz"))) |
              sort_by(.updated_at) | reverse | .[0] |
              {url: .url, name: .name}')

          if [[ -z "${latest_asset}" || "${latest_asset}" == "null" ]]; then
              echo "::error::Failed to resolve a base Armbian image for release [ ${SET_RELEASE} ]"
              exit 1
          fi

          asset_url="$(echo "${latest_asset}" | jq -r '.url')"
          asset_name="$(echo "${latest_asset}" | jq -r '.name')"
          echo "Downloading: ${asset_name}"
          curl -fsSL \
               -H "Authorization: Bearer ${GH_TOKEN}" \
               -H "Accept: application/octet-stream" \
               "${asset_url}" -o "build/output/images/${asset_name}"

          echo "asset_name=${asset_name}" >> "${GITHUB_OUTPUT}"

      - name: Rebuild Armbian with custom kernel
        uses: ophub/amlogic-s9xxx-armbian@main
        with:
          build_target: armbian
          armbian_path: build/output/images/*.img.gz
          armbian_board: ${{ inputs.armbian_board || 's905x' }}
          armbian_kernel: ${{ inputs.armbian_kernel || '6.12.y' }}
          auto_kernel: true
          kernel_repo: ${{ github.repository }}
          kernel_usage: ${{ inputs.kernel_usage || 'stable' }}
          armbian_fstype: ${{ inputs.armbian_fstype || 'ext4' }}
          builder_name: ${{ inputs.builder_name || 'ophub' }}

      - name: Upload Armbian image to Release
        uses: ophub/upload-to-releases@main
        if: ${{ env.PACKAGED_STATUS == 'success' }}
        with:
          tag: Armbian_${{ inputs.set_release || 'trixie' }}_arm64_wifi
          artifacts: ${{ env.PACKAGED_OUTPUTPATH }}/*
          allow_updates: true
          remove_artifacts: false
          replaces_artifacts: true
          make_latest: true
          gh_token: ${{ secrets.GITHUB_TOKEN }}
          body: |
            ### Armbian Image Information (RTL8821AU Wi-Fi driver included)
            - Default username: `root`
            - Default password: `1234`
            - Install command: `armbian-install`
```

- [ ] **Step 2: Run actionlint against the new workflow**

Run:
```bash
docker run --rm -v "/Users/lleans/Documents/untitled folder/upstream:/repo" rhysd/actionlint:latest -color "/repo/.github/workflows/build-armbian-with-wifi.yml"
```
Expected: no `error`-level findings (matching the same bar as Task 3, Step 2).

- [ ] **Step 3: Fix any actionlint findings, then re-run Step 2 until clean of errors**

- [ ] **Step 4: Manual checklist review against the design spec**

Confirm each of the following by reading the file:
- [ ] There is no step that clones `armbian/build` or runs `compile.sh` — the base image comes only from `ophub/amlogic-s9xxx-armbian`'s own Releases via the GitHub API (satisfies "no full Armbian-from-source compile").
- [ ] `kernel_repo: ${{ github.repository }}` — not `ophub/kernel` and not a hardcoded owner/repo string (satisfies "driver persists across `armbian-update`" and "works under whatever name this gets pushed as").
- [ ] `armbian_files` is not set — the driver comes from the kernel package now, no overlay needed (matches the revised Option A design; an overlay here would indicate the design reverted without updating this file).
- [ ] `set_release`, `armbian_board`, `armbian_kernel`, `kernel_usage`, `armbian_fstype`, `builder_name` are all `workflow_dispatch` inputs with the confirmed defaults (`trixie`, `s905x`, `6.12.y`, `stable`, `ext4`, `ophub`).
- [ ] Both `schedule.cron` and `workflow_run` (chained after Stage 1) triggers are present.
- [ ] `permissions.contents: write` is present.

- [ ] **Step 5: Confirm nothing is committed**

Run: `git status --short .github/workflows/`
Expected: `build-armbian-with-wifi.yml` listed with `??`. Do **not** run `git add` or `git commit`.

---

## Final verification (informational — cannot run locally)

Once pushed to a real GitHub repository (out of scope for this plan — the user has only asked for uncommitted local changes), the following manual checks from the design spec's "Testing / verification" section confirm the whole pipeline end-to-end:

1. Manually dispatch `compile-kernel-with-wifi.yml`, then inspect the uploaded `modules-*.tar.gz` to confirm it contains `8821au.ko` and an updated `modules.dep` referencing it.
2. Manually dispatch `build-armbian-with-wifi.yml`, flash the resulting image, and confirm `lsmod | grep 8821au` after boot with the dongle attached.
3. Run `armbian-update` on a device with `KERNEL_REPO` pointed at this repo and confirm the driver is still present afterward.
