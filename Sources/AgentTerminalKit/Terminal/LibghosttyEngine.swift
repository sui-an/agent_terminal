import AppKit
import GhosttyKit


// MARK: - LibghosttyApp

/// Process-wide libghostty runtime. ghostty_init runs once; every Surface is
/// created against this single app handle. Ticks are event-driven via
/// `wakeup_cb`; libghostty signals when it has work, we hop to main and drain.
@MainActor
final class LibghosttyApp {
    static let shared = LibghosttyApp()

    private(set) var app: ghostty_app_t?

    private init() {
        var argv: [UnsafeMutablePointer<CChar>?] = [nil]
        let initResult = argv.withUnsafeMutableBufferPointer {
            ghostty_init(0, $0.baseAddress)
        }
        guard initResult == 0 else {
            NSLog("agentterminal: ghostty_init failed (\(initResult))")
            return
        }

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: agentterminalWakeupCb,
            action_cb: agentterminalActionCb,
            read_clipboard_cb: agentterminalReadClipboardCb,
            confirm_read_clipboard_cb: agentterminalConfirmReadClipboardCb,
            write_clipboard_cb: agentterminalWriteClipboardCb,
            close_surface_cb: agentterminalCloseSurfaceCb
        )

        guard let config = AgentTerminalSettings.makeGhosttyConfig() else {
            NSLog("agentterminal: ghostty_config_new failed")
            return
        }
        self.app = ghostty_app_new(&runtime, config)
        if self.app == nil {
            NSLog("agentterminal: ghostty_app_new failed")
        }
    }

    func reloadConfig() {
        guard let app else { return }
        // Parse settings.json + load ghostty defaults once for the entire
        // reload — `makeGhosttyConfig` is called once per ghostty receiver
        // (app + each surface) but they all need an identical config, so
        // share the parsed agentterminal-side dict to avoid N+1 disk reads + JSON
        // parses for a window with many panes.
        let parsed = AgentTerminalSettings.loadParsed()
        guard let config = AgentTerminalSettings.makeGhosttyConfig(parsed: parsed) else {
            NSLog("agentterminal: ghostty_config_new failed during reload")
            return
        }
        ghostty_app_update_config(app, config)
        GhosttySurfaceRegistry.updateAll(parsed: parsed)
    }

    /// Reloads ghostty config with the given terminal theme injected into the
    /// parsed settings, without persisting it to `settings.json`.
    /// Used when "Follow System" resolves a different theme on system appearance
    /// change — the theme needs to reach ghostty surfaces, but the FollowSystem
    /// selection must remain as the stored preference.
    func reloadConfig(withTerminalTheme theme: AgentTerminalTheme) {
        guard let app else { return }
        var parsed = AgentTerminalSettings.loadParsed() ?? [:]
        var terminal = parsed["terminal"] as? [String: Any] ?? [:]
        terminal["theme"] = theme.storedValue
        parsed["terminal"] = terminal

        guard let config = AgentTerminalSettings.makeGhosttyConfig(parsed: parsed) else {
            NSLog("agentterminal: ghostty_config_new failed for theme reload")
            return
        }
        ghostty_app_update_config(app, config)
        GhosttySurfaceRegistry.updateAll(parsed: parsed)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}

// MARK: - C callbacks

private let agentterminalWakeupCb: ghostty_runtime_wakeup_cb = { _ in
    DispatchQueue.main.async {
        MainActor.assumeIsolated { LibghosttyApp.shared.tick() }
    }
}

/// Hops to main + recovers the originating `GhosttySurfaceView` from libghostty's
/// userdata pointer. Action_cb runs on whichever thread libghostty signals
/// from; SwiftUI / our @MainActor state requires main, hence the bounce.
/// The pointer transits as an `Int` bit pattern because Swift 6 concurrency
/// flags `UnsafeMutableRawPointer` capture across the dispatch boundary.
private func dispatchToView(_ userdata: UnsafeMutableRawPointer, _ work: @MainActor @escaping (GhosttySurfaceView) -> Void) {
    let bits = Int(bitPattern: userdata)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(pointer).takeUnretainedValue()
            work(view)
        }
    }
}

