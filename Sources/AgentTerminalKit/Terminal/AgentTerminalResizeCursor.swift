import AppKit

/// Bidirectional resize cursors built from SF Symbols.
///
/// AppKit ships `NSCursor.resizeLeftRight` / `.resizeUpDown`, but referencing
/// those symbols fails to link in this build environment (the underlying
/// `_resizeLeftRightCursor` / `_resizeUpDownCursor` selectors aren't exported
/// by the SDK we link against). The one-directional `.resizeLeft` / `.resizeUp`
/// link fine but visually imply a single drag direction, which is wrong for a
/// split divider that resizes both ways.
///
/// These helpers synthesize a true bidirectional cursor from the
/// `arrow.left.and.right` / `arrow.up.and.down` SF Symbols via
/// `NSCursor(image:hotSpot:)`. If symbol rendering ever fails (older macOS, a
/// stripped symbol catalog) we fall back to the linkable one-directional
/// cursors so the call site always gets a valid `NSCursor`.
enum AgentTerminalResizeCursor {
    /// Left/right (column / horizontal split) resize cursor.
    @MainActor static let horizontal: NSCursor = make(
        symbol: "arrow.left.and.right",
        fallback: .resizeLeft
    )

    /// Up/down (row / vertical split) resize cursor.
    @MainActor static let vertical: NSCursor = make(
        symbol: "arrow.up.and.down",
        fallback: .resizeUp
    )

    private static func make(symbol: String, fallback: NSCursor) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard
            let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
            let image = base.withSymbolConfiguration(config)
        else {
            return fallback
        }
        // Hot spot at the image centre so the resize arrows straddle the divider.
        let hotSpot = NSPoint(x: image.size.width / 2, y: image.size.height / 2)
        return NSCursor(image: image, hotSpot: hotSpot)
    }
}
