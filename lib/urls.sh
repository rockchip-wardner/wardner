#!/usr/bin/env bash
# Derive the **source host** + org + repo name from "where this script came from".
#
# Hardcoding org/repo means changing the org, the fork or the mirror site
# requires a code change. This goes the other way: whichever URL the script
# was downloaded from decides the host / org / repo it uses — the installer is
# therefore **self-describing**.
#
# Parse a repository URL and print "<host> <org> <repo>". Supported:
#   https://github.com/<org>/<repo>
#   https://github.com/<org>/<repo>/raw/<branch>/<path>
#   https://github.com/<org>/<repo>/blob/<branch>/<path>
#   https://raw.githubusercontent.com/<org>/<repo>/<branch>/<path>
#   git@github.com:<org>/<repo>.git
#   https://gitee.com/<org>/<repo>            ← mirror
#   https://gitee.com/<org>/<repo>/raw/<branch>/<path>
#   git@gitee.com:<org>/<repo>.git
#   http://<host>:<port>/<org>/<repo>.git     ← intranet GitLab (the port lives in the host)
#
# Rule: **the first two path segments are always org / repo**; everything
# after them (raw / blob / branch / file) is dropped. That way GitHub's
# /raw/ and Gitee's /raw/ share a single parser instead of one each.

# Read-only mirror — content is synced from upstream, pushes get overwritten.
#
# This is not a matter of style: pushing the wrong thing **loses code**. A
# commit pushed to a mirror is overwritten by the upstream version on the
# next sync, with no warning at all. The toolchain therefore has to know
# which hosts must never be pushed to.
wardner_host_is_readonly() {
    case "${1:-}" in
        gitee.com) return 0 ;;
        *)          return 1 ;;
    esac
}

# Source host name → human-readable label (for logs)
wardner_host_label() {
    case "${1:-}" in
        github.com) printf 'GitHub' ;;
        gitee.com)  printf 'Gitee mirror' ;;
        *)           printf '%s' "${1:-?}" ;;
    esac
}

# Parse a repository URL → "<host> <org> <repo>". Returns 1 when unparseable.
parse_repo_url() {
    local url="${1%%\?*}"            # strip query strings like ?raw=1
    url="${url%/}"                   # strip trailing slash
    url="${url%.git}"                # strip .git

    local host="" path=""
    case "$url" in
        git@*:*)
            # git@github.com:org/repo.git
            host="${url#git@}"; host="${host%%:*}"
            path="${url#git@*:}"
            ;;
        ssh://*/*)
            # ssh://git@github.com/org/repo.git
            host="${url#ssh://}"; host="${host%%/*}"; host="${host##*@}"
            path="${url#ssh://*/}"
            ;;
        http://*/*|https://*/*)
            # https://github.com/org/repo/... (an intranet GitLab host carries its port)
            host="${url#*://}"; host="${host%%/*}"
            path="${url#*://*/}"
            ;;
        *) return 1 ;;
    esac

    # raw.githubusercontent.com is the domain for **fetching files**, not for
    # cloning — normalise it to github.com, otherwise we derive a clone URL
    # that does not exist.
    case "$host" in
        raw.githubusercontent.com) host="github.com" ;;
    esac

    # org / repo must be the first two path segments. One segment short and
    # we bail out (better to fail than to guess).
    case "$path" in
        */*) ;;
        *) return 1 ;;
    esac

    local org="${path%%/*}"
    path="${path#*/}"
    local repo="${path%%/*}"

    [ -n "$host" ] && [ -n "$org" ] && [ -n "$repo" ] || return 1
    printf '%s %s %s\n' "$host" "$org" "$repo"
}

