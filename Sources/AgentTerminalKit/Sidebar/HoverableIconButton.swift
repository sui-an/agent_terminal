import SwiftUI

/// Square SF-symbol button with a hover-state background tint. Used for the
/// add (+) and close (×) controls in the sidebar and tab bar — keeps the
/// hover affordance consistent and the call sites tiny.
struct HoverableIconButton: View {
    let systemName: String
    let fontSize: CGFloat
    let size: CGFloat
    let help: String?
    let action: () -> Void
    /// Optional rotation in degrees applied to the symbol. Animated via
    /// `easeOut(0.15)` so toggle controls (sidebar disclosure chevron) get
    /// a smooth state transition; default 0 leaves static buttons (× / +)
    /// untouched.
    var rotation: Double = 0
    /// When true, show a custom tooltip immediately on hover instead of the
    /// system `.help()` tooltip which has a noticeable delay.
    var immediateTooltip: Bool = false
    /// Placement for the immediate tooltip relative to the button. Defaults to
    /// `.below` (top-strip / sidebar-toggle); bottom-bar buttons near the
    /// window edge pass `.above` so the tooltip isn't clipped.
    var immediateTooltipPlacement: ImmediateTooltipPlacement = .below
    /// Horizontal anchoring of the immediate tooltip. Defaults to `.center`;
    /// buttons hugging a window edge pass `.leading` (left-edge button →
    /// tooltip grows rightward) or `.trailing` (right-edge button → tooltip
    /// grows leftward) so the tooltip stays inside the window bounds.
    var immediateTooltipAlignment: ImmediateTooltipAlignment = .center

    @State private var isHovered = false

    private var tooltipOverlayAlignment: Alignment {
        let vertical: VerticalAlignment = immediateTooltipPlacement == .above ? .bottom : .top
        switch immediateTooltipAlignment {
        case .center: return Alignment(horizontal: .center, vertical: vertical)
        case .leading: return Alignment(horizontal: .leading, vertical: vertical)
        case .trailing: return Alignment(horizontal: .trailing, vertical: vertical)
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
                .rotationEffect(.degrees(rotation))
                .animation(.easeOut(duration: 0.15), value: rotation)
                .frame(width: size, height: size)
                .background(isHovered ? Theme.chromeHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: min(6, size / 4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: tooltipOverlayAlignment) {
            if immediateTooltip, isHovered, let help, !help.isEmpty {
                TooltipView(text: help)
                    .fixedSize()
                    .offset(y: immediateTooltipPlacement == .above ? -(size + 4) : size + 4)
                    .zIndex(10_000)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered && immediateTooltip ? 10_000 : 0)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .help(immediateTooltip ? "" : (help ?? ""))
    }
}

/// Placement of the immediate hover tooltip relative to its button.
enum ImmediateTooltipPlacement {
    case below
    case above
}

/// Horizontal anchoring of the immediate hover tooltip — keeps tooltips for
/// edge-hugging buttons inside the window bounds.
enum ImmediateTooltipAlignment {
    case center
    case leading
    case trailing
}

/// Lightweight immediate tooltip — appears instantly on hover, positioned
/// below the trigger. Styled to match macOS system tooltips.
private struct TooltipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.black.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
            .allowsHitTesting(false)
    }
}