private let agentterminalActionCb: ghostty_runtime_action_cb = { _, target, action in
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let userdata = ghostty_surface_userdata(surface)
    else { return false }

    switch action.tag {
    case GHOSTTY_ACTION_SCROLLBAR:
        let bar = action.action.scrollbar
        dispatchToView(userdata) { $0.applyScrollbar(total: bar.total, offset: bar.offset, len: bar.len) }
        return true
    case GHOSTTY_ACTION_PWD:
        guard let cstr = action.action.pwd.pwd else { return true }
        let pwd = String(cString: cstr)
        dispatchToView(userdata) { $0.onPwdChange?(pwd) }
        return true
    case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
        // OSC 0 / OSC 2 (and ghostty's tab-title variant). An `ssh` session's
        // remote shell emits its own `user@host:dir` title — surfacing it
        // keeps the tab + workspace name honest about where the shell is.
        let titleAction = action.tag == GHOSTTY_ACTION_SET_TITLE
            ? action.action.set_title
            : action.action.set_tab_title
        guard let cstr = titleAction.title else { return true }
        let title = String(cString: cstr)
        dispatchToView(userdata) { $0.onTitleChange?(title) }
        return true
    case GHOSTTY_ACTION_OPEN_URL:
        // libghostty resolves ⌘+click hits and hands us the URL string. We
        // route it to the default browser, but return `false` when we can't
        // parse the string so libghostty falls back to its own opener — some
        // OSC 8 / unescaped `file://` shapes that `URL(string:)` rejects can
        // still be opened by ghostty's built-in path.
        let urlAction = action.action.open_url
        guard let cstr = urlAction.url, urlAction.len > 0 else { return false }
        let buffer = UnsafeRawBufferPointer(start: cstr, count: Int(urlAction.len))
        let urlString = String(decoding: buffer, as: UTF8.self)
        guard let url = URL(string: urlString) else { return false }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        return true
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        let shape = action.action.mouse_shape
        dispatchToView(userdata) { $0.applyMouseShape(shape) }
        return true
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        // exit 0 → user typed `exit` / `logout`; auto-close the agentterminal tab
        // by returning `true` (suppresses libghostty's "press any key to
        // close" message) AND dispatching the callback that fires `closeTab`.
        // Non-zero exit (crash, segfault, bad command) returns `false` so
        // libghostty's default UI stays — user can read the error before
        // dismissing with a keypress.
        let exit = action.action.child_exited.exit_code
        guard exit == 0 else { return false }
        dispatchToView(userdata) { $0.onProcessExitedCleanly?() }
        return true
    case GHOSTTY_ACTION_RING_BELL:
        dispatchToView(userdata) { $0.onBell?() }
        return true
    case GHOSTTY_ACTION_COMMAND_FINISHED:
        // Shell emitted `OSC 133;D[;exit]` — last command done. exit=-1 means
        // the shell omitted the field; pass `nil` upward so the UI can pick a
        // neutral treatment instead of pretending we know it succeeded.
        let finished = action.action.command_finished
        let exit: Int? = finished.exit_code < 0 ? nil : Int(finished.exit_code)
        let duration = TimeInterval(finished.duration) / 1_000_000_000
        dispatchToView(userdata) { $0.onCommandFinished?(exit, duration) }
        return true
    case GHOSTTY_ACTION_START_SEARCH:
        // libghostty entered search mode (or updated the needle). The needle
        // pointer is a libghostty-owned C string — copy into Swift before
        // hopping main, so we don't read freed memory after dispatch.
        let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
        dispatchToView(userdata) { $0.onSearchStart?(needle) }
        return true
    case GHOSTTY_ACTION_END_SEARCH:
        dispatchToView(userdata) { $0.onSearchEnd?() }
        return true
    case GHOSTTY_ACTION_SEARCH_TOTAL:
        let total = Int(action.action.search_total.total)
        dispatchToView(userdata) { $0.onSearchTotal?(total) }
        return true
    case GHOSTTY_ACTION_SEARCH_SELECTED:
        let selected = Int(action.action.search_selected.selected)
        dispatchToView(userdata) { $0.onSearchSelected?(selected) }
        return true
    default:
        return false
    }
}

private let agentterminalReadClipboardCb: ghostty_runtime_read_clipboard_cb = { _, _, _ in false }
private let agentterminalConfirmReadClipboardCb: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in }
private let agentterminalWriteClipboardCb: ghostty_runtime_write_clipboard_cb = { _, kind, contents, count, _ in
    guard kind == GHOSTTY_CLIPBOARD_STANDARD,
          let contents,
          count > 0
    else { return }
    // libghostty hands us multiple MIME variants of the same selection (e.g.
    // text/plain + text/html). Pick the plain-text variant; fall back to the
    // first entry. NEVER concatenate — they're alternative representations,
    // not separate lines.
    let buffer = UnsafeBufferPointer(start: contents, count: count)
    let preferred = buffer.first { entry in
        guard let mime = entry.mime else { return false }
        return String(cString: mime) == "text/plain"
    } ?? buffer.first
    guard let chosen = preferred, let dataPtr = chosen.data else { return }
    let text = String(cString: dataPtr)
    guard !text.isEmpty else { return }
    // libghostty fires this on its own thread; NSPasteboard writes must be on
    // main for change-notification propagation to clipboard managers
    // (Paste, Maccy, etc.) — otherwise the value lands but listeners miss it.
    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NotificationCenter.default.post(name: NSNotification.Name("copyDidComplete"), object: nil)
    }
}
private let agentterminalCloseSurfaceCb: ghostty_runtime_close_surface_cb = { _, _ in }

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

// MARK: - LibghosttyEngine

@MainActor
final class LibghosttyEngine: TerminalEngine {
    private let surfaceView: GhosttySurfaceView

    var view: NSView { surfaceView }
    var backgroundColor: NSColor { Theme.terminalSurface }
    var onPwdChange: ((String) -> Void)? {
        get { surfaceView.onPwdChange }
        set { surfaceView.onPwdChange = newValue }
    }
    var onTitleChange: ((String) -> Void)? {
        get { surfaceView.onTitleChange }
        set { surfaceView.onTitleChange = newValue }
    }
    var onFocus: (() -> Void)? {
        get { surfaceView.onFocus }
        set { surfaceView.onFocus = newValue }
    }
    var onCommandFinished: ((Int?, TimeInterval) -> Void)? {
        get { surfaceView.onCommandFinished }
        set { surfaceView.onCommandFinished = newValue }
    }
    var onUserInput: (() -> Void)? {
        get { surfaceView.onUserInput }
        set { surfaceView.onUserInput = newValue }
    }
    var onProcessExitedCleanly: (() -> Void)? {
        get { surfaceView.onProcessExitedCleanly }
        set { surfaceView.onProcessExitedCleanly = newValue }
    }
    var onBell: (() -> Void)? {
        get { surfaceView.onBell }
        set { surfaceView.onBell = newValue }
    }
    var onSearchStart: ((String) -> Void)? {
        get { surfaceView.onSearchStart }
        set { surfaceView.onSearchStart = newValue }
    }
    var onSearchEnd: (() -> Void)? {
        get { surfaceView.onSearchEnd }
        set { surfaceView.onSearchEnd = newValue }
    }
    var onSearchTotal: ((Int) -> Void)? {
        get { surfaceView.onSearchTotal }
        set { surfaceView.onSearchTotal = newValue }
    }
    var onSearchSelected: ((Int) -> Void)? {
        get { surfaceView.onSearchSelected }
        set { surfaceView.onSearchSelected = newValue }
    }
    var foregroundPid: pid_t? {
        guard let surface = surfaceView.surface else { return nil }
        let pid = pid_t(ghostty_surface_foreground_pid(surface))
        return pid > 0 ? pid : nil
    }

