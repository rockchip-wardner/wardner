#!/usr/bin/env bash
# Real end-to-end check: run the entry script the way a user does
# (curl | bash) and verify how the "source site" is selected.
#
# It stops at the "source:" line (everything after phase 2 is creating the
# venv + installing the 8 packages, which is not needed here), and it runs
# entirely inside a temporary WARDNER_HOME, so it **never touches** the
# real installation in ~/.wardner.
#
# Usage: bash scripts/verify_e2e_source.sh <github|gitee>
set -uo pipefail

WHICH="${1:-gitee}"
E2E_HOME="$(mktemp -d "${TMPDIR:-/tmp}/wardner-e2e.XXXXXX")"
trap 'rm -rf "$E2E_HOME"' EXIT

case "$WHICH" in
    github) URL="https://github.com/rockchip-wardner/wardner/raw/master/install_github.sh" ;;
    gitee)  URL="https://gitee.com/rockchip-wardner/wardner/raw/master/install_gitee.sh" ;;
    *)      echo "usage: $0 <github|gitee>"; exit 2 ;;
esac

echo "entry point: $URL"
echo "temporary install root: $E2E_HOME"
echo

export WARDNER_HOME="$E2E_HOME"

# Exactly the way a real user does it: curl | bash
curl -fsSL --max-time 60 "$URL" | timeout 240 bash 2>&1 | sed -n '1,60p'
rc=${PIPESTATUS[1]}

echo
echo "--- verdict ---"
echo "the remote of the temporary repo:"
git -C "$E2E_HOME/wardner" remote get-url origin 2>&1 | sed 's/^/  /'
