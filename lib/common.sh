#!/usr/bin/env bash
# wdnwebui one-shot installer — shared configuration and helper functions.
#
# Sourced by install.sh / update.sh — **do not** execute it directly.
#
# The board has no emoji / symbol font: 🖼 ✕ ⚠ ✓ ☑ ▯ 🗑 📁 all render as tofu
# boxes (□). The only symbols that work on the board are `× ● ■ ▶ ← → ↑ ↓`
# — the output below uses only those.

# ---------------------------------------------------------------------------
# Home directory
#
# The script **never elevates privileges** and does not assume who elevated
# it — the home directory is the $HOME of the current process. Whoever runs
# the installer is who gets the wdn command; when permissions are missing
# the script only prints the commands to run, and the operator runs them as
# root.
# ---------------------------------------------------------------------------
wardner_target_home() {
    printf '%s\n' "$HOME"
}

# ---------------------------------------------------------------------------
# Configuration (every value can be overridden by an environment variable,
# which makes testing and customisation easy)
#
# WARDNER_SOURCE_HOST / WARDNER_ORG / WARDNER_REPO_NAME are **inferred** by
# the bootstrap phase of install.sh (from the URL the script itself came
# from, see lib/urls.sh) — hardcoding the org name would mean changing the
# code whenever the org, the fork or the mirror site changes. The values
# here are only fallback defaults.
#
# There are two source hosts:
#   * github.com — the authoritative repository, pushable
#   * gitee.com  — a **read-only mirror**, synced from upstream, **never
#                  push to it**
# Whichever site you install from, the host app and the 8 SDK / plugin
# packages all follow that site (Gitee is faster on mainland networks).
# ---------------------------------------------------------------------------

# The package source prefix **explicitly** set by the user (may be empty).
# Keep a copy: resolve_source recomputes WARDNER_PKG_BASE from the source
# host, and without this copy a mirror address the user set in the
# environment would be **silently overwritten** — exactly the usage the
# README documents.
WARDNER_PKG_BASE_ENV="${WARDNER_PKG_BASE:-}"

: "${WARDNER_HOME:=$(wardner_target_home)/.wardner}"   # install root
: "${WARDNER_SOURCE_HOST:=github.com}"                # source host (github.com / gitee.com)
: "${WARDNER_SOURCE_SCHEME:=$(source_scheme_for_host "$WARDNER_SOURCE_HOST")}"  # source host scheme
: "${WARDNER_ORG:=rockchip-wardner}"                  # org (inferred from the source URL)
: "${WARDNER_REPO_NAME:=wardner}"                     # this repo (inferred from the source URL)
: "${WARDNER_REPO_URL:=https://$WARDNER_SOURCE_HOST/$WARDNER_ORG/$WARDNER_REPO_NAME.git}"
: "${WARDNER_HOST_REPO:=wdnwebui}"                    # host application repo name
: "${WARDNER_PKG_BASE:=git+https://$WARDNER_SOURCE_HOST/$WARDNER_ORG}"
: "${WARDNER_PYTHON:=python3}"
: "${WARDNER_BRANCH:=master}"

WARDNER_HOME="${WARDNER_HOME%/}"
WARDNER_REPO_DIR="$WARDNER_HOME/$WARDNER_REPO_NAME"              # this repo
WARDNER_HOST_DIR="$WARDNER_HOME/$WARDNER_HOST_REPO"               # host application
WARDNER_VENV="$WARDNER_HOST_DIR/.venv"                         # virtual environment
WARDNER_VENV_SRC="$WARDNER_VENV/src"                           # SDK / plugin packages
WARDNER_PACKAGES_CONF="${WARDNER_PACKAGES_CONF:-$SCRIPT_DIR/packages.conf}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

