import AppKit
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, terminalPresets, codingAgents, ssh, notifications, messaging, statusBar, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .terminalPresets: return "Terminals"
        case .codingAgents: return "Agents"
        case .ssh: return "SSH"
        case .notifications: return "Notifications"
        case .messaging: return "Messaging"
        case .statusBar: return "Status Bar"
        case .advanced: return "Advanced"
        }
    }
}

/// Settings panel. Brutalist-minimal:
///   - sidebar list reads like a config-key index: mono font, `▸` prefix on
///     the selected row, no pill highlights, no icons
///   - detail surface is unboxed — rows are hairline-separated, labels are
///     kebab-case config keys in mono, headers use Onest display for the
///     single human-readable hook
///   - all separators are 1pt hairlines, all corners are sharp
/// The goal is to feel like polishing a `.toml` in a clean GUI, not a SaaS
/// settings panel.
struct AgentTerminalSettingsView: View {
    @Bindable var model: AgentTerminalSettingsModel
    let onOpenInTab: () -> Void
    @State private var selected: SettingsCategory = .general
    @State private var themeObserver = ThemeObserver.shared

    var body: some View {
        let _ = themeObserver.version
        // The autosave `.onChange` observers are split across multiple
        // intermediate lets so the Swift type-checker doesn't have to infer
        // the full 16-modifier chain at once ("unable to type-check in
        // reasonable time"). Each segment stays comfortably under the limit.
        let themed = HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.chromeHairline).frame(width: 1)
            ScrollView { detail }
                .frame(maxWidth: .infinity)
        }
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        let core = themed
            .onChange(of: model.fontFamily) { _, _ in model.scheduleSave() }
            .onChange(of: model.fontSize) { _, _ in model.scheduleSave() }
            .onChange(of: model.cursorStyle) { _, _ in model.scheduleSave() }
            .onChange(of: model.agentOrder) { _, _ in model.scheduleSave() }
            .onChange(of: model.hiddenAgents) { _, _ in model.scheduleSave() }
            .onChange(of: model.agentOptions) { _, _ in model.scheduleSave() }
            .onChange(of: model.defaultAgentId) { _, _ in model.scheduleSave() }

        // The terminal-theme onChange closure involves LibghosttyApp which
        // the Swift type-checker finds expensive, so it sits on its own chain
        // segment before the remaining .onChange modifiers.
        let withTheme = core
            .onChange(of: model.terminalThemeSelection) { _, _ in
                model.flushSave()
                Theme.applyTheme(model.selectedTerminalTheme)
                (NSApp.delegate as? AppDelegate)?.refreshThemeAppearances()
                guard let theme = model.selectedTerminalTheme else { return }
                LibghosttyApp.shared.reloadConfig(withTerminalTheme: theme)
            }
        let afterCore = withTheme
            .onChange(of: model.customAgents) { _, _ in model.scheduleSave() }
            .onChange(of: model.resumeConversations) { _, _ in model.scheduleSave() }
            .onChange(of: model.sshRemoteAgentDetection) { _, _ in model.scheduleSave() }
            .onChange(of: model.showSearchPill) { _, _ in model.scheduleSave() }
            .onChange(of: model.terminalPresets) { _, _ in model.scheduleSave() }
            .onChange(of: model.hiddenPresets) { _, _ in model.scheduleSave() }
            .onChange(of: model.statusBarItems) { _, _ in model.scheduleSave() }

        return afterCore
            .onChange(of: model.hiddenStatusBarItems) { _, _ in model.scheduleSave() }
            .onChange(of: model.hiddenToolCallAgents) { _, _ in model.scheduleSave() }
            .onChange(of: model.notificationsEnabled) { _, _ in model.scheduleSave() }
            .onChange(of: model.notifyOnAttention) { _, _ in model.scheduleSave() }
            .onChange(of: model.notifyOnFailure) { _, _ in model.scheduleSave() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS")
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 18)
            ForEach(SettingsCategory.allCases) { category in
                sidebarRow(category)
            }
            Spacer()
        }
        .frame(width: 168, alignment: .topLeading)
        .background(Theme.chromeFaint.opacity(0.08))
    }

    private func sidebarRow(_ category: SettingsCategory) -> some View {
        let isSelected = selected == category
        return HStack(spacing: 0) {
            Text(isSelected ? "▸" : " ")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.chromeForeground : Color.clear)
                .frame(width: 14, alignment: .leading)
            Text(category.title)
                .font(Theme.mono(12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.chromeForeground : Theme.chromeMuted)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { selected = category }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(selected.title)
                    .font(Theme.display(22, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                // The Notifications section's master switch lives on the title
                // row; its per-kind sub-toggles sit in the body below.
                if selected == .notifications {
                    Spacer(minLength: 14)
                    Toggle("", isOn: $model.notificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 22)
            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            switch selected {
            case .general: generalDetail
            case .terminalPresets: terminalPresetsDetail
            case .codingAgents: codingAgentsDetail
            case .ssh: sshDetail
            case .notifications: notificationsDetail
            case .messaging: messagingDetail
            case .statusBar: statusBarDetail
            case .advanced: advancedDetail
            }
            Spacer(minLength: 28)
        }
    }

    private var generalDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "theme") {
                themeControl
            }
            SettingsHairline()
            SettingsRow(label: "font-family") {
                Picker("", selection: $model.fontFamily) {
                    Text("Default").tag("")
                    Divider()
                    ForEach(Self.monospaceFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, alignment: .trailing)
            }
            SettingsHairline()
            SettingsRow(label: "font-size") {
                HStack(spacing: 8) {
                    Text("\(model.fontSize ?? Self.defaultFontSize)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.chromeForeground)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                    Stepper("", value: fontSizeBinding, in: 8...32)
                        .labelsHidden()
                }
                .frame(minWidth: 180, alignment: .trailing)
            }
            SettingsHairline()
            SettingsRow(label: "cursor-style") {
                Picker("", selection: $model.cursorStyle) {
                    Text("Block").tag("block")
                    Text("Underline").tag("underline")
                    Text("Bar").tag("bar")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, alignment: .trailing)
            }
            SettingsHairline()
            SettingsRow(label: "default-new-tab") {
                Picker("", selection: $model.defaultAgentId) {
                    Text("Ask each time").tag(String?.none)
                    Divider()
                    ForEach(AgentTemplate.visibleOrdered(model: model)) { template in
                        Text(template.title).tag(String?.some(template.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, alignment: .trailing)
            }
            SettingsHairline()
            SettingsRow(label: "top bar search") {
                Toggle("", isOn: $model.showSearchPill)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(minWidth: 180, alignment: .trailing)
            }
            terminalRestartCallout
        }
    }

    private var terminalPresetsDetail: some View {
        TerminalPresetsList(model: model)
    }

    private var statusBarDetail: some View {
        StatusBarReorderList(model: model)
    }

    private var codingAgentsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentReorderList(model: model)
            SettingsHairline()
            SettingsRow(label: "resume-conversation-when-reopen") {
                Toggle("", isOn: $model.resumeConversations)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var sshDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "remote-agent-detection") {
                Toggle("", isOn: $model.sshRemoteAgentDetection)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var notificationsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "agent") {
                Toggle("", isOn: $model.notifyOnAttention)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!model.notificationsEnabled)
            }
            SettingsRow(label: "command") {
                Toggle("", isOn: $model.notifyOnFailure)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!model.notificationsEnabled)
            }
        }
    }

    private var messagingDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "cross-workspace") {
                Toggle("", isOn: $model.allowCrossWorkspaceAgentMessaging)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("Allow agents in different workspaces to send messages to each other")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.horizontal, 28)
                .padding(.top, 4)
        }
    }

    private var advancedDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "~/.agentterminal/settings.json") {
                BracketButton("open in new tab", action: onOpenInTab)
            }
            Text("Edit the raw JSON for any key not exposed above. Comments (`//`, `/* */`) are accepted.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.horizontal, 28)
                .padding(.top, 16)
        }
    }

    private var terminalRestartCallout: some View {
        HStack(spacing: 12) {
            Text("Theme reloads existing panes. Font and cursor changes may need restart.")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeMuted)
            Spacer()
            BracketButton("restart agentterminal", action: restartApp)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
    }

    private func restartApp() {
        // Naively `openApplication` + `terminate` races: the new instance
        // boots while the old one still holds `~/Library/Application
        // Support/agentterminal/socket` and the persisted workspace file. The new
        // instance reads stale state and binds to the socket that the old
        // `applicationWillTerminate` is about to delete, leaving AgentTerminalHook
        // unable to reach anyone.
        //
        // Fix: sync-flush settings, detach a bash helper that waits for the
        // current PID to fully exit, then `open` a fresh instance. The
        // helper inherits PID 1 once agentterminal dies, so it keeps running after
        // our terminate.
        model.flushSave()
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = AgentTerminalShellIntegration.quote(Bundle.main.bundlePath)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.3; open -n \(bundle)"
        ]
        try? task.run()
        NSApp.terminate(nil)
    }

    private var themeControl: some View {
        Picker("", selection: $model.terminalThemeSelection) {
            Text("Follow System").tag(AgentTerminalSettingsModel.followSystemThemeSelection)
            if let customLabel = model.customTerminalThemeLabel {
                Text(customLabel).tag(AgentTerminalSettingsModel.customThemeSelection)
            }
            Divider()
            ForEach(model.bundledTerminalThemes) { preset in
                Text(preset.title).tag(preset.id)
            }
            Text("Midnight").tag(AgentTerminalSettingsModel.defaultThemeSelection)
            if !model.ghosttyUserThemes.isEmpty {
                Divider()
                ForEach(model.ghosttyUserThemes) { theme in
                    Text(theme.title).tag(theme.id)
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 180, alignment: .trailing)
    }

    /// Falls back to 13 when the user hasn't explicitly chosen a size —
    /// matches libghostty's own default so the Stepper display doesn't lie.
    private static let defaultFontSize = 13

    /// Bridges `model.fontSize: Int?` to `Stepper`'s required `Binding<Int>`.
    /// Reading the Stepper always shows a concrete number; writing sets the
    /// optional, which `save()` then writes only when non-nil.
    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { model.fontSize ?? Self.defaultFontSize },
            set: { model.fontSize = $0 }
        )
    }

    private static let monospaceFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .compactMap { family -> String? in
                guard let font = NSFont(name: family, size: 12), font.isFixedPitch else { return nil }
                return family
            }
            .sorted()
    }()

}

