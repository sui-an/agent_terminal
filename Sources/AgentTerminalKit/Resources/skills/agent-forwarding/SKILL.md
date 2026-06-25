---
name: agent-forwarding
description: Use when user asks to forward, transfer, hand off, or delegate tasks to another agent (e.g., "send to Claude for review", "let opencode check this", "forward to codex", "让或给XX review", "检查", "继续完成", "实现", "完成", "做")
---

# Agent Forwarding

## Overview

AgentTerminal supports inter-agent communication via the `agentforward` tool.
When users ask to forward tasks to other agents, use this skill to execute the forwarding command.

## When to Use

### 转发/委托类
- User says "交给XX审核" / "send to XX for review"
- User says "让XX检查一下" / "let XX check this"
- User says "转发给XX" / "forward to XX"
- User says "把这个任务交给XX" / "hand this task to XX"
- User says "让或给XX review"
- User says "给XX审查"

### 任务执行类
- User says "让XX继续完成" / "let XX continue and complete"
- User says "让XX实现" / "let XX implement"
- User says "让XX完成" / "let XX complete"
- User says "让XX做" / "let XX do"
- User says "让XX检查" / "let XX check"

### Agent 名称
- User mentions agent names: claude, codex, gemini, opencode, mimo, pi, etc.

## Quick Reference

| Command | Description |
|---------|-------------|
| `agentforward list` | List all running agents |
| `agentforward <source-agent> <target-agent> "<message>"` | Send message directly |
| `echo "@forward <target> <message>" \| agentforward <source-agent>` | Forward via stdin |

## Natural Language Patterns

When user says any of these, use `agentforward`:

| 用户说 | 动作 |
|--------|------|
| "交给claude审核" | `agentforward <current-agent> claude "请审核这个任务"` |
| "让opencode检查" | `agentforward <current-agent> opencode "请检查这个代码"` |
| "转发给codex" | `agentforward <current-agent> codex "<message>"` |
| "发送给mimo" | `agentforward <current-agent> mimo "<message>"` |
| "让或给XX review" | `agentforward <current-agent> XX "请 review 这个任务"` |
| "检查" | `agentforward <current-agent> XX "请检查这个代码"` |
| "继续完成" | `agentforward <current-agent> XX "请继续完成这个任务"` |
| "实现" | `agentforward <current-agent> XX "请实现这个功能"` |
| "完成" | `agentforward <current-agent> XX "请完成这个任务"` |
| "做" | `agentforward <current-agent> XX "请做这个任务"` |

## Implementation

### Step 1: Identify Current Agent
Check `AGENTTERMINAL_AGENT` environment variable or infer from context.

### Step 2: Resolve Target Agent
Common agent aliases:
- `claude` / `claude-code` → Claude Code
- `codex` → Codex
- `opencode` → OpenCode
- `gemini` → Gemini CLI
- `mimo` / `mimocode` → MiMoCode
- `pi` → Pi

### Step 3: Execute Forwarding
```bash
# Method 1: Direct command
agentforward <current-agent> <target-agent> "<message>"

# Method 2: Via stdin
echo "@forward <target-agent> \"<message>\"" | agentforward <current-agent>
```

### Step 4: Confirm Success
Check exit code:
- `0` = Success
- `1` = Failure (agent not found, socket error)

## Example

User: "请完成这个功能，然后交给opencode审核"

Your action:
1. Complete the current task
2. Execute: `agentforward claude opencode "代码已完成，请审核以下变更：[summary]"`
3. Report: "已将任务转发给 OpenCode 进行审核"

User: "让mimo继续完成这个功能"

Your action:
1. Execute: `agentforward claude mimo "请继续完成这个功能"`
2. Report: "已将任务转发给 MiMoCode 继续完成"

User: "给codex检查一下代码"

Your action:
1. Execute: `agentforward claude codex "请检查这个代码"`
2. Report: "已将任务转发给 Codex 进行检查"

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using natural language only | Must execute `agentforward` command |
| Wrong agent name | Use `agentforward list` to verify |
| Missing quotes around message | Always quote multi-word messages |
| Forgetting current agent | Check `AGENTTERMINAL_AGENT` env var |

## Troubleshooting

**Error: "没有运行中的 agent"**
- Ensure AgentTerminal is running
- Check if target agent is active

**Error: "AGENTTERMINAL_HOOK_BIN 未设置"**
- Run command inside AgentTerminal terminal session
- Not in external terminal

**Error: "转发失败"**
- Check socket connection
- Verify agent names with `agentforward list`
