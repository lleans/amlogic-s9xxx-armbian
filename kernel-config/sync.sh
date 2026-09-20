#!/usr/bin/env bash
# kernel-config/sync.sh
#
# Re-sync the vendored kernel config from ophub upstream, re-applying the
# local overrides in local.conf on top.
#
# Why this exists: the workflow passes kernel_config: kernel-config, and the
# action REPLACES the config directory rather than merging (action.yml does
# `rm -f ${config_filepath}/*` then copies ours in). So we own a full copy of
# ophub's config-6.18, and it drifts whenever upstream regenerates theirs.
# This script refreshes that copy and re-applies our edits, so drift is a
# one-command fix instead of a manual re-diff.
#
# The override that matters: ophub ships CONFIG_RTW88_8821AU disabled, which
# is the in-kernel driver for the RTL8821AU/RTL8811AU adapters this project
# targets.
#
# Usage:
#   bash kernel-config/sync.sh            # update, then show what changed
#   bash kernel-config/sync.sh --check    # exit 1 if out of sync, change nothing
#
# Requires: curl, diff, sed, git. Network access to raw.githubusercontent.com.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CONF="${SCRIPT_DIR}/local.conf"

# ophub's config repository / branch / path, matching the values in
# armbian_compile_kernel.sh (kernel_config_repo, _branch, _path).
UPSTREAM_REPO="ophub/kernel"
UPSTREAM_BRANCH="main"
UPSTREAM_PATH="kernel-config/release/stable"

# Which upstream configs to vendor. Kept explicit rather than globbing the
# remote: the RTW88_8821AU symbol only exists in Linux >= 6.14, so vendoring
# an older family would ship a config whose override silently does nothing.
CONFIG_VERSIONS=("6.18")

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

die() { echo "sync.sh: ERROR: $*" >&2; exit 1; }

[[ -f "${LOCAL_CONF}" ]] || die "missing override file: ${LOCAL_CONF}"

# apply_overrides <file>
# Rewrites each local.conf setting into the given config in place. Handles both
# upstream forms: "CONFIG_FOO=..." and "# CONFIG_FOO is not set". A symbol
# absent from the config is appended, so a new override never silently no-ops.
apply_overrides() {
    local file="${1}" line symbol
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        symbol="${line%%=*}"
        if grep -qE "^${symbol}=|^# ${symbol} is not set$" "${file}"; then
            # '|' as delimiter: symbols never contain it, and the replacement
            # may contain '=' and quotes.
            sed -i.bak -E \
                -e "s|^${symbol}=.*|${line}|" \
                -e "s|^# ${symbol} is not set$|${line}|" \
                "${file}"
            rm -f "${file}.bak"
        else
            printf '%s\n' "${line}" >> "${file}"
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "${LOCAL_CONF}" || true)
}

drift=0
updated=0

for ver in "${CONFIG_VERSIONS[@]}"; do
    target="${SCRIPT_DIR}/config-${ver}"
    url="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_BRANCH}/${UPSTREAM_PATH}/config-${ver}"

    echo "==> kernel config ${ver}"

    tmp="$(mktemp)"
    applied="$(mktemp)"
    trap 'rm -f "${tmp}" "${applied}"' EXIT

    curl -fsSL "${url}" -o "${tmp}" || die "failed to fetch ${url}"
    [[ -s "${tmp}" ]] || die "fetched empty config from ${url}"

    cp -f "${tmp}" "${applied}"
    apply_overrides "${applied}"

    if [[ ! -f "${target}" ]]; then
        echo "    MISSING: ${target}"
        drift=1
        if [[ "${CHECK_ONLY}" -eq 0 ]]; then
            cp -f "${applied}" "${target}"
            echo "    created"
            updated=1
        fi
    elif cmp -s "${applied}" "${target}"; then
        echo "    up to date"
    else
        echo "    DRIFT: ${target} differs from upstream + local.conf"
        diff "${target}" "${applied}" | head -40 || true
        drift=1
        if [[ "${CHECK_ONLY}" -eq 0 ]]; then
            cp -f "${applied}" "${target}"
            echo "    updated"
            updated=1
        fi
    fi
done

echo
if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    if [[ "${drift}" -ne 0 ]]; then
        echo "sync.sh: OUT OF SYNC - run 'bash kernel-config/sync.sh' to update."
        exit 1
    fi
    echo "sync.sh: in sync with upstream."
    exit 0
fi

if [[ "${updated}" -eq 0 ]]; then
    echo "sync.sh: nothing to do, already in sync."
else
    echo "sync.sh: updated. Review with 'git diff kernel-config/'."
fi
