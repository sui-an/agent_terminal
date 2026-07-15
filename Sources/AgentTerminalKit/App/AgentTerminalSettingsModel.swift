import AppKit
import SwiftUI

/// `@Observable` mirror of the typed slice of `~/.agentterminal/settings.json` we
/// expose in the Settings UI. Loads on init, debounces writes back to disk
/// so rapid `Stepper` taps don't thrash the file. Only knows about keys that
/// have working bindings in libghostty today — agentterminal-specific keys
/// (`agent.*`, `sidebar.*`, …) live in settings.json but aren't surfaced in
/// the UI yet, because their behavior isn't wired and shipping a hollow
/// toggle is worse than no toggle.
@Observable
@MainActor
final class AgentTerminalSettingsModel {
    /// Singleton so non-Settings UI surfaces (TabBarView's `+` menu, etc.)
    /// observe the same instance and react to user edits without a reload.
    static let shared = AgentTerminalSettingsModel()

    /// Default hidden status bar items — only Remote Login visible.
    static let defaultHiddenStatusBarItems: Set<StatusBarItemKind> = [
        .toolCallActivity, .pythonVenv, .proxy, .gitBranch, .gitDiff
    ]

    /// Default hidden tool-call agents — all pills hidden.
    static let defaultHiddenToolCallAgents: Set<String> = ["claude-code", "pi", "mimocode"]

    var fontFamily: String = ""
    /// `nil` = not overridden — let libghostty fall back to ghostty's own
    /// config (or its default). Writing a default 13 unconditionally would
    /// silently shadow the user's `~/.config/ghostty/config` font-size.
    var fontSize: Int? = nil
    var cursorStyle: String = "block"
    /// Picker selection for the terminal theme row. Values are one of:
    /// `followSystemThemeSelection`, `defaultThemeSelection`,
    /// `customThemeSelection`, or a theme choice id.
    var terminalThemeSelection: String = AgentTerminalSettingsModel.followSystemThemeSelection
    var terminalThemeChoices: [AgentTerminalTheme] = AgentTerminalTheme.availableThemes()
    /// Unknown raw `terminal.theme` values from hand-edited settings.json.
    /// Kept so saving an unrelated Settings field doesn't delete a custom
    /// Ghostty theme path/name that the picker cannot represent as a preset.
    private var customTerminalThemeRawValue: String? = nil

