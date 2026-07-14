import AppKit
import Foundation

/// We don't bundle ghostty's shell-integration assets, so we ship a small zsh
/// wrapper that:
///   1. sources the user's real `~/.zshrc` so their config still applies, then
///   2. installs a `chpwd` hook that emits OSC 7 (`\e]7;file://host/path\e\\`).
///
/// Libghostty's `GHOSTTY_ACTION_PWD` then fires whenever the shell `cd`s, which
/// is what `WorkspaceStore` listens to for cwd-tracking.
enum AgentTerminalShellIntegration {
    /// POSIX single-quote wrap (escape internal `'` by `'\''`). Safe for
    /// arbitrary file paths and argv-style values; reused by anyone that
    /// builds a shell-command string for `engine.sendInput` or PTY spawn.
    static func quote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Backslash-escape every POSIX shell metacharacter — matches the
    /// `\ ` / `\'` style Finder uses when dragging a file onto Terminal.app
    /// or ghostty.app. Picks this over `quote(_:)` for the drag-and-drop
    /// path so the user sees the same untouched-looking path they'd see in
    /// any other macOS terminal, rather than a surrounding pair of quotes.
    /// Non-ASCII bytes (Chinese / emoji / accented chars) pass through
    /// unescaped — every modern shell accepts them as raw UTF-8.
    ///
    /// Edge case: filenames with embedded newlines are legal on macOS but
    /// POSIX shells eat `\<newline>` as line-continuation, dropping both
    /// chars instead of preserving the literal newline. We fall back to
    /// `quote(_:)` for those — visible quotes are uglier than `\ `, but
    /// silent path corruption is worse.
    static func backslashEscape(_ s: String) -> String {
        if s.contains("\n") {
            return quote(s)
        }
        var result = ""
        result.reserveCapacity(s.count)
        for char in s {
            if shellMetacharacters.contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }

    private static let shellMetacharacters: Set<Character> = [
        " ", "\t", "\n", "\\", "\"", "'", "`", "$",
        "(", ")", "|", "&", ";", "<", ">", "*", "?",
        "[", "]", "{", "}", "~", "!", "#",
    ]

    /// Filter `urls` to fileURLs, `backslashEscape` each path, join by
    /// spaces. Nil when nothing survives the filter — the caller falls
    /// through to other paste sources. Shared between Finder drag-drop
    /// (v0.11.3 `performDragOperation`) and Cmd+V on a Finder Copy
    /// (v0.18.2 paste path): both produce a multi-URL pasteboard the
    /// user expects to render as terminal argv.
    static func backslashEscapedFileURLs(_ urls: [URL]) -> String? {
        let escaped = urls.compactMap { $0.isFileURL ? backslashEscape($0.path) : nil }
        return escaped.isEmpty ? nil : escaped.joined(separator: " ")
    }

    /// Resolve pasteboard contents into a terminal-safe text payload —
    /// what Cmd+V and the right-click "Paste" entry should inject.
    ///
    /// Precedence:
    /// 1. **File URLs** (Finder Copy on a file — including images) →
    ///    `backslashEscape($0.path)` joined by spaces. Without this,
    ///    `pb.string(forType: .string)` for a fileURL returns just the
    ///    last path component (the filename), which agents can't open.
    ///    Warp / iTerm2 both do this; matches user expectation.
    /// 2. **Raw image data** (`Cmd+Ctrl+Shift+4` screenshot to
    ///    clipboard, Preview "Edit → Copy" on an open image) →
    ///    spilled to `~/Library/Caches/agentterminal/pastes/screenshot-<ts>.png`,
    ///    then `backslashEscape(file.path)`. Agents (Claude / Cursor /
    ///    Codex) take a file path as input; storing the bytes inline
    ///    would dump base64 garbage into the prompt.
    /// 3. **Plain string** → raw, no escaping (we'd corrupt `ls -la`).
    ///    `bracketed-paste` mode already isolates it from shell parsing.
    static func readTerminalPasteText(from pb: NSPasteboard) -> String? {
        if pb.availableType(from: [.fileURL]) != nil,
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let joined = backslashEscapedFileURLs(urls)
        {
            return joined
        }
        if pb.availableType(from: [.png, .tiff]) != nil,
           let cached = writePasteboardImageToCache(pb)
        {
            return backslashEscape(cached.path)
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            return text
        }
        return nil
    }

    /// Cheap probe used by the right-click "Paste" menu's enabled gate.
    /// Mirrors `readTerminalPasteText`'s precedence but skips the
    /// image-to-disk write so a menu open never spills cache files.
    /// `availableType(...)` is preferred over `pb.string(...)` for the
    /// string check — `pb.string` materialises the full pasted bytes
    /// into a Swift heap copy (~100ms for a 10MB clipboard) just for
    /// an emptiness check; `availableType` is constant-time.
    static func pasteboardHasTerminalPasteContent(_ pb: NSPasteboard) -> Bool {
        if pb.availableType(from: [.fileURL]) != nil,
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: { $0.isFileURL })
        {
            return true
        }
        if pb.availableType(from: [.png, .tiff, .string]) != nil {
            return true
        }
        return false
    }

    /// Spill a pasteboard image to a agentterminal-owned cache file. Returns
    /// the resulting URL on success. Prefers `.png` bytes verbatim;
    /// re-encodes `.tiff` to PNG via `NSBitmapImageRep` when only TIFF
    /// is offered (Cmd+Shift+3 screenshots land as TIFF, not PNG) —
    /// agents accept PNG universally, TIFF support is uneven.
    private static func writePasteboardImageToCache(_ pb: NSPasteboard) -> URL? {
        guard let data = pasteboardPNGData(pb) else { return nil }
        let ts = pasteFilenameTimestamp.string(from: Date())
        let file = pastesCacheDirectory.appendingPathComponent("screenshot-\(ts).png")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    private static func pasteboardPNGData(_ pb: NSPasteboard) -> Data? {
        if let direct = pb.data(forType: .png) { return direct }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let encoded = rep.representation(using: .png, properties: [:])
        {
            return encoded
        }
        return nil
    }

    private static let pasteFilenameTimestamp: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt
    }()

