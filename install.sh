#!/usr/bin/env bash
# wdnwebui one-shot installer
#
#   ── GitHub (default) ───────────────────────────────────────────
#   curl -fsSL https://github.com/rockchip-wardner/wardner/raw/master/install_github.sh | bash
#
#   ── Gitee mirror (faster on mainland networks) ─────────────────
#   curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install_gitee.sh | bash
#
# ⚠️ Note the **/raw/master/** path — do not write .../wardner/install.sh,
#    that is a web route, not the raw file URL (curl gets a 404 or a page of
#    HTML).
#
# The installer **knows which site it belongs to**: the source site is
# declared by the **entry script** — install_github.sh / install_gitee.sh
# declare GitHub / Gitee respectively, while the real installation logic
# lives in install.sh (the two entry scripts are thin shells, the logic
# exists only once).
#
# Whichever site you install from, the host application, the 8 SDK / plugin
# packages and every later `wdn update` follow that same site.
#
# ⚠️ Gitee is a **read-only mirror** (content is synced from upstream) —
#    pulling from it is fine, **never push to it**. Use GitHub (or the
#    intranet primary repo) to push.
#
# Everything lands under ~/.wardner:
#
#   ~/.wardner/wardner/                    this repo (the installer itself, so it can update itself later)
#   ~/.wardner/wdnwebui/                   host application (FastAPI service + card host)
#   ~/.wardner/wdnwebui/.venv/             virtual environment
#   ~/.wardner/wdnwebui/.venv/src/<pkg>/   the 8 SDK / card plugin packages (each its own git repo)
#
# Idempotent: running it again = pull the latest + reinstall. Packages whose
# HEAD did not change are skipped (see update_rkwhl.sh).
#
# Installing the packages, verifying the artifacts and auditing the
# dependencies are all delegated to update_rkwhl.sh in the wdnwebui repo —
# those 470 lines were refined on real boards (.so landing assertions,
# editable-install leftovers, card registration checks, SDK dependency
# audits), so this script **does not reimplement** them; it only moves the
# code to where it belongs.

set -euo pipefail

# ---------------------------------------------------------------------------
# Source URL helpers
#
# These two functions are needed during the bootstrap phase (lib/urls.sh is
# not sourced yet at that point), so a copy lives here — lib/urls.sh holds
# the **same logic**, and **changing one means changing the other**.
# ---------------------------------------------------------------------------

# Is this URL a "file URL" rather than a "repository URL"?
#
# Using a raw file URL as a clone URL **fails outright** — git asks for a
# username (observed: "could not read Username for 'https://gitee.com'"), and
# with a TTY it even hangs on the password prompt, so users think the
# installer froze.
source_url_is_file_url() {
    case "${1:-}" in
        */raw/*|*/blob/*) return 0 ;;
        *.sh|*.py|*.json) return 0 ;;
    esac
    return 1
}

# URL → host (used only to compare whether two URLs point at the same site).
source_url_host() {
    local u="${1:-}"
    case "$u" in
        git@*:*)
            u="${u#git@}"; printf '%s' "${u%%:*}" ;;
        ssh://*/*)
            u="${u#ssh://}"; u="${u##*@}"; printf '%s' "${u%%/*}" ;;
        http://*/*|https://*/*)
            u="${u#*://}"; u="${u##*@}"; printf '%s' "${u%%/*}" ;;
        *)
            printf '%s' "$u" ;;
    esac
}