private struct SettingsRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.chromeForeground)
            Spacer(minLength: 14)
            trailing()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
    }
}

private struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chromeHairline.opacity(0.55))
            .frame(height: 1)
            .padding(.horizontal, 28)
    }
}

/// Reorderable list of non-terminal agent templates. The user's saved order
/// (`model.agentOrder`) is the source of truth; templates absent from it
/// (e.g. a fresh agentterminal install, or a new agent in a future version) are
/// appended in their default `AgentTemplate.all` position.
private struct AgentReorderList: View {
    @Bindable var model: AgentTerminalSettingsModel
    @State private var draggingId: String?
    @State private var endTargeted: Bool = false
    @State private var expandedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, template in
                if index > 0 { SettingsHairline() }
                AgentRow(
                    template: template,
                    visible: !model.hiddenAgents.contains(template.id),
                    isDragging: draggingId == template.id,
                    isExpanded: expandedId == template.id,
                    isCustom: isCustomId(template.id),
                    options: Binding(
                        get: { model.agentOptions[template.id] ?? "" },
                        set: { model.agentOptions[template.id] = $0 }
                    ),
                    title: customBinding(id: template.id, \.title),
                    command: customBinding(id: template.id, \.command),
                    baseAgentId: customBinding(id: template.id, \.baseAgentId),
                    env: customBinding(id: template.id, \.env),
                    onToggleVisible: { toggle(template.id) },
                    onToggleExpanded: {
                        expandedId = expandedId == template.id ? nil : template.id
                    },
                    onBeginDrag: { draggingId = template.id },
                    onDrop: { droppedId in
                        defer { draggingId = nil }
                        return reorder(draggedId: droppedId, before: template.id)
                    },
                    onDelete: isCustomId(template.id) ? { model.deleteCustomAgent(id: template.id) } : nil
                )
            }
            // Trailing drop catcher — drag past the last row to send the
            // agent to the end of the list. Without this, the bottom-most
            // position is only reachable by dropping onto the second-to-last
            // row, which reads wrong.
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingId = nil }
                    guard let id = items.first else { return false }
                    return moveToEnd(id)
                } isTargeted: { endTargeted = $0 }
            HStack {
                Button {
                    let newId = model.customAgents.last?.id
                    model.addCustomAgent()
                    if let id = model.customAgents.last?.id, id != newId {
                        expandedId = id
                    }
                } label: {
                    Text("+ add custom agent")
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .bracketBorder()
                }
                .buttonStyle(.plain)
                Spacer()
                if hasCustomisation {
                    Button("reset to defaults") { model.resetAgentCustomisation() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .underline()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
        }
    }

    private func isCustomId(_ id: String) -> Bool {
        model.customAgents.contains(where: { $0.id == id })
    }

    /// Binding into a specific custom agent's field. Returns a no-op binding
    /// if the row is a built-in agent (`AgentRow` ignores these bindings
    /// when `isCustom == false`).
    private func customBinding(id: String, _ key: WritableKeyPath<CustomAgentData, String>) -> Binding<String> {
        Binding(
            get: { model.customAgents.first(where: { $0.id == id })?[keyPath: key] ?? "" },
            set: { newValue in
                guard let idx = model.customAgents.firstIndex(where: { $0.id == id }) else { return }
                model.customAgents[idx][keyPath: key] = newValue
            }
        )
    }

    /// All non-terminal templates in the user's chosen order — visible and
    /// hidden alike. Hidden agents render greyed out but stay wherever the
    /// user dragged them, so toggling visibility doesn't move them. The
    /// `+` menu's filter to visible-only lives in `AgentTemplate.visibleOrdered`.
    private var rows: [AgentTemplate] { AgentTemplate.ordered(model: model) }

    private var hasCustomisation: Bool {
        !model.agentOrder.isEmpty
            || model.hiddenAgents != ["gemini", "amp", "cursor", "copilot", "grok", "antigravity", "kimi", "pi", "kiro"]
            || model.agentOptions.values.contains(where: { !$0.isEmpty })
            || model.defaultAgentId != nil
            || !model.customAgents.isEmpty
    }

    private func toggle(_ id: String) {
        if model.hiddenAgents.contains(id) {
            model.hiddenAgents.remove(id)
        } else {
            model.hiddenAgents.insert(id)
        }
    }

    private func reorder(draggedId: String, before targetId: String) -> Bool {
        var ids = rows.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              let targetIdx = ids.firstIndex(of: targetId),
              sourceIdx != targetIdx else { return false }
        let item = ids.remove(at: sourceIdx)
        // After remove, target index shifts left by 1 if source was earlier.
        let adjustedTarget = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx
        ids.insert(item, at: adjustedTarget)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.agentOrder = ids
        }
        return true
    }

    private func moveToEnd(_ draggedId: String) -> Bool {
        var ids = rows.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              sourceIdx != ids.count - 1 else { return false }
        let item = ids.remove(at: sourceIdx)
        ids.append(item)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.agentOrder = ids
        }
        return true
    }
}

