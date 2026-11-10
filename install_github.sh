#!/usr/bin/env bash
# GitHub 源的一键安装入口。
#
#   curl -fsSL https://github.com/rockchip-wardner/wardner/raw/master/install_github.sh | bash
#
# 这个脚本只做两件事：
#   1. **声明源站**（GitHub）；
#   2. 下载真正的安装器（install.sh）并执行。
#
# 为什么要有这一层：`curl ... | bash` 时安装器**无法**可靠知道自己从哪下载 ——
# install.sh 只有 ~25KB，一次就能塞进管道缓冲区，curl 写完立刻退出，等脚本
# 扫 /proc 时 curl 早就没了（实测：24KB 脚本 → /proc 里没有 curl；200KB → 还在）。
# 于是「从 Gitee 装」会静默落到 GitHub 源。源站改由**脚本名**声明，
# 不依赖运行时探测。
#
# ⚠️ 内网主仓 / GitHub / Gitee 三个仓内容**逐字节一致** —— 本文件在三处是
#    同一份内容。Gitee 仍然是上游的只读镜像，推送请用 GitHub 或内网主仓。
set -euo pipefail

# 本入口声明的源站（clone 地址）。
WARDNER_SELF_SOURCE_URL="https://github.com/rockchip-wardner/wardner.git"
export WARDNER_SELF_SOURCE_URL

# 真正的安装器在同一个源站上。
_INSTALLER_URL="https://github.com/rockchip-wardner/wardner/raw/master/install.sh"

_tmp="$(mktemp "${TMPDIR:-/tmp}/wardner-install.XXXXXX")"
trap 'rm -f "$_tmp"' EXIT

if ! curl -fsSL "$_INSTALLER_URL" -o "$_tmp"; then
    printf '[fail] 下载安装器失败： %s\n' "$_INSTALLER_URL" >&2
    exit 1
fi
if [ ! -s "$_tmp" ]; then
    printf '[fail] 下载到的安装器是空的： %s\n' "$_INSTALLER_URL" >&2
    exit 1
fi

bash "$_tmp" "$@"