# ---------------------------------------------------------------------------
# Phase 0: bootstrap
#
# With `curl | bash` this file is not on disk — BASH_SOURCE points at
# "bash", so the real script directory is unknown and lib/ cannot be
# sourced. So the first thing to do is clone this repo locally and then
# exec the cloned copy: that one has a real SCRIPT_DIR.
#
# WARDNER_BOOTSTRAPPED is the anti-recursion sentinel — the cloned copy
# carries it and therefore does not bootstrap again.
# ---------------------------------------------------------------------------
if [ -z "${WARDNER_BOOTSTRAPPED:-}" ]; then
    # The install root defaults to the home directory of the current user.
    #
    # The script **never elevates privileges** — when permissions are
    # missing it only prints the command so the operator can run it as root
    # themselves. So "whoever runs the installer is who gets the wdn
    # command": the home directory is $HOME.
    if [ -z "${WARDNER_HOME:-}" ]; then
        WARDNER_HOME="$HOME/.wardner"
    fi
    WARDNER_HOME="${WARDNER_HOME%/}"
    : "${WARDNER_GIT_RETRY:=5}"
    : "${WARDNER_RETRY_DELAY:=5}"
    : "${WARDNER_GIT_LOW_SPEED_LIMIT:=1}"
    : "${WARDNER_GIT_LOW_SPEED_TIME:=30}"
    _repo_dir=""

    if ! command -v git >/dev/null 2>&1; then
        printf '\033[1;31m[fail]\033[0m git is missing, please install it first (apt install git)\n' >&2
        exit 1
    fi

    # ── Infer "where was this script fetched from" ─────────────────────
    #
    # Hardcoding org/repo means changing the org or the fork requires a
    # code change. This goes the other way: the **source site** + org +
    # repo name are derived from the source URL — the installer is
    # therefore **self-describing**.
    #
    # Source priority:
    #   1. WARDNER_REPO_URL environment variable — explicitly set by the
    #      user, highest priority
    #   2. WARDNER_SELF_SOURCE_URL — **carried by the entry script**
    #      (install_github.sh / install_gitee.sh declare their own source).
    #      This is the **main path**
    #   3. The remote of the already installed repo — for a reinstall or
    #      update.sh the current state wins, the source is never switched
    #   4. curl's command line — fallback (with `curl ... | bash` curl has
    #      usually exited by then)
    #   5. The built-in fallback — **warns**, never switches source silently
    #
    # ⚠️ Priority 2 is the main path, because with `curl ... | bash` the
    #    script **reliably** knows where it came from — not by probing the
    #    runtime, but by **file content**: install.sh is only ~25KB, so it
    #    fits into the pipe buffer in one go; curl exits as soon as it has
    #    written it, and by the time the script scans /proc curl is long
    #    gone (observed: a 24KB script → no curl in /proc; 200KB → still
    #    there).
    #    So "the entry script declares the source site" is far more
    #    reliable than "scan /proc and guess" — priority 4 is only a
    #    historical fallback.
    #
    # ⚠️ This runs **before** sourcing lib/*.sh (the script directory is
    #    not known yet), so a copy of the URL parsing logic lives here —
    #    lib/urls.sh holds the same logic, and **changing one means changing
    #    the other**.
    # >>> source resolution begins (scripts/verify_source_selection.sh extracts this block by these two markers for regression testing)
    _src=""
    _src_kind=""
    if [ -n "${WARDNER_REPO_URL:-}" ]; then
        _src="$WARDNER_REPO_URL"
        _src_kind="user"
    elif [ -n "${WARDNER_SELF_SOURCE_URL:-}" ]; then
        _src="$WARDNER_SELF_SOURCE_URL"
        _src_kind="self"
    elif [ -d "$WARDNER_HOME/${WARDNER_REPO_NAME:-wardner}/.git" ]; then
        # Already installed — the **existing remote** wins (the remote is a
        # fact, an inference is not).
        # This keeps update.sh / a reinstall from switching the source site.
        _src="$(git -C "$WARDNER_HOME/${WARDNER_REPO_NAME:-wardner}" \
                    remote get-url origin 2>/dev/null || true)"
        [ -n "$_src" ] && _src_kind="installed"
    fi
    if [ -z "$_src" ]; then
        for _p in /proc/[0-9]*; do
            # ⚠️ `2>/dev/null` must come **before** the input redirection —
            #    the order cannot be reversed.
            #
            # bash applies redirections left to right: it swaps stderr for
            # /dev/null first, so when the input redirection fails the
            # shell's own "No such file or directory" message is swallowed
            # as well. Writing `< file 2>/dev/null` (reversed) leaks that
            # line of noise — scanning hundreds of pids always hits a
            # process that just exited (TOCTOU: the glob is expanded and the
            # process is gone, /proc/<pid> is removed by the kernel), and
            # users think the install failed.
            _cmd="$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline")" || continue
            case "$_cmd" in *curl*install.sh*) ;; *) continue ;; esac
            _u="$(printf '%s\n' "$_cmd" | grep -oE 'https?://[^ ]+' | head -1)"
            [ -n "$_u" ] && { _src="$_u"; _src_kind="probe"; break; }
        done
    fi
    if [ -z "$_src" ]; then
        _src="https://github.com/rockchip-wardner/wardner/raw/master/install.sh"
        _src_kind="default"
        # The fallback **must warn** — switching source silently is one of
        # the hardest bugs to track down here: the user installs from Gitee
        # but silently pulls from GitHub, with no hint at all.
        printf '\033[1;33m[warn]\033[0m could not determine the source URL (no curl in /proc — it exited before the script was read)\n' >&2
        printf '       falling back to the built-in default source: github.com/rockchip-wardner/wardner\n' >&2
        printf '       to use another source, use the matching **entry script** (the script name declares the source site):\n' >&2
        printf '         install_github.sh  →  GitHub source\n' >&2
        printf '         install_gitee.sh   →  Gitee source\n' >&2
        printf '       or set it explicitly: export WARDNER_REPO_URL=https://<host>/<org>/<repo>.git\n' >&2
    fi

    # Parse the source URL → "<host> <org> <repo>".
    #
    # Rule: **the first two path segments are always org / repo**, anything
    # after them (raw / blob / branch / file) is dropped — so GitHub's
    # /raw/ and Gitee's /raw/ share one parser.
    _u="${_src%%\?*}"
    _u="${_u%/}"
    _u="${_u%.git}"
    _host=""; _path=""
    case "$_u" in
        git@*:*)
            _host="${_u#git@}"; _host="${_host%%:*}"
            _path="${_u#git@*:}"
            ;;
        ssh://*/*)
            _host="${_u#ssh://}"; _host="${_host%%/*}"; _host="${_host##*@}"
            _path="${_u#ssh://*/}"
            ;;
        http://*/*|https://*/*)
            _host="${_u#*://}"; _host="${_host%%/*}"
            _path="${_u#*://*/}"
            ;;
    esac
    # raw.githubusercontent.com is the domain for **fetching files**, not for
    # cloning
    case "$_host" in
        raw.githubusercontent.com) _host="github.com" ;;
    esac
    _org=""; _repo=""
    case "$_path" in
        */*)
            _org="${_path%%/*}"
            _path="${_path#*/}"
            _repo="${_path%%/*}"
            ;;
    esac
    if [ -z "$_host" ] || [ -z "$_org" ] || [ -z "$_repo" ]; then
        _host="github.com"; _org="rockchip-wardner"; _repo="wardner"
    fi

    # What the user set explicitly (environment variables) **overrides** the
    # parsed result — consistent with the environment variable table in the
    # README.
    # Previously it was an unconditional override, so exporting it had no
    # effect (it only worked during the `wdn update` phase).
    _env_override=0
    if [ -n "${WARDNER_SOURCE_HOST:-}" ] || [ -n "${WARDNER_ORG:-}" ] \
       || [ -n "${WARDNER_REPO_NAME:-}" ]; then
        _env_override=1
    fi
    : "${WARDNER_SOURCE_HOST:=$_host}"
    : "${WARDNER_ORG:=$_org}"
    : "${WARDNER_REPO_NAME:=$_repo}"
    _host="$WARDNER_SOURCE_HOST"
    _org="$WARDNER_ORG"
    _repo="$WARDNER_REPO_NAME"

    WARDNER_SOURCE_HOST="$_host"
    # The scheme is decided by the **source site**: GitHub / Gitee use https
    # (public repos, anonymous clone), intranet hosts use ssh (the web port
    # of an intranet GitLab is 8080, an HTTP port, so fetching the code uses
    # ssh).
    #
    # ⚠️ This rule also exists in lib/urls.sh::source_scheme_for_host — the
    #    bootstrap phase cannot source lib/ yet, so it is inlined. Changing
    #    one means changing the other.
    case "$_host" in
        github.com|gitee.com) _scheme="https" ;;
        *)                     _scheme="ssh" ;;
    esac
    WARDNER_SOURCE_SCHEME="$_scheme"
    export WARDNER_SOURCE_HOST WARDNER_SOURCE_SCHEME WARDNER_ORG WARDNER_REPO_NAME

    # Where the clone URL comes from:
    #
    # * **The user gave a clone URL** (WARDNER_REPO_URL) → **use it as is** —
    #   it may carry a port, an SSH form or an intranet GitLab path prefix
    #   that no inferred URL would be equivalent to.
    # * **A file URL** (contains /raw/ /blob/, or ends in a file name) →
    #   that is not a clone URL; using it as is makes git ask for a
    #   username (observed: "could not read Username for
    #   'https://gitee.com'", and with a TTY it hangs on the password
    #   prompt) → rebuild it from the parsed host/org/repo.
    # * **The user changed host / org / repo** → the shipped URL no longer
    #   matches → rebuild it.
    # * Otherwise → use as is (the entry script's URL and the remote of an
    #   installed repo are authoritative addresses).
    #
    # ⚠️ This check also exists in lib/urls.sh::source_url_is_file_url —
    #    the bootstrap phase cannot source lib/ yet, so it is inlined.
    #    Changing one means changing the other.
    if [ "$_src_kind" = "user" ] && ! source_url_is_file_url "$_src"; then
        WARDNER_REPO_URL="$_src"
    elif source_url_is_file_url "$_src" || [ "$_env_override" -eq 1 ]; then
        case "$_scheme" in
            ssh) WARDNER_REPO_URL="git@${_host%%:*}:$_org/$_repo.git" ;;
            *)   WARDNER_REPO_URL="https://$_host/$_org/$_repo.git" ;;
        esac
    else
        WARDNER_REPO_URL="$_src"
    fi
    export WARDNER_REPO_URL
    # <<< source resolution ends
    _repo_dir="$WARDNER_HOME/$WARDNER_REPO_NAME"

    mkdir -p "$WARDNER_HOME"

    # Both clone and pull can be interrupted by network flapping, so retry
    # a few times before declaring failure.
    #
    # ⚠️ HTTPS only: most public users have no GitHub SSH key, and SSH just
    #    hangs on "Permission denied (publickey)" or a password prompt.
    #    Anonymous HTTPS clone of a public repo is the only path that is
    #    friendly to people who have never logged in.
    #
    # lowSpeedLimit/lowSpeedTime: git has no connect timeout by default, so
    # a TCP-level failure takes 135s to surface (observed: "Failed to
    # connect ... after 135137 ms"). Across the 9-repo install a single
    # hiccup could cost a quarter of an hour — capping it at 30s keeps the
    # total time bounded together with the retries.
    _try=1
    while true; do
        if [ -d "$_repo_dir/.git" ]; then
            # When the source changes, point the remote at the new one —
            # `git pull` **does not** rewrite the remote URL, so without
            # this an install from Gitee keeps pulling from the old GitHub
            # remote, and resolve_source() keeps showing the old source.
            _old_remote="$(git -C "$_repo_dir" remote get-url origin 2>/dev/null || true)"
            if [ -n "$_old_remote" ] \
               && [ "$(source_url_host "$_old_remote")" != "$WARDNER_SOURCE_HOST" ]; then
                git -C "$_repo_dir" remote set-url origin "$WARDNER_REPO_URL" >/dev/null 2>&1 || true
                printf '  \033[1;33m[warn]\033[0m remote of %s switched to the new source: %s\n' \
                    "$WARDNER_REPO_NAME" "$WARDNER_REPO_URL" >&2
            fi
            git -C "$_repo_dir" -c "http.lowSpeedLimit=$WARDNER_GIT_LOW_SPEED_LIMIT" \
                -c "http.lowSpeedTime=$WARDNER_GIT_LOW_SPEED_TIME" \
                pull --ff-only >/dev/null 2>&1 && break
            _what="git pull $WARDNER_REPO_NAME"
        else
            rm -rf "$_repo_dir"
            git -c "http.lowSpeedLimit=$WARDNER_GIT_LOW_SPEED_LIMIT" \
                -c "http.lowSpeedTime=$WARDNER_GIT_LOW_SPEED_TIME" \
                clone "$WARDNER_REPO_URL" "$_repo_dir" >/dev/null 2>&1 && break
            _what="git clone $WARDNER_REPO_NAME"
        fi
        if [ "$_try" -ge "$WARDNER_GIT_RETRY" ]; then
            printf '\033[1;31m[fail]\033[0m %s failed (after %s attempts)\n' "$_what" "$WARDNER_GIT_RETRY" >&2
            exit 1
        fi
        printf '\033[1;33m[warn]\033[0m %s failed (attempt %s/%s), retrying in %ss\n' \
            "$_what" "$_try" "$WARDNER_GIT_RETRY" "$WARDNER_RETRY_DELAY" >&2
        _try=$((_try + 1))
        sleep "$WARDNER_RETRY_DELAY"
    done

    export WARDNER_BOOTSTRAPPED=1
    exec bash "$_repo_dir/install.sh" "$@"