    init() {
        surfaceView = GhosttySurfaceView()
    }

    func start(config: TerminalSessionConfig) {
        // Surface creation is deferred to viewDidMoveToWindow: SwiftUI's
        // onAppear fires before the NSView has a window, and libghostty needs
        // both a window and real bounds to attach its Metal layer.
        surfaceView.pendingConfig = config
        surfaceView.createSurfaceIfReady()
    }

    func terminate() {
        surfaceView.releaseSurface()
    }

    var suspendsSizePropagation: Bool {
        get { surfaceView.suspendsSizePropagation }
        set { surfaceView.suspendsSizePropagation = newValue }
    }

    var grabsFocusOnMount: Bool {
        get { surfaceView.grabsFocusOnMount }
        set { surfaceView.grabsFocusOnMount = newValue }
    }

    func flushSize() {
        surfaceView.flushPropagateSize()
    }

    func focusSurface() {
        guard let window = surfaceView.window else { return }
        window.makeFirstResponder(surfaceView)
    }

    @discardableResult
    func performAction(_ name: String) -> Bool {
        guard let surface = surfaceView.surface else { return false }
        return name.withCString { cstr in
            ghostty_surface_binding_action(surface, cstr, UInt(name.utf8.count))
        }
    }

    func sendInput(_ text: String) {
        surfaceView.sendInput(text)
    }

    func readSelection() -> String? {
        surfaceView.readSelection()
    }

    func paste(_ text: String) {
        surfaceView.paste(text)
    }
}

@MainActor
private enum GhosttySurfaceRegistry {
    // `NSHashTable.weakObjects()` handles weak storage + compaction
    // internally — every `register` is O(1), and dead refs disappear on
    // their own (no manual `filter`).
    private static let views: NSHashTable<GhosttySurfaceView> = .weakObjects()

    static func register(_ view: GhosttySurfaceView) {
        views.add(view)
    }

    static func updateAll(parsed: [String: Any]?) {
        for view in views.allObjects {
            view.updateConfigFromSettings(parsed: parsed)
        }
    }
}

// MARK: - GhosttySurfaceView

/// AppKit host view that libghostty renders into directly. The view's pointer
/// lives in `ghostty_surface_config_s.platform.macos.nsview`; libghostty owns
/// the Metal layer and draws into it.
@MainActor
final class GhosttySurfaceView: NSView {
    private let scrollIndicator = ScrollIndicator()
    private var lastScrollbar: (total: UInt64, offset: UInt64, len: UInt64)?
    /// Whether the viewport is currently pinned to the bottom (latest output).
    /// Tracked from every SCROLLBAR action so `propagateSizeToSurface` can
    /// re-pin to the bottom after a resize without yanking a user who has
    /// scrolled up into scrollback. Starts true: a fresh surface whose content
    /// fits on screen is trivially at the bottom.
    private var viewportAtBottom = true

    /// ghostty's scrollbar `offset` is measured from the TOP (0 = top of
    /// scrollback); the viewport sits at the bottom (active area) when it spans
    /// down to the last row, i.e. `offset + len == total`. Content that fits on
    /// screen (`total <= len`) is trivially at the bottom.
    static func isViewportAtBottom(total: UInt64, offset: UInt64, len: UInt64) -> Bool {
        total <= len || offset + len >= total
    }

    /// Last backing scale we propagated to libghostty. libghostty captures the
    /// scale once at surface creation and never hears about display moves on
    /// its own, so we re-push it from `viewDidChangeBackingProperties`. Tracked
    /// so a colorspace-only backing change (same scale) doesn't fire a
    /// gratuitous resize. Seeded at surface creation.
    private var lastBackingScale: CGFloat?

    var pendingConfig: TerminalSessionConfig?
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onProcessExitedCleanly: (() -> Void)?
    var onBell: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    /// Read in `viewDidMoveToWindow` to gate the mount-time first-responder
    /// grab; set by `TerminalView` from the pane's active state. See
    /// `TerminalEngine.grabsFocusOnMount` for the why (issue #24).
    var grabsFocusOnMount = true

