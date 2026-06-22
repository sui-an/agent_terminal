import AppKit
import SwiftUI

/// Bundles every modal sheet the sidebar can show so they share one
/// `.sheet(item:)` modifier. `.sheet(isPresented:)` per state would race
/// when switching directly between modes (create → confirm-remove).
private enum SidebarSheet: Identifiable {
    case createWorktree(Workspace)
    case confirmRemoveWorktree(Workspace)
    case confirmCloseOthers(WorkspaceStore.BulkRemovalRequest)
    case confirmCloseSource(WorkspaceStore.CloseSourceRequest)

    var id: String {
        switch self {
        case .createWorktree(let ws): return "create-\(ws.id.uuidString)"
        case .confirmRemoveWorktree(let ws): return "remove-\(ws.id.uuidString)"
        case .confirmCloseOthers(let req): return "close-others-\(req.keeping.id.uuidString)"
        case .confirmCloseSource(let req): return "close-source-\(req.source.id.uuidString)"
        }
    }
}

struct SidebarView: View {
    static let fullWidth: CGFloat = 220
    static let compactWidth: CGFloat = 52
    @Bindable var store: WorkspaceStore
    /// Observed so chrome re-renders when the user switches themes.
    @State private var settings = AgentTerminalSettingsModel.shared
    /// Id of the workspace currently being dragged. Set by `.onDrag`, cleared
    /// on drop. Lets each row compute whether the drag origin is above or
    /// below it so the drop indicator can flip edges.
    @State private var draggingWorkspaceId: UUID?
    /// True while a Finder folder drag is hovering the sidebar — gates the
    /// drop-zone outline so the user sees that releasing here opens a new
    /// workspace.
    @State private var isFolderDropTargeted = false
    /// Source workspace ids whose worktree subtree the user collapsed.
    /// Default behaviour is expanded — only ids the user explicitly closed
    /// land here. Ephemeral by design: a agentterminal relaunch always shows every
    /// worktree on first paint so nothing is hidden by stale state.
    @State private var collapsedParents: Set<UUID> = []
    /// Active modal sheet (create worktree / confirm-delete worktree).
    /// Nil = no sheet. Set by row callbacks and an onChange observer that
    /// watches `store.pendingRemovalRequest` for ⌘⇧W routed via AppDelegate.
    @State private var sheet: SidebarSheet?