    /// User-customised order for the `+` menu agent list (Terminal stays
    /// pinned first regardless). Empty = use `AgentTemplate.all` order.
    /// Unknown ids are dropped on load; ids absent from this array but
    /// present in `AgentTemplate.all` are appended after, so a new agent
    /// shipped in a future agentterminal still shows up.
    var agentOrder: [String] = []
    /// Default: only Claude Code, Codex, MiMoCode, OpenCode visible.
    var hiddenAgents: Set<String> = ["gemini", "amp", "cursor", "copilot", "grok", "antigravity", "kimi", "pi", "kiro"]
    /// Per-agent CLI options appended after the binary name when launching.
    /// E.g. `agentOptions["claude-code"] = "--model opus"` → AGENTTERMINAL_AGENT
    /// becomes `claude --model opus`. The wrapper rc's `eval` splits on
    /// whitespace, so users handle their own quoting for spaces.
    var agentOptions: [String: String] = [:]
    /// `id` of the template that `+` / `⌘T` should open without prompting.
    /// `nil` (or pointing to a now-hidden / unknown agent) means "ask each
    /// time" — the popover stays. Terminal is always a valid choice.
    var defaultAgentId: String? = nil
    /// User-defined agent entries (`agents.custom` in settings.json). Each
    /// becomes a runtime `AgentTemplate` via `AgentTemplate.fromCustom`,
    /// joins the `+` menu / Settings list alongside the builtin agents,
    /// and supports the same visibility / order / options machinery.
    var customAgents: [CustomAgentData] = []
    /// User-defined "Terminal at <path>" presets (`terminals.presets` in
    /// settings.json). Independent of `agentOrder` / `hiddenAgents` /
    /// `agentOptions` — presets have their own list under Settings →
    /// Terminals, not a sub-section of the Agents one.
    var terminalPresets: [TerminalPreset] = []
    /// Sibling of `hiddenAgents` for the preset list. Hidden presets stay
    /// in `terminalPresets` so the user can re-enable without re-configuring.
    var hiddenPresets: Set<String> = []
    /// Pane status bar slots in user-chosen order. Default = the order
    /// agentterminal shipped before customisation (`StatusBarItemKind.defaultOrder`).
    /// Hand-edited settings.json with an unknown raw value or a duplicate
    /// drops the offending entry; missing entries are appended in default
    /// order on load so a new kind shipped in a future agentterminal still shows.
    var statusBarItems: [StatusBarItemKind] = StatusBarItemKind.defaultOrder
    /// Sibling of `hiddenAgents` for status bar slots. Hidden slots stay
    /// in `statusBarItems` so the user can re-enable without losing their
    /// custom order. Default: only Remote Login is visible.
    var hiddenStatusBarItems: Set<StatusBarItemKind> = AgentTerminalSettingsModel.defaultHiddenStatusBarItems
    /// Per-agent visibility of the tool-call activity pill, keyed by builtin
    /// agent id (`claude-code`, `pi`). Empty = every tool-reporting agent
    /// shows its pill (the default). An id in the set suppresses that agent's
    /// pill only — Claude and Pi toggle independently. Customs follow their
    /// base id, so a Claude-based custom honours the `claude-code` entry.
    /// Persisted under `statusbar.toolCallHidden`. Default: hidden.
    var hiddenToolCallAgents: Set<String> = AgentTerminalSettingsModel.defaultHiddenToolCallAgents
    /// When true, agentterminal launches Claude tabs with `--resume <id>` using the
    /// conversation id persisted on each tab (captured via Claude's hook
    /// payload). When false, every Claude tab starts fresh — but the
    /// persisted conversation id stays on disk so turning the toggle back
    /// on resumes from where the user left off.
    var resumeConversations: Bool = true
    /// Opt-in SSH integration for remote agent status. Disabled by default:
    /// when enabled, agentterminal installs an `ssh` wrapper that injects temporary
    /// marker-emitting agent wrappers into plain interactive `ssh host`
    /// sessions. The marker receiver itself is always available.
    var sshRemoteAgentDetection: Bool = false
    /// Shows the `⌘P` search pill in the top chrome strip. When false the
    /// pill is hidden (the palette stays reachable via `⌘P` / the File menu).
    /// Persisted under `general.showSearchPill` (only when non-default).
    var showSearchPill: Bool = true
    /// Master switch for macOS notifications about a non-visible tab. When
    /// off, nothing is posted. The first post triggers the OS permission
    /// prompt. Persisted under `notifications.enabled` (only when non-default).
    var notificationsEnabled: Bool = true
    /// Per-kind sub-toggles, gated behind `notificationsEnabled`: notify when
    /// an agent starts waiting on you, and when a command exits non-zero.
    /// Persisted under `notifications.attention` / `.failure` (non-default only).
    var notifyOnAttention: Bool = true
    var notifyOnFailure: Bool = true
    /// When false (default), agent messaging is restricted to the same workspace.
    /// When true, agents can message across workspaces. Persisted under
    /// `messaging.allowCrossWorkspace` (only when non-default).
    var allowCrossWorkspaceAgentMessaging: Bool = false

    private var saveWork: DispatchWorkItem?

    init() { load() }

