import Foundation

extension Array {
    /// Step `direction` from `current`, wrapping at both ends. Used by tab
    /// and pane cycling. Direction can be any non-zero `Int`; positive walks
    /// forward, negative walks backward. Returns 0 for an empty array so
    /// callers can index without bounds checks (subscripting into an empty
    /// array would still trap, so guard `!isEmpty` before subscripting).
    func cyclicIndex(from current: Int, step direction: Int) -> Int {
        guard !isEmpty else { return 0 }
        return ((current + direction) % count + count) % count
    }
}

/// True iff `url` points at a directory that currently exists on disk.
func isDirectory(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

/// Returns `path` as a directory URL if it exists, otherwise the user's
/// home dir. The fallback prevents agentterminal from spawning a shell at a deleted
/// project path (deleted between sessions, externally unmounted disk),
/// which manifests as the new tab dying with a confusing one-line error.
func resolvedSpawnCwd(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    return isDirectory(url) ? url : URL(fileURLWithPath: NSHomeDirectory())
}

/// Trims a title string; blank or whitespace-only input collapses to `nil`.
/// Shared by the manual-rename paths and the OSC-title observer so "empty
/// means no title" stays one rule.
func normalizedTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Three-state sidebar visibility. `next` cycles full → compact → hidden →
/// full so each toggle hides more and eventually wraps around.
enum SidebarMode: String, Codable, Equatable, Sendable {
    case full
    case compact
    case hidden

    var next: SidebarMode {
        switch self {
        case .full: return .compact
        case .compact: return .hidden
        case .hidden: return .full
        }
    }
}

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceId: UUID?
    /// Session id currently being dragged in any pane's tab bar. Shared across
    /// all `TabBarView` instances so target panes can show drop indicators
    /// even when the source lives in a different pane.
    var draggingTabId: UUID?
    var sidebarMode: SidebarMode = .full
    /// User-customized sidebar width in full mode. Nil = use default (220pt).
    var sidebarWidth: CGFloat? = nil
    /// Right-side agent-overview sidebar — per-window collapse state, sharing
    /// the left sidebar's three modes (full / compact / hidden). The content is
    /// the global `AgentMonitor`; each window toggles its own panel. Defaults
    /// to hidden since it's opt-in.
    var rightSidebarMode: SidebarMode = .hidden
    /// Fired when the last workspace closes. `AgentTerminalWindowController` wires
    /// this to close its window — a window with zero workspaces is empty.
    var onBecameEmpty: (() -> Void)?

    /// Drives the sidebar-resize guide line. The `SidebarResizeHandle` calls
    /// this with the cursor's x (in window-content coords) during a drag and
    /// `nil` on release. `AgentTerminalWindowController` wires it to a top-level
    /// NSView so the line draws ABOVE libghostty's Metal layer — a SwiftUI guide
    /// gets clipped by the terminal surface once it crosses the sidebar edge.
    var showSidebarResizeGuide: ((CGFloat?) -> Void)?

    /// Mutate + schedule save. UI sites wrap in `withAnimation(Theme.chromeTransition)`.
    func setSidebarMode(_ mode: SidebarMode) {
        applySidebarMode(&sidebarMode, mode)
    }

    func setRightSidebarMode(_ mode: SidebarMode) {
        applySidebarMode(&rightSidebarMode, mode)
    }

    private func applySidebarMode(_ storage: inout SidebarMode, _ mode: SidebarMode) {
        guard storage != mode else { return }
        storage = mode
        scheduleSave()
    }

    /// Open the rename popover on the active tab (⌘R). Sets a runtime flag the
    /// active `TabBarItem` observes; the active tab is always present in its
    /// pane's tab bar, so the popover can anchor.
    func requestRenameActiveTab() {
        active?.activeSession?.renameRequested = true
    }

    /// Open the rename popover on the active workspace's sidebar row (⌘⇧R).
    /// Parks the request for `SidebarView` to handle — the active row may be
    /// unmounted (collapsed worktree parent, or scrolled out of the
    /// `LazyVStack`), so the sidebar expands/scrolls it into view before
    /// handing off to the row via `Workspace.renameRequested`. Reveal a hidden
    /// sidebar first so `SidebarView` exists to observe the parked request.
    func requestRenameActiveWorkspace() {
        if sidebarMode == .hidden { setSidebarMode(.full) }
        pendingRenameWorkspace = active
    }

    private let engineFactory: @MainActor () -> any TerminalEngine
    /// Resolves per-agent launch options at spawn time. Production wires this
    /// to `AgentTerminalSettingsModel.shared.agentOptions[id]`; tests pass a closure
    /// that returns nil so unit tests stay independent of the developer's
    /// real `~/.agentterminal/settings.json`.
    private let optionsProvider: @MainActor (String) -> String?
    /// Reads `AgentTerminalSettingsModel.shared.resumeConversations` at spawn time;
    /// tests inject a static value (typically `true`) for the same reason
    /// as `optionsProvider`.
    private let resumeProvider: @MainActor () -> Bool
    /// Every live window's store (including this one) — injected by
    /// `AppDelegate` so a tab dropped here from another window can be located
    /// in the store it came from. Tests default to `{ [] }`, keeping each
    /// store window-isolated.
    private let peerStores: @MainActor () -> [WorkspaceStore]
    /// Invoked when the user picks "Move to New Window" from a tab's
    /// right-click menu — `AppDelegate` opens a fresh window and moves the
    /// session into it. Tests default to a no-op.
    private let moveToNewWindow: @MainActor (UUID) -> Void
    /// Fired when a session enters an attention (waiting-on-you) state or a
    /// command there fails. `AppDelegate` decides whether to surface a system
    /// notification — only when the originating tab isn't currently visible.
    /// Tests default to a no-op.
    private let onSessionAlert: @MainActor (UUID, SessionAlertKind) -> Void
    private let persistence: any Persistence
    private let gitStatusFetcher = GitStatusFetcher()
    /// One watcher per session — refreshes git status when `.git/HEAD` or
    /// `.git/index` changes from any source (agent subprocess, external
    /// terminal, file-level git ops). The OSC 7 / OSC 133 paths only see
    /// the outer shell, so an agent running its own subprocess shell never
    /// trips them; the filesystem layer catches everyone.
    private var gitWatchers: [UUID: GitWatcher] = [:]

    /// Snapshot of a closed tab's reopenable state. Workspace + pane IDs
    /// are best-effort routing — if either is gone by the time the user
    /// hits ⌘⇧T, `reopenLastClosedTab` falls back to the active workspace
    /// / pane.
    private struct ClosedTabState {
        let agent: AgentTemplate
        let cwd: URL
        let customTitle: String?
        let workspaceId: UUID
        let paneId: UUID
        /// Captured conversation id so `⌘⇧T` resumes the Claude session
        /// the user just closed (subject to `resumeConversations` setting).
        let conversationId: String?
    }

    /// LIFO stack of recently-closed tabs for ⌘⇧T (reopen). Capped at
    /// `closedTabHistoryLimit` so a long session doesn't unbounded-grow.
    /// Runtime-only — closed tabs do not survive an app restart.
    private var recentlyClosed: [ClosedTabState] = []
    private static let closedTabHistoryLimit = 50

    /// Timestamp of the last BEL-triggered notification per session, used to
    /// debounce rapid BEL bursts (e.g. a programmatic `\a` loop).
    private var lastBellTime: [UUID: Date] = [:]
    private static let bellDebounce: TimeInterval = 2
    /// Timestamp of the last attention notification per session, used to
    /// debounce rapid attention events (e.g. PreToolUse firing for every
    /// tool call in a turn).
    private var lastAttentionTime: [UUID: Date] = [:]
    private static let attentionDebounce: TimeInterval = 1

    private var pendingSave: Task<Void, Never>?
    /// Monotonic counter bumped on every `toggleZoom`. The async restore
    /// Task captures the value at toggle time and bails if the counter has
    /// moved by the time it fires — keeps a rapid second toggle's
    /// in-flight animation from being prematurely un-suspended by the
    /// previous toggle's stale Task.
    private var zoomSuspensionGeneration: Int = 0
    private static let saveDebounce: UInt64 = 1_000_000_000

    var active: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    init(
        persistence: any Persistence,
        engineFactory: @escaping @MainActor () -> any TerminalEngine = { LibghosttyEngine() },
        optionsProvider: @escaping @MainActor (String) -> String? = { AgentTerminalSettingsModel.shared.agentOptions[$0] },
        resumeProvider: @escaping @MainActor () -> Bool = { AgentTerminalSettingsModel.shared.resumeConversations },
        peerStores: @escaping @MainActor () -> [WorkspaceStore] = { [] },
        moveToNewWindow: @escaping @MainActor (UUID) -> Void = { _ in },
        onSessionAlert: @escaping @MainActor (UUID, SessionAlertKind) -> Void = { _, _ in }
    ) {
        self.persistence = persistence
        self.engineFactory = engineFactory
        self.optionsProvider = optionsProvider
        self.resumeProvider = resumeProvider
        self.peerStores = peerStores
        self.moveToNewWindow = moveToNewWindow
        self.onSessionAlert = onSessionAlert
        if let saved = persistence.load(), !saved.workspaces.isEmpty {
            restore(from: saved)
        } else {
            addWorkspace()
        }
    }

    // MARK: - Workspaces

    @discardableResult
    func addWorkspace(
        workingDirectory: URL? = nil,
        worktreeParent: Workspace? = nil,
        worktreeBranch: String? = nil,
        template: AgentTemplate = .terminal
    ) -> Workspace {
        let dir = workingDirectory
            ?? active?.workingDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let pane = Pane()
        let root = PaneNode(pane: pane)
        let workspace = Workspace(workingDirectory: dir, root: root)
        workspace.worktreeParentId = worktreeParent?.id
        workspace.worktreeBranch = worktreeBranch
        // Pin worktreePath at create time so `git worktree remove` always
        // targets the disk root, no matter where the user cd's later.
        // `.standardizedFileURL` resolves `/tmp` → `/private/tmp` etc. so
        // a later reconcile comparison against `git worktree list`
        // output (which is already realpath'd) lines up.
        if worktreeParent != nil {
            workspace.worktreePath = dir.standardizedFileURL
        }
        let session = spawnSession(template: template, initialCwd: dir)
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
        pane.tabs.append(session)
        pane.activeTabId = session.id
        // Worktrees insert right after their source (or after the source's
        // existing worktrees) — compact-mode sidebar walks `workspaces`
        // in array order, so this visual grouping is load-bearing there.
        if let parent = worktreeParent,
           let parentIdx = workspaces.firstIndex(where: { $0 === parent }) {
            var insertAt = parentIdx + 1
            while insertAt < workspaces.count
                  && workspaces[insertAt].worktreeParentId == parent.id {
                insertAt += 1
            }
            workspaces.insert(workspace, at: insertAt)
        } else {
            workspaces.append(workspace)
        }
        activeWorkspaceId = workspace.id
        scheduleSave()
        return workspace
    }

    /// Creates a git worktree of `source` and adds the resulting directory
    /// as a child workspace under it. `git worktree add` runs on a detached
    /// task so the SwiftUI sheet stays responsive; on failure the stderr
    /// goes back via the outcome so the sheet shows it inline.
    func createWorktree(
        source: Workspace,
        request: CreateWorktreeSheet.Request
    ) async -> CreateWorktreeSheet.CreateOutcome {
        switch request.kind {
        case .create(let mode, let path, let branchForDisplay):
            guard let repoPath = WorktreeManager.repoRoot(near: source.workingDirectory) else {
                return .failure("not inside a git repository")
            }
            let result = await Task.detached(priority: .userInitiated) {
                WorktreeManager.add(repoPath: repoPath, path: path, mode: mode)
            }.value
            if case .failure(let err) = result {
                return .failure(err.description)
            }
            addWorkspace(
                workingDirectory: path,
                worktreeParent: source,
                worktreeBranch: branchForDisplay,
                template: request.template
            )
            return .success
        case .adopt(let worktrees):
            // Pure sidebar materialization — no git command, the
            // directories already exist on disk. One workspace per
            // picked worktree, inserted after the source in array
            // order so sidebar grouping stays correct.
            for info in worktrees {
                addWorkspace(
                    workingDirectory: info.path,
                    worktreeParent: source,
                    worktreeBranch: info.branch,
                    template: request.template
                )
            }
            return .success
        }
    }

    /// Worktree workspaces close through this request first so the
    /// sidebar can pop the brutalist confirm sheet before anything
    /// destructive runs. Plain workspaces skip the prompt and go
    /// straight to `closeWorkspace`. Set non-nil to mean "user asked to
    /// close this worktree, sidebar please ask them about the dir";
    /// cleared by the sheet on dismiss / confirm.
    var pendingRemovalRequest: Workspace?

    /// Cross-view create request. Sidebar rows open the sheet directly, but
    /// global entry points such as the command palette need to ask the
    /// sidebar to host the sheet, especially when the sidebar was hidden and
    /// has to be shown first.
    var pendingCreateWorktreeRequest: Workspace?

    /// ⌘⇧R rename request, parked for `SidebarView` to act on. The active
    /// workspace's row may be unmounted — nested under a collapsed worktree
    /// parent, or scrolled out of the sidebar's `LazyVStack` — so the sidebar
    /// (not the store) has to expand/scroll it into view before the row's
    /// rename popover can anchor. Identity-keyed; cleared by the sidebar once
    /// handled.
    var pendingRenameWorkspace: Workspace?

    /// Payload for the "close source workspace, take its worktrees with
    /// it" confirm sheet. A source can't simply close on its own — its
    /// worktrees would either show as orphan rows (the sidebar fallback)
    /// or vanish silently. Either way the user's mental model breaks.
    struct CloseSourceRequest {
        let source: Workspace
        let worktrees: [Workspace]
    }

    /// Set when a top-level workspace with worktrees is being closed and
    /// the sidebar should pop the bulk confirm sheet. Plain top-level
    /// workspaces (no worktrees) close inline and never park here.
    var pendingCloseSourceRequest: CloseSourceRequest?

    /// UI-level close request. Callers from the sidebar (× button, right-
    /// click menu) and the ⌘⇧W menu item both funnel here so the
    /// confirm prompt only lives in one place.
    func requestCloseWorkspace(_ workspace: Workspace) {
        if workspace.worktreeParentId != nil {
            pendingRemovalRequest = workspace
            return
        }
        let worktrees = workspaces.filter { $0.worktreeParentId == workspace.id }
        if worktrees.isEmpty {
            closeWorkspace(workspace)
            return
        }
        pendingCloseSourceRequest = CloseSourceRequest(source: workspace, worktrees: worktrees)
    }

    /// Performs the deferred source-with-worktrees close from the sheet.
    /// `alsoDelete = true` runs `git worktree remove --force` + branch-d
    /// for each child before closing the source (the v0.18.x default
    /// behaviour, now opt-in via the sheet's checkbox). First failing
    /// git remove aborts and surfaces stderr. `alsoDelete = false` just
    /// drops the workspaces from the sidebar — disk untouched.
    func performCloseSource(_ request: CloseSourceRequest, alsoDelete: Bool) async -> String? {
        if alsoDelete {
            for worktree in request.worktrees {
                if let message = await removeWorktreeDirectory(worktree) {
                    return message
                }
            }
        }
        for worktree in request.worktrees { closeWorkspace(worktree) }
        closeWorkspace(request.source)
        pendingCloseSourceRequest = nil
        return nil
    }

    /// Zombie-clean sidebar worktree workspaces against `git worktree list`.
    /// Runs once at app launch (AppDelegate calls it after every window's
    /// store is restored). Only handles the *removal* side — a sidebar
    /// entry whose worktree directory was deleted from disk (e.g. CLI
    /// `git worktree remove` while agentterminal was closed) gets dropped.
    ///
    /// v0.19.0 removed the disk → sidebar adopt path: agentterminal no longer
    /// surfaces worktrees the user created via CLI or another tool. To
    /// see them, the user explicitly goes through Create Worktree →
    /// "adopt existing worktree" mode. Reasoning: v0.18.x's auto-adopt
    /// caused noisy sidebars + scared users into not closing entries
    /// (close was destructive then). state.json + user action is now
    /// the single source of truth for what agentterminal displays.
    ///
    /// Subprocess fan-out runs off the main actor in a TaskGroup so a
    /// user with N source repos doesn't pay N × ~100ms blocked on launch.
    /// Results apply back on the main actor in source order.
    func reconcileWorktrees() async {
        // Snapshot inputs on the main actor before hopping off — Workspace
        // is @MainActor so the closure can't touch its properties from
        // background tasks.
        let inputs: [(index: Int, sourceId: UUID, cwd: URL)] = workspaces.enumerated().compactMap { index, source in
            guard source.worktreeParentId == nil else { return nil }
            return (index, source.id, source.workingDirectory)
        }
        guard !inputs.isEmpty else { return }

        let results: [(index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])] = await withTaskGroup(
            of: (index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])?.self
        ) { group in
            for input in inputs {
                group.addTask {
                    guard let repoRoot = WorktreeManager.repoRoot(near: input.cwd),
                          case .success(let infos) = WorktreeManager.list(repoPath: repoRoot) else {
                        return nil
                    }
                    return (input.index, input.sourceId, repoRoot, infos)
                }
            }
            var collected: [(index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])] = []
            for await result in group { if let result { collected.append(result) } }
            return collected.sorted { $0.index < $1.index }
        }

        for result in results {
            guard let source = workspaces.first(where: { $0.id == result.sourceId }) else { continue }
            reconcile(source: source, sourceRoot: result.repoRoot, diskWorktrees: result.infos)
        }
    }

    /// `internal` so tests can drive it with synthetic `diskWorktrees`
    /// without spinning up a real git repo. `reconcileWorktrees` is the
    /// production entry point.
    func reconcile(source: Workspace, sourceRoot: URL? = nil, diskWorktrees: [WorktreeManager.Info]) {
        let sourceRootPath = (sourceRoot ?? WorktreeManager.repoRoot(near: source.workingDirectory) ?? source.workingDirectory)
            .standardizedFileURL
            .path
        // Drop the source workspace's own working-tree root so we're
        // comparing only sibling worktrees against the sidebar. This must
        // use a stable repo root, not `Workspace.workingDirectory`, because
        // that property follows the active shell's cwd and may be `/repo/sub`.
        let sidebar = workspaces.filter { $0.worktreeParentId == source.id }
        guard !sidebar.isEmpty else { return }

        // Precompute Set of disk satellite paths so the zombie check is
        // O(M+K) (M sidebar entries, K disk worktrees), not O(M×K) — the
        // user opens agentterminal a lot, every microsecond on this path adds up
        // to perceived launch latency.
        let satellitePaths: Set<String> = Set(
            diskWorktrees.lazy
                .map { $0.path.standardizedFileURL.path }
                .filter { $0 != sourceRootPath }
        )

        // Compare against the pinned worktreePath, not workingDirectory —
        // a sidebar row whose user cd'd to ~/Downloads still matches its
        // disk root via worktreePath. Adopt-on-discovery is deliberately
        // not handled — see method doc comment.
        for wt in sidebar where !satellitePaths.contains(wt.diskPath.standardizedFileURL.path) {
            closeWorkspace(wt)
        }
    }

    /// Runs `git worktree remove --force <path>` on a detached task. The
    /// caller closes the workspace separately — this method only touches
    /// disk. `--force` because the close-confirm sheet already gathered
    /// the user's intent; refusing on dirty state here would just bounce
    /// them back to terminal commands. Returns nil on success, otherwise
    /// the error message to surface inline in the sheet.
    func removeWorktreeDirectory(_ workspace: Workspace) async -> String? {
        guard workspace.worktreeParentId != nil else {
            return "workspace is not a worktree"
        }
        let path = workspace.diskPath
        let parent = workspace.worktreeParentId.flatMap { parentId in
            workspaces.first(where: { $0.id == parentId })
        }
        let repoPath = parent
            .flatMap { WorktreeManager.repoRoot(near: $0.workingDirectory) }
            ?? WorktreeManager.repoRoot(near: path)
            ?? (isDirectory(path) ? path : nil)
        guard let repoPath else {
            // Parent and worktree directory are already gone. Let the caller
            // close the stranded sidebar row; there is no disk left to delete.
            pruneRecentlyClosed(under: workspace)
            return nil
        }
        let normalizedPath = path.standardizedFileURL.path
        let result = await Task.detached(priority: .userInitiated) {
            // Resolve the worktree's real current branch from `git
            // worktree list` before removing — the user may have
            // `git switch`-ed inside the worktree since agentterminal last
            // recorded `worktreeBranch`. Falling back to the stored
            // value would delete an outdated branch and leave the
            // truly-checked-out one orphaned.
            let realBranch: String? = {
                guard case .success(let infos) = WorktreeManager.list(repoPath: repoPath),
                      let match = infos.first(where: {
                          $0.path.standardizedFileURL.path == normalizedPath
                      })
                else { return nil }
                return match.branch
            }()
            let removed = WorktreeManager.remove(repoPath: repoPath, path: path, force: true)
            // Safe-delete the branch (only if merged) after the worktree
            // dir is gone — `git branch -d` would otherwise refuse with
            // "currently checked out at <path>". Failure on unmerged
            // branches is expected and intentionally ignored; the next
            // Create Worktree on the same name surfaces "branch exists
            // locally" then. No data-loss risk because git refuses to
            // drop unmerged commits without the upper-case `-D`.
            if case .success = removed, let realBranch, !realBranch.isEmpty {
                _ = WorktreeManager.deleteBranchIfMerged(repoPath: repoPath, branch: realBranch)
            }
            return removed
        }.value
        if case .failure(let err) = result {
            return err.description
        }
        pruneRecentlyClosed(under: workspace)
        return nil
    }

    /// Drops `recentlyClosed` entries for a worktree workspace we just
    /// `git worktree remove`-d — without this, ⌘⇧T would respawn a tab
    /// at a deleted cwd and `resolvedSpawnCwd` would silently route it
    /// to `$HOME`, surfacing a "Terminal at ~" the user never closed.
    private func pruneRecentlyClosed(under workspace: Workspace) {
        let root = workspace.diskPath.standardizedFileURL.path
        recentlyClosed.removeAll { entry in
            let cwd = entry.cwd.standardizedFileURL.path
            return entry.workspaceId == workspace.id
                || cwd == root
                || cwd.hasPrefix(root + "/")
        }
    }

    func closeWorkspace(_ workspace: Workspace) {
        for pane in workspace.root.allPanes {
            for tab in pane.tabs {
                gitWatchers.removeValue(forKey: tab.id)?.cancel()
                tab.engine.terminate()
            }
        }
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces.remove(at: idx)
        if workspaces.isEmpty {
            activeWorkspaceId = nil
        } else if activeWorkspaceId == workspace.id {
            let nextIdx = min(idx, workspaces.count - 1)
            activeWorkspaceId = workspaces[nextIdx].id
        }
        scheduleSave()
        if workspaces.isEmpty { onBecameEmpty?() }
    }

    func activateWorkspace(_ workspace: Workspace) {
        guard activeWorkspaceId != workspace.id else { return }
        activeWorkspaceId = workspace.id
        scheduleSave()
    }

    @discardableResult
    func duplicateWorkspace(_ workspace: Workspace) -> Workspace {
        addWorkspace(workingDirectory: workspace.workingDirectory)
    }

    /// Set or clear a user-provided workspace title. Empty / whitespace input
    /// clears the override so the sidebar label resumes tracking the cwd.
    func renameWorkspace(_ workspace: Workspace, to newTitle: String) {
        let next = normalizedTitle(newTitle)
        guard workspace.customTitle != next else { return }
        workspace.customTitle = next
        scheduleSave()
    }

    /// Reorder workspaces in the sidebar — dragged workspace takes the
    /// destination index, others shift.
    func moveWorkspace(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex != destIndex,
              (0..<workspaces.count).contains(sourceIndex),
              (0..<workspaces.count).contains(destIndex) else { return }
        let source = workspaces[sourceIndex]
        let rootId = source.worktreeParentId ?? source.id
        let movingIndices = workspaces.indices.filter { idx in
            let ws = workspaces[idx]
            return ws.id == rootId || ws.worktreeParentId == rootId
        }
        guard !movingIndices.contains(destIndex) else { return }

        let movingIds = Set(movingIndices.map { workspaces[$0].id })
        let moving = workspaces.filter { movingIds.contains($0.id) }
        var remaining = workspaces.filter { !movingIds.contains($0.id) }
        let insertAt = min(max(destIndex, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        workspaces = remaining
        scheduleSave()
    }

    /// Payload for the "Close Other Workspaces" confirm sheet — captured
    /// when at least one of the workspaces about to close is a worktree,
    /// so the sheet can show the count and make the directory deletion
    /// explicit before running it.
    struct BulkRemovalRequest {
        let keeping: Workspace
        let others: [Workspace]
        let worktreeOthers: [Workspace]

        @MainActor
        init(keeping: Workspace, others: [Workspace]) {
            self.keeping = keeping
            self.others = others
            self.worktreeOthers = others.filter { $0.worktreeParentId != nil }
        }
    }

    /// Set when `closeOtherWorkspaces` detects a worktree among the
    /// workspaces about to close; sidebar's onChange listener pops the
    /// summary sheet from here. Plain bulk closes skip this and run
    /// inline.
    var pendingCloseOthersRequest: BulkRemovalRequest?

    func closeOtherWorkspaces(keeping workspace: Workspace) {
        // Keep the workspace's worktree family intact so we never strand
        // a worktree without its source (and vice versa):
        //  - keeping a source: also keep every worktree under it
        //  - keeping a worktree: also keep its source (siblings still close)
        var keepIds: Set<UUID> = [workspace.id]
        if let parentId = workspace.worktreeParentId {
            keepIds.insert(parentId)
        } else {
            for ws in workspaces where ws.worktreeParentId == workspace.id {
                keepIds.insert(ws.id)
            }
        }
        let others = workspaces.filter { !keepIds.contains($0.id) }
        if others.contains(where: { $0.worktreeParentId != nil }) {
            pendingCloseOthersRequest = BulkRemovalRequest(keeping: workspace, others: others)
            return
        }
        for ws in others { closeWorkspace(ws) }
    }

    /// Performs the deferred bulk close from the confirm sheet.
    /// `alsoDelete = true` runs `git worktree remove --force` + branch-d
    /// on each worktree in the others list before closing; `alsoDelete
    /// = false` just drops them from the sidebar with disk untouched
    /// (v0.19.0 default — destructive removal is the checkbox path).
    /// First failing git remove aborts.
    func performCloseOthers(_ request: BulkRemovalRequest, alsoDelete: Bool) async -> String? {
        if alsoDelete {
            for worktree in request.worktreeOthers {
                if let message = await removeWorktreeDirectory(worktree) {
                    return message
                }
            }
        }
        for ws in request.others { closeWorkspace(ws) }
        pendingCloseOthersRequest = nil
        return nil
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(
        in workspace: Workspace,
        pane: Pane? = nil,
        template: AgentTemplate = .terminal,
        initialCwd: URL? = nil,
        conversationId: String? = nil,
        initialPrompt: String? = nil
    ) -> Session {
        guard let target = pane ?? workspace.activePane ?? workspace.root.firstPane else {
            preconditionFailure("workspace has no panes")
        }
        // Precedence: explicit caller cwd (`reopenLastClosedTab`,
        // right-click "Ask <agent>") > template's pinned cwd
        // (`TerminalPreset.path` via `AgentTemplate.extraCwd`) > workspace
        // cwd. `~/` is expanded; a vanished path falls back to `$HOME` via
        // `resolvedSpawnCwd`.
        let cwd = initialCwd
            ?? template.extraCwd.map { resolvedSpawnCwd(($0 as NSString).expandingTildeInPath) }
            ?? workspace.workingDirectory
        let session = spawnSession(template: template, initialCwd: cwd, conversationId: conversationId, initialPrompt: initialPrompt)
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
        target.tabs.append(session)
        target.activeTabId = session.id
        if workspace.activePaneId != target.id {
            workspace.activePaneId = target.id
        }
        workspace.invalidateReadout()
        scheduleSave()
        return session
    }

    /// Forward context from `fromSession` to a new tab running the target
    /// agent. Records the handoff in `MessageBus` so the UI can show it.
    /// The new tab receives an initial prompt that references the source tab.
    @discardableResult
    func forwardSession(from fromSession: Session, to targetSessionId: UUID, in workspace: Workspace) -> Session? {
        guard let targetEntry = AgentMonitor.shared.entries.first(where: { $0.id == targetSessionId }),
              let targetPane = workspace.activePane ?? workspace.root.firstPane
        else { return nil }
        let contextPrompt = "Forwarded from \(fromSession.displayAgent.title) (\(fromSession.title))"
        let newSession = addTab(
            in: workspace,
            pane: targetPane,
            template: targetEntry.agent,
            initialPrompt: contextPrompt
        )
        MessageBus.shared.send(
            from: fromSession,
            toSessionId: newSession.id,
            toAgentTitle: targetEntry.agent.title,
            content: contextPrompt
        )
        return newSession
    }

    @discardableResult
    func duplicateTab(_ session: Session, in workspace: Workspace) -> Session? {
        guard let pane = pane(containing: session, in: workspace) else { return nil }
        return addTab(in: workspace, pane: pane, template: session.agent, initialCwd: session.currentDirectory)
    }

    /// Set or clear a user-provided tab title. Empty / whitespace input clears
    /// the override so the title resumes tracking the working directory.
    func renameTab(_ session: Session, to newTitle: String) {
        let next = normalizedTitle(newTitle)
        guard session.customTitle != next else { return }
        session.customTitle = next
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destIndex: Int, in pane: Pane) {
        guard sourceIndex != destIndex,
              (0..<pane.tabs.count).contains(sourceIndex),
              (0..<pane.tabs.count).contains(destIndex) else { return }
        let tab = pane.tabs.remove(at: sourceIndex)
        pane.tabs.insert(tab, at: destIndex)
        scheduleSave()
    }

    /// Move a tab from its current pane to a different pane at a specific
    /// index. Uses direct array manipulation to avoid triggering closePane's
    /// tree restructuring, which can invalidate rendering in the destination.
    func moveTab(_ session: Session, to destPane: Pane, at destIndex: Int, in workspace: Workspace) {
        guard let sourcePane = workspace.root.pane(containingSessionId: session.id) else { return }
        if sourcePane.id == destPane.id { return }
        guard let sourceIndex = sourcePane.tabs.firstIndex(where: { $0.id == session.id }) else { return }

        // Remove from source directly (no detachSession to avoid closePane tree restructure)
        sourcePane.tabs.remove(at: sourceIndex)
        if sourcePane.tabs.isEmpty {
            closePane(sourcePane, in: workspace)
        } else if sourcePane.activeTabId == session.id {
            sourcePane.activeTabId = sourcePane.tabs[min(sourceIndex, sourcePane.tabs.count - 1)].id
            if workspace.activePaneId == sourcePane.id,
               workspace.workingDirectory != sourcePane.activeTab?.currentDirectory {
                workspace.workingDirectory = sourcePane.activeTab?.currentDirectory ?? workspace.workingDirectory
            }
        }
        workspace.invalidateReadout()

        // Insert into destination
        attachSession(session, to: destPane, at: destIndex, in: workspace)

        // Force the engine to re-layout in its new container
        session.engine.flushSize()
    }

    /// Public version of detachSession for use by PaneDropDelegate.
    func detachSessionPublic(_ session: Session, from pane: Pane, at idx: Int, in workspace: Workspace) {
        detachSession(session, from: pane, at: idx, in: workspace)
    }

    /// Removes `session` from `pane`. An emptied pane collapses — cascading
    /// to closing the workspace, and the window, when it was the last one;
    /// otherwise the active-tab crown passes to the neighbour and the
    /// workspace cwd re-syncs. Structural only: the engine keeps running, so
    /// this serves both `closeTab` (which terminates first) and a tab move
    /// (which re-homes the live session elsewhere).
    private func detachSession(_ session: Session, from pane: Pane, at idx: Int, in workspace: Workspace) {
        pane.tabs.remove(at: idx)
        if pane.tabs.isEmpty {
            closePane(pane, in: workspace)
            workspace.invalidateReadout()
            return
        }
        if pane.activeTabId == session.id {
            let next = pane.tabs[min(idx, pane.tabs.count - 1)]
            pane.activeTabId = next.id
            if workspace.activePane?.id == pane.id, workspace.workingDirectory != next.currentDirectory {
                workspace.workingDirectory = next.currentDirectory
            }
        }
        workspace.invalidateReadout()
        scheduleSave()
    }

    /// Inserts an existing `session` into `destPane` at `destIndex` and
    /// promotes it to the active tab + active pane.
    private func attachSession(_ session: Session, to destPane: Pane, at destIndex: Int, in workspace: Workspace) {
        let insertIndex = min(max(destIndex, 0), destPane.tabs.count)
        destPane.tabs.insert(session, at: insertIndex)
        destPane.activeTabId = session.id
        workspace.activePaneId = destPane.id
        // Promoting to active mirrors `activateTab` so the sidebar title and
        // the next tab's spawn cwd follow the new focus without waiting for
        // the next OSC 7.
        if workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
        }
        scheduleSave()
    }

    /// One-shot drop handler for tab reorder gestures. Dispatches three ways:
    /// a same-pane index reorder when source == dest, a cross-pane session
    /// move within this window, or — when the session isn't in this window at
    /// all — a cross-window adoption from whichever peer store owns it.
    /// `destIndex` is the target item's current index in `destPane.tabs` (or
    /// `destPane.tabs.count` for "drop at end").
    @discardableResult
    func handleTabDrop(droppedId: UUID, to destPane: Pane, at destIndex: Int, in workspace: Workspace) -> Bool {
        if let sourcePane = workspace.root.pane(containingSessionId: droppedId),
           let session = sourcePane.tabs.first(where: { $0.id == droppedId }) {
            if sourcePane.id == destPane.id {
                guard let from = sourcePane.tabs.firstIndex(where: { $0.id == droppedId }) else { return false }
                let to = min(max(destIndex, 0), sourcePane.tabs.count - 1)
                guard from != to else { return false }
                moveTab(from: from, to: to, in: sourcePane)
            } else {
                moveTab(session, to: destPane, at: destIndex, in: workspace)
            }
            return true
        }
        // The drag started in another window: take the session from the peer
        // store that owns it, slot it in here, and re-point its engine
        // callbacks at this store so focus / title / activity events follow.
        for source in peerStores() where source !== self {
            if let session = source.surrenderSession(id: droppedId) {
                attachSession(session, to: destPane, at: destIndex, in: workspace)
                wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
                return true
            }
        }
        return false
    }

    /// Removes the session with `id` from this store and returns it for a
    /// peer store (another window) to adopt — its engine, libghostty surface,
    /// scrollback, PTY and agent state all stay alive. Returns nil when this
    /// store doesn't own the id. `internal`, not `private`: `handleTabDrop`
    /// calls it on each peer store.
    func surrenderSession(id: UUID) -> Session? {
        guard let (workspace, pane) = location(ofSessionId: id),
              let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let session = pane.tabs[idx]
        // The drag started in this window, so `onDrag` set our `draggingTabId`
        // — and the destination store's `dropDestination` defer clears only
        // its own. Clear ours so this window's drop indicators reset.
        draggingTabId = nil
        gitWatchers.removeValue(forKey: id)?.cancel()
        detachSession(session, from: pane, at: idx, in: workspace)
        return session
    }

    /// Routes the right-click "Move to New Window" request to `AppDelegate`,
    /// which creates a fresh window and moves the session into it.
    func moveTabToNewWindow(_ sessionId: UUID) {
        moveToNewWindow(sessionId)
    }

    func closeOtherTabs(keeping session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace) else { return }
        let toClose = pane.tabs.filter { $0.id != session.id }
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    func closeTabsToRight(of session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Snapshot direct refs — `closeTab` mutates `pane.tabs` mid-iteration.
        let toClose = Array(pane.tabs[(idx + 1)...])
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    func closeTab(_ session: Session, in workspace: Workspace) {
        closeTab(session, in: workspace, recordHistory: true)
    }

    /// Like `closeTab` but skips the reopen-closed-tab history — for
    /// synthetic tabs the user never knowingly opened (e.g. the placeholder
    /// the new-window orchestration spawns before adopting a moved-in tab).
    /// Without this, `⌘⇧T` after a Move to New Window resurrects a phantom
    /// "terminal at ~" the user never closed.
    func discardTab(_ session: Session, in workspace: Workspace) {
        closeTab(session, in: workspace, recordHistory: false)
    }

    private func closeTab(_ session: Session, in workspace: Workspace, recordHistory: Bool) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Closing the last tab of a worktree workspace cascades through
        // detachSession → closePane → closeWorkspace, which would bypass
        // the confirm sheet. Reroute here before any state mutates so
        // the sheet's cancel path can keep the tab open.
        let isLastTabInWorktree = workspace.worktreeParentId != nil
            && !workspace.root.hasMultiplePanes
            && pane.tabs.count == 1
        if isLastTabInWorktree {
            requestCloseWorkspace(workspace)
            return
        }
        if recordHistory {
            recordClosedTab(session, pane: pane, workspace: workspace)
        }
        gitWatchers.removeValue(forKey: session.id)?.cancel()
        session.engine.terminate()
        detachSession(session, from: pane, at: idx, in: workspace)
    }

    private func recordClosedTab(_ session: Session, pane: Pane, workspace: Workspace) {
        recentlyClosed.append(ClosedTabState(
            agent: session.agent,
            cwd: session.currentDirectory,
            customTitle: session.customTitle,
            workspaceId: workspace.id,
            paneId: pane.id,
            conversationId: session.conversationId
        ))
        if recentlyClosed.count > Self.closedTabHistoryLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.closedTabHistoryLimit)
        }
    }

    /// Pops the most recently closed tab off the history stack and re-spawns
    /// it. Routes back to the original workspace + pane when both still
    /// exist, falling back to the current workspace's active pane otherwise
    /// (a tab closed under a since-deleted workspace lands wherever the user
    /// is now). Returns the new session, or nil when the stack is empty.
    @discardableResult
    func reopenLastClosedTab() -> Session? {
        guard let state = recentlyClosed.popLast() else { return nil }
        guard let workspace = workspaces.first(where: { $0.id == state.workspaceId }) ?? active else {
            return nil
        }
        let pane = workspace.root.allPanes.first { $0.id == state.paneId }
            ?? workspace.activePane
            ?? workspace.root.firstPane
        let cwd = resolvedSpawnCwd(state.cwd.path)
        let session = addTab(
            in: workspace,
            pane: pane,
            template: state.agent,
            initialCwd: cwd,
            conversationId: state.conversationId
        )
        if let custom = state.customTitle, !custom.isEmpty {
            session.customTitle = custom
        }
        activateWorkspace(workspace)
        activateTab(session, in: workspace)
        return session
    }

    /// Cycle the active pane's tab selection. `direction` of `+1` advances
    /// to the next tab, `-1` to the previous; both wrap at the end. Per-pane,
    /// not workspace-wide — focus shouldn't jump panes when the user is
    /// asking to step through tabs in the pane they're looking at.
    func cycleTab(in workspace: Workspace, direction: Int) {
        guard let pane = workspace.activePane,
              let active = pane.activeTab,
              let currentIdx = pane.tabs.firstIndex(where: { $0 === active })
        else { return }
        activateTab(pane.tabs[pane.tabs.cyclicIndex(from: currentIdx, step: direction)], in: workspace)
    }

    func activateTab(_ session: Session, in workspace: Workspace) {
        // Switching to a tab counts as reading any notification that pointed at
        // it — clears the inbox entry + the bell dot without an explicit click.
        NotificationInbox.shared.markRead(forSession: session.id)
        guard let pane = pane(containing: session, in: workspace) else { return }
        var changed = false
        if pane.activeTabId != session.id {
            pane.activeTabId = session.id
            changed = true
        }
        if workspace.activePaneId != pane.id {
            workspace.activePaneId = pane.id
            // Focusing a different pane while zoomed would route ⌘D /
            // ⌘T / cwd-sync at the now-hidden active pane. Auto-exit so
            // the visible pane = the active pane invariant holds.
            if let zoomed = workspace.zoomedPaneId, zoomed != pane.id {
                workspace.zoomedPaneId = nil
            }
            changed = true
        }
        if workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: - Panes

    /// Toggle pane zoom for the active pane (keyboard / menu entry point
    /// — `⌘⇧E` operates on whatever pane has keyboard focus).
    func toggleZoom(in workspace: Workspace) {
        guard let active = workspace.activePaneId else { return }
        toggleZoom(in: workspace, paneId: active)
    }

    /// Toggle zoom for an explicit pane — used by the per-pane button and
    /// the right-click menu, so clicking the button on a non-active pane
    /// zooms *that* pane (and activates it so subsequent ⌘D / ⌘[ / ⌘]
    /// operate on the visibly-zoomed pane).
    func toggleZoom(in workspace: Workspace, paneId: UUID) {
        guard workspace.canZoom else { return }
        // Suspend per-frame `set_size` propagation across every surface in
        // this workspace for the duration of the SwiftUI frame animation.
        // Otherwise each of the ~12-24 intermediate frame sizes fires its
        // own SIGWINCH, triggering the conda-init scrollback wipe (the
        // documented known issue). After the animation settles we push
        // one final size sync.
        let engines = workspace.root.allPanes.flatMap { $0.tabs }.map(\.engine)
        for engine in engines { engine.suspendsSizePropagation = true }

        workspace.activePaneId = paneId
        workspace.zoomedPaneId = workspace.isZoomed(paneId) ? nil : paneId
        scheduleSave()

        // Generation token: a rapid second toggle bumps the counter
        // before the first Task fires, so the stale restore bails out
        // and only the latest toggle's restore actually clears
        // suspension. Without this, a double-tap inside the 0.25s window
        // re-opens the per-frame `set_size` window mid-animation and the
        // SIGWINCH burst (conda scrollback wipe) comes back.
        zoomSuspensionGeneration &+= 1
        let token = zoomSuspensionGeneration
        let restoreDelay: TimeInterval = 0.25
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
            guard let self, self.zoomSuspensionGeneration == token else { return }
            for engine in engines {
                engine.suspendsSizePropagation = false
                engine.flushSize()
            }
        }
    }

    /// Splits `pane` and moves `session` into the new pane. The source pane
    /// keeps its remaining tabs; the new pane gets just the moved session.
    /// Returns the new pane or nil on failure.
    @discardableResult
    func splitPaneMovingSession(_ session: Session, from sourcePane: Pane, orientation: SplitOrientation, in workspace: Workspace) -> Pane? {
        guard let leafNode = workspace.root.paneNode(paneId: sourcePane.id) else { return nil }
        guard case .pane(let existing) = leafNode.content else { return nil }
        guard let srcIdx = sourcePane.tabs.firstIndex(where: { $0.id == session.id }) else { return nil }
        // Remove from source first so the split sees the updated tab list.
        detachSession(session, from: sourcePane, at: srcIdx, in: workspace)
        let newPane = Pane(tabs: [session], activeTabId: session.id)
        let firstChild = PaneNode(pane: existing)
        let secondChild = PaneNode(pane: newPane)
        leafNode.content = .split(orientation: orientation, first: firstChild, second: secondChild, fraction: 0.5)
        workspace.activePaneId = newPane.id
        if workspace.zoomedPaneId != nil { workspace.zoomedPaneId = nil }
        scheduleSave()
        return newPane
    }

    /// Splits `pane` in two. The existing pane stays as the first child of the
    /// new split; the second child is a fresh `Pane` with a single new tab
    /// inheriting the source pane's active-tab agent + cwd. Returns the new
    /// pane (now focused) or nil if `pane` isn't found.
    @discardableResult
    func splitPane(_ pane: Pane, orientation: SplitOrientation, in workspace: Workspace) -> Pane? {
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return nil }
        guard case .pane(let existing) = leafNode.content else { return nil }
        let template = existing.activeTab?.agent ?? .terminal
        let cwd = existing.activeTab?.currentDirectory ?? workspace.workingDirectory
        let newSession = spawnSession(template: template, initialCwd: cwd)
        wireSessionCallbacks(engine: newSession.engine, session: newSession, workspace: workspace)
        let newPane = Pane(tabs: [newSession], activeTabId: newSession.id)
        let firstChild = PaneNode(pane: existing)
        let secondChild = PaneNode(pane: newPane)
        leafNode.content = .split(orientation: orientation, first: firstChild, second: secondChild, fraction: 0.5)
        workspace.activePaneId = newPane.id
        // Splitting while zoomed = "I want to see what I'm creating". Drop
        // zoom so the new pane is visible. Guarded so a no-op write
        // doesn't trigger an extra Observable invalidation.
        if workspace.zoomedPaneId != nil { workspace.zoomedPaneId = nil }
        scheduleSave()
        return newPane
    }

    /// Removes `pane` and its tabs. If it's the workspace's only pane, the
    /// whole workspace closes. Otherwise the sibling pane collapses up to
    /// take the parent split's place.
    func closePane(_ pane: Pane, in workspace: Workspace) {
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return }
        // Worktree last-pane cascade — route through the confirm sheet
        // before any engines get terminated, so a sheet cancel leaves
        // the user's work intact.
        if leafNode === workspace.root && workspace.worktreeParentId != nil {
            requestCloseWorkspace(workspace)
            return
        }
        if workspace.zoomedPaneId == pane.id { workspace.zoomedPaneId = nil }
        for tab in pane.tabs { tab.engine.terminate() }
        // Object identity, not id equality. After `splitPane`, the workspace
        // root keeps its original id but its content becomes a `.split`, while
        // a freshly-constructed child `PaneNode(pane: existing)` reuses the
        // same `pane.id`. Comparing ids would falsely match a leaf child whose
        // pane shares an id with the root and route through `closeWorkspace`.
        if leafNode === workspace.root {
            closeWorkspace(workspace)
            return
        }
        guard let info = workspace.root.parentInfo(forPane: pane.id) else { return }
        info.parent.content = info.sibling.content
        // After collapse, focus whichever pane is now nearest.
        if workspace.activePaneId == pane.id {
            workspace.activePaneId = info.sibling.firstPane?.id
            if let session = workspace.activeSession,
               workspace.workingDirectory != session.currentDirectory {
                workspace.workingDirectory = session.currentDirectory
            }
        }
        scheduleSave()
    }

    func focusPane(_ pane: Pane, in workspace: Workspace) {
        guard workspace.root.pane(id: pane.id) != nil else { return }
        var changed = false
        if workspace.activePaneId != pane.id {
            workspace.activePaneId = pane.id
            // Same "visible-pane = active-pane" invariant as activateTab —
            // cycling focus via ⌘[ / ⌘] off the zoomed pane drops zoom.
            if let zoomed = workspace.zoomedPaneId, zoomed != pane.id {
                workspace.zoomedPaneId = nil
            }
            changed = true
        }
        if let session = pane.activeTab, workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Adjusts the divider fraction of the split node containing `pane` as a
    /// direct child (used by drag-to-resize).
    func setSplitFraction(_ fraction: Double, parentOf pane: Pane, in workspace: Workspace) {
        guard let info = workspace.root.parentInfo(forPane: pane.id) else { return }
        guard case .split(let orient, let first, let second, let current) = info.parent.content else { return }
        let clamped = min(max(fraction, 0.1), 0.9)
        guard abs(clamped - current) > .ulpOfOne else { return }
        info.parent.content = .split(orientation: orient, first: first, second: second, fraction: clamped)
        scheduleSave()
    }

    /// Routes a hook event to the named session. On `.ended`, drops the leaf
    /// back to `.terminal` only if the agent reporting end matches the
    /// session's current agent — otherwise a Codex run inside a Claude tab
    /// (or a delayed `ended`) would wipe the still-active icon.
    func applyHookEvent(agent: AgentTemplate, event: HookEvent, sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        let agentBefore = session.agent.id
        if event == .ended {
            // A custom agent based on this builtin shares its binary's
            // wrapper shim — the `ended` ping arrives with the builtin's
            // slug, not the custom's id. Match on the template's
            // baseAgentId snapshot (frozen at spawn time, see
            // `AgentTemplate.baseAgentId`) so a mid-run Settings edit
            // can't leave the tab pill stuck.
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                // Report completion to the inbox *before* reverting to
                // Terminal, so the event still knows which agent finished
                // (handleSessionAlert reads displayAgent synchronously).
                onSessionAlert(session.id, .completed)
                session.agent = .terminal
            }
        } else if event == .failure {
            // Agent exited with non-zero status — fire failure notification
            // before reverting, so displayAgent is still correct.
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                onSessionAlert(session.id, .failure)
                session.agent = .terminal
            }
        } else if session.agent.isShell {
            // Includes the default Terminal *and* any TerminalPreset — a
            // user starting Claude inside a preset terminal should get
            // the same icon-upgrade the default Terminal does.
            session.agent = agent
        }
        // SessionStart → UserPromptSubmit on Claude (and BeforeAgent on Gemini)
        // re-fires `.running` per turn; the @Observable setter notifies every
        // sidebar/tab observer even on same-value assignment, so guard.
        if session.activityState != event.activityState {
            session.activityState = event.activityState
            if event.activityState == .attention {
                // Debounce: PreToolUse fires for every tool call in a turn,
                // but only permission-requiring ones need a notification.
                // The debounce prevents spam while still allowing Stop
                // (which fires after all tool calls) to trigger.
                let now = Date()
                if let last = lastAttentionTime[session.id],
                   now.timeIntervalSince(last) < Self.attentionDebounce {
                    // Skip notification but still update state
                } else {
                    lastAttentionTime[session.id] = now
                    onSessionAlert(session.id, .attention)
                }
            }
            if let (workspace, _) = location(ofSessionId: sessionId) {
                workspace.invalidateReadout()
            }
        }
        if session.agent.id != agentBefore { scheduleSave() }
    }

    func applyShellEnvironment(_ env: [String: String], sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        session.shellEnvironment = env
        refreshEnvironment(for: session)
    }

    /// Stores the conversation id reported by an agent's hook payload onto
    /// the originating Session and schedules a save so the value survives
    /// across agentterminal launches. Same-value writes are dropped so we don't
    /// churn persistence on every hook firing — Claude pings `session_id`
    /// on every SessionStart / UserPromptSubmit / Stop / SessionEnd, so the
    /// dedup keeps the debounce loop quiet.
    func applyConversationId(conversationId: String, sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        guard session.conversationId != conversationId else { return }
        session.conversationId = conversationId
        scheduleSave()
    }

    /// Routes a Claude tool-call event (PreToolUse / PostToolUse) to the
    /// originating Session's rolling `toolCallEvents` buffer. Runtime-only
    /// — no `scheduleSave()` because `toolCallEvents` isn't persisted.
    /// Unknown sessionIds (race: tab closed mid-flight) drop silently;
    /// other UI keeps rendering.
    func applyToolCallEvent(
        agent: AgentTemplate,
        toolName: String,
        identifier: String,
        event: HookToolEvent,
        success: Bool?,
        toolUseId: String?,
        sessionId: UUID
    ) {
        guard let session = findSession(id: sessionId) else { return }

        switch event {
        case .pre:
            session.recordToolCallStart(
                toolName: toolName,
                identifier: identifier,
                toolUseId: toolUseId
            )
        case .post:
            // Missing success flag (parse miss / wire malformed) defaults
            // to true — better to show the call as succeeded than to
            // falsely flag failure on a Claude that ran fine.
            session.recordToolCallEnd(
                toolName: toolName,
                identifier: identifier,
                success: success ?? true,
                toolUseId: toolUseId
            )
            // Tool call completed — Claude resumes processing.
            // Restore .running so the dot reflects active work, and clear
            // the attention debounce timestamp so the subsequent Stop hook
            // (which also maps to .attention) won't be silently eaten.
            if session.activityState == .attention {
                session.activityState = .running
                lastAttentionTime[session.id] = nil
                if let (workspace, _) = location(ofSessionId: sessionId) {
                    workspace.invalidateReadout()
                }
            }
        }
    }

    /// Route an agent-to-agent message through the `MessageBus`.
    /// Only the store owning `fromSessionId` records the message.
    /// `toAgentTitle` is resolved from the hook payload's `agent` slug
    /// when the target session lives in a different store.
    func applyMessageEvent(from agent: AgentTemplate, content: String, toSessionId: UUID, fromSessionId: UUID) {
        guard let fromSession = findSession(id: fromSessionId) else { return }
        let toAgentTitle: String
        if let toSession = findSession(id: toSessionId) {
            toAgentTitle = toSession.displayAgent.title
        } else {
            toAgentTitle = agent.title
        }
        MessageBus.shared.send(
            from: fromSession,
            toSessionId: toSessionId,
            toAgentTitle: toAgentTitle,
            content: content
        )
    }

    /// The workspace + pane holding the session with `id`, or nil. One DFS
    /// per workspace, stopping at the first hit.
    private func location(ofSessionId id: UUID) -> (workspace: Workspace, pane: Pane)? {
        for workspace in workspaces {
            if let pane = workspace.root.pane(containingSessionId: id) {
                return (workspace, pane)
            }
        }
        return nil
    }

    private func findSession(id: UUID) -> Session? {
        location(ofSessionId: id)?.pane.tabs.first { $0.id == id }
    }

    func flushPersistence() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence.save(snapshot())
    }

    /// Tears the store down when its window closes — releases every
    /// session's libghostty surface + PTY (AppKit closing the `NSWindow`
    /// does not, and Swift 6's nonisolated `deinit` can't reach the
    /// `@MainActor` engine state) and stops background work. Does not
    /// mutate `workspaces` or persist — the caller decides slot retention.
    func terminate() {
        pendingSave?.cancel()
        pendingSave = nil
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for tab in pane.tabs {
                    tab.engine.terminate()
                }
            }
        }
        for watcher in gitWatchers.values { watcher.cancel() }
        gitWatchers.removeAll()
    }

    // MARK: - Internals

    private func pane(containing session: Session, in workspace: Workspace) -> Pane? {
        workspace.root.pane(containingSessionId: session.id)
    }

    private func restore(from state: PersistedState) {
        let fm = FileManager.default
        for ws in state.workspaces {
            guard let root = restorePane(ws.root, fm: fm) else { continue }
            let workspace = Workspace(
                id: ws.id,
                workingDirectory: URL(fileURLWithPath: ws.workingDirectoryPath),
                root: root
            )
            workspace.customTitle = ws.customTitle
            workspace.worktreeParentId = ws.worktreeParentId
            workspace.worktreeBranch = ws.worktreeBranch
            workspace.worktreePath = ws.worktreePath.map { URL(fileURLWithPath: $0) }
            // Wire engines now that workspace is constructed (engines need
            // the workspace ref for cwd-sync callbacks).
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
                }
            }
            if let id = ws.activePaneId, workspace.root.allPanes.contains(where: { $0.id == id }) {
                workspace.activePaneId = id
            } else {
                workspace.activePaneId = workspace.root.firstPane?.id
            }
            workspaces.append(workspace)
        }
        activeWorkspaceId = workspaces.contains(where: { $0.id == state.activeWorkspaceId })
            ? state.activeWorkspaceId
            : workspaces.first?.id
        sidebarMode = state.sidebarMode ?? .full
        rightSidebarMode = state.rightSidebarMode ?? .hidden
    }

    private func restorePane(_ persisted: PersistedPaneNode, fm: FileManager) -> PaneNode? {
        switch persisted.kind {
        case .pane(let p):
            let pane = Pane(id: p.id)
            for tab in p.tabs {
                let agent = AgentTemplate.all.first { $0.id == tab.agentId } ?? .terminal
                let session = spawnSession(
                    template: agent,
                    initialCwd: resolvedSpawnCwd(tab.currentDirectoryPath),
                    sessionId: tab.id,
                    conversationId: tab.conversationId
                )
                session.customTitle = tab.customTitle
                pane.tabs.append(session)
            }
            pane.activeTabId = pane.tabs.contains(where: { $0.id == p.activeTabId })
                ? p.activeTabId
                : pane.tabs.first?.id
            return PaneNode(pane: pane)
        case .split(let orientation, let first, let second, let fraction):
            guard let firstChild = restorePane(first, fm: fm),
                  let secondChild = restorePane(second, fm: fm) else { return nil }
            return PaneNode(
                id: persisted.id,
                content: .split(
                    orientation: orientation,
                    first: firstChild,
                    second: secondChild,
                    fraction: fraction
                )
            )
        }
    }

    /// Spawns the engine + Session. Caller wires `onPwdChange` / `onFocus`
    /// after a workspace ref is available — `restore` builds sessions before
    /// the workspace exists, so callbacks can't capture it here.
    private func spawnSession(template: AgentTemplate, initialCwd: URL, sessionId: UUID = UUID(), conversationId: String? = nil, initialPrompt: String? = nil) -> Session {
        let engine = engineFactory()
        // Resume gated by user setting — `resumeConversations` flips this off
        // when the user wants every Claude tab to start fresh without
        // losing the persisted conversation id (it stays on disk so the
        // setting can be flipped back on later). Non-resumable templates
        // ignore the value via `makeSessionConfig`'s own `supportsResume`
        // gate, so we don't have to re-check here.
        let resumeId = resumeProvider() ? conversationId : nil
        var config = template.makeSessionConfig(
            extraOptions: optionsProvider(template.id),
            resumeId: resumeId,
            initialPrompt: initialPrompt
        )
        config.workingDirectory = initialCwd.path
        // A Claude-Code-based custom agent with an env block hands `claude`
        // its endpoint / key via a per-agent Claude settings file (written by
        // `refreshClaudeCustomSettings`); `agentterminalEnvironment` routes this
        // session's AGENTTERMINAL_HOOKS_PATH there.
        let claudeCustomId = template.baseAgentId == AgentTemplate.claudeCodeID && !template.extraEnv.isEmpty
            ? template.id : nil
        config.environment.merge(
            AgentTerminalShellIntegration.agentterminalEnvironment(for: sessionId, claudeCustomSettingsAgentId: claudeCustomId)
        ) { _, new in new }
        engine.start(config: config)
        return Session(
            id: sessionId,
            engine: engine,
            currentDirectory: initialCwd,
            agent: template,
            conversationId: conversationId
        )
    }

    private func wireSessionCallbacks(engine: any TerminalEngine, session: Session, workspace: Workspace) {
        // Initial refresh — without these, the status bar stays empty until
        // the user `cd`s or runs a command. Both fetchers silently hide
        // results for non-applicable cwds, so the calls are harmless.
        refreshGitStatus(for: session)
        refreshEnvironment(for: session)
        installGitWatcher(for: session)
        engine.onPwdChange = { [weak self, weak session, weak workspace] pwd in
            guard let session else { return }
            let url = URL(fileURLWithPath: pwd)
            if session.currentDirectory.path != pwd {
                session.currentDirectory = url
            }
            if let workspace, workspace.activeSession?.id == session.id, workspace.workingDirectory.path != pwd {
                workspace.workingDirectory = url
            }
            self?.refreshGitStatus(for: session)
            self?.refreshEnvironment(for: session)
            self?.gitWatchers[session.id]?.watch(cwd: session.currentDirectory)
            self?.scheduleSave()
        }
        engine.onTitleChange = { [weak self, weak session] title in
            guard let session else { return }
            // A `agentterminal-remote-login:*` title is an ssh-destination marker, not
            // a visible title — record the host and stop before it reaches
            // `terminalTitle`. Cleared on command-finished (ssh exit).
            if let host = RemoteLoginMarker.parseTitle(title) {
                session.remoteHost = host
                return
            }
            // Any `agentterminal-agent:*` title is a status marker, never a visible
            // title — consume it (applying the agent state when it resolves to
            // a known agent) and stop before it reaches `terminalTitle`.
            if AgentStatusMarker.isMarkerTitle(title) {
                if let marker = AgentStatusMarker.parseTitle(title) {
                    self?.applyAgentStatusMarker(
                        agent: marker.agent,
                        event: marker.event,
                        session: session
                    )
                }
                return
            }
            // A path-shaped SET_TITLE is noise: libghostty synthesises one
            // from OSC 7, and the wrapper re-emits the cwd each prompt — both
            // are things `Session.title` already renders. Keep only what the
            // cwd can't say (`ssh`'s `user@host:dir`, a TUI's filename).
            let next = normalizedTitle(title).flatMap {
                ($0.hasPrefix("/") || $0.hasPrefix("~")) ? nil : $0
            }
            if session.terminalTitle != next { session.terminalTitle = next }
        }
        engine.onFocus = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.activateTab(session, in: workspace)
        }
        engine.onCommandFinished = { [weak self, weak session, weak workspace] exit, duration in
            guard let session else { return }
            if session.transientAgent != nil {
                session.transientAgent = nil
                session.activityState = .idle
            }
            session.remoteHost = nil
            session.lastCommandExit = exit
            session.lastCommandDuration = duration
            if let exit, exit != 0, session.agent == .terminal { self?.onSessionAlert(session.id, .failure) }
            workspace?.invalidateReadout()
            self?.refreshGitStatus(for: session)
            self?.refreshEnvironment(for: session)
        }
        engine.onUserInput = { [weak session, weak workspace] in
            guard let session, session.lastCommandExit != nil else { return }
            session.lastCommandExit = nil
            session.lastCommandDuration = nil
            workspace?.invalidateReadout()
        }
        engine.onProcessExitedCleanly = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.closeTab(session, in: workspace)
        }
        engine.onBell = { [weak self, weak session] in
            guard let self, let session else { return }
            let now = Date()
            if let last = self.lastBellTime[session.id],
               now.timeIntervalSince(last) < Self.bellDebounce { return }
            self.lastBellTime[session.id] = now
            self.onSessionAlert(session.id, .attention)
        }
        engine.onSearchStart = { [weak session] needle in
            guard let session else { return }
            session.searchActive = true
            session.searchNeedle = needle
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchEnd = { [weak session] in
            guard let session else { return }
            session.searchActive = false
            session.searchNeedle = ""
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchTotal = { [weak session] total in
            guard let session, session.searchTotal != total else { return }
            session.searchTotal = total
        }
        engine.onSearchSelected = { [weak session] selected in
            guard let session, session.searchSelected != selected else { return }
            session.searchSelected = selected
        }
    }

    private func applyAgentStatusMarker(agent: AgentTemplate, event: HookEvent, session: Session) {
        let agentBefore = session.agent.id
        if event == .ended {
            if session.transientAgent?.id == agent.id || session.transientAgent?.baseAgentId == agent.id {
                // Remote agent done — inbox completion before clearing, so
                // displayAgent still resolves to the remote agent.
                onSessionAlert(session.id, .completed)
                session.transientAgent = nil
            }
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                session.agent = .terminal
            }
        } else if session.agent.isShell {
            session.transientAgent = agent
        }

        if session.activityState != event.activityState {
            session.activityState = event.activityState
            if event.activityState == .attention { onSessionAlert(session.id, .attention) }
            if let (workspace, _) = location(ofSessionId: session.id) {
                workspace.invalidateReadout()
            }
        }
        if session.agent.id != agentBefore { scheduleSave() }
    }

    private func refreshGitStatus(for session: Session) {
        gitStatusFetcher.fetch(sessionId: session.id, cwd: session.currentDirectory) { [weak session] status in
            guard let session, session.gitStatus != status else { return }
            session.gitStatus = status
        }
    }

    private func installGitWatcher(for session: Session) {
        let watcher = GitWatcher { [weak self, weak session] in
            guard let self, let session else { return }
            self.refreshGitStatus(for: session)
        }
        watcher.watch(cwd: session.currentDirectory)
        gitWatchers[session.id] = watcher
    }

    private func refreshEnvironment(for session: Session) {
        let pid = session.engine.foregroundPid
        let env: ProjectEnvironment
        if session.shellEnvironment.isEmpty {
            env = EnvironmentDetector.detect(cwd: session.currentDirectory, pid: pid)
        } else {
            env = EnvironmentDetector.extract(
                shellEnv: session.shellEnvironment,
                cwd: session.currentDirectory,
                allowProjectFallback: false
            )
        }
        guard session.environment != env else { return }
        session.environment = env
    }

    // MARK: - Agent Status Broadcast

    /// Broadcasts a status update to all sessions in the workspace.
    /// Used when one agent's status changes and others should be notified.
    func broadcastStatusUpdate(from sourceSessionId: UUID, status: SessionActivityState) {
        for session in allSessions where session.id != sourceSessionId {
            // Notify other sessions about the status change
            // This could be used to update UI or trigger agent-specific behavior
        }
    }

    /// Sends data to a specific session within this workspace.
    func sendData(to sessionId: UUID, data: Data, type: String) async {
        guard let session = findSession(sessionId) else { return }
        if let text = String(data: data, encoding: .utf8) {
            session.engine.paste(text)
        }
    }

    /// Broadcasts data to all sessions in the workspace (except optionally one).
    func broadcastData(data: Data, type: String, exclude: UUID? = nil) async {
        for session in allSessions where session.id != exclude {
            if let text = String(data: data, encoding: .utf8) {
                session.engine.paste(text)
            }
        }
    }

    /// Finds a session by its ID across all workspaces.
    func findSession(_ sessionId: UUID) -> Session? {
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                if let session = pane.tabs.first(where: { $0.id == sessionId }) {
                    return session
                }
            }
        }
        return nil
    }

    /// Returns the workspace containing the given session, or nil.
    func workspaceContaining(sessionId: UUID) -> Workspace? {
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                if pane.tabs.contains(where: { $0.id == sessionId }) {
                    return workspace
                }
            }
        }
        return nil
    }

    /// Returns all sessions across all workspaces.
    var allSessions: [Session] {
        workspaces.flatMap { workspace in
            workspace.root.allPanes.flatMap { $0.tabs }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard let self, !Task.isCancelled else { return }
            self.persistence.save(self.snapshot())
        }
    }

    private func snapshot() -> PersistedState {
        PersistedState(
            workspaces: workspaces.map(PersistedWorkspace.init),
            activeWorkspaceId: activeWorkspaceId,
            sidebarMode: sidebarMode,
            rightSidebarMode: rightSidebarMode
        )
    }
}
