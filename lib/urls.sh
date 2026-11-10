#!/usr/bin/env bash
# 从「脚本是从哪儿取来的」反推**源站** + 组织 + 仓库名
#
# 硬编码 org/repo 意味着换组织、换 fork、换镜像站就得改代码。这里反过来：
# 脚本从哪个 URL 拉下来，就用哪个源站 / 组织 / 仓库 —— 安装器因此是**自描述**的。
#
# 解析一个仓库 URL，输出 "<host> <org> <repo>"。支持：
#   https://github.com/<org>/<repo>
#   https://github.com/<org>/<repo>/raw/<branch>/<path>
#   https://github.com/<org>/<repo>/blob/<branch>/<path>
#   https://raw.githubusercontent.com/<org>/<repo>/<branch>/<path>
#   git@github.com:<org>/<repo>.git
#   https://gitee.com/<org>/<repo>            ← 国内镜像
#   https://gitee.com/<org>/<repo>/raw/<branch>/<path>
#   git@gitee.com:<org>/<repo>.git
#   http://<host>:<port>/<org>/<repo>.git     ← 内网 GitLab（端口在 host 里）
#
# 规律：**路径的前两段永远是 org / repo**，后面的（raw/blob/分支/文件）一律丢掉。
# 于是 GitHub 的 /raw/ 与 Gitee 的 /raw/ 用同一套解析，不用各写一份。

# 只读镜像 —— 内容由上游自动同步，推上去会被覆盖。
#
# 这不是「风格偏好」，是**写错了会丢代码**：往镜像推的提交会在下一次同步时
# 被上游版本覆盖，且没有任何提示。所以工具链必须知道哪个站不能推。
wardner_host_is_readonly() {
    case "${1:-}" in
        gitee.com) return 0 ;;
        *)          return 1 ;;
    esac
}

# 源站主机名 → 人类可读的说明（给日志用）
wardner_host_label() {
    case "${1:-}" in
        github.com) printf 'GitHub' ;;
        gitee.com)  printf 'Gitee 镜像' ;;
        *)           printf '%s' "${1:-?}" ;;
    esac
}

# 解析仓库 URL → "<host> <org> <repo>"。认不出来返回 1。
parse_repo_url() {
    local url="${1%%\?*}"            # 去掉 ?raw=1 之类的 query
    url="${url%/}"                   # 去掉尾斜杠
    url="${url%.git}"                # 去掉 .git

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
            # https://github.com/org/repo/...（内网 GitLab 的 host 里带端口）
            host="${url#*://}"; host="${host%%/*}"
            path="${url#*://*/}"
            ;;
        *) return 1 ;;
    esac

    # raw.githubusercontent.com 是**取文件**的域名，不是 clone 的域名 —— 归一成
    # github.com，否则会推出一个不存在的 clone 源。
    case "$host" in
        raw.githubusercontent.com) host="github.com" ;;
    esac

    # org / repo 必须是路径的前两段。少一段就认不出来（宁可失败也别猜）。
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

# 仓库的 git clone 地址
repo_clone_url() {
    repo_clone_url_for https "$@"
}

# 同上，但按指定协议来 —— 内网 GitLab 走 http、SSH 源走 git@ 形式，
# 一律改成 https 会直接把 clone 弄坏。
repo_clone_url_for() {
    local scheme="$1" host="$2" org="$3" repo="$4"
    case "$scheme" in
        ssh)  printf 'git@%s:%s/%s.git'   "$(ssh_host "$host")" "$org" "$repo" ;;
        http) printf 'http://%s/%s/%s.git' "$host" "$org" "$repo" ;;
        *)    printf 'https://%s/%s/%s.git' "$host" "$org" "$repo" ;;
    esac
}

# 源站 → 传输协议
#
# * **GitHub / Gitee 走 https** —— 公开仓，匿名 clone 就行，不需要账号 /
#   SSH key。这是「没登录过的用户也能装」的唯一路径。
# * **内网走 ssh** —— 内网 GitLab 的 web 口在 8080，那是 HTTP 端口；走 ssh
#   才是内网该有的取码方式。
#
# 协议由**源站**决定，不由取脚本用的 URL 协议决定：内网 GitLab 的
# /raw/ 页面是 http 的，但代码要从 ssh 拉。
source_scheme_for_host() {
    case "${1:-}" in
        github.com|gitee.com|"") printf 'https' ;;
        *)                         printf 'ssh' ;;
    esac
}

# SSH 的 host 不带端口 —— web 的 8080 是 HTTP 端口，不是 SSH 端口。
# 写成 git@10.10.10.10:8080:org/repo.git 是错的。
ssh_host() {
    printf '%s' "${1%%:*}"
}

# pip 的 VCS 前缀（update_rkwhl.sh 的 WARDNER_PKG_BASE 用）
pkg_base_for() {
    local scheme="$1" host="$2" org="$3"
    case "$scheme" in
        ssh)  printf 'git+ssh://git@%s/%s'  "$(ssh_host "$host")" "$org" ;;
        http) printf 'git+http://%s/%s'      "$host" "$org" ;;
        *)    printf 'git+https://%s/%s'     "$host" "$org" ;;
    esac
}

# 在 /proc 里翻 curl 的命令行，推断本脚本是从哪个 URL 取来的。
#
# `curl ... | bash` 时脚本自己并不知道来源。但 curl 通常还在跑（脚本还在
# 从管道里读），它的 /proc/<pid>/cmdline 里带着完整 URL。
#
# 只认命令行里含 "install.sh" 的 curl —— 免得把机器上别的 curl 命令
# 认成自己（那会推出一个完全无关的组织名）。
detect_source_url() {
    local p cmd url
    for p in /proc/[0-9]*; do
        # ⚠️ `2>/dev/null` 必须写在输入重定向**之前**，顺序不能反 —— bash 从左到右
        # 执行重定向，进程刚好退出时 shell 自己报的重定向错误也会被吞掉。
        # 写成 `< file 2>/dev/null`（反过来）会漏出 "No such file or directory"
        # 噪音（扫几百个 pid 必撞 TOCTOU）。
        #
        # 与 install.sh 的 bootstrap 段是**同一套逻辑** —— 改一处必须改另一处。
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
