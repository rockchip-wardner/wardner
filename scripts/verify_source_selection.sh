#!/usr/bin/env bash
# Regression script for the source selection logic of wardner.
#
# Pure bash, runs offline (the last section, "all three repos share the
# source", needs the network and can be skipped with --no-net).
#
# Covers:
#   1. Source priority: env > entry script > installed remote > /proc probe >
#      built-in fallback
#   2. File URLs (raw / blob / *.sh) normalised into clone URLs
#   3. The fallback must warn — never switch source silently
#   4. Zero noise while scanning /proc
#   5. Each entry script declares its own source site
#   6. All three repos share the same content (needs the network)
#
# Usage: bash scripts/verify_source_selection.sh [--no-net]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK_NET=1
[ "${1:-}" = "--no-net" ] && CHECK_NET=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wardner-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  \033[1;32m●\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  \033[1;31m×\033[0m %s\n' "$*"; fail=$((fail + 1)); }
sec() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Extract the source resolution logic from install.sh and test it at
# function level
#
# The bootstrap section of install.sh really clones repos, so it cannot run
# as a whole — only the "source resolution" part is extracted (located via
# the >>> / <<< markers inside install.sh).
# ---------------------------------------------------------------------------
{
    sed -n '/^source_url_is_file_url()/,/^}/p' install.sh
    sed -n '/^source_url_host()/,/^}/p' install.sh
    sed -n '/^    # >>> source resolution begins/,/^    # <<< source resolution ends/p' install.sh
} > "$TMP/resolver.sh"

if ! grep -q 'WARDNER_REPO_URL' "$TMP/resolver.sh"; then
    bad "could not extract the source resolution block — the markers or the structure of install.sh changed"
    exit 1
fi

# Run one source selection case, prints "<host>|<scheme>|<org>|<repo>|<clone url>"
resolve() {
    local desc="$1"; shift
    env "$@" WARDNER_HOME="$TMP/home" bash -c '
        set -uo pipefail
        . "$1"
        printf "%s|%s|%s|%s|%s\n" \
            "$WARDNER_SOURCE_HOST" "$WARDNER_SOURCE_SCHEME" \
            "$WARDNER_ORG" "$WARDNER_REPO_NAME" "$WARDNER_REPO_URL"
    ' _ "$TMP/resolver.sh" 2> "$TMP/err"
}

expect() {  # $1=description $2=expected $3=actual
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1"
        printf '      expected: %s\n' "$2"
        printf '      actual:   %s\n' "$3"
    fi
}

# ---------------------------------------------------------------------------
sec "1. Source priority"
# ---------------------------------------------------------------------------

got="$(resolve x WARDNER_REPO_URL=https://gitee.com/rockchip-wardner/wardner.git)"
expect "env sets the clone URL → gitee is used" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_SELF_SOURCE_URL=https://gitee.com/rockchip-wardner/wardner.git)"
expect "the source declared by the entry script → gitee is used" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_REPO_URL=https://github.com/rockchip-wardner/wardner.git \
                  WARDNER_SELF_SOURCE_URL=https://gitee.com/rockchip-wardner/wardner.git)"
expect "env wins over the entry script" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_SELF_SOURCE_URL=git@10.10.10.10:wardner/wardner.git)"
expect "intranet source → ssh scheme" \
    "10.10.10.10|ssh|wardner|wardner|git@10.10.10.10:wardner/wardner.git" "$got"

got="$(resolve x WARDNER_SELF_SOURCE_URL=https://gitee.com/rockchip-wardner/wardner.git \
                  WARDNER_SOURCE_HOST=github.com)"
expect "WARDNER_SOURCE_HOST in the env overrides the entry script" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

# The already installed repo → the existing remote wins (update.sh / a
# reinstall never switches the source)
rm -rf "$TMP/home"; mkdir -p "$TMP/home/wardner"
git -C "$TMP/home/wardner" init -q
git -C "$TMP/home/wardner" remote add origin https://gitee.com/rockchip-wardner/wardner.git
got="$(resolve x)"
expect "already installed repo → the existing remote wins" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

# ---------------------------------------------------------------------------
sec "2. Normalising file URLs"
# ---------------------------------------------------------------------------

got="$(resolve x WARDNER_REPO_URL=https://gitee.com/rockchip-wardner/wardner/raw/master/install.sh)"
expect "a raw file URL → normalised into a clone URL" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_REPO_URL=https://github.com/rockchip-wardner/wardner/blob/master/install.sh)"
expect "a blob URL → normalised into a clone URL" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_REPO_URL=https://github.com/rockchip-wardner/wardner)"
expect "a repo URL without the .git suffix → used as is" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner" "$got"

# ---------------------------------------------------------------------------
sec "3. The fallback must warn"
# ---------------------------------------------------------------------------

rm -rf "$TMP/home"; mkdir -p "$TMP/home"
got="$(resolve x)"
expect "nothing matched → the built-in default source is used" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

if grep -q "could not determine the source URL" "$TMP/err"; then
    ok "the fallback prints a warning (the source is never switched silently)"
else
    bad "the fallback did not warn — users would think they installed the source they picked"
    sed 's/^/      /' "$TMP/err"
fi

# ---------------------------------------------------------------------------
sec "4. Zero noise while scanning /proc"
# ---------------------------------------------------------------------------

: > "$TMP/noise"
# 60 rounds is about 1.5 minutes (each round scans every pid). Crank it up
# if you want it rougher.
ROUNDS="${WARDNER_VERIFY_ROUNDS:-60}"
for _ in $(seq 1 "$ROUNDS"); do
    for _p in /proc/[0-9]*; do
        _cmd="$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline")" || continue
        case "$_cmd" in *curl*install.sh*) ;; *) continue ;; esac
        _u="$(printf '%s\n' "$_cmd" | grep -oE 'https?://[^ ]+' | head -1)"
        [ -n "$_u" ] && break
    done
