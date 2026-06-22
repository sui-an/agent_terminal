import SwiftUI

struct TabBarItem: View {
    @Bindable var tab: Session
    let isActive: Bool
    let canCloseToRight: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let onDuplicate: () -> Void
    let onRename: (String) -> Void
    let onSplit: (SplitOrientation) -> Void
    let onMoveToNewWindow: () -> Void
    let onForward: @MainActor (UUID) -> Void

    @State private var isHovered = false
    @State private var isContextMenuOpen = false
    @State private var isRenameOpen = false
    @State private var isForwardPickerOpen = false
    @State private var pendingRename = ""

    var body: some View {
        HStack(spacing: 5) {
            commandStatusDot
            AgentIconView(
                asset: tab.displayAgent.iconAsset,
                fallbackSymbol: tab.displayAgent.symbol,
                size: TabBarMetrics.tabIconSize
            )
            .overlay(alignment: .topTrailing) {
                let unread = MessageBus.shared.unreadCount(for: tab.id)
                if unread > 0 {
                    Text("\(unread)")
                        .font(Theme.mono(7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.activityAttention))
                        .offset(x: 4, y: -4)
                }
            }
            Text(tab.title)
                .font(Theme.display(TabBarMetrics.tabTitleFontSize, weight: .regular))
                .lineLimit(1)
            HoverableIconButton(
                systemName: "xmark",
                fontSize: TabBarMetrics.tabCloseFontSize,
                size: TabBarMetrics.tabCloseSize,
                help: "Close tab",
                action: onClose
            )
            .opacity(isHovered || isActive ? 1 : 0)
            .allowsHitTesting(isHovered || isActive)
        }
        .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeMuted)
        .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
        .padding(.vertical, TabBarMetrics.tabVerticalPadding)
        .background(tabBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .overlay(RightClickCatcher { _ in isContextMenuOpen = true })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                AgentTerminalMenuRow(title: "Close Tab", shortcut: "⌘W") {
                    isContextMenuOpen = false
                    onClose()
                }
                AgentTerminalMenuRow(title: "Close Other Tabs") {
                    isContextMenuOpen = false
                    onCloseOthers()
                }
                AgentTerminalMenuRow(title: "Close Tabs to the Right", isDisabled: !canCloseToRight) {
                    isContextMenuOpen = false
                    onCloseToRight()
                }
                AgentTerminalMenuDivider()
                AgentTerminalMenuRow(title: "Split Right", shortcut: "⌘D") {
                    isContextMenuOpen = false
                    onSplit(.horizontal)
                }
                AgentTerminalMenuRow(title: "Split Down", shortcut: "⌘⇧D") {
                    isContextMenuOpen = false
                    onSplit(.vertical)
                }
                AgentTerminalMenuRow(title: "Move to New Window") {
                    isContextMenuOpen = false
                    onMoveToNewWindow()
                }
                AgentTerminalMenuDivider()
                AgentTerminalMenuRow(title: "Rename Tab…", shortcut: "⌘R") {
                    isContextMenuOpen = false
                    beginRename(deferred: true)
                }
                AgentTerminalMenuRow(title: "Duplicate Tab") {
                    isContextMenuOpen = false
                    onDuplicate()
                }
                if !tab.agent.isShell {
                    AgentTerminalMenuDivider()
                    AgentTerminalMenuRow(title: "Forward to Agent…") {
                        isContextMenuOpen = false
                        isForwardPickerOpen = true
                    }
                }
                AgentTerminalMenuDivider()
                AgentTerminalMenuRow(title: "Reveal in Finder") {
                    isContextMenuOpen = false
                    NSWorkspace.shared.activateFileViewerSelecting([tab.currentDirectory])
                }
            }
            .padding(3)
            .frame(minWidth: 240)
            .background(Theme.chromeBackground)
        }
        .popover(isPresented: $isRenameOpen, arrowEdge: .bottom) {
            AgentTerminalRenameField(placeholder: "Tab title", text: $pendingRename) {
                onRename(pendingRename)
                isRenameOpen = false
            }
        }
        .popover(isPresented: $isForwardPickerOpen, arrowEdge: .bottom) {
            forwardPickerBody
        }
        .onChange(of: tab.renameRequested) { _, requested in
            // ⌘R routes here via `Session.renameRequested`. Consume the flag
            // so the next ⌘R re-fires.
            guard requested else { return }
            tab.renameRequested = false
            beginRename(deferred: false)
        }
        .onChange(of: isActive) { _, nowActive in
            if nowActive { MessageBus.shared.markRead(for: tab.id) }
        }
        .onAppear {
            if isActive { MessageBus.shared.markRead(for: tab.id) }
        }
    }

    private var tabBackground: some View {
        RoundedRectangle(cornerRadius: TabBarMetrics.tabCornerRadius)
            .fill(isActive ? Theme.chromeActive : (isHovered ? Theme.chromeHover : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: TabBarMetrics.tabCornerRadius)
                    .stroke(isActive ? Theme.chromeHairline : Color.clear, lineWidth: 1)
            }
            .animation(Theme.chromeTransition, value: isActive)
            .animation(Theme.chromeTransition, value: isHovered)
    }

    @ViewBuilder
    private var forwardPickerBody: some View {
        let entries = AgentMonitor.shared.entries.filter { $0.id != tab.id }
        VStack(alignment: .leading, spacing: 0) {
            Text("Forward to…")
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            if entries.isEmpty {
                Text("No other agents running")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            } else {
                ForEach(entries) { entry in
                    AgentTerminalMenuRow(title: entry.agent.title) {
                        AgentIconView(asset: entry.agent.iconAsset, fallbackSymbol: entry.agent.symbol, size: 12)
                    } action: {
                        isForwardPickerOpen = false
                        onForward(entry.id)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 200)
        .background(Theme.chromeBackground)
    }

    /// Seed the edit field from the current title and open the rename popover.
    /// `deferred` waits one runloop tick — needed from the context menu, where
    /// that popover is mid-dismiss and back-to-back popovers off the same
    /// anchor glitch; the ⌘R path opens synchronously. Skips when already open
    /// so a re-trigger mid-edit can't wipe what the user is typing.
    private func beginRename(deferred: Bool) {
        guard !isRenameOpen else { return }
        pendingRename = tab.customTitle ?? tab.title
        if deferred {
            DispatchQueue.main.async { isRenameOpen = true }
        } else {
            isRenameOpen = true
        }
    }

    /// Shows only on non-zero exit. Successful runs intentionally leave the
    /// row clean — a green dot on every command would dominate the chrome.
    @ViewBuilder
    private var commandStatusDot: some View {
        if tab.activityState == .attention {
            Circle()
                .fill(Theme.activityAttention)
                .frame(width: 4, height: 4)
                .help("Waiting for input")
        } else if let exit = tab.lastCommandExit, exit != 0 {
            Circle()
                .fill(Theme.activityFailure)
                .frame(width: 4, height: 4)
                .help(Self.statusTooltip(exit: exit, duration: tab.lastCommandDuration))
        }
    }

    private static func statusTooltip(exit: Int, duration: TimeInterval?) -> String {
        guard let duration else { return "exit \(exit)" }
        return "exit \(exit) · \(formatDuration(duration))"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds / 60)
        let rem = Int(seconds.truncatingRemainder(dividingBy: 60).rounded())
        return "\(minutes)m \(rem)s"
    }
}
