import AppKit
import SwiftUI

/// Holds a weak ref to the broadcast editor's NSTextView so taps anywhere on
/// the bar's chrome can route first-responder to it (problem #3).
@MainActor
final class BroadcastFocus {
    weak var textView: NSTextView?
    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

/// Bottom-anchored broadcast composer. When a workspace has `broadcastActive`
/// set, this bar appears below every pane and sends one message to each
/// visible tab (the active tab of every pane in the split tree) at once.
///
/// Scoped to a single `Workspace`: the draft and visibility live on the
/// workspace (runtime-only, never persisted), so switching workspaces hides
/// the bar and closing it clears the draft — "use and go."
struct BroadcastBar: View {
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    /// True while the field holds committed text OR an in-progress IME
    /// composition (marked text). Drives placeholder visibility so a
    /// half-typed Chinese candidate doesn't overlap the hint (problem #4).
    @State private var hasContent = false
    /// Bridges taps on the bar's chrome to the underlying NSTextView's first
    /// responder (problem #3). The text view registers itself here on mount.
    @State private var focus = BroadcastFocus()
    /// Whether a resize drag is in progress. The editor keeps its current
    /// height throughout the drag; only a guide line follows the cursor.
    /// On release, the final height is committed once — one terminal resize,
    /// zero flicker. (Mirrors SidebarResizeHandle's guide-line pattern.)
    @State private var isDragging = false
    /// Cumulative translation from the drag start. Drives the guide line offset.
    @State private var dragTranslation: CGFloat = 0
    /// Editor height + handle position captured at drag start so the guide
    /// line's final position maps back to a height value on release.
    @State private var dragStartHeight: CGFloat = 0

    private static let defaultHeight: CGFloat = 30
    private static let minHeight: CGFloat = 28
    private static let maxHeight: CGFloat = 260

    /// Editor height lives on the workspace so it survives workspace switches.
    /// Never changed during a drag — the drag only moves a guide line and
    /// commits the result on release.
    private var editorHeight: CGFloat {
        let stored = workspace.broadcastEditorHeight
        return stored > 0 ? stored : Self.defaultHeight
    }

    /// Visible broadcast targets, computed live at send time: the active tab of
    /// every leaf pane in the workspace. Recomputed on each access so mid-edit
    /// tab switches / splits / closes are reflected.
    private var targets: [Session] {
        workspace.root.allPanes.compactMap { $0.activeTab }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            resizeHandle
                .background(
                    GeometryReader { handleGeo in
                        Color.clear.onAppear {
                            // Let the guide line anchor to the handle's top.
                            handleTopY = handleGeo.frame(in: .named("BroadcastBar")).minY
                        }
                        .onChange(of: handleGeo.frame(in: .named("BroadcastBar")).minY) { _, y in
                            handleTopY = y
                        }
                    }
                )
            VStack(alignment: .leading, spacing: 7) {
                header
                editor
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 4)
        }
        .background(
            Rectangle()
                .fill(Theme.chromeBackground.opacity(0.98))
        )
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: "BroadcastBar")
        .overlay {
            // Guide line that tracks the cursor during a resize drag — no
            // layout change, just a visual indicator. On release, commit
            // the height once. Zero flicker, one terminal resize.
            if isDragging {
                Rectangle()
                    .fill(Theme.activityRunning)
                    .frame(height: 2)
                    .position(x: proxyWidth / 2, y: handleTopY + dragTranslation)
                    .allowsHitTesting(false)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { proxyWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in proxyWidth = w }
            }
        )
        // Clicking anywhere in the bar's chrome (header, padding) focuses the
        // field — not just a direct hit on the text view (problem #3).
        .contentShape(Rectangle())
        .onTapGesture { focus.focus() }
    }

    /// Used to position the horizontal guide line during a drag.
    @State private var handleTopY: CGFloat = 0
    @State private var proxyWidth: CGFloat = 300

    // MARK: - Pieces

    /// Top-edge grab handle. Dragging shows a guide line; on release the
    /// editor height is committed once — one terminal resize, zero flicker.
    /// (Mirrors SidebarResizeHandle's guide-line pattern.)
    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(Theme.activityRunning).frame(height: 2)
            Capsule()
                .fill(Theme.chromeMuted.opacity(0.55))
                .frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartHeight = editorHeight
                        dragTranslation = 0
                    }
                    // Drag up (negative translation) → taller editor.
                    dragTranslation = value.translation.height
                }
                .onEnded { _ in
                    let next = dragStartHeight - dragTranslation
                    workspace.broadcastEditorHeight =
                        min(Self.maxHeight, max(Self.minHeight, next))
                    isDragging = false
                    dragTranslation = 0
                }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.activityRunning)
            Text("Broadcast → \(targets.count)")
                .font(Theme.mono(10.5, weight: .medium))
                .foregroundStyle(Theme.activityRunning)
            Spacer(minLength: 0)
            kbd("⏎", "send")
            kbd("⇧⏎", "newline")
            kbd("esc", "close")
        }
    }

    private var editor: some View {
        BroadcastTextView(
            text: $workspace.broadcastDraft,
            focus: focus,
            onSend: send,
            onCancel: close,
            onContentChange: { hasContent = $0 }
        )
        .frame(height: editorHeight)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.chromeForeground.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.chromeHairline, lineWidth: 1)
                )
        )
        .overlay(alignment: .topLeading) {
            if !hasContent {
                Text("type a command to send to all visible terminals")
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.55))
                    .padding(.leading, 14)
                    .padding(.top, 11)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A small keycap + label pill — more legible than bare glyphs.
    private func kbd(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(Theme.mono(9.5, weight: .semibold))
                .foregroundStyle(Theme.chromeForeground.opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.chromeForeground.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Theme.chromeHairline, lineWidth: 1)
                        )
                )
            Text(label)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.chromeMuted)
        }
    }

    // MARK: - Actions

    /// Send the draft to every visible tab, then clear the draft but keep the
    /// bar open so the user can fire successive commands.
    private func send() {
        let trimmed = workspace.broadcastDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let payload = workspace.broadcastDraft
        for session in targets {
            // Two-step submit, mirroring the composer: paste the raw draft
            // (newlines intact, bracketed-paste wrapped) then a carriage
            // return. The CR is DEFERRED to the next runloop turns: full-screen
            // agent TUIs (Claude Code, MiMoCode) process a bracketed paste on
            // their own async event loop, so a CR fired in the same tick lands
            // before the paste is committed to their input box — the text
            // shows but doesn't run (problem #3). A real ⌘V-then-Enter has a
            // human gap; this restores it. Plain shells (opencode/zsh) don't
            // need it but are unharmed.
            let engine = session.engine
            engine.paste(payload)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                engine.sendInput("\r")
            }
        }
        workspace.broadcastDraft = ""
        hasContent = false
    }

    private func close() {
        workspace.broadcastActive = false
        workspace.broadcastDraft = ""
        // Reset height so the next open starts at the default (per spec:
        // closing the bar resets the input area).
        workspace.broadcastEditorHeight = 0
        // Hand first responder back to the active terminal surface so typing
        // resumes there without a click.
        if let view = workspace.activeSession?.engine.view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}

