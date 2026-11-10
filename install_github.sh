#!/usr/bin/env bash
# One-shot install entry point for the GitHub source.
#
#   curl -fsSL https://github.com/rockchip-wardner/wardner/raw/master/install_github.sh | bash
#
# This script does exactly two things:
#   1. **Declare the source site** (GitHub);
#   2. Download the real installer (install.sh) and run it.
#
# Why this layer exists: with `curl ... | bash` the installer **cannot**
# reliably tell where it was downloaded from — install.sh is only ~25KB, so
# it fits into the pipe buffer in one go; curl exits as soon as it has
# written it, and by the time the script scans /proc curl is long gone
# (observed: a 24KB script → no curl in /proc; 200KB → still there).
# So "install from Gitee" silently fell back to the GitHub source — users
# thought they were installing the mainland mirror while everything was
# pulled from GitHub. The source site is now declared by the **script
# name**, with no runtime probing.
#
# ⚠️ The intranet primary repo / GitHub / Gitee are **byte-identical** —
#    this file is the same content in all three. Gitee remains a read-only
#    mirror of the upstream; push to GitHub or to the intranet primary repo.
set -euo pipefail

# The source site declared by this entry point (clone URL).
WARDNER_SELF_SOURCE_URL="https://github.com/rockchip-wardner/wardner.git"
export WARDNER_SELF_SOURCE_URL

# The real installer lives on the same source site.
_INSTALLER_URL="https://github.com/rockchip-wardner/wardner/raw/master/install.sh"

_tmp="$(mktemp "${TMPDIR:-/tmp}/wardner-install.XXXXXX")"
trap 'rm -f "$_tmp"' EXIT

if ! curl -fsSL "$_INSTALLER_URL" -o "$_tmp"; then
    printf '[fail] failed to download the installer: %s\n' "$_INSTALLER_URL" >&2
    exit 1
fi
if [ ! -s "$_tmp" ]; then
    printf '[fail] the downloaded installer is empty: %s\n' "$_INSTALLER_URL" >&2
    exit 1
fi

bash "$_tmp" "$@"
