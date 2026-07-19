# RTL8821AU Driver Injection — Design

## Problem

This repo (a fork of `ophub/amlogic-s9xxx-armbian`) previously carried the RTL8821AU
Wi-Fi driver support as a hand-edit inside
`compile-kernel/tools/script/armbian_compile_kernel_script.sh`. That file changes
upstream fairly often (toolchain bumps, refactors), so the fork drifted badly and
became hard to rebase. This design replaces that hand-edit with an isolated,
additive integration: new files only, nothing upstream owns is modified, so future
`git fetch upstream && git merge` stays conflict-free.

A second requirement surfaced during review: the driver must survive a live
`armbian-update` on the device. `armbian-update` persists `KERNEL_REPO` in
`/etc/ophub-release` and re-downloads the modules package from that repo on every
kernel update. If the driver isn't part of that package, an update silently wipes
it. So the driver must be baked into a kernel package published under a
`kernel_repo` we control, not bolted onto a finished OS image.

## Goals

- RTL8821AU support survives kernel updates performed on the device
  (`armbian-update`).
- No upstream file is ever modified — only new files/workflows are added.
- Kernel version used to compile the driver and the kernel version shipped in the
  final image are always identical (no separate version-resolution step that
  could drift).
- Board, OS release, and kernel family are configurable via `workflow_dispatch`
  inputs, not hardcoded.
- Both build stages (kernel, OS image) are cron-schedulable and auto-publish to
  GitHub Releases, matching the existing project convention.
- No full Armbian-from-source compile — reuse ophub's already-published base
  image instead of rebuilding it.

## Non-goals

- Not modifying any existing upstream script, workflow, or doc.
- Not maintaining a custom fork of the `morrownr/8821au-20210708` driver itself —
  it's cloned fresh from its canonical repo at build time.
- Not supporting devices/boards beyond what's configured (currently `s905x`,
  extensible via the existing board dropdown).

## Architecture

Two new GitHub Actions workflows plus one new helper script. Everything lives
under paths upstream doesn't own, so merges from upstream never conflict.

```
upstream/  (this repo — will become the pushed fork)
├── driver-injection/
│   └── 8821au/
│       └── inject-driver.sh          # NEW
└── .github/workflows/
    ├── compile-kernel-with-wifi.yml  # NEW
    └── build-armbian-with-wifi.yml   # NEW
```

### Stage 1 — `compile-kernel-with-wifi.yml`

Produces a kernel package (header/boot/dtb/modules tarballs) with the RTL8821AU
module already baked into the modules package, and publishes it to **this
repo's own** GitHub Releases under the tag convention the project already uses
(`kernel_<kernel_usage>`, e.g. `kernel_stable`). This repo then becomes a
drop-in `kernel_repo` for the OS build stage (and for `armbian-update` on the
device).