done 2>> "$TMP/noise"

noise_bytes="$(wc -c < "$TMP/noise")"
if [ "$noise_bytes" -eq 0 ]; then
    ok "$ROUNDS rounds of a full pid scan produced zero bytes on stderr"
else
    bad "the /proc scan leaked $noise_bytes bytes of noise"
    head -5 "$TMP/noise" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
sec "5. Each entry script declares its own source site"
# ---------------------------------------------------------------------------

gh_url="$(sed -n 's/^WARDNER_SELF_SOURCE_URL="\(.*\)"$/\1/p' install_github.sh)"
if [ "$gh_url" = "https://github.com/rockchip-wardner/wardner.git" ]; then
    ok "install_github.sh declares the GitHub source"
else
    bad "install_github.sh declares the wrong source: $gh_url"
fi

gt_url="$(sed -n 's/^WARDNER_SELF_SOURCE_URL="\(.*\)"$/\1/p' install_gitee.sh)"
if [ "$gt_url" = "https://gitee.com/rockchip-wardner/wardner.git" ]; then
    ok "install_gitee.sh declares the Gitee source"
else
    bad "install_gitee.sh declares the wrong source: $gt_url"
fi

for f in install_github.sh install_gitee.sh; do
    if grep -q '_INSTALLER_URL="https://' "$f"; then
        ok "$f points at install.sh on the same source site"
    else
        bad "$f does not point at install.sh correctly"
    fi
done

# ---------------------------------------------------------------------------
sec "6. All three repos share the same source"
# ---------------------------------------------------------------------------

if [ "$CHECK_NET" -eq 0 ]; then
    printf '  (--no-net, skipped)\n'