fi

# --- Only now is the real path available ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⚠️ The order cannot be reversed: common.sh uses urls.sh's
#    source_scheme_for_host to derive the source scheme (GitHub / Gitee →
#    https, intranet → ssh).
# shellcheck source=lib/urls.sh
. "$SCRIPT_DIR/lib/urls.sh"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Phase 1: preflight checks
# ---------------------------------------------------------------------------
preflight() {
    step "Preflight checks"

    need_cmd git "apt install git"
    need_cmd "$WARDNER_PYTHON" "apt install python3"

    local ver
    ver="$("$WARDNER_PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    local major="${ver%%.*}" minor="${ver##*.}"
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 9 ]; }; then
        die "Python >= 3.9 is required, current version is $ver"
    fi
    ok "Python $ver"

    # On Debian/Ubuntu python3-venv is a separate package; without it
    # `python3 -m venv` fails with "ensurepip is not available". Say so
    # up front instead of letting users guess from the error message.
    if ! "$WARDNER_PYTHON" -c 'import ensurepip, venv' >/dev/null 2>&1; then
        die "the venv module is missing (Debian/Ubuntu: run apt-get install -y python3-venv as root)"
    fi
    ok "venv module available"

    # ⚠️ Do not write resolve_source() — bash parses the "name of the
    #    command position" as a function **definition**, the trailing } then
    #    becomes a stray token and the whole script fails to parse.
    #    Always call functions without parentheses.
    resolve_source
}

