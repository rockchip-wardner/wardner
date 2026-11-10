#!/usr/bin/env bash
# wdnwebui 一键安装器
#
#   ── GitHub（默认）────────────────────────────────────────────
#   curl -fsSL https://github.com/rockchip-wardner/wardner/raw/master/install.sh | bash
#
#   ── Gitee 国内镜像（国内网络更快）────────────────────────────
#   curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install.sh | bash
#
# ⚠️ 注意是 **/raw/master/**，不能写成 .../wardner/install.sh —— 那是网页路由，
#    不是原始文件地址（curl 会拿到 404 或一段 HTML）。
#
# 安装器**从你用的那个 URL 推断源站**：从 Gitee 装的，宿主应用和 8 个 SDK /
# 插件包、以及后续的 `wdn update` 也都走 Gitee。
#
# ⚠️ Gitee 是**只读镜像**（内容由上游自动同步）—— 从它拉没问题，**不要往它推**。
#    需要推送请用 GitHub（或内网主仓库）。
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
    # 安装根目录默认放在当前用户的家目录下。
    #
    # 脚本**不自行提权** —— 缺权限时只把命令打出来让操作员自己以 root 身份
    # 跑。所以「谁跑安装器，wdn 命令就装给谁」：家目录就是 $HOME。
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
        printf '\033[1;31m[fail]\033[0m 缺少 git，请先安装（apt install git）\n' >&2
        exit 1
    fi

    # ── 推断「脚本是从哪儿取来的」──────────────────────────────────────
    #
    # 硬编码 org/repo 意味着换组织 / 换 fork 就得改代码。这里反过来：从
    # 来源 URL 反推**源站** + 组织 + 仓库名 —— 安装器因此是**自描述**的。
    #
    # 来源优先级：
    #   1. WARDNER_REPO_URL 环境变量（显式覆盖）
    #   2. curl 的命令行（`curl ... | bash` 时脚本自己不知道来源，但 curl
    #      通常还在跑，/proc/<pid>/cmdline 里带着完整 URL）
    #   3. 内置兜底
    #
    # ⚠️ 这段在 source lib/*.sh **之前**跑（那时还不知道脚本目录），
    #    所以 url 解析逻辑在这里内联了一份 —— lib/urls.sh 是同套逻辑的副本，
    #    **改一处必须改另一处**。
    _src="${WARDNER_REPO_URL:-}"
    _explicit=0
    [ -n "$_src" ] && _explicit=1
    if [ -z "$_src" ]; then
        for _p in /proc/[0-9]*; do
            # ⚠️ `2>/dev/null` 必须写在输入重定向**之前**，顺序不能反。
            #
            # bash 按**从左到右**执行重定向：先把 stderr 换成 /dev/null，之后输入
            # 重定向失败时 shell **自己**报的那句 "No such file or directory" 也
            # 一并被吞掉。写成 `< file 2>/dev/null`（反过来）就漏出这行噪音 ——
            # 扫几百个 pid，总有刚退出的（TOCTOU：glob 展开后进程就死了，
            # /proc/<pid> 被内核摘掉），用户会以为安装出错了。
            _cmd="$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline")" || continue
            case "$_cmd" in *curl*install.sh*) ;; *) continue ;; esac
            _u="$(printf '%s\n' "$_cmd" | grep -oE 'https?://[^ ]+' | head -1)"
            [ -n "$_u" ] && { _src="$_u"; break; }
        done
    fi
    [ -z "$_src" ] && _src="https://github.com/rockchip-wardner/wardner/raw/master/install.sh"

    # 解析来源 URL → "<host> <org> <repo>"。
    #
    # 规律：**路径的前两段永远是 org / repo**，后面的（raw / blob / 分支 / 文件）
    # 一律丢掉 —— 于是 GitHub 的 /raw/ 与 Gitee 的 /raw/ 用同一套解析。
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
    # raw.githubusercontent.com 是**取文件**的域名，不是 clone 的域名
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

    WARDNER_SOURCE_HOST="$_host"
    # 协议由**源站**决定：GitHub / Gitee 走 https（公开仓，匿名 clone），
    # 内网走 ssh（内网 GitLab 的 web 口在 8080，那是 HTTP 端口，取码用 ssh）。
    #
    # ⚠️ 这条规则在 lib/urls.sh::source_scheme_for_host 里也有一份 —— bootstrap
    #    阶段还没 source lib/，只能内联。改一处必须改另一处。
    case "$_host" in
        github.com|gitee.com) _scheme="https" ;;
        *)                     _scheme="ssh" ;;
    esac
    WARDNER_SOURCE_SCHEME="$_scheme"
    WARDNER_ORG="$_org"
    WARDNER_REPO_NAME="$_repo"
    export WARDNER_SOURCE_HOST WARDNER_SOURCE_SCHEME WARDNER_ORG WARDNER_REPO_NAME

    # 用户显式给了 clone 地址就**原样用** —— 里面可能有 port、SSH 形式、
    # 内网 GitLab 的路径前缀，推测出来的地址未必等价。
    if [ "$_explicit" -eq 1 ]; then
        WARDNER_REPO_URL="$_src"
    else
        case "$_scheme" in
            ssh) WARDNER_REPO_URL="git@${_host%%:*}:$_org/$_repo.git" ;;
            *)   WARDNER_REPO_URL="https://$_host/$_org/$_repo.git" ;;
        esac
    fi
    _repo_dir="$WARDNER_HOME/$WARDNER_REPO_NAME"

    mkdir -p "$WARDNER_HOME"

    # clone / pull 都可能被网络抖动打断，重试几次再判失败。
    #
    # ⚠️ 只走 HTTPS：公网用户大多没配 GitHub SSH key，走 SSH 只会卡在
    #    "Permission denied (publickey)" 或密码提示上。公开仓的 HTTPS
    #    匿名 clone 才是对「没登录的人」友好的唯一路径。
    #
    # lowSpeedLimit/lowSpeedTime：git 默认没有连接超时，TCP 层失败要等
    # 135s 才报（实测 "Failed to connect ... after 135137 ms"）。9 个仓
    # 的安装里，一次抖动就能拖掉十几分钟 —— 压到 30s，配合重试总耗时可控。
    _try=1
    while true; do
        if [ -d "$_repo_dir/.git" ]; then
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
# ⚠️ 顺序不能反：common.sh 要用 urls.sh 的 source_scheme_for_host 推导
#    源站协议（GitHub / Gitee → https，内网 → ssh）。
# shellcheck source=lib/urls.sh
. "$SCRIPT_DIR/lib/urls.sh"
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
        die "缺 venv 模块（Debian/Ubuntu: 以 root 身份执行 apt-get install -y python3-venv）"
    fi
    ok "venv 模块可用"

    # ⚠️ 不要写 resolve_source() —— bash 会把「命令位置的 name()」当成函数
    #    **定义**解析，后面的 } 就成了多余的 token，整个脚本语法报错。
    #    函数调用一律不带括号。
    resolve_source
}