else
    # Take the file from the GitHub side. raw.githubusercontent.com is often
    # unreachable on mainland networks, so try raw first and fall back to
    # git clone (the git protocol over ssh/https usually still works).
    GH_DIR="$TMP/gh"
    rm -rf "$GH_DIR"
    if ! timeout 60 git clone --depth 1 --quiet \
            https://github.com/rockchip-wardner/wardner.git "$GH_DIR" 2>/dev/null; then
        if ! timeout 60 git clone --depth 1 --quiet \
                git@github.com:rockchip-wardner/wardner.git "$GH_DIR" 2>/dev/null; then
            bad "cannot reach the GitHub repo — this machine cannot reach GitHub, so the check is impossible"
            GH_DIR=""
        fi
    fi

    if [ -n "$GH_DIR" ]; then
        for f in install.sh install_github.sh install_gitee.sh; do
            gt="https://gitee.com/rockchip-wardner/wardner/raw/master/$f"
            if ! timeout 40 curl -fsSL --max-time 35 "$gt" -o "$TMP/gt-$f" 2>/dev/null; then
                bad "failed to fetch $f from Gitee"
                continue
            fi
            if cmp -s "$GH_DIR/$f" "$TMP/gt-$f"; then
                ok "$f is identical on both sites"
            else
                bad "$f differs between the two sites — the Gitee mirror is not synced yet"
                diff "$GH_DIR/$f" "$TMP/gt-$f" | head -10 | sed 's/^/      /'
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
sec "7. The download / exec mechanism of the entry scripts (a fake curl, no network, no real install)"
# ---------------------------------------------------------------------------

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN" "$TMP/work"

cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# A fake curl: it only understands "-o <file> <url>" and writes a stub into it.
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *)  url="$1"; shift ;;
    esac
done
[ -n "${CURL_LOG:-}" ] && printf '%s\n' "$url" >> "$CURL_LOG"
printf '#!/usr/bin/env bash\necho "SELF_SOURCE=$WARDNER_SELF_SOURCE_URL"\necho "ARGS=$*"\n' > "$out"
STUB
chmod +x "$STUB_BIN/curl"

export CURL_LOG="$TMP/curl.log"
: > "$CURL_LOG"

out="$(TMPDIR="$TMP/work" PATH="$STUB_BIN:$PATH" bash install_gitee.sh --dummy-arg 2>&1)"

if printf '%s' "$out" | grep -q "SELF_SOURCE=https://gitee.com/rockchip-wardner/wardner.git"; then
    ok "install_gitee.sh passes the declared source site to the installer"
else
    bad "install_gitee.sh does not pass the declared source site down"
    printf '%s\n' "$out" | sed 's/^/      /'
fi

if printf '%s' "$out" | grep -q "ARGS=--dummy-arg"; then
    ok "the entry script forwards the arguments to the installer"
else
    bad "the entry script does not forward the arguments"
    printf '%s\n' "$out" | sed 's/^/      /'
fi

if grep -q "gitee.com/rockchip-wardner/wardner/raw/master/install.sh" "$CURL_LOG"; then
    ok "the entry script downloads install.sh from the **same source site**"
else
    bad "the entry script downloads install.sh from the wrong URL"
    sed 's/^/      /' "$CURL_LOG"
fi

leftover="$(find "$TMP/work" -name 'wardner-install.*' 2>/dev/null | wc -l)"
if [ "$leftover" -eq 0 ]; then
    ok "the temporary file is removed right after use"
else
    bad "$leftover temporary files were left behind"
fi

# A failed download must **fail hard** (never silently run an empty script
# and exit 0)
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
chmod +x "$STUB_BIN/curl"

out="$(TMPDIR="$TMP/work" PATH="$STUB_BIN:$PATH" bash install_gitee.sh 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "failed to download the installer"; then
    ok "a failed download fails hard and says so (never a silent empty shell)"
else
    bad "the behaviour on a failed download is wrong (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then
    printf '\033[1;32mall checks passed\033[0m (%d)\n' "$pass"
    exit 0
fi
printf '\033[1;31m%d checks failed\033[0m (%d passed)\n' "$fail" "$pass"
exit 1