# ---------------------------------------------------------------------------
# Derive the org / repo name from the actual remote after the clone
#
# The bootstrap phase derives them from the URL the script came from — that
# is an inference. After the clone, what is written in the remote is the
# fact. When the two disagree the remote wins — for example when the script
# was pulled from a fork, that fork's remote is the authoritative one.
# ---------------------------------------------------------------------------
resolve_source() {
    local remote host org repo scheme
    remote="$(git -C "$WARDNER_REPO_DIR" remote get-url origin 2>/dev/null || true)"
    [ -n "$remote" ] || return 0

    read -r host org repo < <(parse_repo_url "$remote") || return 0
    [ -n "${host:-}" ] && [ -n "${org:-}" ] && [ -n "${repo:-}" ] || return 0

    if [ "$org" != "$WARDNER_ORG" ]; then
        log "source org: $WARDNER_ORG → $org (the cloned remote wins)"
    fi
    if [ "$host" != "$WARDNER_SOURCE_HOST" ]; then
        log "source host: $WARDNER_SOURCE_HOST → $host (the cloned remote wins)"
    fi

    scheme="$(source_scheme_for_host "$host")"
    WARDNER_SOURCE_HOST="$host"
    WARDNER_SOURCE_SCHEME="$scheme"
    WARDNER_ORG="$org"
    WARDNER_REPO_NAME="$repo"
    WARDNER_REPO_DIR="$WARDNER_HOME/$WARDNER_REPO_NAME"
    WARDNER_REPO_URL="$(repo_clone_url_for "$scheme" "$host" "$org" "$repo")"
    # The user explicitly set the package source in the environment (an
    # intranet mirror, for example) → do not override it.
    # Overriding it silently replaces a source the user deliberately chose —
    # which is exactly the usage the README documents.
    if [ -z "$WARDNER_PKG_BASE_ENV" ]; then
        WARDNER_PKG_BASE="$(pkg_base_for "$scheme" "$host" "$org")"
    fi
    export WARDNER_SOURCE_HOST WARDNER_SOURCE_SCHEME WARDNER_ORG WARDNER_REPO_NAME WARDNER_REPO_URL WARDNER_PKG_BASE
    ok "source: $host/$org/$repo"

    if wardner_host_is_readonly "$host"; then
        note "$(wardner_host_label "$host") is a read-only mirror (content is synced from upstream automatically) — pulling from it is fine,"
        note "but **never push to it**. To push, point the remote back at GitHub or the intranet primary repo."
    fi
}