    func load() {
        let parsed = AgentTerminalSettings.loadParsed() ?? [:]
        terminalThemeChoices = AgentTerminalTheme.availableThemes()
        let terminal = parsed["terminal"] as? [String: Any] ?? [:]
        fontFamily = (terminal["font-family"] as? String) ?? ""
        fontSize = nil
        if let n = terminal["font-size"] as? Int {
            fontSize = n
        } else if let d = terminal["font-size"] as? Double {
            fontSize = Int(d)
        }
        cursorStyle = (terminal["cursor-style"] as? String) ?? "block"
        let themeState = Self.themeSelection(
            for: terminal["theme"] as? String,
            in: terminalThemeChoices
        )
        terminalThemeSelection = themeState.selection
        customTerminalThemeRawValue = themeState.customRawValue

        let agents = parsed["agents"] as? [String: Any] ?? [:]
        agentOrder = (agents["order"] as? [String]) ?? []
        hiddenAgents = Set((agents["hidden"] as? [String]) ?? [])
        agentOptions = (agents["options"] as? [String: String]) ?? [:]
        defaultAgentId = agents["default"] as? String
        resumeConversations = (agents["resumeConversations"] as? Bool) ?? true

        let ssh = parsed["ssh"] as? [String: Any] ?? [:]
        sshRemoteAgentDetection = (ssh["remoteAgentDetection"] as? Bool) ?? false

        let general = parsed["general"] as? [String: Any] ?? [:]
        showSearchPill = (general["showSearchPill"] as? Bool) ?? true

        let notifications = parsed["notifications"] as? [String: Any] ?? [:]
        notificationsEnabled = (notifications["enabled"] as? Bool) ?? true
        notifyOnAttention = (notifications["attention"] as? Bool) ?? true
        notifyOnFailure = (notifications["failure"] as? Bool) ?? true

        let messaging = parsed["messaging"] as? [String: Any] ?? [:]
        allowCrossWorkspaceAgentMessaging = (messaging["allowCrossWorkspace"] as? Bool) ?? false

        let rawCustom = (agents["custom"] as? [[String: Any]]) ?? []
        let builtinIds = Set(AgentTemplate.builtin.map(\.id))
        var seen: Set<String> = []
        customAgents = rawCustom.compactMap { dict -> CustomAgentData? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            // Drop hand-edited collisions with builtin agents, and the
            // second occurrence of a duplicated id, so the live `all` list
            // is guaranteed-unique downstream.
            if builtinIds.contains(id) { return nil }
            if !seen.insert(id).inserted { return nil }
            return CustomAgentData(
                id: id,
                title: (dict["title"] as? String) ?? "",
                command: (dict["command"] as? String) ?? "",
                baseAgentId: (dict["baseAgentId"] as? String) ?? "",
                iconAsset: (dict["iconAsset"] as? String) ?? "",
                symbol: (dict["symbol"] as? String) ?? "",
                tintHex: (dict["tintHex"] as? String) ?? "",
                env: (dict["env"] as? String) ?? ""
            )
        }

        let statusbar = parsed["statusbar"] as? [String: Any] ?? [:]
        if let rawOrder = statusbar["order"] as? [String] {
            var seen: Set<StatusBarItemKind> = []
            let parsedOrder = rawOrder.compactMap { raw -> StatusBarItemKind? in
                guard let item = StatusBarItemKind(rawValue: raw), !seen.contains(item) else { return nil }
                seen.insert(item)
                return item
            }
            // Insert any items shipped in a agentterminal version newer than the
            // user's saved file at the position they hold in `defaultOrder`,
            // not blindly appended. Appending would break the equality
            // check at `statusOrderIsDefault` for upgrading users whose
            // saved order was the old default — they'd start writing an
            // explicit (now non-default) `statusbar.order` block to
            // settings.json on first save and `hasCustomisation` would
            // report true forever even though they never customised.
            let missing = StatusBarItemKind.allCases.filter { !seen.contains($0) }
            var rebuilt = parsedOrder
            for newKind in missing {
                // The default position is the slot it occupies in defaultOrder.
                // Anchor relative to the nearest already-present neighbour so
                // user-customised orders preserve the intent (e.g., if the
                // user moved gitDiff first, .toolCallActivity still inserts
                // before pythonVenv — its defaultOrder right neighbour).
                let defaultIndex = StatusBarItemKind.defaultOrder.firstIndex(of: newKind) ?? rebuilt.count
                let rightNeighbours = StatusBarItemKind.defaultOrder.suffix(from: defaultIndex + 1)
                let insertBefore = rebuilt.firstIndex(where: { rightNeighbours.contains($0) }) ?? rebuilt.count
                rebuilt.insert(newKind, at: insertBefore)
            }
            statusBarItems = rebuilt
        } else {
            statusBarItems = StatusBarItemKind.defaultOrder
        }
        if let rawHiddenStatus = statusbar["hidden"] as? [String] {
            hiddenStatusBarItems = Set(rawHiddenStatus.compactMap(StatusBarItemKind.init(rawValue:)))
        }
        if let savedToolCallHidden = statusbar["toolCallHidden"] as? [String] {
            hiddenToolCallAgents = Set(savedToolCallHidden)
        }

        let terminals = parsed["terminals"] as? [String: Any] ?? [:]
        hiddenPresets = Set((terminals["hidden"] as? [String]) ?? [])
        let rawPresets = (terminals["presets"] as? [[String: Any]]) ?? []
        // Same id-uniqueness defence as customAgents — a hand-edited
        // settings.json with a duplicate or a builtin-colliding preset id
        // would otherwise produce two AgentTemplate rows with the same id
        // (visibleOrdered would still surface both, but ForEach renders
        // glitchy and id-based lookups become non-deterministic).
        var presetSeen: Set<String> = []
        let customIds = Set(customAgents.map(\.id))
        terminalPresets = rawPresets.compactMap { dict -> TerminalPreset? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            if builtinIds.contains(id) || customIds.contains(id) { return nil }
            if !presetSeen.insert(id).inserted { return nil }
            return TerminalPreset(
                id: id,
                title: (dict["title"] as? String) ?? "",
                path: (dict["path"] as? String) ?? ""
            )
        }
    }

