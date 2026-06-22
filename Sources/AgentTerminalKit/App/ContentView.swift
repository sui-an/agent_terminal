import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    /// Observed so chrome re-renders when the user switches themes.
    @State private var settings = AgentTerminalSettingsModel.shared

    var body: some View {
        let _ = settings.terminalThemeSelection
        
        VStack(spacing: 0) {
            topStrip
                .zIndex(1)
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            HStack(spacing: 0) {
                if store.sidebarMode != .hidden {
                    SidebarView(store: store)
                    SidebarResizeHandle(store: store)
                    Rectangle().fill(Theme.chromeHairline).frame(width: 1)
                }
                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.rightSidebarMode != .hidden {
                    Rectangle().fill(Theme.chromeHairline).frame(width: 1)
                    AgentOverviewSidebar(mode: store.rightSidebarMode)
                }
            }
        }
        .background(chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .ignoresSafeArea(.all)
    }

    /// Top 32pt strip. `window.isMovable = false` is set globally, so the
    /// `WindowDragHandle` background is the only place AppKit allows
    /// window dragging. The `SearchTriggerPill` lives in an *inner* ZStack
    /// scoped to the drag-handle area (not the whole strip) so it centers
    /// in the available space and can't overlap the sidebar toggle when
    /// the window is dragged narrow. `ViewThatFits` drops the pill
    /// entirely once even the inner area can't hold its 280pt frame —
    /// `⌘P` + the File menu still reach the palette.
    private var topStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 82).allowsHitTesting(false)
            HoverableIconButton(
                systemName: "sidebar.left",
                fontSize: 15,
                size: 28,
                help: sidebarTooltip,
                action: {
                    withAnimation(Theme.chromeTransition) {
                        store.setSidebarMode(store.sidebarMode.next)
                    }
                },
                immediateTooltip: true,
                immediateTooltipAlignment: .leading
            )
            WindowDragHandle()
                .overlay {
                    if AgentTerminalSettingsModel.shared.showSearchPill {
                        ViewThatFits(in: .horizontal) {
                            SearchTriggerPill {
                                NSApp.sendAction(#selector(AppDelegate.handleQuickOpen), to: nil, from: nil)
                            }
                            EmptyView()
                        }
                    }
                }
            // Agent Panel button removed
            InboxBell()
                .padding(.trailing, 8)
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private var mainPane: some View {
        if let workspace = store.active {
            PaneTreeView(node: workspace.root, workspace: workspace, store: store)
                .id(workspace.id)
        } else {
            Color.clear
        }
    }

    private var chromeBackground: Color {
        let color = store.active?.activeSession?.engine.backgroundColor ?? Theme.terminalSurface
        return Color(nsColor: color)
    }

    private var sidebarTooltip: String {
        switch store.sidebarMode {
        case .full: return "Foldable sidebar"
        case .compact: return "Hide sidebar"
        case .hidden: return "Show sidebar"
        }
    }

}