# ---------------------------------------------------------------------------
# Phase 2: fetch the host application
# ---------------------------------------------------------------------------
fetch_host() {
    step "Fetching the host application $WARDNER_HOST_REPO"
    fetch_repo "$WARDNER_HOST_DIR" "$WARDNER_HOST_REPO" \
        || die "failed to fetch the host application"
    ok "$WARDNER_HOST_REPO @ $WARDNER_HOST_DIR"
}

# ---------------------------------------------------------------------------
# Phase 3: create the venv
# ---------------------------------------------------------------------------
create_venv() {
    step "Creating the virtual environment"
    if [ -x "$WARDNER_VENV/bin/python" ]; then
        ok "reusing the existing venv ($WARDNER_VENV)"
    else
        mkdir -p "$(dirname "$WARDNER_VENV")"
        "$WARDNER_PYTHON" -m venv "$WARDNER_VENV" \
            || die "failed to create the venv (Debian/Ubuntu: run apt-get install -y python3-venv as root)"
        ok "created $WARDNER_VENV"
    fi
    "$WARDNER_VENV/bin/python" -m pip install --quiet --upgrade pip setuptools wheel
    ok "pip ready ($("$WARDNER_VENV/bin/python" -m pip --version | cut -d' ' -f1-2))"
}

# ---------------------------------------------------------------------------
# Phase 4: fetch the SDK / plugin packages
#
# It **must clone into .venv/src/ before pip installs**:
# the "directory does not exist" branch of update_rkwhl.sh runs
# `pip install -e <git+url>`, and pip installs a VCS editable package by
# cloning the repo into a temporary directory and pointing at it — that
# temporary directory is deleted once the install finishes, so the editable
# install is dead on arrival (import raises ModuleNotFoundError) while pip
# reports success the whole time.
# ---------------------------------------------------------------------------
fetch_packages() {
    step "Fetching the SDK / card plugin packages"
    mkdir -p "$WARDNER_VENV_SRC"
    local pkg repo n=0
    while read -r pkg repo; do
        [ -z "${pkg:-}" ] && continue
        fetch_repo "$WARDNER_VENV_SRC/$pkg" "$repo" || warn "failed to fetch $pkg, skipping"
        n=$((n + 1))
    done <<EOF
$(read_packages)
EOF
    ok "$n packages → $WARDNER_VENV_SRC"
}

