#!/usr/bin/env bash
# wardner 来源判定的回归脚本。
#
# 纯 bash、离线可跑（末尾「三仓同源」一项需要网络，可用 --no-net 跳过）。
#
# 覆盖：
#   1. 来源优先级：env > 入口脚本 > 已装 remote > /proc 探测 > 内置兜底
#   2. 取文件地址（raw / blob / *.sh）归一化成 clone 地址
#   3. 兜底时必须打告警 —— 不静默换源
#   4. /proc 扫描零噪音
#   5. 两个入口脚本各自声明自己的源站
#   6. 三仓内容同源（需要网络）
#
# 用法：bash scripts/verify_source_selection.sh [--no-net]

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
# 抽出 install.sh 里的来源解析逻辑，做函数级测试
#
# install.sh 的 bootstrap 段会真的 clone 仓，不能整段跑 —— 只抽「来源解析」
# 这一段（靠 install.sh 里的 >>> / <<< 标记定位）。
# ---------------------------------------------------------------------------
{
    sed -n '/^source_url_is_file_url()/,/^}/p' install.sh
    sed -n '/^source_url_host()/,/^}/p' install.sh
    sed -n '/^    # >>> 来源解析开始/,/^    # <<< 来源解析结束/p' install.sh
} > "$TMP/resolver.sh"

if ! grep -q 'WARDNER_REPO_URL' "$TMP/resolver.sh"; then
    bad "抽不出来源解析段 —— install.sh 的标记或结构变了"
    exit 1
fi

# 跑一个来源判定用例，输出 "<host>|<scheme>|<org>|<repo>|<clone url>"
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

expect() {  # $1=描述 $2=期望 $3=实际
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1"
        printf '      期望: %s\n' "$2"
        printf '      实际: %s\n' "$3"
    fi
}

# ---------------------------------------------------------------------------
sec "1. 来源优先级"
# ---------------------------------------------------------------------------

got="$(resolve x WARDNER_REPO_URL=https://gitee.com/rockchip-wardner/wardner.git)"
expect "env 指定 clone 地址 → 走 gitee" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_SELF_SOURCE_URL=https://gitee.com/rockchip-wardner/wardner.git)"
expect "入口脚本声明的源 → 走 gitee" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_REPO_URL=https://github.com/rockchip-wardner/wardner.git \
                  WARDNER_SELF_SOURCE_URL=https://gitee.com/rockchip-wardner/wardner.git)"
expect "env 优先于入口脚本" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_SELF_SOURCE_URL=git@10.10.10.10:wardner/wardner.git)"
expect "内网源 → ssh 协议" \
    "10.10.10.10|ssh|wardner|wardner|git@10.10.10.10:wardner/wardner.git" "$got"

got="$(resolve x WARDNER_SELF_SOURCE_URL=https://gitee.com/rockchip-wardner/wardner.git \
                  WARDNER_SOURCE_HOST=github.com)"
expect "env 的 WARDNER_SOURCE_HOST 覆盖入口脚本" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

# 已安装的仓 → 以现有 remote 为准（update.sh / 重跑不会换源）
rm -rf "$TMP/home"; mkdir -p "$TMP/home/wardner"
git -C "$TMP/home/wardner" init -q
git -C "$TMP/home/wardner" remote add origin https://gitee.com/rockchip-wardner/wardner.git
got="$(resolve x)"
expect "已装仓 → 以现有 remote 为准" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

# ---------------------------------------------------------------------------
sec "2. 取文件地址归一化"
# ---------------------------------------------------------------------------

got="$(resolve x WARDNER_REPO_URL=https://gitee.com/rockchip-wardner/wardner/raw/master/install.sh)"
expect "raw 取文件地址 → 归一化成 clone 地址" \
    "gitee.com|https|rockchip-wardner|wardner|https://gitee.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_REPO_URL=https://github.com/rockchip-wardner/wardner/blob/master/install.sh)"
expect "blob 地址 → 归一化成 clone 地址" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

got="$(resolve x WARDNER_REPO_URL=https://github.com/rockchip-wardner/wardner)"
expect "无 .git 后缀的仓库地址 → 原样用" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner" "$got"

# ---------------------------------------------------------------------------
sec "3. 兜底必须告警"
# ---------------------------------------------------------------------------

rm -rf "$TMP/home"; mkdir -p "$TMP/home"
got="$(resolve x)"
expect "全都没命中 → 落到内置默认源" \
    "github.com|https|rockchip-wardner|wardner|https://github.com/rockchip-wardner/wardner.git" "$got"

if grep -q "没能确定来源 URL" "$TMP/err"; then
    ok "兜底时打印了告警（不静默换源）"
else
    bad "兜底时没有告警 —— 用户会以为装的是自己选的源"
    sed 's/^/      /' "$TMP/err"
fi

# ---------------------------------------------------------------------------
sec "4. /proc 扫描零噪音"
# ---------------------------------------------------------------------------

