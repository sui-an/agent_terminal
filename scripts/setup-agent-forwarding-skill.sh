#!/bin/bash

# setup-agent-forwarding-skill.sh
# 开发阶段：为已安装的 Agent 创建符号链接

set -e

echo "=== 设置 Agent Forwarding Skill ==="

# 获取当前目录
CURRENT_DIR=$(pwd)
SKILL_FILE="$CURRENT_DIR/agent_terminal/skills/agent-forwarding/SKILL.md"

# 检查 Skill 文件是否存在
if [ ! -f "$SKILL_FILE" ]; then
    echo "错误: Skill 文件不存在: $SKILL_FILE"
    echo "请确保在项目根目录运行此脚本"
    exit 1
fi

echo "Skill 文件: $SKILL_FILE"
echo ""

# 定义所有可能的 Agent 父目录（不带 /agent-forwarding 后缀）
AGENT_PARENT_DIRS=(
    "~/.agents/skills"
    "~/.claude/skills"
    "~/.codex/skills"
    "~/.gemini/skills"
    "~/.mimocode/skills"
    "~/.amp/skills"
    "~/.cursor/skills"
    "~/.copilot/skills"
    "~/.grok/skills"
    "~/.pi/skills"
    "~/.kiro/skills"
    "~/.opencode/skills"
    "~/.antigravity/skills"
    "~/.kimi/skills"
)

# 创建符号链接
echo "创建符号链接..."

installed_count=0
skipped_count=0

for parent_dir in "${AGENT_PARENT_DIRS[@]}"; do
    # 展开 ~ 为实际路径
    expanded_parent=$(eval echo "$parent_dir")
    
    # 检查父目录是否存在
    if [ ! -d "$expanded_parent" ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi
    
    # 创建 agent-forwarding 子目录
    target_dir="$expanded_parent/agent-forwarding"
    mkdir -p "$target_dir"
    
    # 创建符号链接
    ln -sf "$SKILL_FILE" "$target_dir/SKILL.md"
    echo "✓ $target_dir/SKILL.md"
    installed_count=$((installed_count + 1))
done

echo ""
echo "=== 完成 ==="
echo "已安装: $installed_count 个 Agent"
echo "跳过: $skipped_count 个未安装的 Agent"
echo ""
echo "验证符号链接:"
ls -la ~/.agents/skills/agent-forwarding/
echo ""
echo "测试 Skill 内容:"
head -10 ~/.agents/skills/agent-forwarding/SKILL.md
