import AppKit
import SwiftUI

/// One AppKit host per pane, holding ALL of that pane's tab surfaces stacked,
/// with only the active one visible. Replaces the old per-tab `TerminalView`.
///
/// `engine.view` is a single shared, libghostty-backed NSView. The hard part is
/// custody: a tab move restructures the pane tree, and SwiftUI responds by
/// transiently creating MORE THAN ONE `SurfaceHostView` for the same pane.
/// Tracing proved the failure — the surface got parented into one host while a
/// DIFFERENT, freshly-created host was the one actually shown on screen; the
/// displayed host had no surface (blank), and the surface's host was off-window.
///
/// Fix: surface custody is NEVER decided in the SwiftUI update pass (it can
/// target a stale/duplicate host). Instead the host claims its pane's surfaces
/// from its own `layout()` — an AppKit callback that, for our purposes, only
/// matters when the host is actually in a window. A never-shown duplicate host
/// can't steal the surface; the displayed host re-claims it every layout pass
/// and the state converges. `updateNSView` only refreshes the pane/focus inputs.
struct PaneSurfaceHost: NSViewRepresentable {
    @Bindable var pane: Pane
    let isFocused: Bool

    func makeNSView(context: Context) -> SurfaceHostView {
        let host = SurfaceHostView()
        host.pane = pane
        host.isFocusedPane = isFocused
        return host
    }

    func updateNSView(_ host: SurfaceHostView, context: Context) {
        host.pane = pane
        host.isFocusedPane = isFocused
        // Do NOT touch the view tree here. Mutating subviews (reparent / isHidden)
        // or pushing engine size/focus during SwiftUI's update pass trips
        // AttributeGraph cycle detection. Just request layout — AppKit runs
        // `layout()` at the end of the same runloop turn (so a tab switch is
        // still effectively immediate) and all the real work happens there,
        // outside the update pass.
        host.needsLayout = true
    }
}

final class SurfaceHostView: NSView {
    weak var pane: Pane?
    var isFocusedPane = false
    private var lastFlushedSize: NSSize = .zero
    /// Active tab id we last moved focus to. Tracked so a tab switch grabs the
    /// caret exactly once (the surface isn't re-mounted, so the mount-time
    /// `grabsFocusOnMount` path never fires), without stealing focus on every
    /// unrelated layout pass.
    private var lastFocusedTabId: UUID?

    override func layout() {
        super.layout()
        claimAndArrange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Becoming visible (window non-nil) is when this host should own its
        // surfaces. Reset the flush gate so the size is re-pushed now that the
        // surface's own `window` is finally non-nil (propagateSizeToSurface
        // bails while detached, so the move-time push was dropped).
        lastFlushedSize = .zero
        claimAndArrange()
    }

    /// Pull this pane's tab surfaces in as subviews, size them, show only the
    /// active one. Only an in-window host claims — that's what stops a transient
    /// duplicate host (never shown) from stealing the shared surface. Idempotent.
    func claimAndArrange() {
        guard window != nil, let pane else { return }
        let activeId = pane.activeTabId
        let owned = Set(pane.tabs.map { ObjectIdentifier($0.engine.view) })

        for tab in pane.tabs {
            let surface = tab.engine.view
            if surface.superview !== self {
                surface.removeFromSuperview()
                addSubview(surface)
            }
            surface.frame = bounds
            let isActive = tab.id == activeId
            surface.isHidden = !isActive
            tab.engine.grabsFocusOnMount = isActive && isFocusedPane
        }
        for sub in subviews where !owned.contains(ObjectIdentifier(sub)) {
            sub.removeFromSuperview()
        }

        // flushSize (libghostty resize) and focusSurface (makeFirstResponder)
        // mutate state SwiftUI observes; running them inside the update pass
        // (claimAndArrange is also called from updateNSView for snappy switches)
        // trips AttributeGraph cycle detection. The parenting/visibility above is
        // pure AppKit and safe synchronously — defer only these side effects to
        // the next runloop, off the update pass. Still visually instant.
        let needsFlush = bounds.size != lastFlushedSize && bounds.width > 0 && bounds.height > 0
        let needsFocus = isFocusedPane && activeId != lastFocusedTabId
        guard needsFlush || needsFocus else { return }
        if needsFlush { lastFlushedSize = bounds.size }
        if needsFocus { lastFocusedTabId = activeId }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let pane = self.pane else { return }
            let active = pane.tabs.first { $0.id == pane.activeTabId }
            if needsFlush { active?.engine.flushSize() }
            if needsFocus, self.isFocusedPane { active?.engine.focusSurface() }
        }
    }
}