private struct AgentRow: View {
    let template: AgentTemplate
    let visible: Bool
    let isDragging: Bool
    let isExpanded: Bool
    let isCustom: Bool
    @Binding var options: String
    /// Title binding — only consulted when `isCustom` so the user can rename
    /// their custom agent inline. Bound to a no-op for builtin rows.
    @Binding var title: String
    /// Launch-command binding — same scoping rule as `title`.
    @Binding var command: String
    /// `baseAgentId` binding — same scoping rule as `title`/`command`. Empty
    /// string = no base (generic icon + no wrapper inheritance).
    @Binding var baseAgentId: String
    /// Env-block binding (`.env` syntax) — same scoping rule as `title`;
    /// additionally only shown for Claude-Code-based customs.
    @Binding var env: String
    let onToggleVisible: () -> Void
    let onToggleExpanded: () -> Void
    let onBeginDrag: () -> Void
    let onDrop: (String) -> Bool
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ReorderHandle(payload: template.id, onBeginDrag: onBeginDrag)
                AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 14)
                    .opacity(visible ? 1.0 : 0.35)
                Text(template.title)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
                Spacer(minLength: 14)
                disclosureButton
                Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(ReorderDropZone(row: template.id, isDragging: isDragging, decode: { $0 }, onDrop: onDrop))
            if isExpanded { expandedForm }
        }
        .opacity(isDragging ? 0.35 : 1.0)
    }

    private var disclosureButton: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted.opacity(isExpanded ? 1.0 : 0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Indent the expansion sub-row so it visually hangs under the agent
    /// name. Approximates `row hpad + handle + spacing + icon` from the
    /// HStack above; a magic-but-named constant keeps the layout legible
    /// without reaching for `.alignmentGuide`.
    private static let optionsRowIndent: CGFloat = 56

    @ViewBuilder
    private var expandedForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCustom {
                basedOnRow
                editRow(label: "title", placeholder: "My Agent", text: $title)
                if baseAgentId.isEmpty {
                    editRow(label: "command", placeholder: "aichat --model gpt-4", text: $command)
                }
                if baseAgentId == AgentTemplate.claudeCodeID {
                    editRow(
                        label: "env",
                        placeholder: "ANTHROPIC_BASE_URL=https://...\nANTHROPIC_AUTH_TOKEN=sk-...",
                        text: $env,
                        axis: .vertical
                    )
                }
            }
            editRow(label: "options", placeholder: "--model opus", text: $options)
            if isCustom {
                HStack {
                    Spacer()
                    if let onDelete {
                        Button("delete", action: onDelete)
                            .buttonStyle(.plain)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.activityFailure.opacity(0.85))
                            .underline()
                    }
                }
                .padding(.leading, Self.optionsRowIndent)
                .padding(.trailing, 22)
                .padding(.top, 4)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 12)
        .id(template.id)
    }

    /// "based on" picker — inherits icon / tint / wrapper / launch binary
    /// from the chosen builtin. Empty = generic SF Symbol fallback,
    /// no wrapper-fired lifecycle, `command` field required.
    /// Switching to a non-empty base clears `command` so a stale override
    /// can't silently win over the base's binary.
    private var basedOnRow: some View {
        HStack(spacing: 10) {
            Text("based on")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
            Picker("", selection: $baseAgentId) {
                Text("(none)").tag("")
                Divider()
                ForEach(AgentTemplate.builtin.filter { !$0.isShell }) { template in
                    Text(template.title).tag(template.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 160)
            .onChange(of: baseAgentId) { _, new in
                if !new.isEmpty { command = "" }
            }
        }
        .padding(.leading, Self.optionsRowIndent)
        .padding(.trailing, 22)
    }

    private func editRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        axis: Axis = .horizontal
    ) -> some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: 10) {
            Text(label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
                // drop the label to the multi-line field's first text line
                .padding(.top, axis == .vertical ? 6 : 0)
            Group {
                if axis == .vertical {
                    TextField(placeholder, text: text, axis: .vertical).lineLimit(3...12)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .bracketBorder()
        }
        .padding(.leading, Self.optionsRowIndent)
        .padding(.trailing, 22)
    }

}

/// Singleton NSWindowController so reopening Settings reuses the same window
/// (preserves position, doesn't stack). `show(storeProvider:)` is the only
/// entry point; the provider resolves the *current* active window's store
/// each time "Open in New Tab" runs — a captured store would dangle once
/// its window closed.
@MainActor
final class AgentTerminalSettingsWindowController: NSWindowController {
    static let shared = AgentTerminalSettingsWindowController()
    private let model = AgentTerminalSettingsModel.shared
    private var storeProvider: (() -> WorkspaceStore?)?
    private var host: NSHostingController<AgentTerminalSettingsView>?

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(storeProvider: @escaping () -> WorkspaceStore?) {
        let controller = shared
        controller.storeProvider = storeProvider
        controller.buildWindowIfNeeded()
        controller.model.load()
        if controller.window?.isVisible != true {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let view = AgentTerminalSettingsView(model: model) { [weak self] in
            self?.openSettingsInNewTab()
        }
        let host = NSHostingController(rootView: view)
        self.host = host
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 680, height: 460))
        window.isReleasedWhenClosed = false
        window.appearance = Theme.windowAppearance
        self.window = window
    }

    /// Opens `~/.agentterminal/settings.json` in a new agentterminal tab via `$EDITOR`
    /// (defaulting to `vi`). Falls back to the system default editor (via
    /// NSWorkspace) when no active workspace exists.
    private func openSettingsInNewTab() {
        // Ensure the file exists so the editor lands in a real document.
        if !FileManager.default.fileExists(atPath: AgentTerminalSettings.url.path) {
            AgentTerminalSettings.writeDefaultTemplate()
        }
        guard let store = storeProvider?(), let workspace = store.active else {
            NSWorkspace.shared.open(AgentTerminalSettings.url)
            return
        }
        // AGENTTERMINAL_AGENT is auto-evaluated by the wrapper rcfile; shell expands
        // `${EDITOR:-vi}` at runtime, so the user's chosen editor wins.
        let template = AgentTemplate(
            id: "agentterminal-settings-editor",
            title: "settings.json",
            symbol: "doc.text",
            iconAsset: nil,
            tintHex: nil,
            initialCommand: "${EDITOR:-vi} \(AgentTerminalShellIntegration.quote(AgentTerminalSettings.url.path))"
        )
        let session = store.addTab(in: workspace, template: template)
        session.customTitle = "settings.json"
        window?.orderOut(nil)
    }
}

