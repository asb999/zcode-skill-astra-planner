#!/usr/bin/env bash
# install.sh — 把 zcode-skill-astra-planner 安装为 ZCode 用户级 skill
# 用法:
#   ./install.sh                 安装到 ~/.agents/skills/zcode-skill-astra-planner
#   ./install.sh <目标目录>      安装到指定父目录
#   ./install.sh --uninstall     卸载
set -uo pipefail

SKILL_NAME="zcode-skill-astra-planner"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_target() {
  if [ -d "$HOME/.agents/skills" ]; then echo "$HOME/.agents/skills"
  elif [ -d "$HOME/.zcode/skills" ]; then echo "$HOME/.zcode/skills"
  else echo "$HOME/.agents/skills"; fi
}

if [ "${1:-}" = "--uninstall" ]; then
  target="$(default_target)/$SKILL_NAME"
  rm -rf "$target" && echo "[install] removed: $target"
  exit 0
fi

target_parent="${1:-$(default_target)}"
target="$target_parent/$SKILL_NAME"
mkdir -p "$target"

cp -R "$SRC_DIR/SKILL.md" "$SRC_DIR/scripts" "$SRC_DIR/examples" "$target/" 2>/dev/null
[ -f "$SRC_DIR/LICENSE" ] && cp "$SRC_DIR/LICENSE" "$target/"
chmod +x "$target"/scripts/*.sh 2>/dev/null

echo "[install] installed to: $target"
echo "[install] verify inside ZCode: ask it to 先规划一个非平凡任务 / use astra planner"
