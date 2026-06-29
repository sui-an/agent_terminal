import AppKit
import SwiftUI

/// One agentterminal window: an `NSWindow` paired with its own `WorkspaceStore`.
/// `AppDelegate` keeps an array of these — every window is fully
/// independent (own sidebar, own workspaces, own persisted slice keyed by
/// `windowId`).
@MainActor
final class AgentTerminalWindowController: NSWindowController, NSWindowDelegate {
    let windowId: UUID
    let store: WorkspaceStore
    /// Set by `AppDelegate`. Fires from `windowWillClose` so the delegate
    /// can drop this window from its list and decide whether the window's
    /// persisted slot survives (one of several closed) or is discarded.
    var onWillClose: ((AgentTerminalWindowController) -> Void)?
    /// Fires when this window becomes key — lets `AppDelegate` remember the
    /// most-recently-active agentterminal window, so menu actions route there when a
    /// Settings / Update panel is the key window instead.
    var onDidBecomeKey: ((AgentTerminalWindowController) -> Void)?

    init(windowId: UUID, store: WorkspaceStore) {
        self.windowId = windowId
        self.store = store
        super.init(window: Self.makeWindow())
        window?.delegate = self

        // Top-level container so a resize-guide line can sit ABOVE the SwiftUI
        // hosting view (and thus above libghostty's Metal layer). A SwiftUI
        // overlay can't — the terminal surface clips it past the sidebar edge.
        let container = NSView()
        let hosting = NSHostingView(rootView: ContentView(store: store))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let guide = SidebarResizeGuideView()
        guide.autoresizingMask = [.width, .height]
        guide.frame = container.bounds
        container.addSubview(guide, positioned: .above, relativeTo: hosting)
        window?.contentView = container
        store.showSidebarResizeGuide = { [weak guide] x in guide?.updateGuide(x: x) }
        // The last tab closing opens a default terminal instead of exiting
        store.onBecameEmpty = { [weak self] in
            guard let self = self else { return }
            // addWorkspace already spawns a default tab, so just create workspace
            _ = self.store.addWorkspace()
        }
    }

    required init?(coder: NSCoder) { fatalError("not a storyboard window") }

    /// Builds a agentterminal main window with the standard chrome. Mirrors the
    /// config that used to live inline in `applicationDidFinishLaunching`.
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AgentTerminalApp.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Tab strips sit under the transparent titlebar; only our explicit
        // sidebar handle moves the window so tab DnD never races AppKit.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.appearance = Theme.windowAppearance
        // The controller governs the window's lifetime; without this,
        // `close()` would also `release` it out from under the controller.
        window.isReleasedWhenClosed = false
        // Every window's NSWindow title is the app name, so the system
        // Windows-menu / Dock-tile auto window list stacks a useless
        // "agentterminal × N" above our own workspace/tab list. Drop them — the Dock
        // menu's workspace list and ⌘P are the real navigation.
        window.isExcludedFromWindowsMenu = true
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onDidBecomeKey?(self)
    }
}

/// Top-level overlay that draws a single vertical guide line during a sidebar
/// resize drag. Sits above the SwiftUI hosting view so it isn't clipped by
/// libghostty's Metal surface. `updateGuide(x:)` with nil hides it; non-nil
/// positions a 2pt line at that x (in this view's coords). Pass-through for hit
/// testing so it never intercepts clicks.
final class SidebarResizeGuideView: NSView {
    private let line = NSBox()
    /// Top chrome strip (32pt) + its 1pt hairline. The guide starts below it so
    /// it aligns with the tab bar's top instead of running up to the window top.
    private let topInset: CGFloat = 33

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = NSColor(Theme.chromeActive)
        line.isHidden = true
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError("not a storyboard view") }

    // Never intercept mouse events — the line is purely decorative.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateGuide(x: CGFloat?) {
        guard let x else { line.isHidden = true; return }
        line.isHidden = false
        // NSView origin is bottom-left, y up: leave `topInset` clear at the top.
        line.frame = NSRect(x: x - 1, y: 0, width: 2, height: max(0, bounds.height - topInset))
    }
}