    var body: some View {
        let _ = settings.terminalThemeSelection
        let isCompact = store.sidebarMode == .compact
        VStack(spacing: 0) {
            // Header
            if !isCompact {
                HStack {
                    Text("Workspaces")
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.chromeForeground)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            }
            // Workspace list
            ScrollViewReader { proxy in
                list(isCompact: isCompact, proxy: proxy)
            }

            // Bottom section: + button and settings
            Divider()
            HStack {
                if isCompact {
                    Spacer()
                    HoverableIconButton(
                        systemName: "plus",
                        fontSize: 13,
                        size: 28,
                        help: "New Workspace",
                        action: { store.addWorkspace() },
                        immediateTooltip: true,
                        immediateTooltipPlacement: .above
                    )
                    Spacer()
                } else {
                    HoverableIconButton(
                        systemName: "plus",
                        fontSize: 13,
                        size: 28,
                        help: "New Workspace",
                        action: { store.addWorkspace() },
                        immediateTooltip: true,
                        immediateTooltipPlacement: .above,
                        immediateTooltipAlignment: .leading
                    )
                    Spacer()
                    HoverableIconButton(
                        systemName: "gearshape",
                        fontSize: 13,
                        size: 28,
                        help: "Settings",
                        action: { AgentTerminalSettingsWindowController.show(storeProvider: { store }) },
                        immediateTooltip: true,
                        immediateTooltipPlacement: .above,
                        immediateTooltipAlignment: .trailing
                    )
                }
            }
            .padding(.horizontal, isCompact ? Theme.space2 : Theme.space4)
            .padding(.vertical, Theme.space2)
        }
        .frame(width: isCompact ? Self.compactWidth : (store.sidebarWidth ?? Self.fullWidth))
        .background(Theme.chromeBackground)
        .overlay {
            // Drop affordance: tinted fill + hairline stroke, inset from the
            // sidebar edges so the splitter / titlebar don't clip it. Always
            // in the view tree (alpha-driven) so `easeOut(0.12)` can animate.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.chromeActive)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.chromeForeground.opacity(0.55), lineWidth: 1)
            }
            .padding(Theme.space2)
            .opacity(isFolderDropTargeted ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isFolderDropTargeted)
            .allowsHitTesting(false)
        }
        // Files are silently ignored — `GhosttySurfaceView` already handles
        // "drop a file path at the cursor" inside a pane (M5.kk). The outline
        // lights up for any URL drag (SwiftUI's `.dropDestination` can't
        // pre-filter file-vs-folder); file drags release as no-ops.
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(isDirectory)
            guard !folders.isEmpty else { return false }
            for folder in folders {
                store.addWorkspace(workingDirectory: folder)
            }
            return true
        } isTargeted: { isFolderDropTargeted = $0 }
        .sheet(item: $sheet) { current in
            switch current {
            case .createWorktree(let source):
                CreateWorktreeSheet(
                    source: source,
                    launchTemplates: AgentTemplate.visibleOrdered(model: AgentTerminalSettingsModel.shared),
                    defaultLaunchTemplate: AgentTemplate.defaultLaunchTemplate(model: AgentTerminalSettingsModel.shared)
                        ?? .terminal,
                    // Include every workspace's diskPath, not just worktree
                    // children — if the user opened a worktree directory as
                    // a top-level workspace (Finder drop / ⌘O), adopting it
                    // again would spawn a duplicate row pointing at the same
                    // dir. Source workspaces (the repo root) also belong in
                    // the exclusion set because the adopt picker already
                    // drops them via `sourceRootKey`; including them here is
                    // belt-and-suspenders against multi-source ⌘O scenarios.
                    alreadyAdoptedPaths: Set(
                        store.workspaces.map { $0.diskPath.standardizedFileURL.path }
                    ),
                    create: { request in
                        await store.createWorktree(source: source, request: request)
                    },
                    dismiss: {
                        store.pendingCreateWorktreeRequest = nil
                        sheet = nil
                    }
                )
            case .confirmRemoveWorktree(let workspace):
                ConfirmRemoveWorktreeSheet(
                    workspace: workspace,
                    confirm: { alsoDelete in
                        if alsoDelete {
                            if let message = await store.removeWorktreeDirectory(workspace) {
                                return .failure(message)
                            }
                        }
                        store.closeWorkspace(workspace)
                        store.pendingRemovalRequest = nil
                        return .success
                    },
                    dismiss: {
                        store.pendingRemovalRequest = nil
                        sheet = nil
                    }
                )
            case .confirmCloseOthers(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: "CLOSE-OTHERS",
                    headlineText: "keeping \(request.keeping.title)",
                    subtitleText: bulkSubtitle(
                        closingCount: request.others.count,
                        worktreeCount: request.worktreeOthers.count
                    ),
                    worktreesAmong: request.worktreeOthers,
                    confirm: { alsoDelete in
                        if let message = await store.performCloseOthers(request, alsoDelete: alsoDelete) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: {
                        store.pendingCloseOthersRequest = nil
                        sheet = nil
                    }
                )
            case .confirmCloseSource(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: "CLOSE-WORKSPACE",
                    headlineText: "closing \(request.source.title)",
                    subtitleText: bulkSubtitle(
                        closingCount: request.worktrees.count + 1,
                        worktreeCount: request.worktrees.count
                    ),
                    worktreesAmong: request.worktrees,
                    confirm: { alsoDelete in
                        if let message = await store.performCloseSource(request, alsoDelete: alsoDelete) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: {
                        store.pendingCloseSourceRequest = nil
                        sheet = nil
                    }
                )
            }
        }
        // ⌘⇧W routes through AppDelegate → store.requestCloseWorkspace,
        // which parks worktree workspaces in `pendingRemovalRequest` for
        // the sidebar to pop the confirm sheet on. Identity-keyed so the
        // observer only fires on a fresh request, not internal renames.
        .onChange(of: store.pendingRemovalRequest?.id) { _, _ in
            if let workspace = store.pendingRemovalRequest {
                sheet = .confirmRemoveWorktree(workspace)
            }
        }
        // Global create requests (currently the command palette). When the
        // sidebar was hidden, `onAppear` below catches the already-parked
        // request after AppDelegate makes the sidebar visible.
        .onChange(of: store.pendingCreateWorktreeRequest?.id) { _, _ in
            if let workspace = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(workspace)
            }
        }
        .onAppear {
            if let workspace = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(workspace)
            }
        }
        // Bulk close-others request — keyed off keeping.id since the
        // others list can vary in length but each request is anchored
        // on its keeping workspace.
        .onChange(of: store.pendingCloseOthersRequest?.keeping.id) { _, _ in
            if let request = store.pendingCloseOthersRequest {
                sheet = .confirmCloseOthers(request)
            }
        }
        // Close-source-with-worktrees request — keyed off source.id; the
        // store parks it when ⌘⇧W / × on a top-level workspace would
        // strand its worktrees.
        .onChange(of: store.pendingCloseSourceRequest?.source.id) { _, _ in
            if let request = store.pendingCloseSourceRequest {
                sheet = .confirmCloseSource(request)
            }
        }
    }

    /// Shared subtitle string between the two bulk-close flows — folds
    /// pluralisation into one place so the count never reads as
    /// "1 workspaces" or "1 worktrees".
    private func bulkSubtitle(closingCount: Int, worktreeCount: Int) -> String {
        let workspaceWord = closingCount == 1 ? "workspace" : "workspaces"
        let worktreeWord = worktreeCount == 1 ? "worktree" : "worktrees"
        return "\(closingCount) \(workspaceWord) will close · \(worktreeCount) \(worktreeWord)"
    }

    /// True when `workspace` is a top-level source workspace *and* its
    /// cwd is inside a git repo. Worktree rows are excluded (worktree
    /// nesting isn't supported); non-git workspaces (e.g. `~/Downloads`
    /// opened as a workspace) hide the menu item so users never see an
    /// option that can only error.
    private func canCreateWorktree(from workspace: Workspace) -> Bool {
        guard workspace.worktreeParentId == nil else { return false }
        return GitWatcher.findGitDir(near: workspace.workingDirectory) != nil
    }

    private func list(isCompact: Bool, proxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                if isCompact {
                    // 52pt-wide sidebar can't fit a disclosure triangle next
                    // to a 28pt icon — fall back to a flat list. The order
                    // is stable: store.workspaces already places worktrees
                    // after their source by virtue of being appended at
                    // creation time.
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        // canCreateWorktree walks the fs (`findGitDir`) —
                        // hoist once per workspace so the two row callbacks
                        // don't each stat the same ancestor chain.
                        let canCreate = canCreateWorktree(from: workspace)
                        let goToSource: (() -> Void)? = workspace.worktreeParentId
                            .flatMap { id in store.workspaces.first { $0.id == id } }
                            .map { parent in { store.activateWorkspace(parent) } }
                        DraggableWorkspaceRow(
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            isCompact: isCompact,
                            draggingId: $draggingWorkspaceId,
                            onCreateWorktree: canCreate ? { presentCreateWorktree(workspace) } : nil,
                            onGoToSource: goToSource
                        )
                    }
                } else {
                    // A workspace is "top-level" either because it has no
                    // parent, or because its parent is gone — defensive
                    // fallback so a bug that strands a worktree (parent
                    // closed while child kept) still surfaces the row in
                    // the sidebar instead of vanishing it entirely.
                    let parentIds = Set(store.workspaces.map(\.id))
                    let topLevel = store.workspaces.enumerated().filter { _, ws in
                        guard let parentId = ws.worktreeParentId else { return true }
                        return !parentIds.contains(parentId)
                    }
                    ForEach(Array(topLevel), id: \.element.id) { index, workspace in
                        workspaceTree(parent: workspace, parentIndex: index)
                    }
                }
            }
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, Theme.space2)
        }
        // ⌘⇧R parks the active workspace on the store; reveal its row so the
        // row's own rename popover can open. onChange catches a request made
        // while the sidebar is up; onAppear catches one parked while the
        // sidebar was hidden (SidebarView mounts only after the reveal).
        .onChange(of: store.pendingRenameWorkspace?.id) { _, _ in
            revealWorkspaceForRename(using: proxy)
        }
        .onAppear { revealWorkspaceForRename(using: proxy) }
    }

    @ViewBuilder
    private func workspaceTree(parent: Workspace, parentIndex: Int) -> some View {
        let worktrees = store.workspaces.filter { $0.worktreeParentId == parent.id }
        let hasWorktrees = !worktrees.isEmpty
        let isCollapsed = collapsedParents.contains(parent.id)

        // canCreateWorktree walks the fs (`findGitDir`) — hoist once so
        // the two callbacks don't each stat the same ancestor chain.
        let canCreate = canCreateWorktree(from: parent)
        DraggableWorkspaceRow(
            workspace: parent,
            store: store,
            myIndex: parentIndex,
            isCompact: false,
            draggingId: $draggingWorkspaceId,
            disclosure: hasWorktrees
                ? SidebarWorkspaceRow.WorktreeDisclosure(
                    isCollapsed: isCollapsed,
                    toggle: { toggleCollapsed(parent.id) }
                )
                : nil,
            onCreateWorktree: canCreate ? { presentCreateWorktree(parent) } : nil
        )

        if hasWorktrees && !isCollapsed {
            ForEach(worktrees) { worktree in
                SidebarWorkspaceRow(
                    workspace: worktree,
                    isActive: worktree.id == store.activeWorkspaceId,
                    isCompact: false,
                    canCloseOthers: store.workspaces.count > 1,
                    onActivate: { store.activateWorkspace(worktree) },
                    onClose: { store.requestCloseWorkspace(worktree) },
                    onCloseOthers: { store.closeOtherWorkspaces(keeping: worktree) },
                    onDuplicate: { store.duplicateWorkspace(worktree) },
                    onRename: { store.renameWorkspace(worktree, to: $0) },
                    onGoToSource: { store.activateWorkspace(parent) }
                )
            }
        }
    }

    private func toggleCollapsed(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.12)) {
            if collapsedParents.contains(id) {
                collapsedParents.remove(id)
            } else {
                collapsedParents.insert(id)
            }
        }
    }

    /// Bring the active workspace's row into the view hierarchy so its rename
    /// popover can anchor, then hand off to the row via `renameRequested`. The
    /// row may be unmounted — nested under a collapsed worktree parent, or
    /// scrolled out of the LazyVStack's realized window. Without this the ⌘⇧R
    /// flag would sit unconsumed and then fire stale when the user later
    /// scrolled to / expanded that row.
    private func revealWorkspaceForRename(using proxy: ScrollViewProxy) {
        guard let workspace = store.pendingRenameWorkspace else { return }
        store.pendingRenameWorkspace = nil
        if let parentId = workspace.worktreeParentId, collapsedParents.contains(parentId) {
            collapsedParents.remove(parentId)
        }
        workspace.renameRequested = true
        // Defer so a just-expanded subtree is laid out before scrolling to a
        // row that may have only now been inserted.
        DispatchQueue.main.async {
            proxy.scrollTo(workspace.id, anchor: .center)
        }
    }

    private func presentCreateWorktree(_ workspace: Workspace) {
        // Single channel: parking on the store triggers the `.onChange`
        // observer that sets `sheet`. Direct row clicks and command-palette
        // / AppDelegate routes all go through here, so this stays the one
        // mechanism that opens the create sheet.
        store.pendingCreateWorktreeRequest = workspace
    }
}

