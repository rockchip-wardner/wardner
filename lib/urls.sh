#!/usr/bin/env bash
# 从「脚本是从哪儿取来的」反推 GitHub 根 URL
#
# 硬编码 org/repo 意味着换组织、换 fork 就得改代码。这里反过来：脚本从哪个
# URL 拉下来，就用哪个组织 / 仓库 —— 安装器因此是**自描述**的。
#
# 解析一个 GitHub URL，输出 "<org> <repo>"。支持：
#   https://github.com/<org>/<repo>
#   https://github.com/<org>/<repo>/raw/<branch>/<path>
#   https://github.com/<org>/<repo>/blob/<branch>/<path>
#   https://raw.githubusercontent.com/<org>/<repo>/<branch>/<path>
#   git@github.com:<org>/<repo>.git

parse_github_url() {
    local url="${1%%\?*}"            # 去掉 ?raw=1 之类的 query
    url="${url%/}"                   # 去掉尾斜杠

    local rest=""
    case "$url" in
        https://raw.githubusercontent.com/*) rest="${url#https://raw.githubusercontent.com/}" ;;
        https://github.com/*)                 rest="${url#https://github.com/}" ;;
        http://github.com/*)                  rest="${url#http://github.com/}" ;;
        git@github.com:*)                     rest="${url#git@github.com:}" ;;
        *) return 1 ;;
    esac
    rest="${rest%.git}"

    local org repo
    org="${rest%%/*}"
    rest="${rest#*/}"
    repo="${rest%%/*}"

    [ -n "$org" ] && [ -n "$repo" ] || return 1
    printf '%s %s\n' "$org" "$repo"
}

# 仓库的 git clone 地址
github_clone_url() {
    printf 'https://github.com/%s/%s.git' "$1" "$2"
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
        cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" || continue
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
