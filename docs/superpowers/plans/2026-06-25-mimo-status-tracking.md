# MiMo Code 状态追踪修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 MiMo Code 像 Claude Code / Codex / OpenCode 一样支持完整的四种侧栏状态（蓝/黄/红/无点），并修复完成时先发 error 通知再发 completion 通知的 bug。

**Architecture:** 两个独立修复：(1) 创建 MiMo AgentTerminal 插件，通过 MiMo 的 plugin event API 发送 running/attention 事件到 AgentTerminalHook；(2) 修复 WorkspaceStore 中 onCommandFinished 对 hook-managed agent 重复触发 failure 通知的竞态。

**Tech Stack:** Swift (ShellIntegration, WorkspaceStore), JavaScript/TypeScript (MiMo plugin)

---

## Task 1: 创建 MiMo AgentTerminal 插件

**Files:**
- Create: `Sources/AgentTerminalKit/Terminal/ShellIntegration.swift` (添加 mimocodePluginScript 常量和 mimocodePluginPath)
- Modify: `Sources/AgentTerminalKit/Terminal/ShellIntegration.swift:installAgentHooks` (安装插件)

- [ ] **Step 1: 在 ShellIntegration.swift 中添加 mimocodePluginPath 常量**

在 `opencodePluginPath` 常量（约 line 227-237）之后添加：

```swift
static let mimocodePluginPath: String = {
    let base: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        base = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
        base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    }
    let dir = base.appendingPathComponent("mimocode/plugins/agentterminal", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("agentterminal.js").path
}()
```

- [ ] **Step 2: 在 ShellIntegration.swift 中添加 mimocodePluginScript 常量**

在 `opencodePluginScript`（约 line 1161-1181）之后添加：

```swift
static let mimocodePluginScript = """
// \(managedFileMarker) — pings AgentTerminalHook on message-submit and turn-end so
// the sidebar agent dot tracks per-session activity. Safe to delete; will
// be regenerated next time agentterminal launches.
const plugin = async ({ $ }) => {
  const surface = process.env.AGENTTERMINAL_SURFACE_ID
  const hookBin = process.env.AGENTTERMINAL_HOOK_BIN
  if (!surface || !hookBin) return {}

  const ping = async (state) => {
    try { await $`${hookBin} mimocode ${state}`.quiet() } catch {}
  }

  return {
    "chat.message": async () => { await ping("running") },
    event: async ({ event }) => {
      if (event?.type === "session.idle") await ping("attention")
    },
  }
}

export const server = plugin
export default plugin
"""
```

- [ ] **Step 3: 在 installAgentHooks 中调用安装**

在 `installAgentHooks` 函数中（约 line 400 `writeManagedFile(at: opencodePluginPath, ...)` 之后）添加：

```swift
writeManagedFile(at: mimocodePluginPath, contents: mimocodePluginScript)
```

- [ ] **Step 4: 将插件注册到 MiMo 配置**

在 `installAgentHooks` 中添加一个函数来把插件路径注入 `~/.config/mimocode/mimocode.json` 的 `plugin` 数组。在 `mimocodePluginScript` 常量之后添加：

```swift
static func registerMimocodePlugin() {
    let configPath: String = {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        return base.appendingPathComponent("mimocode/mimocode.json").path
    }()

    guard FileManager.default.fileExists(atPath: configPath),
          let data = FileManager.default.contents(atPath: configPath),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    var plugins = (json["plugin"] as? [String]) ?? []
    let pluginDir = (mimocodePluginPath as NSString).deletingLastPathComponent
    guard !plugins.contains(pluginDir) else { return }
    plugins.append(pluginDir)
    json["plugin"] = plugins

    if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
        try? newData.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }
}
```

在 `installAgentHooks` 末尾调用 `registerMimocodePlugin()`。

- [ ] **Step 5: 验证编译**

```bash
cd /Users/chenhangan/Documents/devSoftware/agentCli/agent_terminal && swift build 2>&1 | tail -5
```

---

## Task 2: 修复双通知 bug

**Files:**
- Modify: `Sources/AgentTerminalKit/Sessions/WorkspaceStore.swift:1448-1461`

- [ ] **Step 1: 修改 onCommandFinished，跳过 hook-managed agent 的 failure 通知**

将 `onCommandFinished` 中的 failure 通知逻辑从：

```swift
if let exit, exit != 0 { self?.onSessionAlert(session.id, .failure) }
```

改为：

```swift
// Hook-managed agents (those with active lifecycle hooks) report completion
// via the .ended hook event. Suppress .failure here to avoid a race where
// the PTY exit detection fires .failure before the hook's .completed arrives.
if let exit, exit != 0, session.agent == .terminal {
    self?.onSessionAlert(session.id, .failure)
}
```

逻辑：只有当 session 的 agent 已经被 `.ended` hook 事件重置为 `.terminal` 时（即 hook 事件已到达），才触发 `.failure` 通知。如果 agent 仍然是非 terminal 状态（hook 事件尚未到达），则跳过——因为 `.ended` 事件即将到达并触发 `.completed`。

- [ ] **Step 2: 验证编译**

```bash
cd /Users/chenhangan/Documents/devSoftware/agentCli/agent_terminal && swift build 2>&1 | tail -5
```

---

## Task 3: 端到端验证

- [ ] **Step 1: 确认插件文件生成**

```bash
cat ~/.config/mimocode/plugins/agentterminal/agentterminal.js
```

预期：包含 `AGENTTERMINAL_SURFACE_ID` 和 `session.idle` 的 JS 文件。

- [ ] **Step 2: 确认 mimocode.json 已注册插件**

```bash
cat ~/.config/mimocode/mimocode.json | grep -A2 agentterminal
```

预期：`plugin` 数组中包含 `agentterminal` 插件路径。

- [ ] **Step 3: 确认 MiMo bracket wrapper 正常**

```bash
cat ~/.agentterminal/bin/mimo | head -20
```

预期：wrapper 脚本存在且包含 `running` / `ended` marker。

---

## Summary

| 修复 | 文件 | 影响 |
|------|------|------|
| MiMo 插件 | ShellIntegration.swift | 创建 `agentterminal.js` 插件，注册到 mimocode.json |
| 双通知 bug | WorkspaceStore.swift | 跳过 hook-managed agent 的重复 failure 通知 |
