# AgentTerminal

> **为 AI Agent 优化的 macOS 终端 **

🇨🇳 中文  ·  🇬🇧 [English](README.md) 

专为 AI coding 优化的极简 macOS 终端。
亮点：
- 支持侧边栏 workspace 管理、水平 / 垂直分屏、一键启动 agent、实时查看 agent 状态；
- 自持Agent之间的通信和协作；
- MIT，基于Ghostty GPU 渲染基于 [libghostty](https://github.com/ghostty-org/ghostty)。

---

## 功能

**垂直 tab、分屏、多窗口。** 侧边栏管理所有 workspace，三档宽度可切换（`⌘⌃S`）。每个 pane 都有独立 tab 栏和当前 tab，用 tab 栏右侧两个按钮或 ⌘D / ⌘⇧D 就能向右 / 向下分屏。⌘R 重命名 tab、⌘⇧R 重命名 workspace。`⌘⇧N` 打开新窗口。tab 可以拖动排序、跨 pane 移动，也能拖进另一个窗口 —— 实时会话整体带过去，scrollback 和正在跑的进程都在。重启后状态自动恢复，每个打开的窗口都会还原。把任意文件夹打开成新 workspace:从 Finder 拖到 sidebar,或者按 ⌘O。按 `⌘⇧E` 把当前 pane 放大占满 workspace 再按一次还原 —— 其他 pane 滑出视野但进程还在跑。

**一键启动各种 agent。** Claude Code · Codex · MimoCode· Gemini CLI · OpenCode · Amp · Cursor CLI · Copilot CLI · Grok Build · Antigravity CLI · Kimi Code · Pi · Kiro CLI。

**Git worktree。** 右键任意 git workspace → "Create Worktree…",在新 branch 上(或 checkout 已有 branch)起一个 worktree。Worktree 在 sidebar 里缩进显示在源 repo 下面,有自己的 tab + agent —— 让 Claude 在 feature branch 上跑活,不打扰 main 上正在跑的进程。命令行 `git worktree add` 建的 worktree,下次启动 AgentTerminal 也会自动出现在 sidebar。

**Agent 之间互相协作。** 跑在 AgentTerminal 里的 agent 可以把活儿交给彼此 —— 委托审核、请求检查、接力后续任务,全程不用你在会话之间复制粘贴。内置的 `agent-forwarding` skill 让每个 agent 都懂得如何把任务转发到另一个 agent 的实时会话。

使用方式（从最省事到最底层）：

- **自然语言（推荐）。** 直接对当前 agent 说就行,比如「完成后交给 opencode 审核」「让 mimo 继续完成这个功能」「给 codex 检查一下代码」「转发给 claude」。`agent-forwarding` skill 会识别这些触发词,自动挑出目标 agent 并把消息发过去 —— 你不用记任何命令。
- **右键 tab → "Forward to Agent…"。** 在 tab 上右键选目标 agent,就会开一个新 tab 并带上转发过来的上下文。
- **`agentforward` 命令。** 在 AgentTerminal 终端里直接调用：`agentforward list` 列出当前在跑的 agent;`agentforward <当前agent> <目标agent> "消息"` 直接发送;也可以走 stdin:`echo '@forward claude "帮我审一下这个 diff"' | agentforward <当前agent>`。支持别名(claude、codex、gemini、opencode、mimo、pi……)。该命令会自动加进你的 `PATH`(`~/.agentterminal/bin`),且只在 AgentTerminal 会话里生效。

**自定义触发词。** 触发词都写在 AgentTerminal 自带的 skill 文件里。怎么找到它:
- **安装版(下载 .dmg 安装的 app):** 右键 `AgentTerminal.app` → **显示包内容** → `Contents/Resources/SKILL.md`。app 每次启动会把这个母版复制到每个已安装 agent 的目录(如 `~/.claude/skills/agent-forwarding/SKILL.md`)。改母版后重启 app 即可分发到所有 agent;直接改 agent 目录下的副本也行,但会在下次启动时被母版覆盖。
- **源码仓库 / 开发模式:** 改 `agent_terminal/skills/agent-forwarding/SKILL.md`(各 agent 目录下是指向它的符号链接,改这一处全部生效),然后重新打包或 `swift run`。
- 要加新触发词,编辑文件顶部的 `description` 以及「When to Use」「Natural Language Patterns」两节。最省事的办法:把文件路径直接丢给当前 agent,让它帮你把新触发词加进去。

**Agent 状态实时展示。** 侧边栏圆点显示每个 agent 的状态：运行中（蓝）、等待你处理（琥珀）、空闲（无色）。上一条命令非零退出时，tab 和 workspace 会同步显示红点；

**通知。** 你没在看的某个 tab 里 agent 开始等你处理、或那里命令失败时，AgentTerminal 会发一条 macOS 系统通知——每一类都能在 Settings → Notifications 里单独开关。顶栏还有个铃铛（⇧⌘I），把这些提醒跨窗口收进一个收件箱——谁在等你、什么失败了、什么跑完了——有没读的就亮红点。点一条直接跳到对应 tab；切到那个 tab，它的提醒会自己清掉。

**默认本地。** 不需要账号，AgentTerminal 的状态都留在本机。

**基于 libghostty。** 使用和 ghostty 同源的 GPU 终端渲染引擎。

## 安装

下载最新的 `.dmg`，打开后把 `AgentTerminal.app` 拖进 `Applications` 文件夹。

**第一次启动会被 Gatekeeper 拦下来**，因为当前构建是 adhoc 签名（还没有 Apple Developer ID；公开分发签名和公证会等有真实用户后再做）。你会看到 *"AgentTerminal cannot be opened because Apple cannot check it for malicious software"* 或者 *"is damaged and cannot be opened"* 这两类报错。下面三种方法任选一个即可：

<details>
<summary><b>方法 A —— 走系统设置 <i>(推荐)</i></b></summary>

1. 先双击一次 `AgentTerminal.app`，macOS 会弹警告，把警告窗口关掉。
2. 打开 **系统设置 → 隐私与安全性**，往下翻到 **安全性** 这一段。
3. 看到 *"AgentTerminal was blocked to protect your Mac"* 后，点旁边的 **Open Anyway**，输入密码。
4. 再双击一次 `AgentTerminal.app`，这次会有 **Open** 按钮，点它即可。
</details>

<details>
<summary><b>方法 B —— 终端一行命令</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/AgentTerminal.app
```
</details>

<details>
<summary><b>方法 C —— 连 "Open Anyway" 按钮都没有</b></summary>

新版 Sequoia 有时会对 adhoc 签名的 app 完全不显示 "Open Anyway" 按钮。这种情况下可以先把旧版的 "Anywhere" 选项打开，再回去走方法 A：

```sh
sudo spctl --global-disable      # macOS 15+；老系统用 --master-disable
# 系统设置 → 隐私与安全性 → "Allow applications from" 选 Anywhere
# 双击 AgentTerminal.app，这次应该可以启动
sudo spctl --global-enable       # AgentTerminal 跑过一次之后，立刻把 Gatekeeper 打开
```

注意：这是**系统级开关**。关着的时候，macOS 会允许任何未签名 app 启动。AgentTerminal 跑过一次就把它重新打开；系统会单独记住已经信任过 AgentTerminal，以后不会再拦。
</details>

macOS **只拦第一次启动**。之后从 Spotlight、Dock、Finder 启动都跟普通 app 一样。

## 从源码构建

需要 Xcode 26+ 和 macOS 14+（Sonoma，`@Observable` 的最低系统要求）。

```sh
./scripts/setup-libghostty.sh        # 一次性：把预编译的 libghostty xcframework 下到 Vendor/
swift build
swift run                            # 开发模式直接跑
swift test                           # 383 个单测

./scripts/build-app.sh               # 产出 dist/AgentTerminal.app
./scripts/build-dmg.sh --build       # 产出 dist/AgentTerminal-vX.Y.Z.dmg
```

## 许可证
MIT