private struct TerminalPresetsList: View {
    @Bindable var model: AgentTerminalSettingsModel
    @State private var draggingId: String?
    @State private var endTargeted: Bool = false
    @State private var expandedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.terminalPresets.enumerated()), id: \.element.id) { index, preset in
                if index > 0 { SettingsHairline() }
                TerminalPresetRow(
                    id: preset.id,
                    visible: !model.hiddenPresets.contains(preset.id),
                    isDragging: draggingId == preset.id,
                    isExpanded: expandedId == preset.id,
                    title: titleBinding(id: preset.id),
                    path: pathBinding(id: preset.id),
                    onToggleVisible: { toggleVisible(preset.id) },
                    onToggleExpanded: {
                        expandedId = expandedId == preset.id ? nil : preset.id
                    },
                    onChooseFolder: { chooseFolder(forPresetId: preset.id) },
                    onDelete: { model.deleteTerminalPreset(id: preset.id) },
                    onBeginDrag: { draggingId = preset.id },
                    onDrop: { droppedId in
                        defer { draggingId = nil }
                        return reorder(draggedId: droppedId, before: preset.id)
                    }
                )
            }
            // Trailing drop catcher — drop past the last row to send the
            // preset to the bottom of the list. Without this, the bottom
            // slot is only reachable by dropping ON the last row (which
            // means "before it"), which reads wrong.
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingId = nil }
                    guard let id = items.first else { return false }
                    return moveToEnd(id)
                } isTargeted: { endTargeted = $0 }
            HStack {
                Button {
                    // Auto-expand the freshly-added preset so the user
                    // doesn't have to chase the disclosure chevron.
                    // Matches `AgentReorderList`'s "+ add custom agent".
                    let priorId = model.terminalPresets.last?.id
                    model.addTerminalPreset()
                    if let newId = model.terminalPresets.last?.id, newId != priorId {
                        expandedId = newId
                    }
                } label: {
                    Text("+ add terminal preset")
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .bracketBorder()
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, model.terminalPresets.isEmpty ? 6 : 14)

            if model.terminalPresets.isEmpty {
                Text("Each preset becomes a Terminal entry in the + menu that always spawns in the configured folder, regardless of the active workspace.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
            }
        }
    }

    /// Resolves bindings by id (not by index) so a deletion that shifts
    /// indices doesn't leave a row writing into the wrong preset.
    private func titleBinding(id: String) -> Binding<String> {
        Binding(
            get: { model.terminalPresets.first(where: { $0.id == id })?.title ?? "" },
            set: { newValue in
                guard let idx = model.terminalPresets.firstIndex(where: { $0.id == id }) else { return }
                model.terminalPresets[idx].title = newValue
            }
        )
    }

    private func pathBinding(id: String) -> Binding<String> {
        Binding(
            get: { model.terminalPresets.first(where: { $0.id == id })?.path ?? "" },
            set: { newValue in
                guard let idx = model.terminalPresets.firstIndex(where: { $0.id == id }) else { return }
                model.terminalPresets[idx].path = newValue
            }
        )
    }

    /// Opens NSOpenPanel as a sheet on the Settings window. Sheet-modal
    /// blocks edits to the underlying view, so resolving the preset by id
    /// in the completion handler is race-free.
    private func chooseFolder(forPresetId id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for this terminal preset."
        let assign: (URL) -> Void = { url in
            // Resolve by id so a concurrent deletion (or a parallel
            // Settings window mutating the same singleton) doesn't write
            // into the wrong row. Stored with `~` for HOME so the preset
            // survives a `$HOME` move.
            guard let idx = model.terminalPresets.firstIndex(where: { $0.id == id }) else { return }
            model.terminalPresets[idx].path = (url.path as NSString).abbreviatingWithTildeInPath
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { assign(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            assign(url)
        }
    }

    private func toggleVisible(_ id: String) {
        if model.hiddenPresets.contains(id) {
            model.hiddenPresets.remove(id)
        } else {
            model.hiddenPresets.insert(id)
        }
    }

    /// Reorder by moving `draggedId` to just before `targetId`. Same shift-
    /// adjust as `AgentReorderList.reorder` — removing from a position earlier
    /// than the target shifts every later index left by one.
    private func reorder(draggedId: String, before targetId: String) -> Bool {
        let ids = model.terminalPresets.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              let targetIdx = ids.firstIndex(of: targetId),
              sourceIdx != targetIdx else { return false }
        var presets = model.terminalPresets
        let item = presets.remove(at: sourceIdx)
        let adjustedTarget = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx
        presets.insert(item, at: adjustedTarget)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.terminalPresets = presets
        }
        return true
    }

    private func moveToEnd(_ draggedId: String) -> Bool {
        guard let sourceIdx = model.terminalPresets.firstIndex(where: { $0.id == draggedId }),
              sourceIdx != model.terminalPresets.count - 1 else { return false }
        var presets = model.terminalPresets
        let item = presets.remove(at: sourceIdx)
        presets.append(item)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.terminalPresets = presets
        }
        return true
    }
}