log()  { printf '%s[wardner]%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
step() { printf '\n%s▶ %s%s\n' "$C_BLU" "$*" "$C_RST" >&2; }
ok()   { printf '  %s●%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '  %s×%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
fail() { printf '  %s×%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { printf '\n%s[fail]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RST" >&2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
need_cmd() {
    local c="$1" hint="${2:-}"
    command -v "$c" >/dev/null 2>&1 && return 0
    die "missing command '$c'${hint:+ — $hint}"
}

# ---------------------------------------------------------------------------
# git retries
#
# The worst thing about a one-shot installer is "the network hiccuped and
# the whole install failed": GitHub may throw GnuTLS recv error / connection
# reset / RPC failed on some networks, and the clone dies halfway through.
# Retrying once usually works, so retry a few times before giving up.
#
# Permanent failures (local and remote have diverged) never get better with
# retries, but a small number of retries with short intervals costs little —
# the real error message is fully visible in the last attempt anyway.
#
# ⚠️ **HTTPS only**, no SSH fallback: most public users have no GitHub SSH
#    key, and SSH just hangs on "Permission denied (publickey)" / a password
#    prompt. Anonymous HTTPS clone of a public repo is the only path that is
#    friendly to people who have never logged in.
#
# lowSpeedLimit/lowSpeedTime: git has **no** connect timeout by default, so a
# TCP-level failure takes 135s to surface (observed: "Failed to connect ...
# after 135137 ms"). Across a 9-repo install that is minutes wasted on a
# single hiccup. Aborting after "30s without a single byte" caps each failed
# attempt at 30s, which keeps the total time bounded together with retries.
# ---------------------------------------------------------------------------
: "${WARDNER_GIT_RETRY:=5}"
: "${WARDNER_RETRY_DELAY:=5}"
: "${WARDNER_GIT_LOW_SPEED_LIMIT:=1}"
: "${WARDNER_GIT_LOW_SPEED_TIME:=30}"

# git network options (must come before the subcommand)
GIT_NET_OPTS=(
    -c "http.lowSpeedLimit=$WARDNER_GIT_LOW_SPEED_LIMIT"
    -c "http.lowSpeedTime=$WARDNER_GIT_LOW_SPEED_TIME"
)

git_retry() {
    local label="$1"; shift
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$WARDNER_GIT_RETRY" ]; then
            return 1
        fi
        warn "$label failed (attempt ${attempt}/${WARDNER_GIT_RETRY}), retrying in ${WARDNER_RETRY_DELAY}s"
        attempt=$((attempt + 1))
        sleep "$WARDNER_RETRY_DELAY"
    done
}

# Clone a repository, or fast-forward it when it already exists (never force
# a repo with local changes or diverged history).
# $1 = target directory  $2 = repository name
#
# ⚠️ The clone URL follows the **source host** — an install from Gitee also
#    pulls the 8 packages from Gitee (faster on mainland networks).
#    The scheme follows the source host as well: an intranet GitLab reached
#    as http://10.10.10.10:8080/... must not be hardcoded to https.
fetch_repo() {
    local dir="$1" name="$2"
    local url
    url="$(repo_clone_url_for "$WARDNER_SOURCE_SCHEME" "$WARDNER_SOURCE_HOST" "$WARDNER_ORG" "$name")"

    if [ -d "$dir/.git" ]; then
        # When the source host changes, point the remote at the new one —
        # `git pull` **does not** rewrite the remote URL, so without this the
        # source host would stay stuck at whatever was installed first.
        local old_remote new_host
        old_remote="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
        new_host="$(source_url_host "$old_remote")"
        if [ -n "$old_remote" ] && [ "$new_host" != "$WARDNER_SOURCE_HOST" ]; then
            git -C "$dir" remote set-url origin "$url" >/dev/null 2>&1 || true
            log "remote of $name switched to the new source: $url"
        fi

        log "updating $name"
        if ! git_retry "git pull $name" \
            git -C "$dir" "${GIT_NET_OPTS[@]}" pull --ff-only; then
            warn "$name has diverged from the remote (or has uncommitted changes), skipping the update"
            warn "  handle it manually: git -C $dir status"
            return 1
        fi
        return 0
    fi

    log "cloning $name"
    mkdir -p "$(dirname "$dir")"
    rm -rf "$dir"
    if ! git_retry "git clone $name" \
        git "${GIT_NET_OPTS[@]}" clone --branch "$WARDNER_BRANCH" "$url" "$dir"; then
        die "cloning $name failed: $url"
    fi
}

# Read every line of packages.conf → "pkg<TAB>repo". Skips blank lines and
# # comments.
read_packages() {
    [ -f "$WARDNER_PACKAGES_CONF" ] || die "package list not found: $WARDNER_PACKAGES_CONF"
    while read -r pkg repo _rest; do
        [ -z "${pkg:-}" ] && continue
        case "$pkg" in \#*) continue ;; esac
        [ -z "${repo:-}" ] && continue
        printf '%s %s\n' "$pkg" "$repo"
    done < "$WARDNER_PACKAGES_CONF"
}

# ---------------------------------------------------------------------------
# The wdn command: put it on PATH + write it into ~/.bashrc
#
# "Let the current user run wdn directly" takes two things:
#   1. The command itself on the PATH — in two places:
#        $WARDNER_HOME/<repo>/bin/wdn   (the real one, added to the PATH by bashrc)
#        ~/.local/bin/wdn               (symlink, for shells that don't read bashrc)
#   2. The environment it needs written into ~/.bashrc — as a managed block
#      with begin/end markers, so a repeated install **replaces** the old
#      block instead of appending a second copy.
#
# A managed block rather than a bare PATH line: the user's own ~/.bashrc gets
# rewritten by every install, and without markers there is no safe way to
# change it back.
# ---------------------------------------------------------------------------
WARDNER_BASHRC_BEGIN="# >>> wardner (wdn) >>>"
WARDNER_BASHRC_END="# <<< wardner (wdn) <<<"

# Write (or replace) the managed block in ~/.bashrc. Idempotent.
wardner_write_bashrc() {
    local rc="$1" home="$2" bindir="$3"
    local begin="$WARDNER_BASHRC_BEGIN" end="$WARDNER_BASHRC_END"

    if [ -z "$rc" ] || [ -z "$bindir" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$rc")"
    [ -f "$rc" ] || : > "$rc"

    # Only delete the old block when **both markers are present** — a lone
    # begin marker means the last write was broken, and in that case it is
    # safer to leave the file alone than to swallow whatever follows it.
    if grep -qF "$begin" "$rc" && grep -qF "$end" "$rc"; then
        local tmp
        tmp="$(mktemp)"
        if awk -v b="$begin" -v e="$end" '
            index($0, b) { inblk = 1; next }
            index($0, e) { inblk = 0; next }
            !inblk { print }
        ' "$rc" > "$tmp"; then
            mv "$tmp" "$rc"
        else
            rm -f "$tmp"
            warn "could not rewrite ~/.bashrc — left it as it is, please add the PATH manually: $bindir"
            return 1
        fi
    fi

    cat >> "$rc" <<EOF

$begin
# Written by wardner install.sh — puts the wdn command on this user's PATH.
# Removing this block does not break the install; you just have to call wdn by its full path.
export WARDNER_HOME="$home"
case ":\$PATH:" in
  *":$bindir:"*) ;;
  *) export PATH="$bindir:\$PATH" ;;
esac
$end
EOF
    return 0
}