    /// Lazy-created `~/Library/Caches/agentterminal/pastes/`. Mirrors the
    /// `agentterminalBinDirectory` / `hooksDirectory` pattern: one
    /// `createDirectory` at first access, all subsequent paste-spills
    /// skip the FS check.
    private static let pastesCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("agentterminal/pastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Sweep stale paste-cache files. macOS evicts Caches under disk
    /// pressure but only when free space is critical — meanwhile a
    /// daily-paste-screenshots workflow accumulates GBs. Call at app
    /// startup via `Task.detached` so it doesn't block launch. The
    /// 30-day default matches Chrome / Firefox HTTP-cache policy.
    static func prunePastesCache(olderThan: TimeInterval = 30 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: pastesCacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        for url in contents {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mod, mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static let zshPath = "/bin/zsh"
    static let bashPath = "/bin/bash"
    static let zdotdirKey = "ZDOTDIR"

    /// Directory we prepend to spawned-shell `PATH` so wrapper scripts (e.g.
    /// `claude` shim) get found before the real binaries on disk.
    static let agentterminalBinDirectory: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("agentterminal/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    /// Path to the generated Claude Code hooks JSON. Passed to `claude` via
    /// `--settings <path>` by the wrapper script when `AGENTTERMINAL_SURFACE_ID` is set.
    static let claudeHooksPath: String = {
        hooksDirectory.appendingPathComponent("claude.json").path
    }()

    /// Path to the agentterminal-managed Gemini system-defaults file. Surfaced to
    /// gemini-cli via `GEMINI_CLI_SYSTEM_SETTINGS_PATH`. Hook arrays merge
    /// with CONCAT semantics across tiers (verified in google-gemini/gemini-cli
    /// `settingsSchema.ts`), so this layers on top of user hooks instead of
    /// replacing them — non-intrusive.
    static let geminiDefaultsPath: String = {
        hooksDirectory.appendingPathComponent("gemini-defaults.json").path
    }()

    /// Path to the agentterminal-managed Copilot hooks file. Copilot CLI auto-loads
    /// every `~/.copilot/hooks/*.json` and merges events across files, so a
    /// dedicated `agentterminal.json` co-exists with anything the user has dropped
    /// in there. Pure path computation — the directory is materialised
    /// (and the file written) only when `~/.copilot/` already exists, so
    /// non-Copilot users don't get an empty agentterminal-owned vendor dir in their
    /// home. We don't honor `COPILOT_HOME` from the user's shell here —
    /// agentterminal.app runs out-of-process, can't see interactive shell env — so
    /// users who customise `COPILOT_HOME` would drop the file themselves.
    static let copilotHooksPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/agentterminal.json").path
    }()

    /// XDG plugin directory OpenCode auto-loads at startup. Honors
    /// `XDG_CONFIG_HOME` when set (the OpenCode launch is a child of the same
    /// shell, so a user-relocated config dir routes consistently between us
    /// and OpenCode); falls back to `~/.config`.
    static let opencodePluginPath: String = {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        let dir = base.appendingPathComponent("opencode/plugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agentterminal.ts").path
    }()

    static let mimocodePluginPath: String = {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        let dir = base.appendingPathComponent("mimocode/plugins/agentterminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agentterminal.js").path
    }()

    private static let hooksDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("agentterminal/hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Absolute path to the `AgentTerminalHook` helper we exec for IPC. We do NOT run
    /// it in place from the bundle: macOS Gatekeeper silently SIGKILLs an
    /// adhoc-signed (unnotarized) *secondary* binary the first time its cdhash
    /// is assessed from inside an app in `/Applications`, and a helper we exec
    /// ourselves has no "Open Anyway" affordance to clear that the way the
    /// main binary does — so every build that changes AgentTerminalHook's code (new
    /// cdhash) would break manual agent detection, Claude hooks, and tool
    /// pills on first install. The exact same bytes run fine from a path
    /// outside `/Applications` (verified: a /tmp copy exits 0 where the
    /// bundled one exits 137). So copy AgentTerminalHook into Application Support — a
    /// location Gatekeeper doesn't exec-assess — on launch and run the copy.
    /// Re-copied every launch so a freshly-installed build's helper supersedes
    /// the stale copy. Falls back to the in-bundle path if the copy fails
    /// (dev `swift run` runs fine in place from `.build/<config>/` anyway).
    static let agentterminalHookBinaryPath: String = {
        guard let exe = Bundle.main.executablePath else { return "" }
        let bundled = (exe as NSString).deletingLastPathComponent + "/AgentTerminalHook"
        let fm = FileManager.default
        // No bundled helper next to us (e.g. the xctest runner) → return the
        // bundle path and DON'T touch the Application Support copy, so running
        // the test suite can't clobber the helper a live agentterminal depends on.
        guard fm.fileExists(atPath: bundled) else { return bundled }
        // `agentterminalBinDirectory` is the App Support `agentterminal/bin` dir (already created).
        let dest = (agentterminalBinDirectory as NSString).appendingPathComponent("AgentTerminalHook")
        do {
            try? fm.removeItem(atPath: dest)  // throws when absent — copyItem just needs a clear dest
            try fm.copyItem(atPath: bundled, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            return dest
        } catch {
            return bundled
        }
    }()

    /// Copy `agentforward` script into the bin directory so it's on PATH.
    static func installAgentForwardScript() {
        let fm = FileManager.default
        let dest = (agentterminalBinDirectory as NSString).appendingPathComponent("agentforward")
        // Try finding the script resource in any bundle (SPM or .app).
        // bundleResourceURL is @MainActor, so we iterate bundles directly here.
        // Note: SPM processes Resources with .process(), which flattens all
        // subdirectory contents to the bundle root — no subdirectory prefix.
        let bundlesToCheck: [Bundle] = [Bundle.main] + Bundle.allBundles
        var sourceURL: URL?
        for bundle in bundlesToCheck {
            if let url = bundle.url(forResource: "agentforward", withExtension: nil) {
                sourceURL = url
                break
            }
        }
        if let url = sourceURL, fm.fileExists(atPath: url.path) {
            do {
                try? fm.removeItem(atPath: dest)
                try fm.copyItem(atPath: url.path, toPath: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
                return
            } catch {}
        }
        // Fallback: try adjacent to executable (legacy .app bundle layout)
        guard let exe = Bundle.main.executablePath else { return }
        let bundled = (exe as NSString).deletingLastPathComponent + "/../Scripts/agentforward"
        guard fm.fileExists(atPath: bundled) else { return }
        do {
            try? fm.removeItem(atPath: dest)
            try fm.copyItem(atPath: bundled, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
        } catch {}
    }

    /// Copy `agentterminal-uninstall` script into the bin directory.
    static let uninstallScriptPath: String = {
        guard let exe = Bundle.main.executablePath else { return "" }
        let bundled = (exe as NSString).deletingLastPathComponent + "/../Scripts/agentterminal-uninstall"
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled) else { return bundled }
        let dest = (agentterminalBinDirectory as NSString).appendingPathComponent("agentterminal-uninstall")
        do {
            try? fm.removeItem(atPath: dest)
            try fm.copyItem(atPath: bundled, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            return dest
        } catch {
            return bundled
        }
    }()

    /// Per-session env vars our wrappers + hook helper read. Caller supplies
    /// the surface UUID; everything else is process-wide. PATH prepends
    /// `agentterminalBinDirectory` so wrapper shims resolve before the real binaries.
    /// `claudeCustomSettingsAgentId`, when set, routes `AGENTTERMINAL_HOOKS_PATH` to
    /// that custom agent's per-agent Claude settings file (endpoint / key)
    /// instead of the shared `claude.json`.
    static func agentterminalEnvironment(
        for sessionId: UUID,
        claudeCustomSettingsAgentId: String? = nil
    ) -> [String: String] {
        let parentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let hooksPath = claudeCustomSettingsAgentId.map(claudeCustomSettingsPath(agentId:)) ?? claudeHooksPath
        var env: [String: String] = [
            "AGENTTERMINAL_SURFACE_ID": sessionId.uuidString,
            "AGENTTERMINAL_HOOKS_PATH": hooksPath,
            "AGENTTERMINAL_BIN_DIR": agentterminalBinDirectory,
            "AGENTTERMINAL_HOOK_BIN": agentterminalHookBinaryPath,
            // AGENTTERMINAL_AGENT_MARKERS is deliberately NOT set locally: the
            // AgentTerminalHook socket is the local status channel. OSC-title markers
            // are the ssh-remote fallback (the remote bootstrap exports the
            // var there), so emitting them locally would double-report and
            // risk leaking OSC bytes into a redirected agent's stdout.
            "PATH": "\(agentterminalBinDirectory):\(parentPath)",
            // Gemini CLI loads this as the lowest-precedence settings tier,
            // but its hooks arrays use CONCAT-merge — so our entries fire
            // alongside whatever the user has in `~/.gemini/settings.json`,
            // not instead of. The file is ours, regenerated each launch.
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": geminiDefaultsPath,
            // libghostty defaults TERM to "xterm-ghostty"; not every system
            // ships its terminfo. Pinning to xterm-256color gives all TUIs a
            // well-known capability profile.
            "TERM": "xterm-256color",
        ]
        // Preserve the user's original ZDOTDIR (if they had one — rare, mostly
        // dotfile organizers). The wrapper rc consumes this to restore ZDOTDIR
        // after sourcing ~/.zshrc; child installer scripts then see the real
        // value (or no ZDOTDIR at all) and write PATH exports to ~/.zshrc
        // instead of our ephemeral wrapper rc.
        if let original = ProcessInfo.processInfo.environment["ZDOTDIR"], !original.isEmpty {
            env["AGENTTERMINAL_ORIGINAL_ZDOTDIR"] = original
        }
        return env
    }

    /// Writes wrapper shims, hook configs, and the OpenCode plugin to disk.
    /// Idempotent — call on every app launch so each agent's hook command
    /// tracks the latest `AgentTerminalHook` location.
    static func installAgentHooks(sshRemoteAgentDetection: Bool = false) {
        writeWrapper(name: "claude", script: claudeWrapperScript)
        writeWrapper(name: "codex", script: codexWrapperScript)
        // Gemini doesn't need a wrapper — `GEMINI_CLI_SYSTEM_SETTINGS_PATH`
        // in the spawned shell is enough for hooks to fire from gemini itself.
        writeWrapper(name: "opencode", script: bracketWrapperScript(slug: "opencode"))
        writeWrapper(name: "amp", script: bracketWrapperScript(slug: "amp"))
        writeWrapper(name: "cursor-agent", script: bracketWrapperScript(slug: "cursor-agent"))
        writeWrapper(name: "copilot", script: bracketWrapperScript(slug: "copilot"))
        writeWrapper(name: "grok", script: bracketWrapperScript(slug: "grok"))
        writeWrapper(name: "agy", script: antigravityWrapperScript)
        writeWrapper(name: "kimi", script: bracketWrapperScript(slug: "kimi"))
        writeWrapper(name: "pi", script: bracketWrapperScript(slug: "pi"))
        writeWrapper(name: "kiro-cli", script: bracketWrapperScript(slug: "kiro-cli"))
        writeWrapper(name: "mimo", script: bracketWrapperScript(slug: "mimo"))
        refreshSshRemoteAgentDetection(enabled: sshRemoteAgentDetection)

        let hookCmd = agentterminalHookBinaryPath
        writeJSON(at: claudeHooksPath, object: claudeHooksObject(hookCmd: hookCmd))
        writeJSON(at: geminiDefaultsPath, object: geminiDefaultsObject(hookCmd: hookCmd))
        installCopilotHooksIfPresent(hookCmd: hookCmd)
        writeManagedFile(at: opencodePluginPath, contents: opencodePluginScript)
        // MiMoCode uses a plugin system (not a hooks JSON). The plugin is a managed
        // .js file that pings AgentTerminalHook on chat.message (running) and
        // session.idle (attention) events.
        writeManagedFile(at: mimocodePluginPath, contents: mimocodePluginScript)
        let mimocodePluginDir = (mimocodePluginPath as NSString).deletingLastPathComponent
        let mimocodePkgPath = (mimocodePluginDir as NSString).appendingPathComponent("package.json")
        writeManagedFile(at: mimocodePkgPath, contents: mimocodePluginPackageJson)
        registerMimocodePlugin()
        installPiExtensionIfPresent()
        // Grok CLI has no JSON hook file like Claude — its `~/.grok/hooks/`
        // is a script directory driven by env vars (GROK_HOOK_EVENT /
        // GROK_SESSION_ID), so the bracket wrapper handles running/ended
        // and full lifecycle integration requires a different code path.
        //
        // Kimi Code's hooks are TOML-only (`~/.kimi-code/config.toml`
        // `[[hooks]]`) with no system-settings env-var override — so unlike
        // Gemini we can't point it at a agentterminal-owned defaults file, and unlike
        // Copilot it has no per-event hooks directory; the bracket wrapper
        // gives running/ended until a config.toml-merge path exists.
        //
        // Pi rides a agentterminal-managed TypeScript extension (installed only when
        // `~/.pi/` exists — see `installPiExtensionIfPresent`) that subscribes
        // to pi's session / turn events and pings AgentTerminalHook, same model as the
        // OpenCode plugin — so the dot also reaches `attention` (waiting on
        // you), not just the bracket wrapper's running/ended.
        //
        // Kiro CLI (`kiro-cli`) is bracket-wrapper-only: its hooks are
        // context-injection ("pre/post command" context for the model), not a
        // lifecycle feed agentterminal can map to attention, so running/ended is all
        // the wrapper surfaces. We wrap `kiro-cli`, never `kiro` (the IDE
        // launcher).

        // Ensure `agentforward` CLI script is available in the bin directory.
        installAgentForwardScript()
    }

    static func refreshSshRemoteAgentDetection(enabled: Bool) {
        if enabled {
            writeWrapper(name: "ssh", script: sshWrapperScript)
        } else {
            removeManagedWrapper(
                name: "ssh",
                markers: ["AGENTTERMINAL_DISABLE_SSH_AGENT_MARKERS", "agentterminal-agent-markers"]
            )
        }
    }

    /// Writes the Copilot hooks JSON only when the user already has a
    /// `~/.copilot/` directory — i.e. they've at least run Copilot CLI once.
    /// Skips otherwise so agentterminal doesn't pre-stage a vendor namespace for
    /// users who may never install Copilot. Installing Copilot later then
    /// requires one agentterminal restart to pick up the hooks (acceptable: the
    /// bracket wrapper still gives running/ended on the first run).
    private static func installCopilotHooksIfPresent(hookCmd: String) {
        let copilotHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
        guard FileManager.default.fileExists(atPath: copilotHome.path) else { return }
        let hooksDir = copilotHome.appendingPathComponent("hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        writeManagedJSON(at: copilotHooksPath, object: copilotHooksObject(hookCmd: hookCmd))
    }

    /// Writes the Pi extension only when the user already has a `~/.pi/`
    /// directory — i.e. they've run Pi at least once. Like the Copilot hooks,
    /// this avoids pre-staging a vendor namespace for users who may never
    /// install Pi; the bracket wrapper still gives running/ended on the first
    /// run, and a agentterminal restart picks up the extension once `~/.pi/` exists.
    /// Pi auto-loads every `*.ts` in `~/.pi/agent/extensions/`.
    private static func installPiExtensionIfPresent() {
        let piHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
        guard FileManager.default.fileExists(atPath: piHome.path) else { return }
        let dir = piHome.appendingPathComponent("agent/extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeManagedFile(at: dir.appendingPathComponent("agentterminal.ts").path, contents: piExtensionScript)
    }

    /// Pi extension (TypeScript, auto-loaded from `~/.pi/agent/extensions/`).
    /// Subscribes to pi's lifecycle events and pings AgentTerminalHook so the sidebar
    /// dot tracks per-session activity — running while a turn executes,
    /// attention when the turn ends and pi waits on the user. Mirrors the
    /// OpenCode plugin: gated on `AGENTTERMINAL_SURFACE_ID`, reads `AGENTTERMINAL_HOOK_BIN`
    /// from the env agentterminal injects, and carries the managed marker so a user
    /// edit isn't clobbered. Pi runs extensions under Node, so `process.env`
    /// and `pi.exec` are available.
    static let piExtensionScript = """
    // \(managedFileMarker) — pings AgentTerminalHook on pi's session / turn / tool
    // events so the sidebar agent dot tracks per-session activity (running
    // while a turn runs, attention when it ends and waits on you), the pane
    // status bar shows the tool pi is running right now (its tool_execution_*
    // events), and the session id is reported so agentterminal can resume the
    // conversation (`pi --session <id>`) after a restart. Safe to delete; it
    // is regenerated next time agentterminal launches.
    export default function (pi) {
      const surface = process.env.AGENTTERMINAL_SURFACE_ID
      const hookBin = process.env.AGENTTERMINAL_HOOK_BIN
      if (!surface || !hookBin) return

      const ping = async (state) => {
        try { await pi.exec(hookBin, ["pi", state]) } catch {}
      }
      const reportSession = async (ctx) => {
        try {
          const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile()
          if (!file) return
          const id = file.split("/").pop().replace(/\\.jsonl$/, "")
          if (id) await pi.exec(hookBin, ["pi", "conversation", id])
        } catch {}
      }
      // The "what" shown in the tool-call pill. pi's args use `path` (not
      // Claude's `file_path`) and lowercase tool names; unknown / custom tools
      // fall back to the first non-empty string arg (keys sorted for a stable
      // pick). Mirrors AgentTerminalHookKit.extractIdentifier on the Claude side.
      const toolIdentifier = (toolName, args) => {
        if (!args || typeof args !== "object") return ""
        switch (toolName) {
          case "bash": return typeof args.command === "string" ? args.command : ""
          case "read": case "edit": case "write": case "ls":
            return typeof args.path === "string" ? args.path : ""
          case "grep": case "find":
            return typeof args.pattern === "string" ? args.pattern
              : (typeof args.path === "string" ? args.path : "")
          default:
            for (const k of Object.keys(args).sort()) {
              if (typeof args[k] === "string" && args[k]) return args[k]
            }
            return ""
        }
      }

      // Report the session id on session_start only — pi fires it on
      // new / resume / fork (every time the session file changes); turns
      // don't move the file, so per-turn reporting would just respawn for the
      // same id.
      pi.on("session_start", async (event, ctx) => { await reportSession(ctx); await ping("running") })
      pi.on("turn_start", async () => { await ping("running") })
      pi.on("turn_end", async () => { await ping("attention") })
      pi.on("session_shutdown", async () => { await ping("ended") })

      // Tool-call activity pill. tool_execution_start carries the args, so it
      // ships the identifier; tool_execution_end has no args (just result /
      // isError), so it ships an empty identifier + ok/fail. pi's toolCallId
      // is stable across the pair, so agentterminal matches start/end by it.
      pi.on("tool_execution_start", async (event) => {
        try {
          await pi.exec(hookBin, ["pi", "tool", "pre", event.toolCallId || "", event.toolName || "", toolIdentifier(event.toolName, event.args)])
        } catch {}
      })
      pi.on("tool_execution_end", async (event) => {
        try {
          await pi.exec(hookBin, ["pi", "tool", "post", event.toolCallId || "", event.toolName || "", "", event.isError ? "fail" : "ok"])
        } catch {}
      })
    }
    """

    /// Wired via `claude --settings <path>`. SessionStart promotes manually-typed
    /// `claude` immediately; without it the tab icon waits for the user's first
    /// prompt. PreToolUse / PostToolUse / PostToolUseFailure subscribe Claude's
    /// tool-call lifecycle so the activity strip can render pills — they pass
    /// their raw event name as `argv[2]` (not a `HookEvent` rawValue) because
    /// `main.swift` reads stdin for those events and routes through
    /// `parseToolEventPayload`, not `buildLifecyclePayload`. Without
    /// `PostToolUseFailure`, a failed tool call's Pre record sits in `.running`
    /// for 60s before flipping to `.stalled` instead of immediately showing the
    /// red failure pill.
    /// PreToolUse is a passthrough event (tool payload for the activity strip)
    /// AND also triggers `.attention` so the user gets notified when Claude
    /// pauses for a permission prompt mid-turn. `main.swift` sends both the
    /// tool payload and a lifecycle attention payload for this event.
    static func claudeHooksObject(hookCmd: String) -> [String: Any] {
        hooksObject(
            slug: "claude",
            hookCmd: hookCmd,
            events: [
                "SessionStart":      .running,
                "UserPromptSubmit":  .running,
                "Stop":              .attention,
                "Notification":      .attention,
                "SessionEnd":        .ended,
            ],
            passthroughEvents: ["PreToolUse", "PostToolUse", "PostToolUseFailure"]
        )
    }

    /// Path to a per-custom-agent Claude settings file. Same directory as
    /// `claudeHooksPath`; named `claude-<agentId>.json` (id sanitised so a
    /// hand-edited settings.json can't escape the directory). Written by
    /// `refreshClaudeCustomSettings` and passed to `claude` via `--settings`
    /// for that agent's sessions, overriding `AGENTTERMINAL_HOOKS_PATH`.
    static func claudeCustomSettingsPath(agentId: String) -> String {
        let safe = String(agentId.map {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" ? $0 : "_"
        })
        return hooksDirectory.appendingPathComponent("claude-\(safe).json").path
    }

    /// A Claude `settings.json` fragment for a custom agent: the hooks
    /// `claudeHooksObject` produces, plus an `env` block carrying the
    /// agent's custom environment (endpoint / key / …). Passed to `claude`
    /// via `--settings`, so the variables apply to that Claude process
    /// only — agentterminal never exports them to the shell.
    static func claudeCustomSettingsObject(env: [String: String], hookCmd: String) -> [String: Any] {
        var object = claudeHooksObject(hookCmd: hookCmd)
        object["env"] = env
        return object
    }

    /// Materialises a per-agent Claude settings file for every Claude-Code-
    /// based custom agent that carries an env block, and deletes any stale
    /// `claude-<id>.json` no longer matching one (a since-deleted agent, or
    /// an env block the user cleared — the file can hold an API token).
    /// Called at launch and after every Settings save, so the on-disk files
    /// always track the current custom-agent set.
    static func refreshClaudeCustomSettings(customAgents: [CustomAgentData]) {
        let hookCmd = agentterminalHookBinaryPath
        var liveFiles: Set<String> = []
        for agent in customAgents where agent.baseAgentId == AgentTemplate.claudeCodeID {
            let env = AgentTemplate.parseEnv(agent.env)
            guard !env.isEmpty else { continue }
            let path = claudeCustomSettingsPath(agentId: agent.id)
            writeJSON(at: path, object: claudeCustomSettingsObject(env: env, hookCmd: hookCmd))
            liveFiles.insert((path as NSString).lastPathComponent)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: hooksDirectory.path)
        else { return }
        for name in names
        where name.hasPrefix("claude-") && name.hasSuffix(".json") && !liveFiles.contains(name) {
            try? FileManager.default.removeItem(at: hooksDirectory.appendingPathComponent(name))
        }
    }

    /// Gemini's hook event names diverge from Claude's (BeforeAgent / AfterAgent
    /// instead of UserPromptSubmit / Stop). Hook scripts must not write to
    /// stdout — `AgentTerminalHook` only writes to its socket so this is safe.
    /// SessionStart promotes manually-typed `gemini` to `.gemini` immediately,
    /// same pattern as Claude.
    static func geminiDefaultsObject(hookCmd: String) -> [String: Any] {
        hooksObject(slug: "gemini", hookCmd: hookCmd, events: [
            "SessionStart": .running,
            "BeforeAgent":  .running,
            "AfterAgent":   .attention,
            "Notification": .attention,
            "SessionEnd":   .ended,
        ])
    }

    /// Copilot CLI's hooks schema diverges from Claude/Gemini's enough that
    /// it doesn't fit `hooksObject`: top-level `version: 1`, camelCase event
    /// names, no inner `{"hooks": [...]}` wrapper, and the command goes in
    /// a `bash` field (not `command`). Event mapping mirrors Claude's
    /// (sessionStart / userPromptSubmitted → running; agentStop / notification
    /// → attention; sessionEnd → ended). The `_agentterminalManaged` sentinel is the
    /// JSON-friendly equivalent of the text marker — `writeManagedJSON` reads
    /// it back to decide whether the file is ours to overwrite.
    static func copilotHooksObject(hookCmd: String) -> [String: Any] {
        let events: [(String, HookEvent)] = [
            ("sessionStart",        .running),
            ("userPromptSubmitted", .running),
            ("agentStop",           .attention),
            ("notification",        .attention),
            ("sessionEnd",          .ended),
        ]
        var hooks: [String: Any] = [:]
        let quotedCmd = quote(hookCmd)
        for (event, state) in events {
            hooks[event] = [
                ["type": "command", "bash": "\(quotedCmd) copilot \(state.rawValue)", "timeoutSec": 5]
            ]
        }
        return ["version": 1, "_agentterminalManaged": managedFileMarker, "hooks": hooks]
    }

    /// Builds a `claude --settings`-style hooks object for any agent that
    /// follows the `{"hooks": {<EventName>: [{"hooks": [{"type": "command",
    /// "command": "..."}]}]}}` shape (Claude Code, Gemini CLI). Routing
    /// `HookEvent` cases through `.rawValue` keeps the wrapper-emitted strings
    /// in sync with the receiver in `HookServer`.
    /// Builds a Claude / Gemini-style hooks JSON object. `events` maps hook
    /// names → lifecycle state (running / attention / idle / ended); agentterminal-hook
    /// is invoked with the state's rawValue as `argv[2]`. `passthroughEvents`
    /// is for events whose handler needs the raw event name preserved (e.g.
    /// Claude's `PreToolUse` / `PostToolUse` — agentterminal-hook reads stdin for
    /// those and dispatches via `parseToolEventPayload`, so the raw name is
    /// what main.swift gates on, not a HookEvent rawValue).
    private static func hooksObject(
        slug: String,
        hookCmd: String,
        events: [String: HookEvent],
        passthroughEvents: [String] = []
    ) -> [String: Any] {
        // `events` and `passthroughEvents` MUST be disjoint — a collision
        // would silently overwrite the lifecycle dispatch with the passthrough
        // variant (or vice versa, depending on the loop order below). Better
        // to crash here at install time than ship a hook config that drops
        // an .attention/.running ping with no test failure. Currently disjoint
        // (Claude lifecycle = SessionStart/UserPromptSubmit/Stop/Notification/
        // SessionEnd, passthrough = PreToolUse/PostToolUse), but any new
        // caller adding richer payloads needs to pick a side per event.
        let lifecycleKeys = Set(events.keys)
        let passthroughSet = Set(passthroughEvents)
        precondition(
            lifecycleKeys.isDisjoint(with: passthroughSet),
            "hooksObject: events and passthroughEvents share key(s) \(lifecycleKeys.intersection(passthroughSet)) — collision would silently drop a hook"
        )

        var hooks: [String: Any] = [:]
        // Claude / Gemini run `command` through `/bin/sh -c`, so an unquoted
        // `AgentTerminalHook` path breaks the moment the app lives under a path with
        // spaces or shell metacharacters (e.g. `/Applications/AgentTerminal 2.app/…`).
        let quotedCmd = quote(hookCmd)
        for (event, state) in events {
            hooks[event] = [["hooks": [["type": "command", "command": "\(quotedCmd) \(slug) \(state.rawValue)"]]]]
        }
        for event in passthroughEvents {
            hooks[event] = [["hooks": [["type": "command", "command": "\(quotedCmd) \(slug) \(event)"]]]]
        }
        return ["hooks": hooks]
    }

    /// Marker we embed at the top of every agentterminal-generated user-config file
    /// (currently the OpenCode plugin). `writeManagedFile` reads existing
    /// files and refuses to overwrite anything that doesn't carry this tag —
    /// so a user's same-named plugin stays untouched on upgrade.
    private static let managedFileMarker = "agentterminal-managed-do-not-edit"

    private static func writeJSON(at path: String, object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Writes a file in user-config space (e.g. OpenCode plugin) only when
    /// either the path is unused or the existing content carries our marker.
    /// A user-owned file with the same name is left alone — better to skip a
    /// feature than nuke their plugin.
    private static func writeManagedFile(at path: String, contents: String) {
        let url = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.contains(managedFileMarker) {
            return
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// JSON variant of `writeManagedFile` — preserves a user-authored
    /// `agentterminal.json` that happens to live at the same path by looking for the
    /// `_agentterminalManaged` sentinel field. The Copilot hooks dir is user-owned
    /// (`~/.copilot/hooks/`), so a same-named user file is plausible enough
    /// to guard against. A corrupt-or-non-JSON file at the same path is
    /// treated as ours to overwrite — same policy `writeManagedFile` uses
    /// for non-UTF-8 / marker-less text. The alternative (silently skipping)
    /// would leave the user without working hooks and no signal as to why.
    private static func writeManagedJSON(at path: String, object: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (parsed["_agentterminalManaged"] as? String) != managedFileMarker {
            return
        }
        writeJSON(at: path, object: object)
    }

    private static func writeWrapper(name: String, script: String) {
        let path = (agentterminalBinDirectory as NSString).appendingPathComponent(name)
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    private static func removeManagedWrapper(name: String, markers: [String]) {
        let path = (agentterminalBinDirectory as NSString).appendingPathComponent(name)
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        guard markers.allSatisfy({ contents.contains($0) }) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// OSC-2 status marker, gated and tty-targeted. Fires only when
    /// `AGENTTERMINAL_AGENT_MARKERS` is set — ssh remotes export it, local sessions
    /// don't (they report through the AgentTerminalHook socket), so the local bracket
    /// wrappers stay silent and never double-report. Writes to `/dev/tty`, not
    /// stdout: a redirected agent (`claude -p … > out`) must not get OSC bytes
    /// in its output, and the marker must still reach the terminal when the
    /// agent's stdout is a pipe. `2>/dev/null` comes *before* `> /dev/tty` so a
    /// missing controlling tty (`/dev/tty` won't open) has its redirection error
    /// already silenced instead of leaking onto the caller's stderr.
    private static func agentMarkerCommand(slug: String, event: HookEvent) -> String {
        "[[ -n \"$AGENTTERMINAL_AGENT_MARKERS\" ]] && printf '\\033]2;\(AgentStatusMarker.title(slug: slug, event: event))\\a' 2>/dev/null > /dev/tty"
    }

    /// Binary slugs the SSH remote bootstrap installs marker-emitting shims for.
    /// Derived from `builtin` so every agent — and every future one — is covered
    /// without a second hand-maintained roster to keep in sync. `compactMap`
    /// drops Terminal (nil `initialCommand`); customs are excluded on purpose
    /// (their binary is user-defined, unknowable to a remote pre-staged shim).
    private static let remoteAgentMarkerSlugs = AgentTemplate.builtin.compactMap(\.initialCommand)

    /// Common bash header for every wrapper: locate the real binary on
    /// `$PATH` skipping our own dir, abort if missing.
    private static func wrapperPreamble(binary: String) -> String {
        """
        #!/usr/bin/env bash
        self_dir="$(cd "$(dirname "$0")" && pwd)"
        real=""
        IFS=:
        for dir in $PATH; do
            [[ "$dir" == "$self_dir" ]] && continue
            if [[ -x "$dir/\(binary)" ]]; then
                real="$dir/\(binary)"
                break
            fi
        done
        unset IFS

        if [[ -z "$real" ]]; then
            printf '\\n  \\033[33m%s is not installed.\\033[0m\\n\\n' "\(binary)" >&2
            # The new-tab path eagerly sets session.agent based on the template,
            # expecting bracket wrapper to ping `running` next. We never got
            # there — revert the icon so it doesn't lie about what's running.
            if [[ -n "$AGENTTERMINAL_SURFACE_ID" || -n "$AGENTTERMINAL_AGENT_MARKERS" ]]; then
                \(agentMarkerCommand(slug: binary, event: .ended))
            fi
            if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" ]]; then
                "$AGENTTERMINAL_HOOK_BIN" \(binary) ended 2>/dev/null
            fi
            exit 127
        fi
        """
    }

    /// Pass a pipe-driven programmatic invocation (a broker spawning the agent
    /// for JSON-RPC over stdio — `codex app-server`, the `codex:review` hang)
    /// straight through, skipping instrumentation: a AgentTerminalHook ping, OSC
    /// markers, and `-c notify` / `--settings` injection would all perturb the
    /// agent it spawned. Gate on BOTH fds (not `||`) so `claude -p … | tee`
    /// (stdin still a tty) keeps its sidebar dot. Each wrapper places this after
    /// the preamble AND after any exec-safety check — antigravity must reject
    /// the IDE-launcher shim first, else a background `agy` reopens the GUI.
    private static let ttyPassthroughGuard = """
    if [[ ! -t 0 && ! -t 1 ]]; then
        exec "$real" "$@"
    fi
    """

    /// Inside a agentterminal session ($AGENTTERMINAL_SURFACE_ID set), injects --settings so
    /// Claude Code's hooks report state back to the app via the bundled
    /// AgentTerminalHook helper. `AGENTTERMINAL_AGENT_MARKERS` enables the OSC-title fallback
    /// for remote shells that can write terminal bytes but cannot reach the
    /// local unix socket. Outside both, transparent passthrough.
    private static let claudeWrapperScript = """
    \(wrapperPreamble(binary: "claude"))

    \(ttyPassthroughGuard)

    if [[ -n "$AGENTTERMINAL_SURFACE_ID" || -n "$AGENTTERMINAL_AGENT_MARKERS" ]]; then
        \(agentMarkerCommand(slug: "claude", event: .running))
        if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOKS_PATH" ]]; then
            "$real" --settings "$AGENTTERMINAL_HOOKS_PATH" "$@"
        else
            "$real" "$@"
        fi
        status=$?
        \(agentMarkerCommand(slug: "claude", event: .ended))
        exit $status
    fi
    exec "$real" "$@"
    """

    /// Codex doesn't expose a Claude-style hooks settings file we can override
    /// per-invocation, but it does have `notify = ["cmd", "arg", ...]` in
    /// config.toml — fired after each agent turn with a JSON payload appended
    /// as the final argv. We override `notify` inline via `-c` so user's
    /// ~/.codex/config.toml is left untouched. The single signal we get is
    /// "turn complete" which we map to `attention`.
    static let codexWrapperScript = """
    \(wrapperPreamble(binary: "codex"))

    \(ttyPassthroughGuard)

    if [[ -n "$AGENTTERMINAL_SURFACE_ID" || -n "$AGENTTERMINAL_AGENT_MARKERS" ]]; then
        # Codex doesn't expose SessionStart / SessionEnd lifecycle hooks
        # we can override per-invocation. Bracket the run from the wrapper:
        # send `running` before codex starts (immediate icon promotion),
        # then `ended` after exit (revert to terminal). Mid-run state
        # transitions still come from Codex's `notify` config below.
        \(agentMarkerCommand(slug: "codex", event: .running))
        if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" ]]; then
            "$AGENTTERMINAL_HOOK_BIN" codex running 2>/dev/null
            "$real" -c "notify=[\\"$AGENTTERMINAL_HOOK_BIN\\",\\"codex\\",\\"attention\\"]" "$@"
        else
            "$real" "$@"
        fi
        status=$?
        if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" ]]; then
            if [[ $status -ne 0 ]]; then
                "$AGENTTERMINAL_HOOK_BIN" codex failure 2>/dev/null
            fi
            "$AGENTTERMINAL_HOOK_BIN" codex ended 2>/dev/null
        fi
        \(agentMarkerCommand(slug: "codex", event: .ended))
        exit $status
    fi
    exec "$real" "$@"
    """

    /// SSH is the one common path where the agent runs outside agentterminal's local
    /// process tree. For a plain interactive `ssh host`, inject a temporary
    /// remote shell session whose PATH starts with marker-emitting wrappers.
    /// Cases where SSH is used as transport (`git`, `scp`, `ssh host cmd`,
    /// port forwards, config dumps) pass through untouched.
    static let sshWrapperScript: String = {
        let remoteCommand = "sh -lc \(quote(remoteAgentBootstrapScript))"
        return """
        \(wrapperPreamble(binary: "ssh"))

        if [[ -n "${AGENTTERMINAL_DISABLE_SSH_AGENT_MARKERS:-}" || ! -t 0 || ! -t 1 ]]; then
            exec "$real" "$@"
        fi

        args=("$@")
        skip_next=0
        destination_seen=0
        remote_command_seen=0
        for ((i = 0; i < ${#args[@]}; i++)); do
            arg="${args[$i]}"
            if (( skip_next )); then
                skip_next=0
                continue
            fi
            if (( ! destination_seen )); then
                if [[ "$arg" == "--" ]]; then
                    ((i++))
                    [[ $i -lt ${#args[@]} ]] || exec "$real" "$@"
                    dest="${args[$i]}"
                    destination_seen=1
                    continue
                fi
                if [[ "$arg" == -* && "$arg" != "-" ]]; then
                    # `-o RemoteCommand=…` (attached or as the next arg) means the
                    # user already supplies the remote command — pass through like
                    # `ssh host cmd` instead of clobbering it with our bootstrap.
                    o_value=""
                    if [[ "$arg" == "-o" ]]; then
                        o_value="${args[$((i + 1))]:-}"
                    elif [[ "$arg" == -o?* ]]; then
                        o_value="${arg#-o}"
                    fi
                    case "$o_value" in
                        [Rr]emote[Cc]ommand*) exec "$real" "$@" ;;
                    esac
                    # Walk the short-option group left to right. A no-remote-shell
                    # flag (N/T/V/G/Q/O/W) — even bundled, e.g. `-fN` for a port
                    # forward — means this isn't an interactive login, so pass
                    # through. Stop at the first argument-taking option: the rest
                    # of the group (or the next arg, via skip_next) is its value.
                    group="${arg#-}"
                    c=0
                    while (( c < ${#group} )); do
                        case "${group:c:1}" in
                            [NTVGQOW]) exec "$real" "$@" ;;
                            [BbcDEeFIiJLlmOopQRSWw])
                                (( c == ${#group} - 1 )) && skip_next=1
                                break
                                ;;
                        esac
                        (( c++ ))
                    done
                    continue
                fi
                dest="$arg"
                destination_seen=1
                continue
            fi
            remote_command_seen=1
            break
        done

        if (( ! destination_seen || remote_command_seen )); then
            exec "$real" "$@"
        fi

        printf '\\033]2;\(RemoteLoginMarker.titlePrefix)%s\\a' "$dest" > /dev/tty 2>/dev/null

        remote_command=\(quote(remoteCommand))
        exec "$real" -t "$@" "$remote_command"
        """
    }()

    /// Remote-side bootstrap used only by `sshWrapperScript`. It writes wrapper
    /// binaries into a temp dir on the remote, then starts the user's shell
    /// with that dir prepended after normal rc replay. The temp dir is removed
    /// when the remote shell exits, so this does not persist files on servers.
    static let remoteAgentBootstrapScript: String = {
        let slugs = remoteAgentMarkerSlugs.map(quote).joined(separator: " ")
        return #"""
        _agentterminal_root="${TMPDIR:-/tmp}/agentterminal-agent-markers-${USER:-user}-$$"
        _agentterminal_bin="$_agentterminal_root/bin"
        mkdir -p "$_agentterminal_bin" 2>/dev/null || {
            printf 'agentterminal: could not create remote marker directory\n' >&2
            "${SHELL:-/bin/sh}" -l
            exit $?
        }
        trap 'rm -rf "$_agentterminal_root"' EXIT
        trap 'rm -rf "$_agentterminal_root"; exit' HUP INT TERM

        _agentterminal_write_agent_wrapper() {
            _agentterminal_slug="$1"
            cat > "$_agentterminal_bin/$_agentterminal_slug" <<'AGENTTERMINAL_AGENT_WRAPPER'
        #!/bin/sh
        _agentterminal_slug="${0##*/}"
        _agentterminal_self_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
        _agentterminal_real=""
        _agentterminal_old_ifs=$IFS
        IFS=:
        for _agentterminal_dir in $PATH; do
            [ "$_agentterminal_dir" = "$_agentterminal_self_dir" ] && continue
            [ -x "$_agentterminal_dir/$_agentterminal_slug" ] || continue
            _agentterminal_real="$_agentterminal_dir/$_agentterminal_slug"
            break
        done
        IFS=$_agentterminal_old_ifs

        if [ -z "$_agentterminal_real" ]; then
            printf '\033]2;agentterminal-agent:%s:ended\a' "$_agentterminal_slug" > /dev/tty 2>/dev/null
            printf '\n  %s is not installed.\n\n' "$_agentterminal_slug" >&2
            exit 127
        fi

        printf '\033]2;agentterminal-agent:%s:running\a' "$_agentterminal_slug" > /dev/tty 2>/dev/null
        "$_agentterminal_real" "$@"
        _agentterminal_status=$?
        printf '\033]2;agentterminal-agent:%s:ended\a' "$_agentterminal_slug" > /dev/tty 2>/dev/null
        exit "$_agentterminal_status"
        AGENTTERMINAL_AGENT_WRAPPER
            chmod +x "$_agentterminal_bin/$_agentterminal_slug"
        }

        for _agentterminal_slug in \#(slugs); do
            _agentterminal_write_agent_wrapper "$_agentterminal_slug"
        done
        unset _agentterminal_slug

        case "${SHELL:-}" in
            */zsh)
                mkdir -p "$_agentterminal_root/zsh"
                cat > "$_agentterminal_root/zsh/.zshrc" <<AGENTTERMINAL_ZSHRC
        if [[ -n "\${AGENTTERMINAL_ORIGINAL_ZDOTDIR:-}" ]]; then
            export ZDOTDIR="\$AGENTTERMINAL_ORIGINAL_ZDOTDIR"
            unset AGENTTERMINAL_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi
        # /etc/zshrc (already ran under our ephemeral ZDOTDIR) may have resolved
        # HISTFILE into the temp dir we rm -rf on exit — reset before user rc so
        # remote shell history lands in \$HOME and a user override still wins.
        export HISTFILE="\$HOME/.zsh_history"
        [[ -r "\${ZDOTDIR:-\$HOME}/.zshenv" ]] && source "\${ZDOTDIR:-\$HOME}/.zshenv"
        [[ -r "\${ZDOTDIR:-\$HOME}/.zprofile" ]] && source "\${ZDOTDIR:-\$HOME}/.zprofile"
        [[ -r "\${ZDOTDIR:-\$HOME}/.zshrc" ]] && source "\${ZDOTDIR:-\$HOME}/.zshrc"
        export AGENTTERMINAL_AGENT_MARKERS=1
        export PATH="$_agentterminal_bin:\$PATH"
        AGENTTERMINAL_ZSHRC
                AGENTTERMINAL_ORIGINAL_ZDOTDIR="${ZDOTDIR:-}" ZDOTDIR="$_agentterminal_root/zsh" zsh -l
                ;;
            */bash)
                cat > "$_agentterminal_root/bashrc" <<AGENTTERMINAL_BASHRC
        _agentterminal_login_rc_loaded=
        for _agentterminal_rc in "\$HOME/.bash_profile" "\$HOME/.bash_login" "\$HOME/.profile"; do
            if [[ -r "\$_agentterminal_rc" ]]; then
                source "\$_agentterminal_rc"
                _agentterminal_login_rc_loaded=1
                break
            fi
        done
        unset _agentterminal_rc
        if [[ -z "\$_agentterminal_login_rc_loaded" && -r "\$HOME/.bashrc" ]]; then
            source "\$HOME/.bashrc"
        fi
        unset _agentterminal_login_rc_loaded
        export AGENTTERMINAL_AGENT_MARKERS=1
        export PATH="$_agentterminal_bin:\$PATH"
        AGENTTERMINAL_BASHRC
                bash --rcfile "$_agentterminal_root/bashrc" -i
                ;;
            *)
                export AGENTTERMINAL_AGENT_MARKERS=1
                export PATH="$_agentterminal_bin:$PATH"
                "${SHELL:-/bin/sh}" -l
                ;;
        esac
        """#
    }()

    /// Antigravity CLI shares its binary name (`agy`) with Antigravity 2.0
    /// IDE's command-line launcher (`~/.antigravity/antigravity/bin/agy`
    /// is a symlink into `/Applications/Antigravity.app/...`). With only
    /// the IDE installed, PATH-resolution would pick up the launcher and
    /// a plain `exec agy` opens the GUI — surprising the user who picked
    /// "Antigravity CLI" from the `+` menu. Detect the IDE shim by
    /// resolving one symlink hop and matching `/Antigravity.app/`; on
    /// match, route through the same "not installed" path the preamble
    /// uses (red message + AgentTerminalHook `ended` ping so the tab icon
    /// reverts) plus surface the official CLI install command.
    static let antigravityWrapperScript = """
    \(wrapperPreamble(binary: "agy"))

    real_target="$(readlink "$real" 2>/dev/null || true)"
    case "${real_target:-$real}" in
        */Antigravity.app/*)
            printf '\\n  \\033[33mThe `agy` on PATH is the Antigravity IDE launcher, not the CLI.\\033[0m\\n' >&2
            printf '  Install the CLI:\\n' >&2
            printf '    \\033[36mcurl -fsSL https://antigravity.google/cli/install.sh | bash\\033[0m\\n\\n' >&2
            if [[ -n "$AGENTTERMINAL_SURFACE_ID" || -n "$AGENTTERMINAL_AGENT_MARKERS" ]]; then
                \(agentMarkerCommand(slug: "agy", event: .ended))
            fi
            if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" ]]; then
                "$AGENTTERMINAL_HOOK_BIN" agy ended 2>/dev/null
            fi
            exit 127
            ;;
    esac

    \(bracketBody(slug: "agy"))
    """

    /// Generic bracket wrapper for agents we can't drive mid-run state from
    /// (no hook system or no installed plugin yet). Sends `running` before
    /// exec and `ended` after exit; activity dot stays green for the whole
    /// run, then drops to idle on quit. Used for `amp` (no plugin) and
    /// `opencode` — opencode's plugin upgrades mid-run state once installed.
    static func bracketWrapperScript(slug: String) -> String {
        """
        \(wrapperPreamble(binary: slug))

        \(bracketBody(slug: slug))
        """
    }

    /// The `running` → exec → `ended` body shared by `bracketWrapperScript`
    /// and `antigravityWrapperScript`. Outside a agentterminal session (and without
    /// `AGENTTERMINAL_AGENT_MARKERS`) the bracket is a no-op — `exec "$real"` is the
    /// only line that runs so the wrapper is transparent when the user invokes
    /// the binary from a plain Terminal.app shell.
    private static func bracketBody(slug: String) -> String {
        """
        \(ttyPassthroughGuard)

        if [[ -n "$AGENTTERMINAL_SURFACE_ID" || -n "$AGENTTERMINAL_AGENT_MARKERS" ]]; then
            \(agentMarkerCommand(slug: slug, event: .running))
            if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" ]]; then
                "$AGENTTERMINAL_HOOK_BIN" \(slug) running 2>/dev/null
            fi
            "$real" "$@"
            status=$?
            if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" ]]; then
                if [[ $status -ne 0 ]]; then
                    "$AGENTTERMINAL_HOOK_BIN" \(slug) failure 2>/dev/null
                fi
                "$AGENTTERMINAL_HOOK_BIN" \(slug) ended 2>/dev/null
            fi
            \(agentMarkerCommand(slug: slug, event: .ended))
            exit $status
        fi
        exec "$real" "$@"
        """
    }

    /// OpenCode auto-loads any `.ts`/`.js` file in
    /// `$XDG_CONFIG_HOME/opencode/plugin/` (or `~/.config/opencode/plugin/`)
    /// at startup. The plugin runs in opencode's own Bun runtime, inherits
    /// AGENTTERMINAL_SURFACE_ID + AGENTTERMINAL_HOOK_BIN from the shell, and shells out to
    /// AgentTerminalHook on each lifecycle event. The first-line marker
    /// (`managedFileMarker`) lets `writeManagedFile` recognise the file as
    /// agentterminal-generated on upgrade — a user's own `agentterminal.ts` plugin would
    /// not carry the marker and stays untouched.
    static let opencodePluginScript = """
    // \(managedFileMarker) — pings AgentTerminalHook on prompt-submit, turn-end,
    // and error so the sidebar dot tracks per-session activity across all states.
    // Safe to delete; will be regenerated next time agentterminal launches.
    export const AgentTerminalPlugin = async ({ $ }) => {
      const surface = process.env.AGENTTERMINAL_SURFACE_ID
      const hookBin = process.env.AGENTTERMINAL_HOOK_BIN
      if (!surface || !hookBin) return {}

      const ping = async (state) => {
        try { await $`${hookBin} opencode ${state}`.quiet() } catch {}
      }

      return {
        "chat.message": async () => { await ping("running") },
        event: async ({ event }) => {
          if (event?.type === "session.idle") await ping("attention")
          if (event?.type === "session.error") await ping("failure")
        },
      }
    }
    """

    static let mimocodePluginScript = """
    // \(managedFileMarker) — pings AgentTerminalHook on message-submit, turn-end,
    // and error so the sidebar dot tracks per-session activity across all states.
    // Safe to delete; will be regenerated next time agentterminal launches.
    const AgentTerminalPlugin = async ({ $ }) => {
      const surface = process.env.AGENTTERMINAL_SURFACE_ID
      const hookBin = process.env.AGENTTERMINAL_HOOK_BIN
      if (!surface || !hookBin) return {}

      const ping = async (state) => {
        try { await $`${hookBin} mimo ${state}`.quiet() } catch {}
      }

      return {
        "chat.message": async () => { await ping("running") },
        event: async ({ event }) => {
          if (event?.type === "session.idle") await ping("attention")
          if (event?.type === "session.error") await ping("failure")
        },
      }
    }

    export const server = AgentTerminalPlugin
    export default AgentTerminalPlugin
    export { AgentTerminalPlugin }
    """

    static let mimocodePluginPackageJson = """
    {
      "name": "agentterminal",
      "version": "1.0.1",
      "main": "agentterminal.js",
      "private": true
    }
    """

    static func registerMimocodePlugin() {
        let configPath: String = {
            let base: URL
            if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                base = URL(fileURLWithPath: xdg, isDirectory: true)
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
            }
            return base.appendingPathComponent("mimocode/mimocode.json").path
        }()

        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var plugins = (json["plugin"] as? [String]) ?? []
        let pluginDir = (mimocodePluginPath as NSString).deletingLastPathComponent
        guard !plugins.contains(pluginDir) else { return }
        plugins.append(pluginDir)
        json["plugin"] = plugins

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        }
    }

    enum DetectedUserShell { case zsh, bash, other }

    static var detectedUserShell: DetectedUserShell {
        let path = ProcessInfo.processInfo.environment["SHELL"] ?? zshPath
        if path.hasSuffix("/zsh") { return .zsh }
        if path.hasSuffix("/bash") { return .bash }
        return .other
    }

    /// Path to a tiny launcher script that re-execs bash as an interactive,
    /// non-login shell with our `--rcfile`. Required because libghostty starts
    /// every `command` as a login shell (`argv[0]` prefixed with `-`), and
    /// login bash ignores `--rcfile` entirely (it reads `~/.bash_profile`
    /// instead). The launcher is a degenerate `bash` itself, so it gets the
    /// login prefix; it then `exec`s a fresh bash without the prefix.
    static let bashLauncherPath: String = {
        let dir = NSTemporaryDirectory()
        let launcherPath = dir.appending("agentterminal-bash-launch-\(getpid()).sh")
        let rcfilePath = dir.appending("agentterminal-bashrc-\(getpid())")

        let bashrc = """
        # Default word-jump bindings; readline doesn't bind Ctrl/Alt+arrow on
        # macOS by default. See the matching block in zshDirectory.
        bind '"\\e[1;5D": backward-word'     # Ctrl+Left
        bind '"\\e[1;5C": forward-word'      # Ctrl+Right
        bind '"\\e[1;3D": backward-word'     # Alt+Left
        bind '"\\e[1;3C": forward-word'      # Alt+Right

        # bash is launched as interactive non-login (`--rcfile` is incompatible
        # with `-l`), so it would normally skip the login rc chain. macOS users
        # traditionally put PATH / env in ~/.bash_profile (Apple Terminal starts
        # bash as login), so without this they'd see env vars vanish. Replay
        # the first existing login rc, matching bash's own lookup order.
        _agentterminal_login_rc_loaded=
        for _agentterminal_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [[ -r "$_agentterminal_rc" ]]; then
                source "$_agentterminal_rc"
                _agentterminal_login_rc_loaded=1
                break
            fi
        done
        unset _agentterminal_rc

        # No login rc existed, so its standard `source ~/.bashrc` chain never
        # ran — fall back so the user's interactive config still loads. Skip
        # when a login rc was found: bash login shells don't auto-source
        # .bashrc, and the user's profile chain (if they want it) handles
        # that. Avoids double-load when .bash_profile already chained .bashrc
        # (NVM / oh-my-bash / PROMPT_COMMAND duplication = 150-300ms).
        if [[ -z "$_agentterminal_login_rc_loaded" && -r "$HOME/.bashrc" ]]; then
            source "$HOME/.bashrc"
        fi
        unset _agentterminal_login_rc_loaded

        # User rc may rewrite PATH; re-prepend the agentterminal wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$AGENTTERMINAL_BIN_DIR" ]] && export PATH="$AGENTTERMINAL_BIN_DIR:$PATH"

        _agentterminal_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOSTNAME" "$PWD"; }
        # Re-assert the cwd as the OSC title each prompt (see zsh wrapper) —
        # prepended so it runs before the user's PROMPT_COMMAND title hook.
        _agentterminal_title_pwd() { printf '\\e]2;%s\\a' "$PWD"; }
        \(envStatusBlock)

        PROMPT_COMMAND="_agentterminal_title_pwd;_agentterminal_osc7_pwd;_agentterminal_env_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        _agentterminal_osc7_pwd
        _agentterminal_env_status

        \(agentLaunchBlock)
        """
        writeFile(at: rcfilePath, contents: bashrc)

        let launcher = """
        #!/bin/bash
        exec \(bashPath) --rcfile "\(rcfilePath)" -i

        """
        writeFile(at: launcherPath, contents: launcher, executable: true)
        return launcherPath
    }()

    /// Path to a per-process directory containing our wrapper `.zshrc`. Pass
    /// this as `ZDOTDIR` when spawning zsh so it loads the wrapper instead of
    /// `~/.zshrc` directly.
    static let zshDirectory: String = {
        let dir = NSTemporaryDirectory().appending("agentterminal-zsh-\(getpid())")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir), withIntermediateDirectories: true
        )
        let zshrc = """
        # Default word-jump bindings. zsh ZLE only binds Alt+B/F by default;
        # most other terminals (iTerm2, ghostty, Apple Terminal) remap the
        # Ctrl/Alt+arrow sequences to ESC+B/F so users don't notice. agentterminal
        # binds them directly here. Placed before sourcing ~/.zshrc so user
        # rc files retain final say if they override the same sequences.
        bindkey '^[[1;5D' backward-word    # Ctrl+Left
        bindkey '^[[1;5C' forward-word     # Ctrl+Right
        bindkey '^[[1;3D' backward-word    # Alt+Left
        bindkey '^[[1;3C' forward-word     # Alt+Right

        # Restore ZDOTDIR to the user's original (almost always unset) *before*
        # replaying their rc chain. zsh has already consumed ZDOTDIR to locate
        # this wrapper rc — changing it now is safe and ensures any
        # `$ZDOTDIR/...` reference inside .zshenv / .zprofile / .zshrc
        # (compinit's `.zcompdump`, plugin caches, znap/zinit roots, HISTFILE
        # overrides) resolves to real `$HOME` instead of our ephemeral
        # agentterminal-zsh-<pid> dir. Also stops `curl | bash`-style installers
        # (opencode, rustup) from writing PATH exports to our ephemeral rc.
        if [[ -n "$AGENTTERMINAL_ORIGINAL_ZDOTDIR" ]]; then
            export ZDOTDIR="$AGENTTERMINAL_ORIGINAL_ZDOTDIR"
            unset AGENTTERMINAL_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi

        # macOS `/etc/zshrc` (already ran) resolved HISTFILE against our
        # ephemeral ZDOTDIR; `cleanup()` deletes that dir on quit, taking
        # history with it. Reset to the real path *before* user rc so a user
        # HISTFILE override in any of the three files below still wins.
        export HISTFILE="$HOME/.zsh_history"

        # Re-assert the cwd as the OSC title each prompt — registered before
        # the user rc so it runs first in precmd_functions. Drops a stale
        # ssh / TUI title; a title the user's theme sets later this prompt
        # still wins (it runs after). agentterminal maps a cwd-shaped title to the
        # bare basename. `return $_s` keeps $? intact for the user hooks.
        autoload -Uz add-zsh-hook
        _agentterminal_title_pwd() { local _s=$?; printf '\\e]2;%s\\a' "$PWD"; return $_s }
        add-zsh-hook precmd _agentterminal_title_pwd

        # Replay the rc files zsh would have run if ZDOTDIR had pointed at the
        # user's real dir. Resolve via `${ZDOTDIR:-$HOME}` after each source —
        # so users who park their zsh config in a custom dir (e.g.
        # `~/.config/zsh` via parent-shell ZDOTDIR, or via `export ZDOTDIR=...`
        # inside .zshenv itself) get the full chain. Re-resolve after each
        # source because .zshenv / .zprofile may mutate ZDOTDIR.
        [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
        [[ -r "${ZDOTDIR:-$HOME}/.zprofile" ]] && source "${ZDOTDIR:-$HOME}/.zprofile"
        [[ -r "${ZDOTDIR:-$HOME}/.zshrc" ]] && source "${ZDOTDIR:-$HOME}/.zshrc"

        # User rc may rewrite PATH; re-prepend the agentterminal wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$AGENTTERMINAL_BIN_DIR" ]] && export PATH="$AGENTTERMINAL_BIN_DIR:$PATH"

        _agentterminal_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOST" "$PWD" }
        add-zsh-hook chpwd _agentterminal_osc7_pwd
        _agentterminal_osc7_pwd

        \(envStatusBlock)

        \(osc133Block)

        \(agentLaunchBlock)
        """
        writeFile(at: (dir as NSString).appendingPathComponent(".zshrc"), contents: zshrc)
        return dir
    }()

    /// Removes per-process temp files. Wired into `applicationWillTerminate`
    /// so wrappers don't accumulate in `NSTemporaryDirectory()` across runs.
    static func cleanup() {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory()
        let pid = getpid()
        for path in [
            dir.appending("agentterminal-bash-launch-\(pid).sh"),
            dir.appending("agentterminal-bashrc-\(pid)"),
            dir.appending("agentterminal-zsh-\(pid)"),
        ] {
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Internals

    /// Inline agent launch — invoked by both wrapper rcs to start AGENTTERMINAL_AGENT
    /// before the first prompt prints. AGENTTERMINAL_AGENT_LAUNCHED guards against
    /// re-entry from subshells the agent itself may spawn.
    static let agentLaunchBlock = """
        if [[ -n "$AGENTTERMINAL_AGENT" && -z "$AGENTTERMINAL_AGENT_LAUNCHED" ]]; then
            export AGENTTERMINAL_AGENT_LAUNCHED=1
            _agentterminal_cmd="$AGENTTERMINAL_AGENT"
            _agentterminal_agent_bin="${_agentterminal_cmd%% *}"
            unset AGENTTERMINAL_AGENT
            # `eval` lets AGENTTERMINAL_AGENT carry multi-word commands (e.g. an
            # editor + file path); single-word agent commands like `claude`
            # behave identically.
            eval "$_agentterminal_cmd"
            _agentterminal_status=$?
            # The agent ran in the foreground, so reaching here means it exited
            # — or never really started: a user alias (e.g. `alias pi=...`) can
            # shadow the PATH wrapper before its `ended` ping fires, stranding
            # the eagerly-promoted tab icon on the agent. Revert to a plain
            # shell. Idempotent — a wrapper that already pinged `ended` makes
            # this a no-op (`applyHookEvent` dedups same-value writes).
            if [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" ]]; then
                "$AGENTTERMINAL_HOOK_BIN" "$_agentterminal_agent_bin" ended 2>/dev/null
            fi
            # Restore the agent's exit code — the revert ping clobbered `$?`,
            # but the first prompt (and theme hooks / `_agentterminal_title_pwd` that
            # read `$?`) should see the agent's real status, not our hook call's.
            ( exit $_agentterminal_status )
        fi
        """

    /// Two layers of memoization in this hook avoid heavy per-prompt work:
    /// (a) `node --version` is the dominant cost (~50-200ms for V8 cold-start
    ///     on every prompt). We cache its result against the resolved `node`
    ///     binary path + NVM_BIN — if neither changed, the cached version is
    ///     still valid.
    /// (b) the `agentterminal-hook env` IPC fork is skipped entirely when no env key
    ///     differs from the previous send. Most prompts have steady env, so
    ///     this turns the hook into a no-op the vast majority of the time.
    static let envStatusBlock = """
        _agentterminal_env_status() {
            [[ -n "$AGENTTERMINAL_SURFACE_ID" && -n "$AGENTTERMINAL_HOOK_BIN" && -x "$AGENTTERMINAL_HOOK_BIN" ]] || return 0
            local _agentterminal_node_path=""
            command -v node >/dev/null 2>&1 && _agentterminal_node_path="$(command -v node)"
            local _agentterminal_node_key="${_agentterminal_node_path}|${NVM_BIN:-}"
            if [[ "$_agentterminal_node_key" != "$_AGENTTERMINAL_NODE_KEY_LAST" ]]; then
                _AGENTTERMINAL_NODE_VERSION_LAST=""
                [[ -n "$_agentterminal_node_path" ]] && _AGENTTERMINAL_NODE_VERSION_LAST="$("$_agentterminal_node_path" --version 2>/dev/null)"
                _AGENTTERMINAL_NODE_KEY_LAST="$_agentterminal_node_key"
            fi
            # Accept both lowercase and uppercase forms — curl / git / requests
            # respect lowercase; some tools (and many corp setups) export
            # uppercase only. Fall through to uppercase when lowercase is unset.
            local _agentterminal_https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
            local _agentterminal_http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
            local _agentterminal_all_proxy="${all_proxy:-${ALL_PROXY:-}}"
            local _agentterminal_env_now="${VIRTUAL_ENV:-}|${CONDA_DEFAULT_ENV:-}|${NVM_BIN:-}|${NVM_DIR:-}|$_AGENTTERMINAL_NODE_VERSION_LAST|$_agentterminal_https_proxy|$_agentterminal_http_proxy|$_agentterminal_all_proxy"
            [[ "$_agentterminal_env_now" == "$_AGENTTERMINAL_ENV_LAST" ]] && return 0
            # Only advance the dedup cache when the IPC actually succeeded —
            # if agentterminal-hook returns non-zero (agentterminal restarting, socket gone
            # before the hook server bound), the next prompt will retry
            # instead of staying frozen at the unsent value.
            "$AGENTTERMINAL_HOOK_BIN" env "${VIRTUAL_ENV:-}" "${CONDA_DEFAULT_ENV:-}" "${NVM_BIN:-}" "${NVM_DIR:-}" "$_AGENTTERMINAL_NODE_VERSION_LAST" "$_agentterminal_https_proxy" "$_agentterminal_http_proxy" "$_agentterminal_all_proxy" 2>/dev/null \
                && _AGENTTERMINAL_ENV_LAST="$_agentterminal_env_now"
            # Mask our internal IPC status so user precmd hooks downstream in
            # zsh's precmd_functions chain don't see `$?=1` and bleed it into
            # their prompt rendering. The dedup logic is internal — its
            # success/failure must not leak into the rest of the shell.
            return 0
        }
        """

    /// FinalTerm / OSC 133 prompt+command boundary markers. libghostty parses
    /// these and fires `GHOSTTY_ACTION_COMMAND_FINISHED` on `D` (per-tab
    /// last-command status + duration, scroll-to-prompt jumps), and uses
    /// `A;cl=line` to anchor `cursor-click-to-move` so option-/single-click
    /// on a prompt jumps the shell cursor to that column. Re-injects the
    /// `B` marker into PROMPT on every redraw because Starship / p10k-style
    /// themes rebuild PROMPT each `precmd` and would otherwise drop our suffix.
    private static let osc133Block = #"""
        __agentterminal_133_first=1
        __agentterminal_133_precmd() {
            local last=$?
            if (( ! __agentterminal_133_first )); then
                printf '\e]133;D;%s\a' "$last"
            fi
            __agentterminal_133_first=0
            # `cl=line` is ghostty's required marker metadata — without it
            # libghostty silently ignores the prompt sentinel and features
            # that depend on it (`cursor-click-to-move`, jump-to-prompt)
            # stay dormant. `\a` (BEL) terminator matches ghostty's own
            # zsh shell-integration script exactly.
            printf '\e]133;A;cl=line\a'
            # Wrap the OSC 133 B marker in zsh's zero-width brackets (%{ ... %}).
            # Without them zsh counts every byte of the escape sequence (ESC, ],
            # `133;B`, BEL) toward the PROMPT's visible width, miscalculates the
            # wrap column by ~8 cells, and ZLE redraws the input on the wrong
            # row the moment a long input wraps — wiping the first visible line.
            [[ "$PROMPT" != *$'\e]133;B\a'* ]] && PROMPT="${PROMPT}"$'%{\e]133;B\a%}'
            _agentterminal_env_status
            # Same masking concern as `_agentterminal_env_status` itself: the agentterminal
            # hooks must not leak `$?` into user prompts that downstream
            # precmd hooks may sample.
            return 0
        }
        __agentterminal_133_preexec() { printf '\e]133;C\a' }
        add-zsh-hook precmd __agentterminal_133_precmd
        add-zsh-hook preexec __agentterminal_133_preexec
        """#

    private static func writeFile(at path: String, contents: String, executable: Bool = false) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { chmod(path, 0o755) }
    }
}