private struct TerminalPresetRow: View {
    let id: String
    let visible: Bool
    let isDragging: Bool
    let isExpanded: Bool
    @Binding var title: String
    @Binding var path: String
    let onToggleVisible: () -> Void
    let onToggleExpanded: () -> Void
    let onChooseFolder: () -> Void
    let onDelete: () -> Void
    let onBeginDrag: () -> Void
    let onDrop: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ReorderHandle(payload: id, onBeginDrag: onBeginDrag)
                AgentIconView(
                    asset: AgentTemplate.terminal.iconAsset,
                    fallbackSymbol: AgentTemplate.terminal.symbol,
                    size: 14
                )
                .opacity(visible ? 1.0 : 0.35)
                Text(displayTitle)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
                Spacer(minLength: 14)
                disclosureButton
                Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(ReorderDropZone(row: id, isDragging: isDragging, decode: { $0 }, onDrop: onDrop))
            if isExpanded { expandedForm }
        }
        .opacity(isDragging ? 0.35 : 1.0)
    }

    private var displayTitle: String {
        TerminalPreset(id: id, title: title, path: path).displayTitle
    }

    private var disclosureButton: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted.opacity(isExpanded ? 1.0 : 0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Indent the expansion sub-rows so they visually hang under the row
    /// title, matching `AgentRow.optionsRowIndent`.
    private static let editRowIndent: CGFloat = 56

    private var expandedForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            editRow(label: "name", placeholder: "Work", text: $title)
            HStack(alignment: .center, spacing: 10) {
                Text("path")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .frame(width: 50, alignment: .leading)
                TextField("~/projects/foo", text: $path)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .bracketBorder()
                Button("choose") { onChooseFolder() }
                    .buttonStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .bracketBorder()
            }
            .padding(.leading, Self.editRowIndent)
            .padding(.trailing, 22)
            HStack {
                Spacer()
                Button("delete", action: onDelete)
                    .buttonStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.activityFailure.opacity(0.85))
                    .underline()
            }
            .padding(.leading, Self.editRowIndent)
            .padding(.trailing, 22)
            .padding(.top, 4)
        }
        .padding(.bottom, 12)
    }

    private func editRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .bracketBorder()
        }
        .padding(.leading, Self.editRowIndent)
        .padding(.trailing, 22)
    }

}

