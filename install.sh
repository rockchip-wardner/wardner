#!/usr/bin/env bash
# wdnwebui 一键安装器
#
#   curl -fsSL https://github.com/rockchip-wardner/wardner/raw/master/install.sh | bash
#
# 等价的写法（同一个文件）：
#   curl -fsSL https://raw.githubusercontent.com/rockchip-wardner/wardner/master/install.sh | bash
#
# ⚠️ 注意是 **/raw/master/**，不能写成 .../wardner/install.sh —— 后者是 GitHub
#    的网页路由，不是原始文件地址（curl 会拿到 404 或一段 HTML）。
#
# 装到 ~/.wardner 下：
#
#   ~/.wardner/wardner/                    本仓（安装器自身，便于日后更新）
#   ~/.wardner/wdnwebui/                   宿主应用（FastAPI 服务 + 卡片宿主）
#   ~/.wardner/wdnwebui/.venv/             虚拟环境
#   ~/.wardner/wdnwebui/.venv/src/<pkg>/   8 个 SDK / 卡片插件包（各自独立 git 仓）
#
# 幂等：重跑一次 = 拉最新 + 重装。HEAD 没变的包会跳过重装（见 update_rkwhl.sh）。
#
# 实际装包、产物校验、依赖审计都交给 wdnwebui 仓里的 update_rkwhl.sh —— 那
# 470 行是在板子上打磨出来的（.so 落地断言、editable 残留清理、卡片注册校验、
# SDK 声明依赖审计），这里**不重复实现**，只负责把代码拉到该在的位置。

set -euo pipefail

# ---------------------------------------------------------------------------
# Phase 0: bootstrap
#
# `curl | bash` 时本文件并不在磁盘上 —— BASH_SOURCE 指向的是 "bash"，拿不到
# 真实的脚本目录，也就 source 不了 lib/。所以第一件事是把本仓克隆到本地，
# 然后 exec 克隆出来的那份：那份有真实的 SCRIPT_DIR。
#
# WARDNER_BOOTSTRAPPED 是防递归哨兵 —— 克隆版带着它跑，就不会再次 bootstrap。
# ---------------------------------------------------------------------------
if [ -z "${WARDNER_BOOTSTRAPPED:-}" ]; then
    : "${WARDNER_HOME:=$HOME/.wardner}"
    WARDNER_HOME="${WARDNER_HOME%/}"
    : "${WARDNER_ORG:=rockchip-wardner}"
    : "${WARDNER_REPO_URL:=https://github.com/$WARDNER_ORG/wardner.git}"
    _repo_dir="$WARDNER_HOME/wardner"
    : "${WARDNER_GIT_RETRY:=3}"
    : "${WARDNER_RETRY_DELAY:=5}"

    if ! command -v git >/dev/null 2>&1; then
        printf '\033[1;31m[fail]\033[0m 缺少 git，请先安装（apt install git）\n' >&2
        exit 1
    fi

    mkdir -p "$WARDNER_HOME"

    # clone / pull 都可能被网络抖动打断，重试几次再判失败。
    #
    # ⚠️ 只走 HTTPS：公网用户大多没配 GitHub SSH key，走 SSH 只会卡在
    #    "Permission denied (publickey)" 或密码提示上。公开仓的 HTTPS
    #    匿名 clone 才是对「没登录的人」友好的唯一路径。
    #
    # 这段在 source lib/common.sh **之前**跑（那时还不知道脚本目录），
    # 所以用不了 common.sh 里的 fetch_repo —— 重复一小段是刻意的。
    _try=1
    while true; do
        if [ -d "$_repo_dir/.git" ]; then
            git -C "$_repo_dir" pull --ff-only >/dev/null 2>&1 && break
            _what="git pull wardner"
        else
            rm -rf "$_repo_dir"
            git clone "$WARDNER_REPO_URL" "$_repo_dir" >/dev/null 2>&1 && break
            _what="git clone wardner"
        fi
        if [ "$_try" -ge "$WARDNER_GIT_RETRY" ]; then
            printf '\033[1;31m[fail]\033[0m %s 失败（已重试 %s 次）\n' "$_what" "$WARDNER_GIT_RETRY" >&2
            exit 1
        fi
        printf '\033[1;33m[warn]\033[0m %s 失败（第 %s/%s 次），%ss 后重试\n' \
            "$_what" "$_try" "$WARDNER_GIT_RETRY" "$WARDNER_RETRY_DELAY" >&2
        _try=$((_try + 1))
        sleep "$WARDNER_RETRY_DELAY"
    done

    export WARDNER_BOOTSTRAPPED=1
    exec bash "$_repo_dir/install.sh" "$@"