# Is this URL a "file URL" rather than a "repository URL"?
#
# Using a raw file URL as a clone URL **fails outright** — git asks for a
# username (observed: "could not read Username for 'https://gitee.com'"), and
# with a TTY it even hangs on the password prompt, so users think the
# installer froze.
#
# ⚠️ install.sh carries an **inline copy** of this in its bootstrap section
#    (lib/urls.sh is not sourced yet at that point) — **change one, change
#    the other**.
source_url_is_file_url() {
    case "${1:-}" in
        */raw/*|*/blob/*) return 0 ;;
        *.sh|*.py|*.json) return 0 ;;
    esac
    return 1
}

# URL → host (used only to compare whether two URLs point at the same site).
#
# ⚠️ install.sh carries an **inline copy** of this in its bootstrap section
#    — change one, change the other.
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

# The git clone URL of a repository
repo_clone_url() {
    repo_clone_url_for https "$@"
}

# Same, but with an explicit scheme — an intranet GitLab over http and an
# SSH source need their own forms; forcing https breaks the clone.
repo_clone_url_for() {
    local scheme="$1" host="$2" org="$3" repo="$4"
    case "$scheme" in
        ssh)  printf 'git@%s:%s/%s.git'   "$(ssh_host "$host")" "$org" "$repo" ;;
        http) printf 'http://%s/%s/%s.git' "$host" "$org" "$repo" ;;
        *)    printf 'https://%s/%s/%s.git' "$host" "$org" "$repo" ;;
    esac
}

# Source host → transport scheme
#
# * **GitHub / Gitee use https** — public repos, anonymous clone is enough,
#   no account / SSH key required. This is the only path that works for
#   users who have never logged in.
# * **Intranet hosts use ssh** — an intranet GitLab serves its web UI on
#   8080, which is an HTTP port; ssh is the right way to fetch the code.
#
# The scheme is decided by the **source host**, not by the scheme of the URL
# the script was downloaded from: an intranet GitLab serves its /raw/ pages
# over http, but the code has to come over ssh.
source_scheme_for_host() {
    case "${1:-}" in
        github.com|gitee.com|"") printf 'https' ;;
        *)                         printf 'ssh' ;;
    esac
}

# The SSH host carries no port — the web UI's 8080 is an HTTP port, not an
# SSH port. Writing git@10.10.10.10:8080:org/repo.git is wrong.
ssh_host() {
    printf '%s' "${1%%:*}"
}

# The pip VCS prefix (used as WARDNER_PKG_BASE by update_rkwhl.sh)
pkg_base_for() {
    local scheme="$1" host="$2" org="$3"
    case "$scheme" in
        ssh)  printf 'git+ssh://git@%s/%s'  "$(ssh_host "$host")" "$org" ;;
        http) printf 'git+http://%s/%s'      "$host" "$org" ;;
        *)    printf 'git+https://%s/%s'     "$host" "$org" ;;
    esac
}

# Scan /proc for curl's command line to infer which URL this script was
# fetched from.
#
# With `curl ... | bash` the script itself does not know the source. curl is
# usually still running (the script is still reading from the pipe), and its
# /proc/<pid>/cmdline carries the full URL.
#
# Only curl command lines containing "install.sh" are considered — otherwise
# an unrelated curl on the machine would be mistaken for ourselves (and
# would yield a completely unrelated org name).
detect_source_url() {
    local p cmd url
    for p in /proc/[0-9]*; do
        # ⚠️ `2>/dev/null` must come **before** the input redirection — the
        #    order cannot be reversed. bash applies redirections left to
        #    right, so a process that exits right then has the shell's own
        #    redirection error swallowed as well.
        # Writing `< file 2>/dev/null` (reversed) leaks "No such file or
        #    directory" noise (scanning hundreds of pids always hits TOCTOU).
        #
        # This is the **same logic** as the bootstrap section of install.sh
        # — change one, change the other.
        cmd="$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" || continue
        case "$cmd" in
            *curl*install.sh*) ;;
            *) continue ;;
        esac
        url="$(printf '%s\n' "$cmd" | grep -oE 'https?://[^ ]+' | head -1)"
        [ -n "$url" ] || continue
        printf '%s\n' "$url"
        return 0
    done
    return 1
}