/// Drag source + drop target with a direction-aware edge indicator —
/// `top` when origin is below (dragging up), `bottom` when origin is above
/// (dragging down), so the line always shows where the dropped row will land.
private struct DraggableWorkspaceRow: View {
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let isCompact: Bool
    @Binding var draggingId: UUID?
    /// Non-nil only for source workspaces that own at least one worktree.
    /// Worktree rows themselves render via `SidebarWorkspaceRow` directly,
    /// without this wrapper, so they don't pick up drag/drop handlers.
    var disclosure: SidebarWorkspaceRow.WorktreeDisclosure? = nil
    var onCreateWorktree: (() -> Void)? = nil
    var onGoToSource: (() -> Void)? = nil

    @State private var isTargeted = false

    var body: some View {
        let originIndex: Int? = {
            guard let id = draggingId, id != workspace.id else { return nil }
            return store.workspaces.firstIndex(where: { $0.id == id })
        }()
        let dragsDownward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsDownward ? .bottom : .top
        let isSelfDrag = draggingId == workspace.id

        SidebarWorkspaceRow(
            workspace: workspace,
            isActive: workspace.id == store.activeWorkspaceId,
            isCompact: isCompact,
            canCloseOthers: store.workspaces.count > 1,
            onActivate: { store.activateWorkspace(workspace) },
            onClose: { store.requestCloseWorkspace(workspace) },
            onCloseOthers: { store.closeOtherWorkspaces(keeping: workspace) },
            onDuplicate: { store.duplicateWorkspace(workspace) },
            onRename: { store.renameWorkspace(workspace, to: $0) },
            disclosure: disclosure,
            onCreateWorktree: onCreateWorktree,
            onGoToSource: onGoToSource
        )
        .dropIndicator(active: isTargeted && !isSelfDrag, on: edge)
        .onDrag {
            draggingId = workspace.id
            return NSItemProvider(object: workspace.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { draggingId = nil }
            guard let id = dropped.first.flatMap(UUID.init),
                  let from = store.workspaces.firstIndex(where: { $0.id == id })
            else { return false }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.moveWorkspace(from: from, to: myIndex)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Draggable handle on the right edge of the sidebar for resizing.
struct SidebarResizeHandle: View {
    @Bindable var store: WorkspaceStore
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0
    /// Horizontal displacement of the drag guide line from the handle's
    /// resting position. Only this line moves during the drag; the sidebar
    /// width is committed once on release to avoid live re-layout jitter.
    @State private var guideOffset: CGFloat = 0

    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 400

    var body: some View {
        Rectangle()
            .fill(isHovering || isDragging ? Theme.chromeMuted.opacity(0.3) : Color.clear)
            .frame(width: 6)
            .overlay {
                if isDragging {
                    Rectangle()
                        .fill(Theme.chromeActive)
                        .frame(width: 2)
                        .offset(x: guideOffset)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered in
                isHovering = hovered
                if hovered {
                    AgentTerminalResizeCursor.horizontal.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                // Balance a pushed cursor if the handle vanishes mid-hover
                // (e.g. sidebar collapses) so the resize cursor doesn't leak.
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = (store.sidebarWidth ?? SidebarView.fullWidth).rounded()
                        }
                        // Move only the guide line; clamp so it stops at the
                        // width bounds even as the cursor keeps moving.
                        let target = clampedWidth(dragStartWidth + value.translation.width)
                        guideOffset = target - dragStartWidth
                    }
                    .onEnded { value in
                        let target = clampedWidth(dragStartWidth + value.translation.width)
                        isDragging = false
                        guideOffset = 0
                        commitSidebarWidth(target)
                    }
            )
    }

    private func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth).rounded()
    }

    private func commitSidebarWidth(_ width: CGFloat) {
        let current = (store.sidebarWidth ?? SidebarView.fullWidth).rounded()
        guard current != width else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            store.sidebarWidth = width
        }
    }
}