fi

# --- 到这里才拿得到真实路径 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Phase 1: 前置检查
# ---------------------------------------------------------------------------
preflight() {
    step "前置检查"

    need_cmd git "apt install git"
    need_cmd "$WARDNER_PYTHON" "apt install python3"

    local ver
    ver="$("$WARDNER_PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    local major="${ver%%.*}" minor="${ver##*.}"
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 9 ]; }; then
        die "需要 Python >= 3.9，当前是 $ver"
    fi
    ok "Python $ver"

    # Debian/Ubuntu 的 python3-venv 是单独的包，缺了 `python3 -m venv` 会报
    # "ensurepip is not available"。提前说清楚，别让用户对着报错猜。
    if ! "$WARDNER_PYTHON" -c 'import ensurepip, venv' >/dev/null 2>&1; then
        die "缺 venv 模块（Debian/Ubuntu: sudo apt install python3-venv）"
    fi
    ok "venv 模块可用"
}

# ---------------------------------------------------------------------------
# Phase 2: 拉宿主应用
# ---------------------------------------------------------------------------
fetch_host() {
    step "拉取宿主应用 $WARDNER_HOST_REPO"
    fetch_repo "$WARDNER_HOST_DIR" "$WARDNER_HOST_REPO" \
        || die "宿主应用拉取失败"
    ok "$WARDNER_HOST_REPO @ $WARDNER_HOST_DIR"
}

# ---------------------------------------------------------------------------
# Phase 3: 建 venv
# ---------------------------------------------------------------------------
create_venv() {
    step "创建虚拟环境"
    if [ -x "$WARDNER_VENV/bin/python" ]; then
        ok "复用已有 venv（$WARDNER_VENV）"
    else
        mkdir -p "$(dirname "$WARDNER_VENV")"
        "$WARDNER_PYTHON" -m venv "$WARDNER_VENV" \
            || die "创建 venv 失败（Debian/Ubuntu: sudo apt install python3-venv）"
        ok "已创建 $WARDNER_VENV"
    fi
    "$WARDNER_VENV/bin/python" -m pip install --quiet --upgrade pip setuptools wheel
    ok "pip 就绪（$("$WARDNER_VENV/bin/python" -m pip --version | cut -d' ' -f1-2)）"
}

# ---------------------------------------------------------------------------
# Phase 4: 拉 SDK / 插件包
#
# 必须**先 clone 到 .venv/src/ 再让 pip 装**：
# update_rkwhl.sh 的 "目录不存在" 分支走的是 `pip install -e <git+url>`，
# 而 pip 对 VCS 的 editable 安装是把仓库 clone 到临时目录再指向它 —— 临时
# 目录装完就被删，editable 安装当场就废（import 报 ModuleNotFoundError），
# 而 pip 全程报成功。
# ---------------------------------------------------------------------------
fetch_packages() {
    step "拉取 SDK / 卡片插件包"
    mkdir -p "$WARDNER_VENV_SRC"
    local pkg repo n=0
    while read -r pkg repo; do
        [ -z "${pkg:-}" ] && continue
        fetch_repo "$WARDNER_VENV_SRC/$pkg" "$repo" || warn "$pkg 拉取失败，跳过"
        n=$((n + 1))
    done <<EOF
$(read_packages)
EOF
    ok "共 $n 个包 → $WARDNER_VENV_SRC"
}