    /// Schedules a debounced write. UI bindings call this on every change;
    /// the 300ms timer collapses a burst of edits (Stepper, typing, etc.)
    /// into one write.
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Cancels the pending debounce and writes synchronously. Called from
    /// the Restart flow so the new instance is guaranteed to see the user's
    /// latest edits.
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        save()
    }

    private func save() {
        var parsed = AgentTerminalSettings.loadParsed() ?? [:]
        var terminal = parsed["terminal"] as? [String: Any] ?? [:]
        let previousTerminal = terminal
        // Sentinel values (empty string / nil / "block") drop the key so
        // libghostty falls back to ghostty's own config or its own default.
        terminal["font-family"] = fontFamily.isEmpty ? nil : fontFamily
        terminal["font-size"] = fontSize
        terminal["cursor-style"] = cursorStyle == "block" ? nil : cursorStyle
        terminal["theme"] = Self.persistedThemeValue(
            selection: terminalThemeSelection,
            customRawValue: customTerminalThemeRawValue,
            in: terminalThemeChoices
        )
        parsed["terminal"] = terminal

        let nonEmptyOptions = agentOptions.filter { !$0.value.isEmpty }
        let serialisedCustom: [[String: Any]] = customAgents.compactMap { c in
            guard !c.id.isEmpty else { return nil }
            var dict: [String: Any] = ["id": c.id]
            if !c.title.isEmpty { dict["title"] = c.title }
            if !c.command.isEmpty { dict["command"] = c.command }
            if !c.baseAgentId.isEmpty { dict["baseAgentId"] = c.baseAgentId }
            if !c.iconAsset.isEmpty { dict["iconAsset"] = c.iconAsset }
            if !c.symbol.isEmpty { dict["symbol"] = c.symbol }
            if !c.tintHex.isEmpty { dict["tintHex"] = c.tintHex }
            if !c.env.isEmpty { dict["env"] = c.env }
            return dict
        }
        let allDefaults = agentOrder.isEmpty
            && hiddenAgents.isEmpty
            && nonEmptyOptions.isEmpty
            && defaultAgentId == nil
            && serialisedCustom.isEmpty
            && resumeConversations  // default-true is the no-op case
        if allDefaults {
            parsed.removeValue(forKey: "agents")
        } else {
            var agents = parsed["agents"] as? [String: Any] ?? [:]
            agents["order"] = agentOrder.isEmpty ? nil : agentOrder
            agents["hidden"] = hiddenAgents.isEmpty ? nil : Array(hiddenAgents).sorted()
            agents["options"] = nonEmptyOptions.isEmpty ? nil : nonEmptyOptions
            agents["default"] = defaultAgentId
            agents["custom"] = serialisedCustom.isEmpty ? nil : serialisedCustom
            // Only serialise when non-default to keep settings.json lean.
            agents["resumeConversations"] = resumeConversations ? nil : false
            parsed["agents"] = agents
        }

        var ssh = parsed["ssh"] as? [String: Any] ?? [:]
        ssh["remoteAgentDetection"] = sshRemoteAgentDetection ? true : nil
        if ssh.isEmpty {
            parsed.removeValue(forKey: "ssh")
        } else {
            parsed["ssh"] = ssh
        }

        var general = parsed["general"] as? [String: Any] ?? [:]
        general["showSearchPill"] = showSearchPill ? nil : false
        if general.isEmpty {
            parsed.removeValue(forKey: "general")
        } else {
            parsed["general"] = general
        }

        var notifications = parsed["notifications"] as? [String: Any] ?? [:]
        notifications["enabled"] = notificationsEnabled ? nil : false
        notifications["attention"] = notifyOnAttention ? nil : false
        notifications["failure"] = notifyOnFailure ? nil : false
        if notifications.isEmpty {
            parsed.removeValue(forKey: "notifications")
        } else {
            parsed["notifications"] = notifications
        }

        var messaging = parsed["messaging"] as? [String: Any] ?? [:]
        messaging["allowCrossWorkspace"] = allowCrossWorkspaceAgentMessaging ? nil : false
        if messaging.isEmpty {
            parsed.removeValue(forKey: "messaging")
        } else {
            parsed["messaging"] = messaging
        }

        let serialisedPresets: [[String: Any]] = terminalPresets.compactMap { p in
            guard !p.id.isEmpty else { return nil }
            var dict: [String: Any] = ["id": p.id]
            if !p.title.isEmpty { dict["title"] = p.title }
            if !p.path.isEmpty { dict["path"] = p.path }
            return dict
        }
        if serialisedPresets.isEmpty && hiddenPresets.isEmpty {
            parsed.removeValue(forKey: "terminals")
        } else {
            var terminals = parsed["terminals"] as? [String: Any] ?? [:]
            terminals["presets"] = serialisedPresets.isEmpty ? nil : serialisedPresets
            terminals["hidden"] = hiddenPresets.isEmpty ? nil : Array(hiddenPresets).sorted()
            parsed["terminals"] = terminals
        }

        let statusOrderIsDefault = statusBarItems == StatusBarItemKind.defaultOrder
        if statusOrderIsDefault && hiddenStatusBarItems.isEmpty && hiddenToolCallAgents.isEmpty {
            parsed.removeValue(forKey: "statusbar")
        } else {
            var statusbar = parsed["statusbar"] as? [String: Any] ?? [:]
            statusbar["order"] = statusOrderIsDefault ? nil : statusBarItems.map(\.rawValue)
            statusbar["hidden"] = hiddenStatusBarItems.isEmpty ? nil : hiddenStatusBarItems.map(\.rawValue).sorted()
            statusbar["toolCallHidden"] = hiddenToolCallAgents.isEmpty ? nil : Array(hiddenToolCallAgents).sorted()
            parsed["statusbar"] = statusbar
        }

        AgentTerminalSettings.write(parsed)
        AgentTerminalShellIntegration.refreshClaudeCustomSettings(customAgents: customAgents)
        AgentTerminalShellIntegration.refreshSshRemoteAgentDetection(enabled: sshRemoteAgentDetection)
        // Theme-only diff is the trigger for chrome / window-appearance
        // refresh — font and cursor changes also flow through `reloadConfig`
        // so libghostty picks up the new values, but they don't change
        // chrome tokens, so skip the window-appearance pass for them.
        let themeChanged = (previousTerminal["theme"] as? String) != (terminal["theme"] as? String)
        let terminalChanged = !NSDictionary(dictionary: previousTerminal).isEqual(to: terminal)
        if terminalChanged {
            // When "Follow System" is selected, settings.json has no
            // terminal.theme (persistedThemeValue returns nil). Push the
            // resolved theme so ghostty renders the correct colors.
            if terminalThemeSelection == Self.followSystemThemeSelection,
               let resolvedTheme = selectedTerminalTheme {
                LibghosttyApp.shared.reloadConfig(withTerminalTheme: resolvedTheme)
            } else {
                LibghosttyApp.shared.reloadConfig()
            }
            if themeChanged {
                Theme.applyTheme(selectedTerminalTheme)
                (NSApp.delegate as? AppDelegate)?.refreshThemeAppearances()
            }
        }
    }

    func resetAgentCustomisation() {
        agentOrder = []
        hiddenAgents = ["gemini", "amp", "cursor", "copilot", "grok", "antigravity", "kimi", "pi", "kiro"]
        agentOptions = [:]
        defaultAgentId = nil
        customAgents = []
        scheduleSave()
    }

    static let followSystemThemeSelection = "__agentterminal-follow-system"
    static let defaultThemeSelection = "__agentterminal-default-theme"
    static let customThemeSelection = "__agentterminal-custom-theme"

    var selectedTerminalTheme: AgentTerminalTheme? {
        if terminalThemeSelection == Self.followSystemThemeSelection {
            return Self.resolveFollowSystemTheme(in: terminalThemeChoices)
        }
        return terminalThemeChoices.first { $0.id == terminalThemeSelection }
    }

    /// Detects the current macOS system appearance and returns the matching
    /// `macos-dark` or `macos-light` preset.
    static func resolveFollowSystemTheme(in themes: [AgentTerminalTheme]) -> AgentTerminalTheme? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return themes.first { $0.id == (isDark ? "macos-dark" : "macos-light") }
    }

    var customTerminalThemeLabel: String? {
        guard terminalThemeSelection == Self.customThemeSelection else { return nil }
        guard let raw = customTerminalThemeRawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return "Custom (\(raw))"
    }

    var bundledTerminalThemes: [AgentTerminalTheme] {
        terminalThemeChoices.filter(\.isBundled)
    }

    var ghosttyUserThemes: [AgentTerminalTheme] {
        terminalThemeChoices.filter { !$0.isBundled }
    }

    static func themeSelection(
        for rawTheme: String?,
        in themes: [AgentTerminalTheme] = AgentTerminalTheme.presets
    ) -> (selection: String, customRawValue: String?) {
        guard let rawTheme,
              !rawTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (followSystemThemeSelection, nil)
        }
        if let theme = AgentTerminalTheme.theme(for: rawTheme, in: themes) {
            return (theme.id, nil)
        }
        return (customThemeSelection, rawTheme)
    }

    static func persistedThemeValue(
        selection: String,
        customRawValue: String?,
        in themes: [AgentTerminalTheme] = AgentTerminalTheme.presets
    ) -> String? {
        if selection == followSystemThemeSelection {
            return nil
        }
        if selection == defaultThemeSelection {
            return nil
        }
        if selection == customThemeSelection {
            let raw = customRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        return themes.first { $0.id == selection }?.storedValue
    }

    /// Appends a new blank custom agent. The id is `custom-N`, the title is
    /// empty (user fills it inline) — `AgentTemplate.fromCustom` falls back
    /// to showing the id as title until the user edits it.
    func addCustomAgent() {
        let usedIds = Set(AgentTemplate.builtin.map(\.id) + customAgents.map(\.id))
        var n = customAgents.count + 1
        var candidate = "custom-\(n)"
        while usedIds.contains(candidate) { n += 1; candidate = "custom-\(n)" }
        customAgents.append(CustomAgentData(id: candidate))
        scheduleSave()
    }

    func deleteCustomAgent(id: String) {
        customAgents.removeAll { $0.id == id }
        agentOrder.removeAll { $0 == id }
        hiddenAgents.remove(id)
        agentOptions.removeValue(forKey: id)
        if defaultAgentId == id { defaultAgentId = nil }
        scheduleSave()
    }

    /// `preset-N` slug deliberately doesn't reuse the `custom-N` namespace
    /// so a hand-edited settings.json with a preset id stays distinct
    /// from a custom-agent id on the same numeric tail.
    func addTerminalPreset() {
        let usedIds = Set(
            AgentTemplate.builtin.map(\.id)
            + customAgents.map(\.id)
            + terminalPresets.map(\.id)
        )
        var n = terminalPresets.count + 1
        while usedIds.contains("preset-\(n)") { n += 1 }
        terminalPresets.append(TerminalPreset(id: "preset-\(n)"))
        scheduleSave()
    }

    func resetStatusBar() {
        statusBarItems = StatusBarItemKind.defaultOrder
        hiddenStatusBarItems = AgentTerminalSettingsModel.defaultHiddenStatusBarItems
        hiddenToolCallAgents = AgentTerminalSettingsModel.defaultHiddenToolCallAgents
        scheduleSave()
    }

    func deleteTerminalPreset(id: String) {
        terminalPresets.removeAll { $0.id == id }
        hiddenPresets.remove(id)
        // Stale-default cleanup: if the user had this preset set as the
        // default for `+` / `⌘T`, the saved id would otherwise point at a
        // now-gone row → `defaultLaunchTemplate` returns nil → +/⌘T
        // silently fall back to the popover. Matches `deleteCustomAgent`.
        if defaultAgentId == id { defaultAgentId = nil }
        scheduleSave()
    }
}