/// AppKit-backed multiline editor for the broadcast bar. Mirrors the pane
/// composer's `ComposerTextView`: Return sends, Shift+Return inserts a newline,
/// Esc closes. A SwiftUI `TextEditor` inserts the newline before `onKeyPress`
/// sees it, so an `NSTextView` intercepting `insertNewline` is required.
private struct BroadcastTextView: NSViewRepresentable {
    @Binding var text: String
    let focus: BroadcastFocus
    var onSend: () -> Void
    var onCancel: () -> Void
    /// Reports whether the field currently shows anything — committed text or
    /// an in-flight IME composition — so the placeholder can hide the instant
    /// the user starts typing a multi-keystroke (e.g. Chinese) character.
    var onContentChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let tv = BroadcastNSTextView(frame: .zero)
        tv.onContentChange = onContentChange
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.textColor = NSColor(Theme.chromeForeground)
        tv.insertionPointColor = NSColor(Theme.chromeForeground)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 3, height: 5)
        // This text feeds a terminal / agent verbatim — kill every auto-rewrite
        // so smart quotes / dashes, text replacement, and autocorrect can't
        // mangle command args, JSON, or `--flags`.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        // Auto-hiding scroller: the bar shows none on a single line and only
        // reveals one once the text actually overflows (problem #2).
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        // Let chrome taps route focus here (problem #3), and grab it on mount
        // so Return / Esc work without a click.
        focus.textView = tv
        // Restored drafts (e.g. after a workspace switch + back) carry text but
        // the parent's `hasContent` @State reset to false on view rebuild —
        // report once on mount so the placeholder doesn't overlap that text.
        // Deferred to avoid mutating parent state mid view-update.
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.reportContent()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? BroadcastNSTextView else { return }
        // Don't stomp an in-flight IME composition — replacing `.string` mid
        // marked-text aborts the candidate window.
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
            tv.reportContent()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: BroadcastTextView
        init(_ parent: BroadcastTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? BroadcastNSTextView else { return }
            parent.text = tv.string
            tv.reportContent()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return → newline (let the text view handle it);
                // plain Return → send.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                parent.onSend()
                return true
            case #selector(NSResponder.cancelOperation(_:)):  // Esc
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// NSTextView that also fires `onContentChange` for IME composition state.
/// `textDidChange` doesn't fire while marked (uncommitted) text is on screen,
/// so without overriding the marked-text path the placeholder would overlap a
/// half-typed Chinese candidate (problem #4).
private final class BroadcastNSTextView: NSTextView {
    var onContentChange: ((Bool) -> Void)?

    /// Emit current emptiness: committed glyphs OR an active IME composition.
    func reportContent() {
        onContentChange?(!string.isEmpty || hasMarkedText())
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        reportContent()
    }

    override func unmarkText() {
        super.unmarkText()
        reportContent()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        reportContent()
    }
}
