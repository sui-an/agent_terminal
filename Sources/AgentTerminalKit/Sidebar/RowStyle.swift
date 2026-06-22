import AppKit
import SwiftUI

/// Shared row background palette for sidebar / tab / popover-menu rows.
/// Centralizes the hover/active alpha values so a future theme toggle has one
/// place to change.
extension View {
    func hoverableRowBackground(isActive: Bool = false, isHovered: Bool) -> some View {
        let color: Color
        if isActive {
            color = Theme.chromeActive
        } else if isHovered {
            color = Theme.chromeHover
        } else {
            color = .clear
        }
        return background(color)
    }

    /// Menu rows are single-state: hover reads as the selected menu row.
    func menuRowHover(_ isHovered: Bool) -> some View {
        background(isHovered ? Theme.chromeActive : Color.clear)
    }
}

/// One row in a agentterminal popover menu — tab right-click, "+" agent menu, etc.
/// Shares hover treatment + typography with the rest of the chrome.
/// Optional `shortcut` renders right-aligned in the same monospace style
/// AppKit uses for native NSMenuItem key equivalents (e.g. "⌘W", "⌘⇧D").
struct AgentTerminalMenuRow<Leading: View>: View {
    let title: String
    let shortcut: String?
    let isDisabled: Bool
    let leading: Leading
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        shortcut: String? = nil,
        isDisabled: Bool = false,
        @ViewBuilder leading: () -> Leading,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.shortcut = shortcut
        self.isDisabled = isDisabled
        self.leading = leading()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                leading
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isDisabled ? Theme.chromeMuted : Theme.chromeForeground)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular))
                        .tracking(0.35)
                        .foregroundStyle(isDisabled ? Theme.chromeMuted.opacity(0.6) : Theme.chromeMuted)
                        .padding(.leading, Theme.space2)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .menuRowHover(isHovered && !isDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 && !isDisabled }
        .animation(Theme.chromeTransition, value: isHovered)
    }
}

extension AgentTerminalMenuRow where Leading == EmptyView {
    init(
        title: String,
        shortcut: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            shortcut: shortcut,
            isDisabled: isDisabled,
            leading: { EmptyView() },
            action: action
        )
    }
}

extension View {
    /// 2pt drop-target indicator anchored to one edge of the view, animated on
    /// the `active` toggle. Used by reorder gestures (sidebar workspaces, tab
    /// pills, the trailing `+` button) to show "drop will land here".
    /// `offset` nudges the line into a visual gap between sibling views.
    /// `length` only applies to horizontal-axis (leading/trailing) edges.
    func dropIndicator(active: Bool, on edge: Alignment, offset: CGFloat = 0, length: CGFloat = 22) -> some View {
        let isVertical = edge == .top || edge == .bottom
        return overlay(alignment: edge) {
            let color = Theme.chromeForeground.opacity(active ? 0.55 : 0)
            if isVertical {
                Rectangle()
                    .fill(color)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: offset)
                    .animation(.easeOut(duration: 0.12), value: active)
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 2, height: length)
                    .offset(x: offset)
                    .animation(.easeOut(duration: 0.12), value: active)
            }
        }
    }
}

struct AgentTerminalMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chromeHairline)
            .frame(height: 1)
            .padding(.vertical, 2)
            .padding(.horizontal, Theme.space2)
    }
}

/// `≡` drag-source glyph used by every reorderable list (Settings →
/// Agents, Terminals, Status Bar). Scoping `.onDrag` to the handle — not
/// the whole row — keeps Toggle / TextField hit-testing independent and
/// makes openHand the only cursor inside the row.
struct ReorderHandle: View {
    let payload: String
    let onBeginDrag: () -> Void

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.chromeMuted.opacity(0.7))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onDrag {
                onBeginDrag()
                return NSItemProvider(object: payload as NSString)
            }
    }
}

/// Row-level drop catcher used by every reorderable list. The `Color.clear`
/// surface is load-bearing: putting `.dropDestination` on the row HStack
/// with `.contentShape(Rectangle())` routes Toggle / TextField clicks
/// through the row-wide content shape and registers them against the wrong
/// row. `decode` converts the dragged `NSItemProvider` payload (always a
/// `String`) into the caller's typed item; return `nil` to reject the drop.
struct ReorderDropZone<Item: Equatable>: View {
    let row: Item
    let isDragging: Bool
    let decode: (String) -> Item?
    let onDrop: (Item) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .dropIndicator(active: isTargeted && !isDragging, on: .top)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let dropped = decode(raw),
                      dropped != row else { return false }
                return onDrop(dropped)
            } isTargeted: { isTargeted = $0 }
            .allowsHitTesting(true)
    }
}

/// Shared rename-popover body used by tab + workspace rename. Both render
/// inside `.popover` modifiers anchored to their own row; the caller picks
/// the arrowEdge so the popover points the right way.
struct AgentTerminalRenameField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.display(13))
            .foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2 + 2)
            .frame(minWidth: 220)
            .background(Theme.chromeBackground)
            .onSubmit(onSubmit)
    }
}