Steps:
1. Checkout.
2. `uses: ophub/amlogic-s9xxx-armbian@main` with `build_target: kernel` and the
   usual kernel inputs (`kernel_source`, `kernel_version`, `kernel_auto`,
   `kernel_toolchain`, etc. — exposed as `workflow_dispatch` inputs with the
   project's existing defaults, e.g. kernel family `6.12.y`).
3. Run `driver-injection/8821au/inject-driver.sh`, pointed at the action's
   output directory (`compile-kernel/output/`). For each
   `modules-<kernel_name>.tar.gz` produced, this script:
   - Extracts it alongside the matching `header-<kernel_name>.tar.gz` (also in
     that output directory — same run, so the versions are guaranteed to
     match; there's no separate version lookup to get wrong).
   - Downloads/reuses the cross-compilation toolchain referenced in the
     project's own docs (`documents/README.md` §9.3).
   - Shallow-clones `https://github.com/morrownr/8821au-20210708` and builds
     `8821au.ko` against the extracted headers (`KSRC` pointed at the
     extracted header tree, `ARCH=arm64`, matching cross `CROSS_COMPILE`).
   - Copies the resulting `.ko` into the extracted modules tree at
     `lib/modules/<kernel_name>/kernel/drivers/net/wireless/8821au.ko`, and
     adds `lib/modules/<kernel_name>/modules.d/rtl8821au.conf` containing
     `8821au` (matching the autoload convention already used elsewhere in this
     project).
   - Runs `depmod -b <extracted-modules-root> <kernel_name>` to regenerate
     `modules.dep`/alias maps for that tree directly — no chroot or loop-mount
     needed, since this operates on a plain directory tree, not a disk image.
   - Re-tars the modules directory back into
     `modules-<kernel_name>.tar.gz`, overwriting the original in
     `compile-kernel/output/`.
   - Idempotent: safe to re-run against the same output directory.
4. `uses: ophub/upload-to-releases@main`, uploading `compile-kernel/output/*`
   to this repo's Releases, tag `kernel_<kernel_usage>`.

Triggers: `workflow_dispatch` (all kernel params as inputs) + `schedule: cron`.

### Stage 2 — `build-armbian-with-wifi.yml`

Produces the final bootable OS image using the kernel package from Stage 1.

Steps:
1. Checkout.
2. Resolve and download the latest matching base image directly from
   `ophub/amlogic-s9xxx-armbian`'s own GitHub Releases (via the GitHub API,
   filtered by the selected `set_release`), the same technique upstream's own
   `build-armbian-using-releases-files.yml` uses for self-reuse, just pointed
   at ophub's repo instead of this one. This avoids ever compiling Armbian
   from source.
3. `uses: ophub/amlogic-s9xxx-armbian@main` with `build_target: armbian`,
   `armbian_path` set to the downloaded image, `armbian_board` (default
   `s905x`), `armbian_kernel` (default `6.12.y`), `auto_kernel: true`,
   `kernel_repo: ${{ github.repository }}` (this repo — dynamic, not
   hardcoded, so it works under whatever name/owner this ends up pushed as),
   `kernel_usage`, `armbian_fstype`, `builder_name`. No `armbian_files` overlay
   is needed — the driver is already inside the kernel package.
4. `uses: ophub/upload-to-releases@main`, uploading the produced image to this
   repo's Releases.

Triggers: `workflow_dispatch` (`set_release` dropdown: trixie/bookworm/resolute/
noble, default `trixie`; `armbian_board` dropdown, default `s905x`; kernel
family, `kernel_usage`, `armbian_fstype`, `builder_name`) + `schedule: cron`.

## Data flow

```
[Stage 1: compile-kernel-with-wifi.yml]
  ophub/amlogic-s9xxx-armbian@main (build_target: kernel)
    -> compile-kernel/output/{header,boot,dtb,modules}-<kernel_name>.tar.gz
    -> inject-driver.sh mutates modules-<kernel_name>.tar.gz in place
    -> upload-to-releases -> this repo's Releases (tag kernel_<usage>)

[Stage 2: build-armbian-with-wifi.yml]
  download latest ophub/amlogic-s9xxx-armbian release image (base rootfs)
    -> ophub/amlogic-s9xxx-armbian@main (build_target: armbian,
       kernel_repo: this repo)
    -> pulls kernel package from this repo's Releases (with driver baked in)
    -> produces final .img.gz
    -> upload-to-releases -> this repo's Releases

[Device]
  flashes final image -> boots with 8821au already loaded
  armbian-update (later) -> KERNEL_REPO is this repo -> driver persists
```

## Error handling

- `inject-driver.sh` exits non-zero (failing the workflow) if: no
  `modules-*.tar.gz` files are found, a matching `header-*.tar.gz` is missing
  for any modules tarball, the driver clone or build fails, or `depmod`
  reports errors. Silent partial success (an image published without the
  driver) is treated as a build failure, not a warning.
- Toolchain/driver-repo downloads retry consistent with the project's existing
  pattern elsewhere (e.g. `rebuild`'s kernel download loop retries 10 times).

## Testing / verification

- Manual `workflow_dispatch` run of Stage 1, inspecting the uploaded
  `modules-*.tar.gz` to confirm it contains `8821au.ko` and an updated
  `modules.dep` referencing it.
- Manual `workflow_dispatch` run of Stage 2 using the Stage 1 output, flashing
  the resulting image and confirming `lsmod | grep 8821au` after boot with the
  dongle attached.
- Confirm `armbian-update` on a running device (with `KERNEL_REPO` pointed at
  this repo) still has the driver present afterward.

## Maintenance

- Nothing upstream owns is ever touched, so `git fetch upstream && git merge`
  requires no conflict resolution for this feature.
- The only ongoing maintenance is the driver source itself
  (`morrownr/8821au-20210708`) breaking against a future kernel API — visible
  immediately as a Stage 1 build failure, not a silent runtime gap.
