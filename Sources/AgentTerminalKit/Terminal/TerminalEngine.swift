import AppKit

struct TerminalSessionConfig {
    var command: String
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]

    static func defaultShell() -> TerminalSessionConfig {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? AgentTerminalShellIntegration.zshPath
        return TerminalSessionConfig(command: shell, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Pinned zsh — pairs with the ZDOTDIR wrapper for AGENTTERMINAL_AGENT + OSC 7.
    static func zshShell() -> TerminalSessionConfig {
        TerminalSessionConfig(command: AgentTerminalShellIntegration.zshPath, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Bash via launcher script — direct `--rcfile` flags don't work because
    /// libghostty makes every `command` a login shell, which strips
    /// `--rcfile` semantics. Launcher re-execs as interactive non-login.
    static func bashShell(launcher: String) -> TerminalSessionConfig {
        TerminalSessionConfig(command: launcher, arguments: [], workingDirectory: nil, environment: [:])
    }
}

@MainActor
protocol TerminalEngine: AnyObject {
    var view: NSView { get }
    var backgroundColor: NSColor { get }
    /// Called when the engine observes a working-directory change (libghostty's
    /// `GHOSTTY_ACTION_PWD`, fired when the shell emits OSC 7). Lets the
    /// workspace track the active tab's cwd so new tabs inherit the latest path.
    var onPwdChange: ((String) -> Void)? { get set }
    /// Called when the running program sets the terminal title via an `OSC 0`
    /// / `OSC 2` escape sequence (libghostty's `GHOSTTY_ACTION_SET_TITLE`).
    /// Drives the tab + workspace name so an `ssh` into a remote host — whose
    /// shell emits its own `user@host:dir` title — shows in agentterminal's chrome.
    var onTitleChange: ((String) -> Void)? { get set }
    /// Called when this engine's surface becomes the window's first responder
    /// (i.e. the user clicked into it). Lets the workspace mark the matching
    /// leaf as focused so split-aware operations (cwd tracking, ⌘D inheritance)
    /// follow the visually-active pane.
    var onFocus: (() -> Void)? { get set }
    /// Called when libghostty sees `OSC 133;D` from the shell — the
    /// most-recent command's exit code and run duration. `exitCode` is `nil`
    /// when the shell omitted it from the OSC sequence.
    var onCommandFinished: ((Int?, TimeInterval) -> Void)? { get set }
    /// Fires when the user begins the next command — any keystroke (typing,
    /// Return, arrows, Ctrl / edit shortcuts), paste, or programmatic injection.
    /// libghostty exposes command *finish* (OSC 133;D) but not command *start*,
    /// so user input is the signal a session uses to clear a stale command-
    /// failure dot the moment the user moves on.
    var onUserInput: (() -> Void)? { get set }
    /// Search lifecycle from libghostty's `start_search` / `end_search` /
    /// `navigate_search` keybinds. While `onSearchStart` is the most recent
    /// signal, libghostty owns the input loop and reports the current needle
    /// + total / selected match index back through these callbacks. The UI
    /// is a passive mirror — agentterminal doesn't push the needle string itself.
    var onSearchStart: ((String) -> Void)? { get set }
    var onSearchEnd: (() -> Void)? { get set }
    var onSearchTotal: ((Int) -> Void)? { get set }
    var onSearchSelected: ((Int) -> Void)? { get set }
    /// PID of the foreground process inside the surface. Used only as an
    /// initial/fallback env snapshot before the prompt hook reports live
    /// `VIRTUAL_ENV` / `NVM_BIN`.
    var foregroundPid: pid_t? { get }
    /// Fires when the surface's child process exits cleanly (exit code 0
    /// — `exit` / `logout` typed in the shell). Non-zero exits intentionally
    /// don't fire this — libghostty's "press any key to close" message
    /// stays so the user can read crash output before dismissing.
    var onProcessExitedCleanly: (() -> Void)? { get set }
    /// Fires when the terminal receives a BEL character (`\x07`). Programs
    /// use BEL to request user attention — e.g. Claude Code's permission
    /// prompts, shell error alerts, or `echo -e '\a'`.
    var onBell: (() -> Void)? { get set }
    func start(config: TerminalSessionConfig)
    func terminate()
    /// When true, AppKit `setFrameSize` callbacks skip `ghostty_surface_set_size`.
    /// Set during animated workspace-layout changes (pane zoom) so each
    /// intermediate animation frame doesn't fire its own SIGWINCH burst —
    /// the documented "12-24 set_size calls per toggle" scrollback-wipe
    /// problem that hits conda init users (see CLAUDE.md known issues).
    /// Pair every `true` assignment with `flushSize()` once the layout
    /// settles so libghostty's grid catches up to the final dimensions.
    var suspendsSizePropagation: Bool { get set }
    /// Gates whether the engine's view grabs keyboard first-responder when it
    /// mounts into a window. The SwiftUI layer sets it from the pane's active
    /// state so a workspace switch — which re-mounts every pane's surface —
    /// lands focus on the active pane, not whichever surface mounted last
    /// (issue #24). Default true: a single pane or a fresh split/tab still
    /// grabs focus on mount.
    var grabsFocusOnMount: Bool { get set }
    /// Force a one-shot size sync of the surface to the current view
    /// frame. Used when un-suspending after an animation.
    func flushSize()
    /// Trigger a libghostty named action (e.g. `increase_font_size:1`,
    /// `decrease_font_size:1`, `reset_font_size`, `clear_screen`). Returns
    /// `true` when the engine recognised and dispatched the action.
    @discardableResult
    func performAction(_ name: String) -> Bool
    /// Sends committed text into the PTY as if the user typed it.
    func sendInput(_ text: String)
    /// Routes `text` through the engine's paste path — wrapped in
    /// bracketed-paste sequences when the shell has enabled them so
    /// `zsh` line-editor multi-line guards and `vim` paste mode behave
    /// the same as a real ⌘V. The right-click "Paste" menu item uses
    /// this instead of `sendInput` so the two paths can't drift.
    func paste(_ text: String)
    /// Returns the current selection as a UTF-8 string, or nil if no
    /// selection is active. Powers the right-click "Ask agent" path and
    /// the menu-bar Copy item — same surface, two callers.
    func readSelection() -> String?
}