# ---------------------------------------------------------------------------
# Phase 5: 编译依赖
#
# wdndds 的 .so 是**装的时候现场编**的（_build.py 的 build_py 钩子），
# 需要 cmake / g++ / patchelf / foonathan 开发头文件。
#
# FastDDS 3.6 的官方预编译产物是**随 wdndds 仓一起分发**的
# （native/lib/ 下），不需要联网编译 —— 这点很关键，板子常常没外网。
# native/bin/nodesize_dbg 桩也在仓里，不需要额外生成。
# ---------------------------------------------------------------------------
ensure_build_deps() {
    step "检查编译依赖（wdndds 的 .so 要现场编）"

    local need=()
    local p
    for p in cmake build-essential patchelf libfoonathan-memory-dev; do
        dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
    done

    if [ ${#need[@]} -eq 0 ]; then
        ok "编译依赖齐全"
        return 0
    fi

    if [ "$(id -u)" -eq 0 ]; then
        log "安装 apt 依赖： ${need[*]}"
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y "${need[@]}" >/dev/null 2>&1 \
            || warn "apt 安装失败，继续往下走"
        ok "编译依赖处理完毕"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        log "用 sudo 安装 apt 依赖： ${need[*]}"
        sudo apt-get update -qq >/dev/null 2>&1 || true
        sudo apt-get install -y "${need[@]}" >/dev/null 2>&1 \
            || warn "apt 安装失败，继续往下走"
        ok "编译依赖处理完毕"
        return 0
    fi

    warn "缺编译依赖： ${need[*]}"
    warn "wdndds 的 .so 可能编不出来（算力页会报「功能未启用」）。装完后补："
    warn "  sudo apt-get install -y ${need[*]}"
    warn "  bash $WARDNER_HOST_DIR/update_rkwhl.sh   # 重跑即可补编"
    return 0   # 不致命：其它链路不依赖它
}

# ---------------------------------------------------------------------------
# Phase 6: 装包 + 校验
#
# 真正的安装交给 wdnwebui 仓里的 update_rkwhl.sh：
#   * 装 requirements.txt（web 侧依赖）
#   * 修补 v4l2 的 py3 兼容问题
#   * 逐包 git pull + editable 重装（HEAD 没变就跳过）
#   * 断言 wdndds / wdnav 的 .so 真的落地了（setuptools 会静默吞 hook 失败）
#   * 校验 4 个插件包的卡片真的注册上了（entry point → manifest id → static/）
#   * 审计各 SDK 声明的依赖（--no-deps 装法的对冲）
#
# 首次安装必须 FORCE_REBUILD：刚 clone 出来的包，pull 前后 HEAD 一致，
# update_rkwhl.sh 会判定「HEAD 未变」而跳过安装 —— 结果就是啥都没装。
# ---------------------------------------------------------------------------
install_packages() {
    step "安装与校验"

    local script="$WARDNER_HOST_DIR/update_rkwhl.sh"
    [ -f "$script" ] || die "找不到 $script（宿主仓拉取不完整？）"

    local force=""
    if ! "$WARDNER_VENV/bin/python" -c "import wdnav, wdnai, wdndds, wdnhid" >/dev/null 2>&1; then
        force=1
        note "首次安装 —— 强制重建全部包"
    fi

    # WARDNER_PKG_BASE：让 update_rkwhl.sh 的「目录不存在」兜底路径也走公网，
    # 而不是默认的内网镜像（现场板子没外网时才需要内网）。
    if ! (
        cd "$WARDNER_HOST_DIR" || exit 1
        WARDNER_PKG_BASE="$WARDNER_PKG_BASE" \
        UPDATE_RKWHL_FORCE_REBUILD="$force" \
        bash "$script"
    ); then
        # update_rkwhl.sh 逐包驱动：某个包失败只记 warn 并继续，最后统一
        # 汇总「以下包未更新」并 exit 1。首次安装时这意味着**有包没装上**。
        echo "" >&2
        die "安装未完成 —— 见上方「以下包未更新」的汇总。
     首次安装失败最常见的是网络：clone / pip 拉 GitHub 抖了一下。
     直接重跑本脚本即可（已装好的包会跳过）："
    fi

    ok "全部包安装完成"
}

# ---------------------------------------------------------------------------
# Phase 7: 冒烟验证 + 交付信息
# ---------------------------------------------------------------------------
verify() {
    step "冒烟验证"

    "$WARDNER_VENV/bin/python" - <<'PY' || warn "SDK import 检查未全过"
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

    local so="$WARDNER_VENV_SRC/wdndds/src/wdndds/dds/_native/libwdndds_cshim.so"
    if [ -f "$so" ]; then
        ok "libwdndds_cshim.so 已就位"
    else
        warn "libwdndds_cshim.so 缺失 —— 算力（本地模型）功能不可用"
        warn "  补编： bash $WARDNER_HOST_DIR/update_rkwhl.sh"
    fi

    local shim="$WARDNER_VENV_SRC/wdnav/src/wdnav/lib/libshim_video.so"
    if [ -f "$shim" ]; then
        ok "libshim_video.so 已就位"
    else
        warn "libshim_video.so 缺失 —— 视频编解码不可用"
    fi
}

report() {
    cat >&2 <<EOF

$(printf '%s' "$C_GRN")安装完成。$(printf '%s' "$C_RST")

  安装根目录   $WARDNER_HOME
  宿主应用     $WARDNER_HOST_DIR
  虚拟环境     $WARDNER_VENV
  SDK / 插件   $WARDNER_VENV_SRC

启动服务：

  cd $WARDNER_HOST_DIR
  .venv/bin/python run.py          # 打开 http://<板子IP>:8000/

更新（拉最新 + 重装）：

  $WARDNER_REPO_DIR/install.sh
  # 或： $WARDNER_REPO_DIR/update.sh

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
    report
}

main "$@"
