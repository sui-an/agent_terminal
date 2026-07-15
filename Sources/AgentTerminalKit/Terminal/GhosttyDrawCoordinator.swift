import Foundation
import GhosttyKit

// MARK: - GhosttyDrawCoordinator

enum DrawPriority {
    case active   // 60fps — focused pane
    case visible  // 15fps — visible but not focused
    case hidden   // 0fps — not in a window / offscreen
}

/// Shared draw scheduler that replaces per-surface NSTimers with two
/// global timers: one at 60 Hz for the focused pane, one at 15 Hz for
/// visible-but-unfocused panes. Hidden surfaces are not drawn at all.
@MainActor
final class GhosttyDrawCoordinator {
    static let shared = GhosttyDrawCoordinator()

    /// Surfaces currently in active (60fps) draw rotation
    private var activeSurfaces: NSHashTable<GhosttySurfaceView> = .weakObjects()
    /// Surfaces in throttled (15fps) draw rotation
    private var throttledSurfaces: NSHashTable<GhosttySurfaceView> = .weakObjects()

    private var drawTimer: Timer?
    private var throttleTimer: Timer?

    private init() {}

    func register(_ view: GhosttySurfaceView, priority: DrawPriority) {
        switch priority {
        case .active:
            activeSurfaces.add(view)
            throttledSurfaces.remove(view)
        case .visible:
            throttledSurfaces.add(view)
            activeSurfaces.remove(view)
        case .hidden:
            activeSurfaces.remove(view)
            throttledSurfaces.remove(view)
        }
        ensureTimers()
    }

    func unregister(_ view: GhosttySurfaceView) {
        activeSurfaces.remove(view)
        throttledSurfaces.remove(view)
        stopTimersIfEmpty()
    }

    func setPriority(_ view: GhosttySurfaceView, priority: DrawPriority) {
        register(view, priority: priority)
    }

    func isRegistered(_ view: GhosttySurfaceView) -> Bool {
        activeSurfaces.contains(view) || throttledSurfaces.contains(view)
    }

    private func ensureTimers() {
        if drawTimer == nil && !activeSurfaces.allObjects.isEmpty {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for view in self.activeSurfaces.allObjects {
                        guard let surface = view.surface else { continue }
                        ghostty_surface_draw(surface)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            drawTimer = timer
        }
        if throttleTimer == nil && !throttledSurfaces.allObjects.isEmpty {
            let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for view in self.throttledSurfaces.allObjects {
                        guard let surface = view.surface else { continue }
                        ghostty_surface_draw(surface)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            throttleTimer = timer
        }
    }

    private func stopTimersIfEmpty() {
        if activeSurfaces.allObjects.isEmpty {
            drawTimer?.invalidate()
            drawTimer = nil
        }
        if throttledSurfaces.allObjects.isEmpty {
            throttleTimer?.invalidate()
            throttleTimer = nil
        }
    }
}
