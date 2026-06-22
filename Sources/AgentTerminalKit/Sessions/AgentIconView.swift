import AppKit
import SwiftUI

/// Loader for the bundled lobe-icons PNGs. Chosen over SVG because Apple's
/// CoreSVG renderer mis-parses lobe's compact arc-flag form (gemini-color is
/// the canonical victim) and the 640×640 PNGs are plenty for tab/menu usage.
///
/// Cached because `AgentIconView.body` calls this on every SwiftUI re-render
/// (hover, scroll, OSC 7 push) — without the cache each call paid a stat +
/// PNG decode.
@MainActor
enum AgentIcon {
    private static var cache: [String: NSImage] = [:]

    /// Asset names whose bundled lobe-icon is a single-color (white) mark with
    /// the glyph carried in the alpha channel. Drawn as-is they disappear on
    /// light themes — the chrome inverts but the PNG stays white — so
    /// `AgentIconView` template-renders these tinted with `Theme.chromeForeground`
    /// instead. Color-brand marks (claudecode / codex / gemini / amp /
    /// antigravity) are intentionally absent: they keep their own colors on
    /// every theme. Keyed on `iconAsset`, so a custom agent based on a mono
    /// brand inherits the treatment for free. `nonisolated` so the predicate
    /// is reachable from tests without hopping to the main actor.
    nonisolated static let monochromeAssets: Set<String> = ["opencode", "cursor", "githubcopilot", "grok", "kimi", "pi"]

    nonisolated static func isMonochrome(_ asset: String) -> Bool {
        monochromeAssets.contains(asset)
    }

    /// NSImage with a 16×16 logical size suitable for SwiftUI menu items
    /// (`Image(nsImage:)` in a `Label` bridges to `NSMenuItem.image`, which
    /// uses `image.size` to lay out the menu row). Pixel data stays at 640×640
    /// so SwiftUI `.resizable()` callers still render sharp at any frame size.
    static func nsImage(asset: String) -> NSImage? {
        if let hit = cache[asset] { return hit }
        guard let url = bundleResourceURL(name: asset, ext: "png", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        cache[asset] = image
        return image
    }
}

struct AgentIconView: View {
    let asset: String?
    let fallbackSymbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let asset, let image = AgentIcon.nsImage(asset: asset) {
                styledIcon(image, monochrome: AgentIcon.isMonochrome(asset))
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }

    /// Mono marks (white-on-transparent lobe icons) template-render tinted with
    /// `Theme.chromeForeground` so they adapt per theme instead of vanishing on
    /// light chrome — reading that token also registers the theme observation so
    /// they re-flip on a theme switch. Color brands render `.original` and are
    /// left untinted, keeping their own pixels on every theme.
    @ViewBuilder
    private func styledIcon(_ image: NSImage, monochrome: Bool) -> some View {
        let img = Image(nsImage: image)
            .renderingMode(monochrome ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
        if monochrome {
            img.foregroundStyle(Theme.chromeForeground)
        } else {
            img
        }
    }
}