: > "$TMP/noise"
# 轮数：60 轮约 1.5 分钟（每轮要把全量 pid 扫一遍）。想更狠可以调大。
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
    ok "$ROUNDS 轮全量 pid 扫描，stderr 零字节"
else
    bad "/proc 扫描漏出了 $noise_bytes 字节噪音"
    head -5 "$TMP/noise" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
sec "5. 入口脚本各自声明源站"
# ---------------------------------------------------------------------------

gh_url="$(sed -n 's/^WARDNER_SELF_SOURCE_URL="\(.*\)"$/\1/p' install_github.sh)"
if [ "$gh_url" = "https://github.com/rockchip-wardner/wardner.git" ]; then
    ok "install_github.sh 声明 GitHub 源"
else
    bad "install_github.sh 声明的源不对： $gh_url"
fi

gt_url="$(sed -n 's/^WARDNER_SELF_SOURCE_URL="\(.*\)"$/\1/p' install_gitee.sh)"
if [ "$gt_url" = "https://gitee.com/rockchip-wardner/wardner.git" ]; then
    ok "install_gitee.sh 声明 Gitee 源"
else
    bad "install_gitee.sh 声明的源不对： $gt_url"
fi

for f in install_github.sh install_gitee.sh; do
    if grep -q '_INSTALLER_URL="https://' "$f"; then
        ok "$f 指向了同一个源站上的 install.sh"
    else
        bad "$f 没有正确指向 install.sh"
    fi
done

# ---------------------------------------------------------------------------
sec "6. 三仓同源"
# ---------------------------------------------------------------------------

if [ "$CHECK_NET" -eq 0 ]; then
    printf '  （--no-net，跳过）\n'
else
    same=1
    for f in install.sh install_github.sh install_gitee.sh; do
        gh="https://github.com/rockchip-wardner/wardner/raw/master/$f"
        gt="https://gitee.com/rockchip-wardner/wardner/raw/master/$f"
        curl -fsSL --max-time 30 "$gh" -o "$TMP/gh-$f" 2>/dev/null || { bad "拉取 GitHub 的 $f 失败"; same=0; continue; }
        curl -fsSL --max-time 30 "$gt" -o "$TMP/gt-$f" 2>/dev/null || { bad "拉取 Gitee 的 $f 失败"; same=0; continue; }
        if cmp -s "$TMP/gh-$f" "$TMP/gt-$f"; then
            ok "$f 两个站的内容一致"
        else
            bad "$f 两个站的内容**不一致** —— Gitee 的镜像还没同步"
            diff "$TMP/gh-$f" "$TMP/gt-$f" | head -10 | sed 's/^/      /'
            same=0
        fi
    done
    if [ "$same" -eq 1 ]; then
        ok "三仓同源"
    fi
fi

# ---------------------------------------------------------------------------
sec "7. 入口脚本的下载 / 执行机制（用假的 curl，不联网、不碰真实安装）"
# ---------------------------------------------------------------------------

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN" "$TMP/work"

cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# 假的 curl：只认 "-o <file> <url>"，写一份 stub 进去。
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
    ok "install_gitee.sh 把源站声明传给了安装器"
else
    bad "install_gitee.sh 没有把源站声明传下去"
    printf '%s\n' "$out" | sed 's/^/      /'
fi

if printf '%s' "$out" | grep -q "ARGS=--dummy-arg"; then
    ok "入口脚本把参数转发给了安装器"
else
    bad "入口脚本没有转发参数"
    printf '%s\n' "$out" | sed 's/^/      /'
fi

if grep -q "gitee.com/rockchip-wardner/wardner/raw/master/install.sh" "$CURL_LOG"; then
    ok "入口脚本从**同一个源站**下载 install.sh"
else
    bad "入口脚本下载的 install.sh 地址不对"
    sed 's/^/      /' "$CURL_LOG"
fi

leftover="$(find "$TMP/work" -name 'wardner-install.*' 2>/dev/null | wc -l)"
if [ "$leftover" -eq 0 ]; then
    ok "临时文件用完即删"
else
    bad "临时文件残留了 $leftover 个"
fi

# 下载失败必须**硬失败**（不能静默跑一个空脚本然后 exit 0）
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
chmod +x "$STUB_BIN/curl"

out="$(TMPDIR="$TMP/work" PATH="$STUB_BIN:$PATH" bash install_gitee.sh 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "下载安装器失败"; then
    ok "下载失败时硬失败并给出提示（不会静默装了个空壳）"
else
    bad "下载失败时的行为不对（rc=$rc）"
    printf '%s\n' "$out" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then
    printf '\033[1;32m全部通过\033[0m（%d 项）\n' "$pass"
    exit 0
fi
printf '\033[1;31m有 %d 项失败\033[0m（通过 %d 项）\n' "$fail" "$pass"
exit 1
