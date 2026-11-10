#!/usr/bin/env bash
# wdnwebui update script — pull the latest code + reinstall.
#
#   ~/.wardner/wardner/update.sh
#
# The difference to install.sh: install.sh follows the "install from
# scratch" mental model, update.sh follows "I am already using it, give me
# the new one". In practice both take the same path (install.sh itself is
# idempotent: it pulls every repo and only reinstalls the packages whose
# HEAD changed), update.sh just makes the intent clear, so nobody has to
# remember where things were installed.
#
# The real work happens in update_rkwhl.sh of the host repo — 470 lines of
# update logic refined on real boards (.so landing assertions / editable
# install leftovers / card registration checks / SDK dependency audits) live
# there.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/install.sh" ]; then
    echo "[fail] $SCRIPT_DIR/install.sh does not exist — this does not look like a normal install directory" >&2
    exit 1
fi

exec bash "$SCRIPT_DIR/install.sh" "$@"
