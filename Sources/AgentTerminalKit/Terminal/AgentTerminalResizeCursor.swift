import AppKit

/// Bidirectional resize cursors.
///
/// Uses the native AppKit resize cursors which automatically adapt to the
/// current appearance (light/dark). `.resizeLeftRight` is the true
/// bidirectional cursor but may fail to link on some SDK configurations;
/// `.resizeLeft` is the guaranteed fallback that still looks correct for a
/// sidebar resize handle.
enum AgentTerminalResizeCursor {
    /// Left/right (column / horizontal split) resize cursor.
    @MainActor static let horizontal: NSCursor = .resizeLeftRight

    /// Up/down (row / vertical split) resize cursor.
    @MainActor static let vertical: NSCursor = .resizeUpDown
}
