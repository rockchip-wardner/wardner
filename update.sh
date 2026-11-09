#!/usr/bin/env bash
# wdnwebui 更新脚本 —— 拉最新代码 + 重装。
#
#   ~/.wardner/wardner/update.sh
#
# 与 install.sh 的区别：install.sh 是「从零装」的心智模型，update.sh 是
# 「我已经在用了，给我新的」。实际上两者走同一条路径（install.sh 本身幂等，
# 会 pull 每个仓、只重装 HEAD 变了的包），update.sh 只是把语义说清楚，
# 免得用户记不住装到哪了。
#
# 真正干活的是宿主仓里的 update_rkwhl.sh —— 470 行在板子上打磨过的更新逻辑
# （.so 落地断言 / editable 残留清理 / 卡片注册校验 / SDK 依赖审计）都在那。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/install.sh" ]; then
    echo "[fail] $SCRIPT_DIR/install.sh 不存在 —— 这不像是个正常的安装目录" >&2
    exit 1
fi

exec bash "$SCRIPT_DIR/install.sh" "$@"