# ---------------------------------------------------------------------------
# 以 clone 之后的实际 remote 为准，反推组织 / 仓库名
#
# bootstrap 阶段是从「脚本的来源 URL」推断的，那是推断；clone 之后
# remote 里写着的才是事实。两者不一致时以 remote 为准 —— 比如脚本是从
# 某个 fork 拉的，那 fork 的 remote 就是权威的。
# ---------------------------------------------------------------------------
resolve_source() {
    local remote host org repo scheme
    remote="$(git -C "$WARDNER_REPO_DIR" remote get-url origin 2>/dev/null || true)"
    [ -n "$remote" ] || return 0

    read -r host org repo < <(parse_repo_url "$remote") || return 0
    [ -n "${host:-}" ] && [ -n "${org:-}" ] && [ -n "${repo:-}" ] || return 0

    if [ "$org" != "$WARDNER_ORG" ]; then
        log "源组织： $WARDNER_ORG → $org（以 clone 的 remote 为准）"
    fi
    if [ "$host" != "$WARDNER_SOURCE_HOST" ]; then
        log "源站： $WARDNER_SOURCE_HOST → $host（以 clone 的 remote 为准）"
    fi

    scheme="$(source_scheme_for_host "$host")"
    WARDNER_SOURCE_HOST="$host"
    WARDNER_SOURCE_SCHEME="$scheme"
    WARDNER_ORG="$org"
    WARDNER_REPO_NAME="$repo"
    WARDNER_REPO_DIR="$WARDNER_HOME/$WARDNER_REPO_NAME"
    WARDNER_REPO_URL="$(repo_clone_url_for "$scheme" "$host" "$org" "$repo")"
    # 用户在环境变量里显式指定了包来源（内网镜像等）→ 不覆盖它。
    # 覆盖了就等于把用户特意指定的源静默改掉 —— 那正是 README 里写明的用法。
    if [ -z "$WARDNER_PKG_BASE_ENV" ]; then
        WARDNER_PKG_BASE="$(pkg_base_for "$scheme" "$host" "$org")"
    fi
    export WARDNER_SOURCE_HOST WARDNER_SOURCE_SCHEME WARDNER_ORG WARDNER_REPO_NAME WARDNER_REPO_URL WARDNER_PKG_BASE
    ok "源： $host/$org/$repo"

    if wardner_host_is_readonly "$host"; then
        note "$(wardner_host_label "$host") 是只读镜像（内容由上游自动同步）—— 从它拉没问题，"
        note "但**不要往它推**。要推送请把 remote 指回 GitHub 或内网主仓库。"
    fi
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
            || die "创建 venv 失败（Debian/Ubuntu: 以 root 身份执行 apt-get install -y python3-venv）"
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

    # 非 root：脚本**不自行提权** —— 只把要执行的命令原样打出来，由操作员
    # 自己在 root 身份下跑。缺这几个包只影响 wdndds 的 .so，其余链路不依赖
    # 它，所以不致命。
    warn "缺编译依赖： ${need[*]}"
    warn "wdndds 的 .so 可能编不出来（算力页会报「功能未启用」）。"
    warn "请以 root 身份执行下面三条，然后重跑本脚本补编："
    warn "  apt-get update"
    warn "  apt-get install -y ${need[*]}"
    warn "  bash $WARDNER_HOST_DIR/update_rkwhl.sh"
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

    # WARDNER_PKG_BASE：让 update_rkwhl.sh 的「目录不存在」兜底路径也走**源站**
    # （GitHub 或 Gitee），而不是默认的内网镜像。
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
     首次安装失败最常见的是网络：clone / pip 拉 $WARDNER_SOURCE_HOST 抖了一下。
     直接重跑本脚本即可（已装好的包会跳过）："
    fi

    ok "全部包安装完成"
}