    private(set) var surface: ghostty_surface_t? {
        didSet {
            if surface != nil {
                propagateSizeToSurface()
                GhosttyDrawCoordinator.shared.register(self, priority: grabsFocusOnMount ? .active : .visible)
            } else {
                GhosttyDrawCoordinator.shared.unregister(self)
            }
        }
    }
    /// In-progress IME preedit string. `setMarkedText` writes it,
    /// `unmarkText` / `insertText` clear it. Mirrors ghostty.app's
    /// `markedText` field — `hasMarkedText() = !markedText.isEmpty`,
    /// load-bearing for keyDown's Enter / arrow / Esc gating while a
    /// candidate window is open.
    private var markedText: String = ""
    /// Non-nil signals "we're inside `keyDown`'s `handleEvent` call".
    /// IME callbacks during that window batch into here instead of
    /// pushing each transient state straight to libghostty — without
    /// batching, libghostty receives a noisy sequence of preedit /
    /// clear / commit for every keystroke and leaves stray cells on
    /// long sequences (the v0.11.4 `\u{3000}`-looking phantom space
    /// between 发's). Cleared by keyDown's `defer`. Mirrors ghostty's
    /// `keyTextAccumulator` pattern verbatim.
    private var keyTextAccumulator: [String]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ScrollIndicator.install(scrollIndicator, in: self)
        updateTrackingAreas()
        wireScrollDrag()
        GhosttySurfaceRegistry.register(self)
        // Accept Finder-style file drops — the user drags a file or folder
        // onto the terminal pane and we inject its backslash-escaped
        // absolute path (or paths, space-separated) as if it were pasted.
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL]) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let escaped = AgentTerminalShellIntegration.backslashEscapedFileURLs(urls)
        else { return false }
        paste(escaped)
        return true
    }

    private func wireScrollDrag() {
        scrollIndicator.onDragKnobTo = { [weak self] desiredPosition in
            guard let self, let surface = self.surface,
                  let last = self.lastScrollbar,
                  last.total > last.len
            else { return }
            let maxOffset = last.total - last.len
            let desiredOffset = UInt64(Double(maxOffset) * (1.0 - desiredPosition))
            let lineDelta = Int64(last.offset) - Int64(desiredOffset)
            guard lineDelta != 0 else { return }
            ghostty_surface_mouse_scroll(surface, 0, Double(lineDelta), 0)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // `.activeWhenFirstResponder` keeps non-focused panes from receiving
        // mouseMoved and stomping on the focused surface's hover.
        // `.cursorUpdate` lets us re-apply `currentCursor` whenever the mouse
        // re-enters the surface — libghostty's `MOUSE_SHAPE` action only fires
        // when the shape *changes*, so without this the I-beam → pointer
        // transition wouldn't recover after the cursor briefly leaves.
        let options: NSTrackingArea.Options = [
            .activeWhenFirstResponder, .mouseMoved, .cursorUpdate, .inVisibleRect,
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    private var currentCursor: NSCursor = .iBeam

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    /// Map libghostty's `ghostty_action_mouse_shape_e` to an `NSCursor` and
    /// apply it. Skip the `.set()` syscall when the cursor hasn't changed —
    /// libghostty's contract is "fires on shape change" but defensive callers
    /// can repeat the same shape and we shouldn't churn AppKit.
    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_MOVE: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY: cursor = .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: cursor = .dragLink
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        guard currentCursor !== cursor else { return }
        currentCursor = cursor
        cursor.set()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // No deinit: Swift 6's nonisolated deinit can't touch @MainActor state.
    // Teardown is the explicit `releaseSurface()` path, called from
    // `LibghosttyEngine.terminate()` when a session is closed.

    func releaseSurface() {
        guard let dying = surface else { return }
        GhosttyDrawCoordinator.shared.unregister(self)
        surface = nil
        ghostty_surface_free(dying)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            let reattaching = surface != nil
            createSurfaceIfReady()
            // Always re-register — SwiftUI's rebuild cycle may have unregistered us.
            GhosttyDrawCoordinator.shared.register(self, priority: grabsFocusOnMount ? .active : .visible)
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if self.grabsFocusOnMount {
                    window.makeFirstResponder(self)
                }
                if reattaching { self.propagateSizeToSurface() }
            }
        }
        // Do NOT unregister here — SwiftUI's rebuild cycle temporarily sets
        // window=nil during tab moves, which would kill the draw coordinator
        // registration. The coordinator handles orphaned surfaces fine.
    }

    func createSurfaceIfReady() {
        guard surface == nil,
              let window,
              let config = pendingConfig,
              let app = LibghosttyApp.shared.app
        else { return }

        let scale = Double(window.backingScaleFactor)
        // Pin contentsScale so Core Animation doesn't double-scale ghostty's
        // already-pixel-correct render.
        layer?.contentsScale = scale
        // Seed so the first viewDidChangeBackingProperties on this display is a
        // no-op; only a real cross-display scale change re-pushes (issue #8).
        lastBackingScale = window.backingScaleFactor

        let workingDir = config.workingDirectory ?? NSHomeDirectory()
        // Merge our wrapper ZDOTDIR into the caller's env dict. AgentTemplate
        // populates AGENTTERMINAL_AGENT here so the wrapper .zshrc auto-launches the
        // selected CLI before the user ever sees a shell prompt.
        var envDict = config.environment
        envDict[AgentTerminalShellIntegration.zdotdirKey] = AgentTerminalShellIntegration.zshDirectory
        // Dynamic count of env entries — strdup each, free after surface_new.
        // libghostty copies the strings during init, so the lifetime only needs
        // to span the call below.
        let envCStrings = envDict.flatMap { (k, v) -> [UnsafeMutablePointer<CChar>] in
            [strdup(k)!, strdup(v)!]
        }
        defer { envCStrings.forEach { free($0) } }
        var envVars = stride(from: 0, to: envCStrings.count, by: 2).map { i in
            ghostty_env_var_s(key: envCStrings[i], value: envCStrings[i + 1])
        }

        let new: ghostty_surface_t? = workingDir.withCString { wdPtr in
            // command is populated by TerminalSessionConfig.defaultShell() — bypass
            // /usr/bin/login so we don't get a "Last login:…" line each session.
            config.command.withCString { cmdPtr in
                var surfaceConfig = ghostty_surface_config_new()
                surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
                surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
                // Userdata lets the @convention(c) action callback recover the
                // originating Swift view from a surface-scoped event.
                surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
                surfaceConfig.scale_factor = scale
                surfaceConfig.working_directory = wdPtr
                surfaceConfig.command = cmdPtr
                return envVars.withUnsafeMutableBufferPointer { buf in
                    surfaceConfig.env_vars = buf.baseAddress
                    surfaceConfig.env_var_count = buf.count
                    return ghostty_surface_new(app, &surfaceConfig)
                }
            }
        }

        guard let new else {
            NSLog("agentterminal: ghostty_surface_new failed")
            return
        }
        surface = new
        pendingConfig = nil
        ghostty_surface_refresh(new)
    }

    func updateConfigFromSettings(parsed: [String: Any]?) {
        guard let surface else { return }
        guard let config = AgentTerminalSettings.makeGhosttyConfig(parsed: parsed) else {
            NSLog("agentterminal: ghostty_config_new failed during surface reload")
            return
        }
        ghostty_surface_update_config(surface, config)
        ghostty_surface_refresh(surface)
    }

    override var acceptsFirstResponder: Bool { true }

    /// Toggled true around animated layout changes (pane zoom). Per-frame
    /// `setFrameSize` callbacks then skip the SIGWINCH-propagating
    /// `ghostty_surface_set_size` and the caller pushes one final size
    /// sync via `flushPropagateSize` after the animation settles.
    var suspendsSizePropagation: Bool = false
    private var resizeWorkItem: DispatchWorkItem?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let registered = GhosttyDrawCoordinator.shared.isRegistered(self)
        if surface != nil, window != nil, !registered {
            GhosttyDrawCoordinator.shared.register(self, priority: grabsFocusOnMount ? .active : .visible)
        }
        if suspendsSizePropagation { return }
        resizeWorkItem?.cancel()
        let prevSize = self.frame.size
        let areaChanged = abs(prevSize.width * prevSize.height - newSize.width * newSize.height)
        if areaChanged > 50000 {
            propagateSizeToSurface()
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.propagateSizeToSurface()
            }
            resizeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
        }
    }

    func flushPropagateSize() {
        propagateSizeToSurface()
    }

    /// Fires when the window moves to a display with a different backing scale
    /// (e.g. a Retina laptop screen → a 1x external monitor) — or on a
    /// colorspace change. libghostty captured the scale at surface creation and
    /// has no other way to learn the window changed displays; left stale, it
    /// keeps sizing the cell grid at the old DPI while receiving the new
    /// display's pixel dimensions, so the grid no longer fills the surface — a
    /// blank gutter on the right and input overflowing the viewport (issue #8).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        // Skip colorspace-only changes (same scale) so we don't fire a
        // gratuitous set_size → SIGWINCH (conda scrollback-wipe known issue).
        guard scale != lastBackingScale else { return }
        lastBackingScale = scale
        layer?.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        propagateSizeToSurface()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            if let surface { ghostty_surface_set_focus(surface, true) }
            GhosttyDrawCoordinator.shared.setPriority(self, priority: .active)
            onFocus?()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if let surface { ghostty_surface_set_focus(surface, false) }
            if window != nil {
                GhosttyDrawCoordinator.shared.setPriority(self, priority: .visible)
            }
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        let mods = event.modifierFlags
        let cmd = mods.contains(.command)
        let cmdOnly = cmd && mods.intersection([.shift, .control, .option]).isEmpty

        // Cmd+V: read the system pasteboard directly and inject as text via
        // the paste path so bracketed-paste mode wraps it correctly. The
        // right-click Paste menu shares the same path via `paste(_:)`.
        // `readTerminalPasteText` covers fileURLs (Finder Copy → full
        // path, not bare filename) and raw image data (screenshots →
        // spilled to a cache PNG so agents can open it as a path).
        if cmdOnly,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let pasted = AgentTerminalShellIntegration.readTerminalPasteText(from: .general),
           !pasted.isEmpty
        {
            paste(pasted)
            return
        }

        // Cmd+C with a live selection — without this branch libghostty's
        // bypassed keybinding system would leave Cmd+C dead.
        if cmdOnly,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           ghostty_surface_has_selection(surface)
        {
            performCopy()
            return
        }

        // macOS Cocoa text-edit shortcuts → the control bytes readline / zsh
        // ZLE already bind. Without this Cmd combos get swallowed by the
        // responder chain, and libghostty's default Option+Delete sequence
        // isn't what most shells recognise.
        if cmdOnly {
            switch event.keyCode {
            case 123: sendInputBytes("\u{01}", to: surface); return  // Cmd+← → ^A
            case 124: sendInputBytes("\u{05}", to: surface); return  // Cmd+→ → ^E
            case 51:  sendInputBytes("\u{15}", to: surface); return  // Cmd+⌫ → ^U
            default:  break
            }
        }
        if mods.contains(.option), !cmd, !mods.contains(.control), event.keyCode == 51 {
            sendInputBytes("\u{17}", to: surface)                    // Option+⌫ → ^W
            return
        }

        // Any other Cmd+combo: hand off to AppKit's responder chain so menu
        // key equivalents (Cmd+W close, Cmd+T new tab — when M4 wires them)
        // can fire instead of being swallowed by the PTY.
        if cmd {
            super.keyDown(with: event)
            return
        }

        // Cursor keys are mode-aware: after a TUI enables DECCKM (`smkx`),
        // libghostty must switch them from CSI (`ESC [ A`) to SS3
        // (`ESC O A`). Route the physical key event through libghostty so
        // old terminfo-strict programs (vim 7.2 on CentOS 6, etc.) see the
        // active mode instead of agentterminal hard-coding CSI forever. If libghostty
        // declines the key — shouldn't happen for a focused surface — fall
        // back to the CSI form; a non-mode-aware arrow still beats a dead one.
        if !hasMarkedText(),
           Self.shouldForwardModeAwareKeyToLibghostty(keyCode: event.keyCode, modifierFlags: mods) {
            // Arrow keys at a shell prompt recall history (↑/↓) or move the
            // cursor (←/→) — the start of the next command, so clear a stale
            // command-failure dot. Scrollback is the wheel, not arrows; inside
            // a TUI the dot is already cleared, so this is a no-op there.
            onUserInput?()
            if !sendKey(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface),
               let bytes = Self.handWrittenEscapeSequence(forKeyCode: event.keyCode, modifierFlags: mods) {
                sendInputBytes(bytes, to: surface)
            }
            return
        }

        // AgentTerminal-specific functional keys with explicit byte behavior. Skipped
        // while IME is composing so Enter / Esc / arrows can dismiss / accept
        // the candidate window without leaking through to the PTY.
        if !hasMarkedText(),
           let bytes = Self.handWrittenEscapeSequence(forKeyCode: event.keyCode, modifierFlags: mods) {
            sendInputBytes(bytes, to: surface)
            return
        }

        // Ctrl+letter — NSEvent already gives the control byte (Ctrl+A →
        // "\u{01}"); IME would swallow these, so we forward them ourselves.
        if mods.contains(.control), !mods.contains(.option),
           let chars = event.characters, !chars.isEmpty,
           let scalar = chars.unicodeScalars.first?.value, scalar < 0x20 {
            sendInputBytes(chars, to: surface)
            return
        }

        // Regular text + IME composition. inputContext routes through
        // NSTextInputClient: insertText for committed input, setMarkedText
        // for in-progress composition. We batch all IME effects via
        // keyTextAccumulator so libghostty sees one atomic preedit-sync
        // + one text-commit per keystroke instead of per-IME-callback —
        // critical for CJK composition where rapid transient preedit
        // states otherwise leak phantom cells.
        let hadMarkedTextBefore = !markedText.isEmpty
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        inputContext?.handleEvent(event)
        // Only sync preedit when there's a state change to communicate.
        // Sending `ghostty_surface_preedit(nil, 0)` on every keystroke
        // (including pure ASCII typing) was confusing libghostty's wrap
        // accounting on long lines — once the line wrapped, the original
        // first row would scroll out of view as if the surface were only
        // a few rows tall.
        syncPreedit(clearIfNeeded: hadMarkedTextBefore)
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                sendKeyText(text, to: surface)
            }
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if !markedText.isEmpty {
            markedText.withCString { cstr in
                ghostty_surface_preedit(surface, cstr, UInt(strlen(cstr)))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// Commits text from an IME composition or AppKit text-input session through
    /// libghostty's key-event API. We do this instead of `ghostty_surface_text_input`
    /// because the key-event path keeps cursor/wrap accounting in sync with how
    /// libghostty's grid expects user-driven keystrokes to advance; `text_input`
    /// is a lower-level injection that miscalculates wrap on long multi-byte
    /// sequences. Control bytes (< 0x20) still go through `text_input` — those
    /// are post-translation control sequences agentterminal already encodes itself.
    /// Mirrors ghostty.app's `committedPreeditTextAction` pattern.
    private func sendKeyText(_ text: String, to surface: ghostty_surface_t) {
        guard !text.isEmpty else { return }
        if let first = text.utf8.first, first < 0x20 {
            sendInputBytes(text, to: surface)  // control byte → fires onUserInput there
            return
        }
        // Visible typed text is the start of the next command — clear a stale
        // command-failure dot (libghostty exposes no command-START signal). The
        // control-byte branch above routes through sendInputBytes, which fires
        // its own onUserInput, so only this visible-text path needs one here.
        onUserInput?()
        text.withCString { ptr in
            var key_ev = ghostty_input_key_s()
            key_ev.action = GHOSTTY_ACTION_PRESS
            key_ev.keycode = 0
            key_ev.text = ptr
            key_ev.composing = false
            key_ev.mods = GHOSTTY_MODS_NONE
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.unshifted_codepoint = 0
            _ = ghostty_surface_key(surface, key_ev)
        }
    }

    private func sendInputBytes(_ bytes: String, to surface: ghostty_surface_t) {
        // Chokepoint for every control-sequence input the user initiates —
        // Return / Tab / function keys (handWrittenEscapeSequence), Ctrl+letter
        // (^R history search, ^C, ^L), the Cocoa edit shortcuts (Cmd+←/→/⌫,
        // Option+⌫), and pill injection (sendInput). All start the next command,
        // so clear a stale failure dot here once rather than at each caller.
        // Visible typing (ghostty_surface_key) and paste (ghostty_surface_text)
        // don't route through here, so they fire at their own sites.
        onUserInput?()
        bytes.withCString { cstr in
            ghostty_surface_text_input(surface, cstr, UInt(strlen(cstr)))
        }
    }

    func sendInput(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Pill-injected commands (nvm use, git checkout, unset proxy) are the
        // next command too; sendInputBytes fires onUserInput to clear the dot.
        sendInputBytes(text, to: surface)
    }

    /// Physical keys whose output depends on libghostty's terminal mode state.
    /// Keep these out of `handWrittenEscapeSequence`: hard-coded CSI cursor
    /// bytes break applications that requested application cursor keys.
    nonisolated static func shouldForwardModeAwareKeyToLibghostty(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else {
            return false
        }
        switch keyCode {
        case 123, 124, 125, 126: return true  // left, right, down, up
        default: return false
        }
    }

    /// Map agentterminal's own functional-key policy to bytes. Returns `nil` for
    /// normal text and mode-aware physical keys that must go through
    /// `ghostty_surface_key`.
    nonisolated static func handWrittenEscapeSequence(
        forKeyCode code: UInt16,
        modifierFlags mods: NSEvent.ModifierFlags
    ) -> String? {
        let modDigit = csiModifierDigit(shift: mods.contains(.shift),
                                        alt: mods.contains(.option),
                                        ctrl: mods.contains(.control))

        switch code {
        // Functional
        case 36:
            // Shift+Enter: send `\` then CR — zsh line-continuation and
            // Claude Code's documented `\` + Enter → newline trick both
            // honor this. `\n` alone is useless: ZLE binds it to accept-line.
            return mods.contains(.shift) ? "\\\r" : "\r"
        case 48:  return mods.contains(.shift) ? "\u{1B}[Z" : "\t"  // Tab / Shift+Tab
        case 51:  return "\u{7F}"                          // Backspace (DEL)
        case 53:  return "\u{1B}"                          // Escape

        // Modified arrows (`ESC [ 1;m x`) resolve here. Unmodified arrows are
        // routed through `ghostty_surface_key` in `keyDown` so libghostty
        // picks CSI vs SS3 per DECCKM; these `csiArrow` forms are also that
        // path's fallback if libghostty declines the key.
        case 123: return csiArrow("D", modDigit: modDigit)
        case 124: return csiArrow("C", modDigit: modDigit)
        case 125: return csiArrow("B", modDigit: modDigit)
        case 126: return csiArrow("A", modDigit: modDigit)

        // Control pad
        case 115: return csiArrow("H", modDigit: modDigit)  // Home
        case 119: return csiArrow("F", modDigit: modDigit)  // End
        case 116: return csiTilde("5", modDigit: modDigit)  // Page Up
        case 121: return csiTilde("6", modDigit: modDigit)  // Page Down
        case 117: return csiTilde("3", modDigit: modDigit)  // Forward Delete
        case 114: return csiTilde("2", modDigit: modDigit)  // Help / Insert

        // Function keys
        case 122: return ssFnKey("P", modDigit: modDigit)   // F1
        case 120: return ssFnKey("Q", modDigit: modDigit)   // F2
        case 99:  return ssFnKey("R", modDigit: modDigit)   // F3
        case 118: return ssFnKey("S", modDigit: modDigit)   // F4
        case 96:  return csiTilde("15", modDigit: modDigit) // F5
        case 97:  return csiTilde("17", modDigit: modDigit) // F6
        case 98:  return csiTilde("18", modDigit: modDigit) // F7
        case 100: return csiTilde("19", modDigit: modDigit) // F8
        case 101: return csiTilde("20", modDigit: modDigit) // F9
        case 109: return csiTilde("21", modDigit: modDigit) // F10
        case 103: return csiTilde("23", modDigit: modDigit) // F11
        case 111: return csiTilde("24", modDigit: modDigit) // F12

        default:  return nil
        }
    }

    /// CSI modifier digit: 2 = Shift, 3 = Alt, 4 = Shift+Alt, 5 = Ctrl, … 8.
    /// Returns nil when no modifier is set so the unmodified sequence is used.
    nonisolated private static func csiModifierDigit(shift: Bool, alt: Bool, ctrl: Bool) -> Int? {
        let mask = (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        return mask == 0 ? nil : mask + 1
    }

    nonisolated private static func csiArrow(_ final: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[1;\(m)\(final)" }
        return "\u{1B}[\(final)"
    }

    nonisolated private static func csiTilde(_ number: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[\(number);\(m)~" }
        return "\u{1B}[\(number)~"
    }

    nonisolated private static func ssFnKey(_ final: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[1;\(m)\(final)" }
        return "\u{1B}O\(final)"
    }

    override func keyUp(with event: NSEvent) {
        // Intentionally do not forward key-release to libghostty: when an
        // app (e.g. Codex / ratatui-crossterm) pushes kitty keyboard
        // protocol with event-types enabled, libghostty turns the release
        // into an escape sequence that the app then re-interprets as a
        // second press, doubling every keystroke (codex#18564). Press +
        // modifier flagsChanged carry enough state for libghostty's
        // internal modifier tracking; release is only meaningful to
        // applications that opt into the kitty enhancement, and those that
        // do tend to mishandle it.
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else {
            super.flagsChanged(with: event)
            return
        }
        sendKey(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface)
    }

    private var scrollAccum: NSPoint = .zero
    private static let scrollLinePoints: Double = 20.0

    override func scrollWheel(with event: NSEvent) {
        guard let surface else {
            super.scrollWheel(with: event)
            return
        }
        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate point deltas and only forward when we cross a
            // line threshold. libghostty's mouse_scroll treats integer-ish
            // deltas as line counts, so naive scaling lands on whole-line jumps
            // for every tiny finger movement.
            scrollAccum.x += event.scrollingDeltaX
            scrollAccum.y += event.scrollingDeltaY
            let dx = (scrollAccum.x / Self.scrollLinePoints).rounded(.towardZero)
            let dy = (scrollAccum.y / Self.scrollLinePoints).rounded(.towardZero)
            guard dx != 0 || dy != 0 else { return }
            ghostty_surface_mouse_scroll(surface, dx, dy, 0)
            scrollAccum.x -= dx * Self.scrollLinePoints
            scrollAccum.y -= dy * Self.scrollLinePoints
        } else {
            // Wheel: already in line ticks.
            ghostty_surface_mouse_scroll(surface,
                                         event.scrollingDeltaX,
                                         event.scrollingDeltaY,
                                         0)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        forwardMouseEvent(event, button: (.PRESS, .LEFT))
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event, button: (.RELEASE, .LEFT))
    }

    /// Direct selection extraction — bypasses the libghostty binding +
    /// write_clipboard_cb path so `keyDown`'s Cmd+C fallback works
    /// regardless of which keys are bound for copy in the active config.
    /// The right-click "Copy" entry in the SwiftUI popover takes the same
    /// path via the `TerminalEngine.readSelection()` interface.
    private func performCopy() {
        guard let str = readSelection() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
        NotificationCenter.default.post(name: NSNotification.Name("copyDidComplete"), object: nil)
    }

    func readSelection() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        // libghostty allocated the buffer; we must hand it back, otherwise every
        // read leaks the selection's bytes.
        defer { ghostty_surface_free_text(surface, &text) }
        guard let textPtr = text.text, text.text_len > 0 else { return nil }
        let data = Data(bytes: textPtr, count: Int(text.text_len))
        guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return nil }
        return str
    }

    func paste(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Pasting (⌘V) or dropping a file (performDragOperation routes here)
        // is the start of the next command too — same stale-failure-dot clear
        // as a keystroke, covering paste-with-trailing-newline that runs on
        // arrival, which a Return-key trigger would miss.
        onUserInput?()
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    /// Drives the scroll indicator from libghostty's SCROLLBAR action. Skips
    /// the layout pass entirely when the values haven't changed (libghostty
    /// emits these liberally).
    func applyScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        // Track bottom-pinned state on every tick — including the ones we skip
        // below for indicator purposes — so the resize re-pin in
        // propagateSizeToSurface always sees a current value.
        viewportAtBottom = Self.isViewportAtBottom(total: total, offset: offset, len: len)
        guard total > len, len > 0 else { return }
        let next = (total: total, offset: offset, len: len)
        let previous = lastScrollbar
        guard previous?.total != total
                || previous?.offset != offset
                || previous?.len != len else { return }
        lastScrollbar = next

        let maxOffset = total - len
        let position = 1.0 - Double(offset) / Double(maxOffset)
        let proportion = Double(len) / Double(total)
        scrollIndicator.update(position: max(0, min(1, position)), proportion: proportion)
        if previous?.offset != offset {
            scrollIndicator.flash()
        }
    }

    private func forwardMouseEvent(_ event: NSEvent, button: (state: ghostty_input_mouse_state_e, code: ghostty_input_mouse_button_e)? = nil) {
        guard let surface else { return }
        let mods = Self.mapModifiers(event.modifierFlags)
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, mods)
        if let button {
            _ = ghostty_surface_mouse_button(surface, button.state, button.code, mods)
        }
    }

    @discardableResult
    private func sendKey(event: NSEvent, action: ghostty_input_action_e, surface: ghostty_surface_t) -> Bool {
        let mods = Self.mapModifiers(event.modifierFlags)
        let chars = event.characters ?? ""
        // NSEvent gives function/arrow keys a Private-Use-Area "character"
        // (e.g. NSUpArrowFunctionKey = 0xF700). Those aren't real text — strip
        // them so libghostty relies on `keycode` instead and emits the correct
        // escape sequence (CSI A/B/C/D, etc.).
        let firstScalar = chars.unicodeScalars.first?.value ?? 0
        let textToSend = (firstScalar >= 0xE000 && firstScalar <= 0xF8FF) ? "" : chars

        return textToSend.withCString { cstr in
            var key = ghostty_input_key_s()
            key.action = action
            key.mods = mods
            key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            key.keycode = UInt32(event.keyCode)
            key.text = textToSend.isEmpty ? nil : cstr
            key.unshifted_codepoint = 0
            key.composing = false
            return ghostty_surface_key(surface, key)
        }
    }

    private static func mapModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func propagateSizeToSurface() {
        // Require a live window — never propagate while detached. A workspace
        // switch briefly removes the session's NSView from the window
        // (ContentView's `.id(workspace.id)` rebuild); the old `?? 2.0` scale
        // fallback then sized the grid at 2x on a 1x external display, so text
        // overflowed and stuck until the next resize (issue #8 follow-up — only
        // on the 1x monitor, never on the 2x laptop where the fallback matched).
        // viewDidMoveToWindow re-syncs on reattach.
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        let widthPx = UInt32(bounds.size.width * scale)
        let heightPx = UInt32(bounds.size.height * scale)
        // SwiftUI's tab-swap rebuild briefly hands us a 0-sized frame before
        // layout completes; pushing 0 to libghostty shrinks its row count and
        // never fully recovers, so the visible buffer creeps upward each swap.
        guard widthPx > 0, heightPx > 0 else { return }
        ghostty_surface_set_size(surface, widthPx, heightPx)
        // ghostty does NOT re-pin the viewport to the bottom on resize — it only
        // follows the latest output when a PTY write or keystroke calls
        // scroll(.active). A resize (live window drag → SIGWINCH-per-frame,
        // status-bar appear/disappear flush, pane-zoom flush, fullscreen) can
        // therefore strand the viewport above the active area while output is
        // streaming, leaving the prompt + newest output rendered below the fold
        // (issue #7). ghostty's `scroll-to-bottom = output` config that would
        // paper over this is unimplemented upstream, so re-pin ourselves — but
        // only when we were already at the bottom, so a user reading scrollback
        // isn't yanked down mid-resize.
        if viewportAtBottom {
            let action = "scroll_to_bottom"
            action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
        }
    }
}

// MARK: - Ghostty enum sugar

private extension ghostty_input_mouse_state_e {
    static var PRESS: Self { GHOSTTY_MOUSE_PRESS }
    static var RELEASE: Self { GHOSTTY_MOUSE_RELEASE }
}

private extension ghostty_input_mouse_button_e {
    static var LEFT: Self { GHOSTTY_MOUSE_LEFT }
    static var RIGHT: Self { GHOSTTY_MOUSE_RIGHT }
}

// MARK: - NSTextInputClient (IME / 中日韩 composition)

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Commit ends composition. If we're inside keyDown's IME batching
        // window the actual byte send is deferred until after the preedit
        // sync (one atomic transaction); otherwise (e.g. dictation outside
        // a real keystroke) we send immediately.
        markedText = ""
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface, !text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
            sendKeyText(text, to: surface)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Inside keyDown we defer the libghostty sync until handleEvent
        // returns; outside (rare — layout change mid-compose) we sync
        // immediately so the candidate window has a current anchor.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        markedText = ""
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Anchor the IME candidate window at the real cursor cell so 中日韩
        // composition reads naturally. libghostty hands us the rect in
        // surface-local top-left coords; AppKit's NSView is bottom-left,
        // so flip Y before handing the rect up to the window → screen
        // conversion chain that NSTextInputClient expects.
        guard let surface, let window else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(
            x: x,
            y: bounds.height - y - h,
            width: w,
            height: h
        )
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
}