# ---------------------------------------------------------------------------
# Phase 5: build dependencies
#
# The .so of wdndds is **compiled at install time** (the build_py hook of
# _build.py), which needs cmake / g++ / patchelf / the foonathan development
# headers.
#
# The official prebuilt binaries of FastDDS 3.6 are **shipped with the
# wdndds repo** (under native/lib/), so no networked build is needed — that
# matters because boards often have no internet access. The native/bin/
# nodesize_dbg stub is in the repo as well and needs no extra generation.
# ---------------------------------------------------------------------------
ensure_build_deps() {
    step "Checking the build dependencies (the .so of wdndds is compiled on the spot)"

    local need=()
    local p
    for p in cmake build-essential patchelf libfoonathan-memory-dev; do
        dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
    done

    if [ ${#need[@]} -eq 0 ]; then
        ok "all build dependencies present"
        return 0
    fi

    if [ "$(id -u)" -eq 0 ]; then
        log "installing the apt dependencies: ${need[*]}"
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y "${need[@]}" >/dev/null 2>&1 \
            || warn "the apt install failed, continuing anyway"
        ok "build dependencies handled"
        return 0
    fi

    # Not root: the script **never elevates privileges** — it only prints the
    # commands to run, and the operator runs them as root. These packages
    # only affect the .so of wdndds; the rest of the chain does not depend on
    # it, so it is not fatal.
    warn "missing build dependencies: ${need[*]}"
    warn "the .so of wdndds may fail to build (the compute page will report \"feature not enabled\")."
    warn "run the three commands below as root, then re-run this script to build the rest:"
    warn "  apt-get update"
    warn "  apt-get install -y ${need[*]}"
    warn "  bash $WARDNER_HOST_DIR/update_rkwhl.sh"
    return 0   # not fatal: the other chains do not depend on it
}

# ---------------------------------------------------------------------------
# Phase 6: install the packages + verify
#
# The real installation is delegated to update_rkwhl.sh in the wdnwebui repo:
#   * installs requirements.txt (the web side dependencies)
#   * patches the py3 compatibility issue of v4l2
#   * per package: git pull + editable reinstall (skipped when HEAD is
#     unchanged)
#   * asserts that the .so of wdndds / wdnav really landed (setuptools
#     silently swallows hook failures)
#   * verifies that the cards of the 4 plugin packages really registered
#     (entry point → manifest id → static/)
#   * audits the dependencies declared by each SDK (the hedge against the
#     --no-deps install method)
#
# The first install must FORCE_REBUILD: for a freshly cloned package the
# HEAD is identical before and after the pull, so update_rkwhl.sh decides
# "HEAD unchanged" and skips the install — the result is that nothing is
# installed.
# ---------------------------------------------------------------------------
install_packages() {
    step "Installing and verifying"

    local script="$WARDNER_HOST_DIR/update_rkwhl.sh"
    [ -f "$script" ] || die "not found: $script (was the host repo fetched completely?)"

    local force=""
    if ! "$WARDNER_VENV/bin/python" -c "import wdnav, wdnai, wdndds, wdnhid" >/dev/null 2>&1; then
        force=1
        note "first install — forcing a rebuild of all packages"
    fi

    # WARDNER_PKG_BASE: makes the "directory does not exist" fallback of
    # update_rkwhl.sh use the **source site** (GitHub or Gitee) as well,
    # instead of the default intranet mirror.
    if ! (
        cd "$WARDNER_HOST_DIR" || exit 1
        WARDNER_PKG_BASE="$WARDNER_PKG_BASE" \
        UPDATE_RKWHL_FORCE_REBUILD="$force" \
        bash "$script"
    ); then
        # update_rkwhl.sh drives package by package: a failing package only
        # logs a warning and the run continues, then it summarises "the
        # following packages were not updated" and exits 1. On a first
        # install that means **some packages were not installed**.
        echo "" >&2
        die "the install did not complete — see the \"the following packages were not updated\" summary above.
     The most common cause on a first install is the network: the clone / pip
     pull from $WARDNER_SOURCE_HOST hiccuped. Just re-run this script (the
     packages that are already installed are skipped):"
    fi

    ok "all packages installed"
}

# ---------------------------------------------------------------------------
# Phase 7: smoke test + handover information
# ---------------------------------------------------------------------------
verify() {
    step "Smoke test"

    # Hard assertion: the 4 SDKs must really be importable.
    #
    # ⚠️ This has to fail hard, not just warn — verify_outputs of
    #    update_rkwhl.sh `return 0` for wdnai / wdnhid (pure Python, no .so
    #    to assert), and audit_sdk_deps only checks "can the SDK-declared
    #    dependencies be used", not whether the package itself can be
    #    imported. So a broken .pth / editable install slips **through every
    #    gate**, and the script still prints "installation complete" — and
    #    wdnai is the base of every LLM/VLM capability.
    #
    #    wdndds / wdnav have .so landing assertions, the 4 plugin packages
    #    have card registration checks (a failing find_spec is BAD).
    #    wdnai / wdnhid are exactly the ones missing that check.
    if ! "$WARDNER_VENV/bin/python" - <<'PY'
import importlib, sys
mods = ["wdnav", "wdnai", "wdndds", "wdnhid"]
bad = []
for m in mods:
    try:
        importlib.import_module(m)
        print(f"  import {m}: ok")
    except Exception as exc:
        bad.append(m)
        print(f"  import {m}: FAILED ({exc})")
sys.exit(1 if bad else 0)
PY
    then
        die "the SDK import check failed — the packages listed above are not installed properly.
     Common causes: the .pth of an editable install points at a path that
     does not exist, or the clone/pull of a package failed halfway.
     Fix: delete the directory of the affected package and re-run this script
     (it clones it again):
       rm -rf $WARDNER_VENV_SRC/<package-name>"
    fi

    local so="$WARDNER_VENV_SRC/wdndds/src/wdndds/dds/_native/libwdndds_cshim.so"
    if [ -f "$so" ]; then
        ok "libwdndds_cshim.so is in place"
    else
        warn "libwdndds_cshim.so is missing — the compute (local model) feature is unavailable"
        warn "  rebuild: bash $WARDNER_HOST_DIR/update_rkwhl.sh"
    fi

    local shim="$WARDNER_VENV_SRC/wdnav/src/wdnav/lib/libshim_video.so"
    if [ -f "$shim" ]; then
        ok "libshim_video.so is in place"
    else
        warn "libshim_video.so is missing — video encoding/decoding is unavailable"
    fi
}

# ---------------------------------------------------------------------------
# Phase 8: install the wdn command
#
# wdn = the wardner command line entry point: bin/wdn (a bash launcher) →
# runs cli/wdn.py with the python of the .venv. The first subcommand is
# `wdn update` — it updates every downloaded repo to the latest GitHub
# revision and re-syncs the venv.
#
# Installed in two places:
#   * $WARDNER_HOME/<repo>/bin/wdn   the real one; the PATH comes from the
#     managed block in the rc files
#   * ~/.local/bin/wdn               symlink, a fallback for the cases that
#     do not read the rc files (on Debian ~/.profile adds ~/.local/bin to the
#     PATH by default)
#
# Then WARDNER_HOME + PATH are written into the **managed block** of the rc
# files of the shells the user uses — ~/.bashrc **and** ~/.zshrc (with
# begin/end markers, so a repeated install replaces the old block instead of
# appending a second copy). Both are needed: a board that logs in with zsh
# never reads ~/.bashrc, and one that logs in with bash never reads
# ~/.zshrc.
# ---------------------------------------------------------------------------
install_wdn_command() {
    step "Installing the wdn command"

    local bindir="$WARDNER_REPO_DIR/bin"
    local cmd="$bindir/wdn"
    if [ ! -f "$cmd" ]; then
        warn "not found: $cmd — skipping the wdn installation"
        return 0
    fi
    chmod +x "$cmd" 2>/dev/null || true

    local target_home
    target_home="$(wardner_target_home)"

    # The symlink in ~/.local/bin
    local local_bin="$target_home/.local/bin"
    if mkdir -p "$local_bin" 2>/dev/null; then
        if ln -sf "$cmd" "$local_bin/wdn" 2>/dev/null; then
            ok "symlink: $local_bin/wdn → $cmd"
        else
            warn "could not create the symlink (does not affect usage, the PATH is set in the rc files below)"
        fi
    else
        warn "could not create $local_bin (does not affect usage, the PATH is set in the rc files below)"
    fi

    # The managed block in the rc files of the shells the user uses —
    # ~/.bashrc **and** ~/.zshrc. A zsh login shell never reads ~/.bashrc,
    # so writing only that one leaves the command unusable in zsh.
    local rc
    while IFS= read -r rc; do
        if wardner_write_rc "$rc" "$WARDNER_HOME" "$bindir"; then
            ok "written to $rc"
        else
            warn "could not write $rc — adding this line by hand works too:"
            warn "  export PATH=\"$bindir:\$PATH\""
        fi
    done <<EOF
$(wardner_shell_rcs "$target_home")
EOF
}

report() {
    local src_label; src_label="$(wardner_host_label "$WARDNER_SOURCE_HOST")"
    local src_line="  Source host    $WARDNER_SOURCE_HOST ($src_label)"

    if wardner_host_is_readonly "$WARDNER_SOURCE_HOST"; then
        src_line="$src_line
  Note: read-only mirror — the content is synced from upstream automatically, **do not push code to it**;
        push to GitHub / the intranet primary repo instead"
    fi

    cat >&2 <<EOF

$(printf '%s' "$C_GRN")Installation complete.$(printf '%s' "$C_RST")

  Install root   $WARDNER_HOME
$src_line
  Host app       $WARDNER_HOST_DIR
  Virtual env    $WARDNER_VENV
  SDK / plugins  $WARDNER_VENV_SRC

Start the service:

  cd $WARDNER_HOST_DIR
  .venv/bin/python run.py          # opens http://<board-ip>:8000/

The wdn command (already on the PATH):

  wdn update                       # update every repo to the latest on $src_label and re-sync the venv
  wdn status                       # show each repo's commit / remote and the state of the venv

  Note: not active in this terminal yet — open a new terminal, or run: $(wardner_source_hint)

To update (pull the latest + reinstall):

  $WARDNER_REPO_DIR/install.sh
  # or: $WARDNER_REPO_DIR/update.sh
  # or: wdn update

EOF
}

main() {
    preflight
    fetch_host
    create_venv
    fetch_packages
    ensure_build_deps
    install_packages
    verify
    install_wdn_command
    report
}

main "$@"
