import Foundation

@MainActor
@Observable
final class Workspace: Identifiable {
    let id: UUID
    /// Project root. New tabs spawn here; the active pane's active tab's OSC 7
    /// reports keep this in sync — `cd` in any visible terminal updates the
    /// workspace, the next new pane / tab inherits the latest path.
    var workingDirectory: URL
    /// Single split tree per workspace. Always non-nil; a fresh workspace
    /// holds one Pane with one Session.
    var root: PaneNode
    /// Currently focused leaf-pane id. Splits/closes update this so cwd
    /// tracking and ⌘D act on what the user is looking at.
    var activePaneId: UUID?
    /// When non-nil, `PaneTreeView` renders only this pane and hides the
    /// rest of the split tree (pane zoom). Runtime-only — never persisted,
    /// so a agentterminal relaunch never strands the user in zoom. `closePane` /
    /// `splitPane` clear this automatically when the zoomed pane changes
    /// shape.
    var zoomedPaneId: UUID?

    /// Is `paneId` the currently zoomed pane?
    func isZoomed(_ paneId: UUID) -> Bool { zoomedPaneId == paneId }

    /// True when ⌘⇧E / the zoom button has something to do — either there
    /// are multiple panes to choose between, or the workspace is already
    /// zoomed (so toggling un-zooms).
    var canZoom: Bool { root.hasMultiplePanes || zoomedPaneId != nil }
    /// Empty / whitespace input via `renameWorkspace` clears this back to
    /// `nil` so the sidebar label resumes tracking the cwd.
    var customTitle: String? = nil

    /// Set by `SidebarView` once it has brought this workspace's row into the
    /// view hierarchy (the ⌘⇧R flow, parked on
    /// `WorkspaceStore.pendingRenameWorkspace`). The row's `SidebarWorkspaceRow`
    /// observes it — onChange while already mounted, onAppear for a row that
    /// just mounted after the sidebar expanded/scrolled to it — opens its
    /// rename popover, and resets the flag. Runtime-only.
    var renameRequested = false

    /// When non-nil, this workspace is a git worktree whose source workspace
    /// has this id. Sidebar groups worktrees under their source via a
    /// disclosure triangle. Set at creation and never changes for the
    /// workspace's lifetime — re-parenting a worktree is not a supported op.
    var worktreeParentId: UUID? = nil
    /// Branch the worktree was created on, shown next to its sidebar row.
    /// Captured at creation; the pane status bar still owns the live branch
    /// readout if the user checks out something else inside the worktree.
    var worktreeBranch: String? = nil
    /// Disk root of this worktree, captured at creation. Distinct from
    /// `workingDirectory` because the latter follows OSC 7 cwd reports —
    /// `cd ~/Downloads` inside a worktree tab drifts `workingDirectory`
    /// off the worktree, but `worktreePath` stays pinned to the directory
    /// `git worktree add` produced. The close / reconcile paths must use
    /// this, not `workingDirectory`, so `git worktree remove` doesn't
    /// target the wrong path.
    var worktreePath: URL? = nil

    /// Single source of truth for "where the worktree actually lives on
    /// disk." For worktree workspaces `worktreePath` wins (pinned at
    /// create time); upgraded state.json files written before the field
    /// existed fall through to `workingDirectory` and behave as before.
    /// Use this everywhere `git worktree remove` / `reconcile` /
    /// confirm-sheet subtitle needs the disk root.
    var diskPath: URL { worktreePath ?? workingDirectory }

    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if let reported = activeSession?.terminalTitle, !reported.isEmpty { return reported }
        if workingDirectory.path == NSHomeDirectory() { return "Home" }
        let last = workingDirectory.lastPathComponent
        return last.isEmpty ? workingDirectory.path : last
    }

    var activePane: Pane? {
        if let id = activePaneId, let pane = root.pane(id: id) { return pane }
        return root.firstPane
    }

    var activeSession: Session? { activePane?.activeTab }

    /// Generation counter bumped on structural changes (tab add/remove,
    /// activity state change). Drives `sidebarReadout` memoization so the
    /// expensive tree walk only runs when the tree actually changed.
    private var readoutGeneration = 0
    private var cachedReadout: (agents: [AgentTemplate], state: SessionActivityState, hasCommandFailure: Bool)?

    /// Bump this whenever the pane tree structure changes (tabs added/removed,
    /// activity state changed, command finished). Called from WorkspaceStore.
    func invalidateReadout() {
        readoutGeneration &+= 1
        cachedReadout = nil
    }

    /// Distinct non-terminal agents and aggregated activity, computed in a
    /// single tree walk. Sidebar reads all three per render. Cached — the
    /// tree walk only reruns when `invalidateReadout()` is called.
    var sidebarReadout: (agents: [AgentTemplate], state: SessionActivityState, hasCommandFailure: Bool) {
        if let cached = cachedReadout { return cached }
        let result = computeReadout()
        cachedReadout = result
        return result
    }

    private func computeReadout() -> (agents: [AgentTemplate], state: SessionActivityState, hasCommandFailure: Bool) {
        var seen: Set<String> = []
        var agents: [AgentTemplate] = []
        var state: SessionActivityState = .idle
        var hasFailure = false
        walk(root) { pane in
            for tab in pane.tabs {
                let agent = tab.displayAgent
                if !agent.isShell, !seen.contains(agent.id) {
                    seen.insert(agent.id)
                    agents.append(agent)
                }
                if let exit = tab.lastCommandExit, exit != 0 { hasFailure = true }
                switch tab.activityState {
                case .attention: state = .attention
                case .running where state != .attention: state = .running
                default: break
                }
            }
        } shouldStop: { false }
        return (agents, state, hasFailure)
    }

    var distinctAgents: [AgentTemplate] { sidebarReadout.agents }
    var activityState: SessionActivityState { sidebarReadout.state }
    /// True when any tab's last command exited non-zero. Sidebar uses this
    /// (with attention > failure > running > idle precedence) so a
    /// background-pane failure surfaces at the workspace level too.
    var hasCommandFailure: Bool { sidebarReadout.hasCommandFailure }

    private func walk(_ node: PaneNode, visit: (Pane) -> Void, shouldStop: () -> Bool) {
        switch node.content {
        case .pane(let p):
            visit(p)
        case .split(_, let a, let b, _):
            walk(a, visit: visit, shouldStop: shouldStop)
            if shouldStop() { return }
            walk(b, visit: visit, shouldStop: shouldStop)
        }
    }

    init(id: UUID = UUID(), workingDirectory: URL, root: PaneNode) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.root = root
        self.activePaneId = root.firstPane?.id
    }
}