private struct StatusBarReorderList: View {
    @Bindable var model: AgentTerminalSettingsModel
    @State private var draggingItem: StatusBarItemKind?
    @State private var endTargeted: Bool = false

    /// Items that participate in drag-reorder + right-side FlowLayout
    /// rendering. Excludes `.toolCallActivity` because its visual position
    /// is hardcoded (leftmost in the bar) and reordering wouldn't change
    /// anything visible. It still appears in the list under the "claude
    /// code" section, but without a drag handle.
    private var reorderableItems: [StatusBarItemKind] {
        model.statusBarItems.filter { $0 != .toolCallActivity }
    }

    /// Builtin agents that feed tool-call activity — each gets its own
    /// section (header + tool-call toggle) in Settings → Status Bar. Derived
    /// from `reportsToolCalls` so a future tool-reporting agent appears here
    /// automatically.
    private var toolCallAgents: [AgentTemplate] {
        AgentTemplate.builtin.filter { $0.reportsToolCalls }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Environment")
            ForEach(Array(reorderableItems.enumerated()), id: \.element) { index, item in
                if index > 0 { SettingsHairline() }
                StatusBarRow(
                    item: item,
                    visible: !model.hiddenStatusBarItems.contains(item),
                    isDragging: draggingItem == item,
                    reorderable: true,
                    onToggleVisible: { toggleVisible(item) },
                    onBeginDrag: { draggingItem = item },
                    onDrop: { droppedItem in
                        defer { draggingItem = nil }
                        return reorder(draggedItem: droppedItem, before: item)
                    }
                )
            }
            // One section per tool-reporting agent — header is the agent
            // (icon + name), the row under it is that agent's tool-call pill
            // toggle. Grouped by agent, not by feature.
            ForEach(toolCallAgents) { agent in
                SettingsHairline()
                sectionHeader(agent.title, agentAsset: agent.iconAsset)
                StatusBarRow(
                    item: .toolCallActivity,
                    visible: !model.hiddenToolCallAgents.contains(agent.id),
                    isDragging: false,
                    reorderable: false,
                    onToggleVisible: { toggleToolCallAgent(agent.id) },
                    onBeginDrag: nil,
                    onDrop: nil
                )
            }
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingItem = nil }
                    guard let raw = items.first,
                          let dropped = StatusBarItemKind(rawValue: raw),
                          dropped != .toolCallActivity
                    else { return false }
                    return moveToEnd(dropped)
                } isTargeted: { endTargeted = $0 }

            HStack {
                Spacer()
                if hasCustomisation {
                    Button("reset to defaults") { model.resetStatusBar() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .underline()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
        }
    }

    /// Brutalist mono section heading. `agentAsset`, when set, prepends
    /// the agent's iconAsset (e.g. `AgentTemplate.claudeCode.iconAsset`
    /// → the AgentIconView's rendered Claude mark) so a section belonging
    /// to a specific agent reads at a glance without a wall of text.
    private func sectionHeader(_ text: String, agentAsset: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let agentAsset {
                AgentIconView(asset: agentAsset, fallbackSymbol: "sparkles", size: 16)
            }
            Text(text)
                .font(Theme.mono(12, weight: .medium))
                .foregroundStyle(Theme.chromeMuted)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var hasCustomisation: Bool {
        model.statusBarItems != StatusBarItemKind.defaultOrder
            || model.hiddenStatusBarItems != AgentTerminalSettingsModel.defaultHiddenStatusBarItems
            || model.hiddenToolCallAgents != AgentTerminalSettingsModel.defaultHiddenToolCallAgents
    }

    private func toggleVisible(_ item: StatusBarItemKind) {
        if model.hiddenStatusBarItems.contains(item) {
            model.hiddenStatusBarItems.remove(item)
        } else {
            model.hiddenStatusBarItems.insert(item)
        }
    }

    private func toggleToolCallAgent(_ id: String) {
        if model.hiddenToolCallAgents.contains(id) {
            model.hiddenToolCallAgents.remove(id)
        } else {
            model.hiddenToolCallAgents.insert(id)
        }
    }

    private func reorder(draggedItem: StatusBarItemKind, before target: StatusBarItemKind) -> Bool {
        var order = model.statusBarItems
        guard let src = order.firstIndex(of: draggedItem),
              let dst = order.firstIndex(of: target),
              src != dst else { return false }
        let moved = order.remove(at: src)
        let adjusted = src < dst ? dst - 1 : dst
        order.insert(moved, at: adjusted)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.statusBarItems = order
        }
        return true
    }

    private func moveToEnd(_ item: StatusBarItemKind) -> Bool {
        var order = model.statusBarItems
        guard let src = order.firstIndex(of: item), src != order.count - 1 else { return false }
        let moved = order.remove(at: src)
        order.append(moved)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.statusBarItems = order
        }
        return true
    }
}

