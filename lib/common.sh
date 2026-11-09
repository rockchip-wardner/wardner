#!/usr/bin/env bash
# wdnwebui 一键安装器 —— 公共配置与工具函数
#
# 被 install.sh / update.sh source，**不要**直接执行。
#
# 板端没有 emoji / 符号字体：`🖼 ✕ ⚠ ✓ ☑ ▯ 🗑 📁` 全部渲染成豆腐块（□）。
#    板端可用的只有 `× ● ■ ▶ ← → ↑ ↓` —— 下面的输出只用这些。

# ---------------------------------------------------------------------------
# 配置（都可用环境变量覆盖，方便测试与定制）
#
# WARDNER_ORG / WARDNER_REPO_NAME 由 install.sh 的 bootstrap 阶段**推断**
# 出来（从脚本自身的来源 URL 反推，见 lib/urls.sh）—— 硬编码组织名的话，
# 换个组织 / 换个 fork 就得改代码。这里只是兜底默认值。
# ---------------------------------------------------------------------------
: "${WARDNER_HOME:=$HOME/.wardner}"                 # 安装根目录
: "${WARDNER_ORG:=rockchip-wardner}"                # GitHub 组织（由来源 URL 推断）
: "${WARDNER_REPO_NAME:=wardner}"                   # 本仓名（由来源 URL 推断）
: "${WARDNER_REPO_URL:=https://github.com/$WARDNER_ORG/$WARDNER_REPO_NAME.git}"
: "${WARDNER_HOST_REPO:=wdnwebui}"                  # 宿主应用仓名
: "${WARDNER_PKG_BASE:=git+https://github.com/$WARDNER_ORG}"
: "${WARDNER_PYTHON:=python3}"
: "${WARDNER_BRANCH:=master}"

WARDNER_HOME="${WARDNER_HOME%/}"
WARDNER_REPO_DIR="$WARDNER_HOME/$WARDNER_REPO_NAME"              # 本仓
WARDNER_HOST_DIR="$WARDNER_HOME/$WARDNER_HOST_REPO"               # 宿主应用
WARDNER_VENV="$WARDNER_HOST_DIR/.venv"                         # 虚拟环境
WARDNER_VENV_SRC="$WARDNER_VENV/src"                           # SDK / 插件包
WARDNER_PACKAGES_CONF="${WARDNER_PACKAGES_CONF:-$SCRIPT_DIR/packages.conf}"

# ---------------------------------------------------------------------------
# 输出
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
# 工具
# ---------------------------------------------------------------------------
need_cmd() {
    local c="$1" hint="${2:-}"
    command -v "$c" >/dev/null 2>&1 && return 0
    die "缺少命令 '$c'${hint:+ —— $hint}"
}

# ---------------------------------------------------------------------------
# git 重试
#
# 一键安装最怕的就是「网络抖一下，整套装失败」：GitHub 在部分网络下会
# GnuTLS recv error / connection reset / RPC failed，clone 到一半断掉。
# 这类失败重试一次通常就成了，所以重试几次再判死刑。
#
# 永久性失败（本地与远端分叉）重试也没用，但重试次数少、间隔短，
# 代价可以接受 —— 真正报错的信息在最后一次尝试里是完整可见的。
#
# ⚠️ **只走 HTTPS**，不提供 SSH 回退：公网用户大多没配 GitHub SSH key，
#    走 SSH 只会卡在 "Permission denied (publickey)" / 密码提示上。
#    公开仓的 HTTPS 匿名 clone 是唯一对「没登录的人」友好的路径。
#
# lowSpeedLimit/lowSpeedTime：git 默认**没有**连接超时，TCP 层的失败要等
# 135s 才报出来（实测 "Failed to connect ... after 135137 ms"）。这在
# 9 个仓的安装里意味着一次抖动就要等十几分钟。设成「30 秒内不到 1 字节
# 就 abort」把失败尝试压到 30s，配合重试总耗时可控。
# ---------------------------------------------------------------------------
: "${WARDNER_GIT_RETRY:=5}"
: "${WARDNER_RETRY_DELAY:=5}"
: "${WARDNER_GIT_LOW_SPEED_LIMIT:=1}"
: "${WARDNER_GIT_LOW_SPEED_TIME:=30}"

# git 的网络参数（放在子命令前）
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
        warn "$label 失败（第 ${attempt}/${WARDNER_GIT_RETRY} 次），${WARDNER_RETRY_DELAY}s 后重试"
        attempt=$((attempt + 1))
        sleep "$WARDNER_RETRY_DELAY"
    done
}

# 克隆或快进一个仓库。已存在则 pull --ff-only（本地有改动 / 分叉时不硬来）。
# $1 = 目标目录  $2 = GitHub 仓库名
fetch_repo() {
    local dir="$1" name="$2"
    local url="https://github.com/$WARDNER_ORG/$name.git"

    if [ -d "$dir/.git" ]; then
        log "更新 $name"
        if ! git_retry "git pull $name" \
            git -C "$dir" "${GIT_NET_OPTS[@]}" pull --ff-only; then
            warn "$name 本地与远端已分叉（或有未提交改动），跳过更新"
            warn "  手工处理： git -C $dir status"
            return 1
        fi
        return 0
    fi

    log "克隆 $name"
    mkdir -p "$(dirname "$dir")"
    rm -rf "$dir"
    if ! git_retry "git clone $name" \
        git "${GIT_NET_OPTS[@]}" clone --branch "$WARDNER_BRANCH" "$url" "$dir"; then
        die "克隆 $name 失败： $url"
    fi
}

# 读 packages.conf 的每一行 → "pkg<TAB>repo"。跳过空行与 # 注释。
read_packages() {
    [ -f "$WARDNER_PACKAGES_CONF" ] || die "找不到包清单 $WARDNER_PACKAGES_CONF"
    while read -r pkg repo _rest; do
        [ -z "${pkg:-}" ] && continue
        case "$pkg" in \#*) continue ;; esac
        [ -z "${repo:-}" ] && continue
        printf '%s %s\n' "$pkg" "$repo"
    done < "$WARDNER_PACKAGES_CONF"
}