# ---------------------------------------------------------------------------
# Phase 7: 冒烟验证 + 交付信息
# ---------------------------------------------------------------------------
verify() {
    step "冒烟验证"

    # 硬断言：4 个 SDK 必须真的 import 得起来。
    #
    # ⚠️ 这里必须硬失败，不能只 warn —— update_rkwhl.sh 的 verify_outputs 对
    #    wdnai / wdnhid 直接 `return 0`（纯 Python，没有 .so 可断言），而
    #    audit_sdk_deps 只查「SDK 声明的依赖能不能用」，不查包自身能不能
    #    import。于是 .pth / editable 装歪了这类故障会**穿过所有门禁**，
    #    最后还打印一句「安装完成」—— 而 wdnai 是所有 LLM/VLM 能力的底座。
    #
    #    wdndds / wdnav 另有 .so 落地断言兜着，4 个插件包另有卡片注册校验
    #    兜着（find_spec 失败即 BAD）。wdnai / wdnhid 缺的正是这一道。
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
        die "SDK import 检查未通过 —— 上面失败的包没装好。
     常见原因：editable 安装的 .pth 指向了不存在的路径，或某个包的
     clone/pull 中途失败只装了一半。
     修复：删掉对应包目录后重跑本脚本（会重新 clone）：
       rm -rf $WARDNER_VENV_SRC/<包名>"
    fi

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

# ---------------------------------------------------------------------------
# Phase 8: 装 wdn 命令
#
# wdn = wardner 命令行入口：bin/wdn（bash 启动器）→ 用 .venv 的 python 跑
# cli/wdn.py。第一个子命令是 `wdn update` —— 把所有已下载的仓更新到 GitHub
# 最新并重新同步 venv。
#
# 装两处：
#   * $WARDNER_HOME/<repo>/bin/wdn   真身；PATH 由 ~/.bashrc 的托管块给出
#   * ~/.local/bin/wdn               symlink，给不读 bashrc 的场景兜底
#     （debian 默认 ~/.profile 会把 ~/.local/bin 加进 PATH）
#
# 再把 WARDNER_HOME + PATH 写进 ~/.bashrc 的**托管块**（带起止标记），
# 重复安装是替换旧块而不是追加两份。
# ---------------------------------------------------------------------------
install_wdn_command() {
    step "安装 wdn 命令"

    local bindir="$WARDNER_REPO_DIR/bin"
    local cmd="$bindir/wdn"
    if [ ! -f "$cmd" ]; then
        warn "找不到 $cmd —— 跳过 wdn 安装"
        return 0
    fi
    chmod +x "$cmd" 2>/dev/null || true

    local target_home
    target_home="$(wardner_target_home)"

    # ~/.local/bin 的软链
    local local_bin="$target_home/.local/bin"
    if mkdir -p "$local_bin" 2>/dev/null; then
        if ln -sf "$cmd" "$local_bin/wdn" 2>/dev/null; then
            ok "软链： $local_bin/wdn → $cmd"
        else
            warn "建软链失败（不影响使用，bashrc 里已加 PATH）"
        fi
    else
        warn "建不了 $local_bin（不影响使用，bashrc 里已加 PATH）"
    fi

    # ~/.bashrc 托管块
    local rc="$target_home/.bashrc"
    if wardner_write_bashrc "$rc" "$WARDNER_HOME" "$bindir"; then
        ok "已写入 $rc"
    else
        warn "写 $rc 失败 —— 手工加这一行也能用："
        warn "  export PATH=\"$bindir:\$PATH\""
    fi
}

report() {
    local src_label; src_label="$(wardner_host_label "$WARDNER_SOURCE_HOST")"
    local src_line="  源站         $WARDNER_SOURCE_HOST（$src_label）"

    if wardner_host_is_readonly "$WARDNER_SOURCE_HOST"; then
        src_line="$src_line
  ※ 只读镜像 —— 内容由上游自动同步，**不要往它推代码**；推送请用 GitHub / 内网主仓库"
    fi

    cat >&2 <<EOF

$(printf '%s' "$C_GRN")安装完成。$(printf '%s' "$C_RST")

  安装根目录   $WARDNER_HOME
$src_line
  宿主应用     $WARDNER_HOST_DIR
  虚拟环境     $WARDNER_VENV
  SDK / 插件   $WARDNER_VENV_SRC

启动服务：

  cd $WARDNER_HOST_DIR
  .venv/bin/python run.py          # 打开 http://<板子IP>:8000/

wdn 命令（已装进 PATH）：

  wdn update                       # 把所有仓更新到 $src_label 最新并重新同步 venv
  wdn status                       # 看各仓的 commit / remote 和 venv 状态

  ※ 当前终端还没生效 —— 新开一个终端，或执行： source ~/.bashrc

更新（拉最新 + 重装）：

  $WARDNER_REPO_DIR/install.sh
  # 或： $WARDNER_REPO_DIR/update.sh
  # 或： wdn update

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