private struct StatusBarRow: View {
    let item: StatusBarItemKind
    let visible: Bool
    let isDragging: Bool
    /// When `false` the drag handle is replaced by an invisible spacer
    /// (matching `ReorderHandle`'s 22pt frame so the icon column stays
    /// aligned) and the row no longer hosts a `ReorderDropZone`. Used by
    /// the `.toolCallActivity` row whose position is hardcoded in the bar.
    let reorderable: Bool
    let onToggleVisible: () -> Void
    let onBeginDrag: (() -> Void)?
    let onDrop: ((StatusBarItemKind) -> Bool)?

    var body: some View {
        HStack(spacing: 12) {
            if reorderable, let onBeginDrag {
                ReorderHandle(payload: item.rawValue, onBeginDrag: onBeginDrag)
            }
            // No else — non-reorderable rows skip the handle column
            // entirely and the label hugs the row's left edge. Their
            // visual alignment matches the section header above (both
            // start 22pt in from the panel edge via the row padding).
            if let symbol = item.symbol {
                // Kinds with their own SF Symbol surface it here (Python
                // venv "p.circle.fill" etc.). `.toolCallActivity` returns
                // nil — its visual identity comes from the tool-call section
                // header's agent marks (Claude + Pi) rather than a per-row glyph.
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
                    .frame(width: 14)
                    .opacity(visible ? 1.0 : 0.4)
            }
            Text(item.displayName)
                .font(Theme.mono(12.5))
                .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
            Spacer(minLength: 14)
            Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(reorderableBackground)
        .opacity(isDragging ? 0.35 : 1.0)
    }

    @ViewBuilder
    private var reorderableBackground: some View {
        if reorderable, let onDrop {
            ReorderDropZone(row: item, isDragging: isDragging,
                            decode: StatusBarItemKind.init(rawValue:),
                            onDrop: onDrop)
        } else {
            EmptyView()
        }
    }
}
