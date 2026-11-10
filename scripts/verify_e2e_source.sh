#!/usr/bin/env bash
# 真实端到端：按用户的方式跑入口脚本（curl | bash），验证「源站」判定。
#
# 只跑到「源：」那一行就掐断（Phase 2 之后是建 venv + 装 8 个包，没必要），
# 全程在临时 WARDNER_HOME 里跑，**不碰** ~/.wardner 里的真实安装。
#
# 用法：bash scripts/verify_e2e_source.sh <github|gitee>
set -uo pipefail

WHICH="${1:-gitee}"
E2E_HOME="$(mktemp -d "${TMPDIR:-/tmp}/wardner-e2e.XXXXXX")"
trap 'rm -rf "$E2E_HOME"' EXIT

case "$WHICH" in
    github) URL="https://github.com/rockchip-wardner/wardner/raw/master/install_github.sh" ;;
    gitee)  URL="https://gitee.com/rockchip-wardner/wardner/raw/master/install_gitee.sh" ;;
    *)      echo "用法: $0 <github|gitee>"; exit 2 ;;
esac

echo "入口: $URL"
echo "临时安装根: $E2E_HOME"
echo

export WARDNER_HOME="$E2E_HOME"

# 与真实用户完全一样的姿势：curl | bash
curl -fsSL --max-time 60 "$URL" | timeout 240 bash 2>&1 | sed -n '1,60p'
rc=${PIPESTATUS[1]}

echo
echo "--- 判定 ---"
echo "临时仓的 remote:"
git -C "$E2E_HOME/wardner" remote get-url origin 2>&1 | sed 's/^/  /'
