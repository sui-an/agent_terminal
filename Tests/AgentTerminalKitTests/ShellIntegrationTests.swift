import AppKit
import XCTest
@testable import AgentTerminalKit

/// Verifies the *content* the integration generates. Tests do not invoke
/// `installAgentHooks()` because that writes to user-config dirs using a
/// hookCmd derived from the running binary (xctest's helpers under
/// `/Applications/Xcode.app/...`), which would pollute and corrupt
/// real user config files. Self-heals on next agentterminal launch but better
/// avoided: the writers are trivial, the content getters are the
/// load-bearing surface.
final class ShellIntegrationTests: XCTestCase {
    private static let stubHook = "/usr/local/bin/AgentTerminalHook"

    func testGeminiDefaultsExposesAllFourLifecycleEvents() throws {
        let object = AgentTerminalShellIntegration.geminiDefaultsObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        let expected: [String: String] = [
            "BeforeAgent": "running",
            "AfterAgent": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ]
        for (event, state) in expected {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["type"] as? String, "command")
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' gemini \(state)")
        }
    }

    func testClaudeHooksObjectStaysWiredAfterRefactor() throws {
        let object = AgentTerminalShellIntegration.claudeHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for (event, state) in [
            "UserPromptSubmit": "running",
            "Stop": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' claude \(state)")
        }
    }

    /// Tool-call lifecycle subscriptions added for the activity strip. These
    /// differ from lifecycle hooks: the third command argv preserves the raw
    /// event name (`PreToolUse` / `PostToolUse`) because `main.swift` reads
    /// stdin and routes through `AgentTerminalHookKit.parseToolEventPayload` for
    /// these — not a `HookEvent` rawValue.
    func testClaudeHooksObjectSubscribesToolCallEvents() throws {
        let object = AgentTerminalShellIntegration.claudeHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for event in ["PreToolUse", "PostToolUse"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["type"] as? String, "command")
            // argv[2] = raw Claude event name (not a HookEvent rawValue)
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' claude \(event)")
        }
    }

    /// Regression guard — Gemini wrapper doesn't expose tool-level hooks
    /// (per CLAUDE.md M5.x); its passthroughEvents stays empty. If we ever
    /// add tool events to Gemini, update this test deliberately.
    func testGeminiHooksObjectDoesNotSubscribeToolEvents() throws {
        let object = AgentTerminalShellIntegration.geminiDefaultsObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PostToolUse"])
    }

    func testBracketWrapperPassesThroughWhenSurfaceIdMissing() {
        let script = AgentTerminalShellIntegration.bracketWrapperScript(slug: "amp")

        XCTAssertTrue(script.contains("self_dir"), "must skip own dir on PATH walk")
        XCTAssertTrue(script.contains("\"$AGENTTERMINAL_HOOK_BIN\" amp running"))
        XCTAssertTrue(script.contains("\"$AGENTTERMINAL_HOOK_BIN\" amp ended"))
        XCTAssertTrue(script.contains("agentterminal-agent:amp:running"))
        XCTAssertTrue(script.contains("agentterminal-agent:amp:ended"))
        XCTAssertTrue(script.contains("AGENTTERMINAL_AGENT_MARKERS"))
        XCTAssertTrue(script.contains("2>/dev/null > /dev/tty"), "OSC marker targets the tty (not a redirected agent's stdout), stderr silenced before the open so a missing tty can't leak")
        XCTAssertTrue(script.contains("[[ -n \"$AGENTTERMINAL_AGENT_MARKERS\" ]] && printf"), "marker gated on AGENTTERMINAL_AGENT_MARKERS so local sessions stay socket-only")
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when AGENTTERMINAL_SURFACE_ID is unset")
    }

    func testWrapperPassesThroughForBackgroundPipedCaller() {
        // A background / programmatic caller (a broker spawning the agent to
        // speak JSON-RPC over piped stdin+stdout) is not a session a human is
        // watching. The shared preamble must exec the real binary before any
        // instrumentation runs, so the wrapper never pings AgentTerminalHook.
        let script = AgentTerminalShellIntegration.bracketWrapperScript(slug: "amp")
        XCTAssertTrue(script.contains("if [[ ! -t 0 && ! -t 1 ]]; then"),
                      "preamble must pass through when both stdin and stdout are non-terminals")
    }

    func testCodexWrapperGuardsBackgroundCallBeforeInstrumenting() {
        // The reported hang: a broker spawns `codex app-server` (JSON-RPC over
        // piped stdin+stdout) and `codex:review` freezes. The guard must run
        // before the AgentTerminalHook ping and before the `-c notify` injection (which
        // would alter the codex the broker spawned).
        let script = AgentTerminalShellIntegration.codexWrapperScript
        let guardLine = "if [[ ! -t 0 && ! -t 1 ]]; then"
        XCTAssertTrue(script.contains(guardLine), "codex wrapper must pass through a pipe-driven background call")

        let guardIdx = script.range(of: guardLine)!.lowerBound
        let pingIdx = script.range(of: "\"$AGENTTERMINAL_HOOK_BIN\" codex running")!.lowerBound
        let notifyIdx = script.range(of: "notify=")!.lowerBound
        XCTAssertLessThan(guardIdx, pingIdx, "tty guard must precede the AgentTerminalHook running ping")
        XCTAssertLessThan(guardIdx, notifyIdx, "tty guard must precede the -c notify injection")
    }

    func testAntigravityIDEShimCheckPrecedesTtyPassthrough() {
        // The generic pipe-driven passthrough must NOT run before agy's
        // IDE-launcher rejection — otherwise a background `agy` call (both fds
        // piped) would exec the resolved binary, reopening the GUI the wrapper
        // exists to block. The IDE-shim `case` must come first.
        let script = AgentTerminalShellIntegration.antigravityWrapperScript
        let ideIdx = script.range(of: "*/Antigravity.app/*")!.lowerBound
        let guardIdx = script.range(of: "if [[ ! -t 0 && ! -t 1 ]]; then")!.lowerBound
        XCTAssertLessThan(ideIdx, guardIdx, "IDE-shim rejection must precede the tty passthrough")
    }

    @MainActor
    func testAgentStatusMarkerParsesKnownAgentTitle() throws {
        let parsed = try XCTUnwrap(AgentStatusMarker.parseTitle("agentterminal-agent:codex:attention"))

        XCTAssertEqual(parsed.agent.id, AgentTemplate.codex.id)
        XCTAssertEqual(parsed.event, .attention)
        XCTAssertNil(AgentStatusMarker.parseTitle("agentterminal-agent:not-real:running"))
        XCTAssertNil(AgentStatusMarker.parseTitle("corey@web-prod: ~/srv"))
    }

    func testKimiWrapperBracketsRunningAndEnded() {
        // Kimi's lifecycle hooks are TOML-only with no system-settings
        // override, so it rides the generic bracket wrapper (running before
        // exec, ended after exit) like grok / amp rather than a JSON hooks
        // file. Regression guard for the v0.20.0 wiring.
        let script = AgentTerminalShellIntegration.bracketWrapperScript(slug: "kimi")

        XCTAssertTrue(script.contains("\"$AGENTTERMINAL_HOOK_BIN\" kimi running"))
        XCTAssertTrue(script.contains("\"$AGENTTERMINAL_HOOK_BIN\" kimi ended"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when AGENTTERMINAL_SURFACE_ID is unset")
    }

    func testSshWrapperInjectsRemoteBootstrapForPlainInteractiveLogin() {
        let script = AgentTerminalShellIntegration.sshWrapperScript

        XCTAssertTrue(script.contains("AGENTTERMINAL_DISABLE_SSH_AGENT_MARKERS"))
        XCTAssertTrue(script.contains("! -t 0 || ! -t 1"), "must skip non-interactive ssh transport")
        XCTAssertTrue(script.contains("remote_command="), "must append exactly one remote shell command")
        XCTAssertTrue(script.contains("sh -lc"), "remote command should run through POSIX sh")
        XCTAssertTrue(script.contains("exec \"$real\" -t \"$@\" \"$remote_command\""))
    }

    func testSshWrapperPassesThroughRemoteCommandsAndTransportModes() {
        let script = AgentTerminalShellIntegration.sshWrapperScript

        // A no-remote-shell flag anywhere in a short-option group (e.g. `-fN`
        // in `ssh -fN -L …`) passes through untouched — regression guard for
        // clobbering combined-flag port forwards.
        XCTAssertTrue(script.contains("[NTVGQOW]) exec \"$real\" \"$@\""))
        // An explicit `-o RemoteCommand=…` is the user's own remote command;
        // don't override it with our bootstrap.
        XCTAssertTrue(script.contains("[Rr]emote[Cc]ommand*) exec \"$real\" \"$@\""))
        XCTAssertTrue(script.contains("remote_command_seen=1"))
        XCTAssertTrue(script.contains("if (( ! destination_seen || remote_command_seen )); then"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""))
    }

    func testRemoteAgentBootstrapWritesMarkerWrappers() {
        let script = AgentTerminalShellIntegration.remoteAgentBootstrapScript

        XCTAssertTrue(script.contains(#"_agentterminal_root="${TMPDIR:-/tmp}/agentterminal-agent-markers-"#))
        XCTAssertTrue(script.contains("for _agentterminal_slug in 'claude' 'codex'"))
        // Every builtin agent's binary must flow into the bootstrap (the slug
        // list derives from `builtin`), so a remote launch of any agent —
        // including future ones — emits markers. A new agent silently missing
        // from the SSH bootstrap fails here instead of shipping a dead shim.
        for binary in AgentTemplate.builtin.compactMap(\.initialCommand) {
            XCTAssertTrue(script.contains("'\(binary)'"),
                          "remote bootstrap must include a marker shim for '\(binary)'")
        }
        XCTAssertTrue(script.contains(#"printf '\033]2;agentterminal-agent:%s:running\a'"#))
        XCTAssertTrue(script.contains(#"printf '\033]2;agentterminal-agent:%s:ended\a'"#))
        XCTAssertTrue(script.contains("export AGENTTERMINAL_AGENT_MARKERS=1"))
        XCTAssertTrue(script.contains(#"export PATH="$_agentterminal_bin:$PATH""#))
        XCTAssertTrue(script.contains("> /dev/tty"), "remote markers must target the tty, not the agent's redirected stdout")
        XCTAssertTrue(script.contains("export HISTFILE="), "remote zsh must reset HISTFILE off the ephemeral ZDOTDIR (else remote history is rm -rf'd on logout)")
    }

    func testAntigravityWrapperGuardsAgainstIDEShim() {
        // Antigravity 2.0 IDE installs a launcher also called `agy` that
        // symlinks into `/Applications/Antigravity.app/...`. Without
        // detection, an IDE-only-installed user picking "Antigravity CLI"
        // from `+` would accidentally open the GUI app.
        let script = AgentTerminalShellIntegration.antigravityWrapperScript

        XCTAssertTrue(script.contains("readlink \"$real\""), "must resolve symlink one hop")
        XCTAssertTrue(script.contains("*/Antigravity.app/*"), "must match IDE launcher resolved path")
        XCTAssertTrue(script.contains("antigravity.google/cli/install.sh"), "must surface CLI install command")
        XCTAssertTrue(script.contains("\"$AGENTTERMINAL_HOOK_BIN\" agy ended"), "must revert tab icon on shim-detection bail")
        XCTAssertTrue(script.contains("exit 127"), "must mirror preamble's not-installed exit code")
    }

    func testAntigravityWrapperBracketsRunningAndEndedForRealCLI() {
        let script = AgentTerminalShellIntegration.antigravityWrapperScript

        XCTAssertTrue(script.contains("\"$AGENTTERMINAL_HOOK_BIN\" agy running"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when AGENTTERMINAL_SURFACE_ID is unset")
    }

    func testOpencodePluginShellsOutToHookBinForBothEvents() {
        let body = AgentTerminalShellIntegration.opencodePluginScript

        XCTAssertTrue(body.contains("chat.message"), "plugin must subscribe to per-prompt event")
        XCTAssertTrue(body.contains("session.idle"), "plugin must subscribe to turn-end event")
        XCTAssertTrue(body.contains(#"ping("running")"#))
        XCTAssertTrue(body.contains(#"ping("attention")"#))
        XCTAssertTrue(body.contains("opencode"), "plugin must pass agent slug to AgentTerminalHook")
        XCTAssertTrue(body.contains("AGENTTERMINAL_SURFACE_ID"))
        XCTAssertTrue(body.contains("agentterminal-managed-do-not-edit"), "plugin must carry the upgrade-safety marker")
    }

    func testPiExtensionSubscribesLifecycleEventsAndPingsHook() {
        let body = AgentTerminalShellIntegration.piExtensionScript

        // Subscribes to pi's session / turn lifecycle and maps each to a
        // AgentTerminalHook state — running while a turn runs, attention when it ends.
        XCTAssertTrue(body.contains("session_start"))
        XCTAssertTrue(body.contains("turn_start"))
        XCTAssertTrue(body.contains("turn_end"))
        XCTAssertTrue(body.contains("session_shutdown"))
        XCTAssertTrue(body.contains(#"ping("running")"#))
        XCTAssertTrue(body.contains(#"ping("attention")"#))
        XCTAssertTrue(body.contains(#"ping("ended")"#))
        XCTAssertTrue(body.contains(#"pi.exec(hookBin, ["pi""#), "must ping AgentTerminalHook with the pi slug")
        // Reports the session id so agentterminal can resume (`pi --session <id>`).
        XCTAssertTrue(body.contains("getSessionFile"), "must read pi's current session file")
        XCTAssertTrue(body.contains(#"["pi", "conversation", id]"#), "must report the session id for resume")
        XCTAssertTrue(body.contains("AGENTTERMINAL_SURFACE_ID"))
        XCTAssertTrue(body.contains("AGENTTERMINAL_HOOK_BIN"))
        XCTAssertTrue(body.contains("agentterminal-managed-do-not-edit"), "must carry the upgrade-safety marker")
    }

    func testPiExtensionReportsToolCallsForActivityPill() {
        let body = AgentTerminalShellIntegration.piExtensionScript
        // Subscribes to pi's tool lifecycle and relays each to AgentTerminalHook's
        // `tool` argv branch (pre carries the identifier, post the ok/fail).
        XCTAssertTrue(body.contains("tool_execution_start"))
        XCTAssertTrue(body.contains("tool_execution_end"))
        XCTAssertTrue(body.contains(#"["pi", "tool", "pre""#), "pre must report the identifier")
        XCTAssertTrue(body.contains(#"["pi", "tool", "post""#), "post must report the result")
        XCTAssertTrue(body.contains("event.toolCallId"), "must thread pi's toolCallId for Pre/Post matching")
        XCTAssertTrue(body.contains(#"event.isError ? "fail" : "ok""#), "post maps isError → ok/fail")
        // identifier extraction uses pi's arg keys (`path`, not Claude's
        // `file_path`) and lowercase tool names.
        XCTAssertTrue(body.contains("toolIdentifier"))
        XCTAssertTrue(body.contains("args.command"))
        XCTAssertTrue(body.contains("args.path"))
        XCTAssertTrue(body.contains("args.pattern"))
    }

    func testAgentLaunchBlockRevertsIconAfterAgentReturns() {
        let block = AgentTerminalShellIntegration.agentLaunchBlock
        // The eagerly-promoted tab/sidebar icon must revert when the foreground
        // agent exits — or never started, e.g. a user alias shadowing the PATH
        // wrapper so its own `ended` ping never fires.
        XCTAssertTrue(block.contains("eval \"$_agentterminal_cmd\""))
        XCTAssertTrue(block.contains(#"_agentterminal_agent_bin="${_agentterminal_cmd%% *}""#), "must derive the agent binary for the revert ping")
        XCTAssertTrue(block.contains(#""$AGENTTERMINAL_HOOK_BIN" "$_agentterminal_agent_bin" ended"#), "must ping ended after the agent returns")
        // The revert ping must not clobber the agent's exit code — capture it
        // before, restore it after, so the first prompt's `$?` is the agent's.
        XCTAssertTrue(block.contains("_agentterminal_status=$?"), "must capture the agent exit status before the revert ping")
        XCTAssertTrue(block.contains("( exit $_agentterminal_status )"), "must restore the agent exit status after the ping")
    }

    func testEnvStatusBlockReportsLiveShellEnvironment() {
        let body = AgentTerminalShellIntegration.envStatusBlock

        XCTAssertTrue(body.contains("\"$AGENTTERMINAL_HOOK_BIN\" env"))
        XCTAssertTrue(body.contains(#""${VIRTUAL_ENV:-}""#))
        XCTAssertTrue(body.contains(#""${CONDA_DEFAULT_ENV:-}""#))
        XCTAssertTrue(body.contains(#""${NVM_BIN:-}""#))
        XCTAssertTrue(body.contains(#""${NVM_DIR:-}""#))
        XCTAssertTrue(body.contains("--version"), "must invoke node --version")
        XCTAssertTrue(body.contains("_AGENTTERMINAL_NODE_KEY_LAST"), "must memoize node version against path+NVM_BIN")
        XCTAssertTrue(body.contains("_AGENTTERMINAL_ENV_LAST"), "must skip the agentterminal-hook IPC when env unchanged")
    }

    @MainActor
    func testHookServerParsesAgentPayload() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "agent": "claude",
            "event": "running",
            "surface": id.uuidString,
        ])

        guard case .agent(let agent, let event, let sessionId) = HookServer.parseMessage(data) else {
            return XCTFail("expected agent hook message")
        }
        XCTAssertEqual(agent, .claudeCode)
        XCTAssertEqual(event, .running)
        XCTAssertEqual(sessionId, id)
    }

    @MainActor
    func testHookServerParsesShellEnvironmentPayload() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "env",
            "surface": id.uuidString,
            "VIRTUAL_ENV": "/tmp/app/.venv",
            "CONDA_DEFAULT_ENV": "",
            "NVM_BIN": "/Users/corey/.nvm/versions/node/v20.1.0/bin",
            "NVM_DIR": "/Users/corey/.nvm",
            "AGENTTERMINAL_NODE_VERSION": "v20.1.0",
        ])

        guard case .shellEnvironment(let env, let sessionId) = HookServer.parseMessage(data) else {
            return XCTFail("expected shell environment hook message")
        }
        XCTAssertEqual(sessionId, id)
        XCTAssertEqual(env["VIRTUAL_ENV"], "/tmp/app/.venv")
        XCTAssertEqual(env["NVM_BIN"], "/Users/corey/.nvm/versions/node/v20.1.0/bin")
        XCTAssertEqual(env["NVM_DIR"], "/Users/corey/.nvm")
        XCTAssertEqual(env["AGENTTERMINAL_NODE_VERSION"], "v20.1.0")
    }

    func testBackslashEscapeLeavesPlainPathUntouched() {
        XCTAssertEqual(AgentTerminalShellIntegration.backslashEscape("/Users/corey/file.txt"), "/Users/corey/file.txt")
    }

    func testBackslashEscapeEscapesSpaceAndQuoteAndDollar() {
        XCTAssertEqual(
            AgentTerminalShellIntegration.backslashEscape("/Users/corey/My Folder/don't $cost"),
            #"/Users/corey/My\ Folder/don\'t\ \$cost"#
        )
    }

    func testBackslashEscapePassesThroughNonAscii() {
        // Chinese / emoji filenames are common on macOS; shells accept raw
        // UTF-8 so we don't escape them.
        XCTAssertEqual(AgentTerminalShellIntegration.backslashEscape("/tmp/项目/🚀.md"), "/tmp/项目/🚀.md")
    }

    func testClaudeCustomSettingsObjectCarriesHooksAndEnv() throws {
        let object = AgentTerminalShellIntegration.claudeCustomSettingsObject(
            env: ["ANTHROPIC_BASE_URL": "https://mirror.example.com"],
            hookCmd: Self.stubHook
        )
        // The env block Claude reads natively for the custom endpoint / key.
        let env = try XCTUnwrap(object["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://mirror.example.com")
        // Hooks must ride along — the per-agent file is the only settings
        // file passed to that session, so agentterminal's activity hooks have to be
        // in it too, not just the env block.
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' claude running")
    }

    func testBackslashEscapeFallsBackToQuoteOnNewlineToAvoidLineContinuation() {
        // POSIX: `\<newline>` is line continuation and gets dropped — so a
        // legitimate macOS filename containing `\n` would be silently
        // corrupted by the plain backslash-escape path. Codex P3 fix
        // (v0.11.3): fall back to single-quote wrap, which preserves the
        // literal newline.
        let escaped = AgentTerminalShellIntegration.backslashEscape("/tmp/multi\nline/file.txt")
        XCTAssertEqual(escaped, "'/tmp/multi\nline/file.txt'")
    }

    // MARK: - readTerminalPasteText / pasteboardHasTerminalPasteContent

    /// Create an isolated pasteboard so tests never touch `.general` or
    /// each other. `NSPasteboard(name:)` with a unique name returns a
    /// process-private board that AppKit cleans up on exit.
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let unique = "agentterminal-test-\(UUID().uuidString)"
        return NSPasteboard(name: NSPasteboard.Name(unique))
    }

    /// 1×1 transparent PNG — small valid PNG to exercise the image-spill path.
    private static let oneByOnePNG: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIA" +
        "AAoAAv/lxKUAAAAASUVORK5CYII="
    )!

    func testReadTerminalPasteTextReturnsRawStringForPlainText() {
        // String paste is the common case (Cmd+V on a shell command).
        // No backslash-escaping — `ls -la` must round-trip verbatim.
        let pb = makeIsolatedPasteboard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("ls -la", forType: .string)
        XCTAssertEqual(AgentTerminalShellIntegration.readTerminalPasteText(from: pb), "ls -la")
    }

    func testReadTerminalPasteTextReturnsEscapedPathForFileURL() {
        // Finder Copy on a file (including images) gives a fileURL on the
        // pasteboard. We backslash-escape the full disk path so the
        // shell / agent receives an addressable argument — not the bare
        // filename that `.string` would return.
        let pb = makeIsolatedPasteboard()
        let url = URL(fileURLWithPath: "/tmp/some folder/image one.png")
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        XCTAssertEqual(
            AgentTerminalShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/some\\ folder/image\\ one.png"
        )
    }

    func testReadTerminalPasteTextJoinsMultipleFileURLsWithSpace() {
        let pb = makeIsolatedPasteboard()
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])
        XCTAssertEqual(
            AgentTerminalShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/a.png /tmp/b.png"
        )
    }

    func testReadTerminalPasteTextSpillsPNGImageDataToCacheFile() throws {
        // Cmd+Ctrl+Shift+4 screenshots show up as raw PNG bytes with no
        // fileURL representation. Without spill-to-disk the agent has no
        // way to read the image — we cache it under
        // ~/Library/Caches/agentterminal/pastes/screenshot-*.png and paste the
        // escaped file path.
        let pb = makeIsolatedPasteboard()
        pb.declareTypes([.png], owner: nil)
        pb.setData(Self.oneByOnePNG, forType: .png)
        let pasted = try XCTUnwrap(AgentTerminalShellIntegration.readTerminalPasteText(from: pb))
        // Resolve the escape so we can `stat` the file.
        let rawPath = pasted.replacingOccurrences(of: "\\", with: "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawPath),
            "Expected pasted path to point at a real file on disk: \(rawPath)"
        )
        XCTAssertTrue(rawPath.contains("/agentterminal/pastes/screenshot-"))
        XCTAssertTrue(rawPath.hasSuffix(".png"))
        try? FileManager.default.removeItem(atPath: rawPath)
    }

    func testReadTerminalPasteTextSpillsTIFFImageDataAsPNG() throws {
        // Cmd+Shift+3 (full-screen-to-clipboard) and Preview "Copy" land
        // as TIFF on the pasteboard, not PNG — the TIFF→PNG re-encode
        // branch is the actual screenshot hot path. Without coverage
        // this can regress silently if someone tweaks the helper.
        let pb = makeIsolatedPasteboard()
        // Synthesise a 1×1 TIFF via NSBitmapImageRep so we exercise the
        // re-encode branch without bundling a binary fixture.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        )!
        let tiffData = try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))
        pb.declareTypes([.tiff], owner: nil)
        pb.setData(tiffData, forType: .tiff)
        let pasted = try XCTUnwrap(AgentTerminalShellIntegration.readTerminalPasteText(from: pb))
        let rawPath = pasted.replacingOccurrences(of: "\\", with: "")
        XCTAssertTrue(rawPath.hasSuffix(".png"))
        // Confirm we actually wrote PNG bytes (not TIFF with a .png suffix).
        let cached = try XCTUnwrap(FileManager.default.contents(atPath: rawPath))
        XCTAssertNotNil(NSBitmapImageRep(data: cached), "Cached file should parse as a bitmap image")
        let magic = cached.prefix(8)
        XCTAssertEqual(
            Array(magic),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "Cached file should have a PNG magic header, not TIFF"
        )
        try? FileManager.default.removeItem(atPath: rawPath)
    }

    func testReadTerminalPasteTextPrefersFileURLOverImageData() {
        // Finder Copy on an image populates both fileURL and TIFF/PNG.
        // fileURL must win — the user already has a real file on disk;
        // re-spilling the bytes to a cache file loses provenance + bloats
        // ~/Library/Caches.
        let pb = makeIsolatedPasteboard()
        let url = URL(fileURLWithPath: "/tmp/real-image.png")
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setData(Self.oneByOnePNG, forType: .png)
        XCTAssertEqual(
            AgentTerminalShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/real-image.png"
        )
    }

    func testReadTerminalPasteTextReturnsNilForEmptyPasteboard() {
        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        XCTAssertNil(AgentTerminalShellIntegration.readTerminalPasteText(from: pb))
    }

    func testPasteboardHasTerminalPasteContentMatchesReadability() {
        // Gate must agree with `readTerminalPasteText` so the right-click
        // Paste menu enables exactly when the action will produce input.
        let emptyPb = makeIsolatedPasteboard()
        emptyPb.clearContents()
        XCTAssertFalse(AgentTerminalShellIntegration.pasteboardHasTerminalPasteContent(emptyPb))

        let stringPb = makeIsolatedPasteboard()
        stringPb.declareTypes([.string], owner: nil)
        stringPb.setString("x", forType: .string)
        XCTAssertTrue(AgentTerminalShellIntegration.pasteboardHasTerminalPasteContent(stringPb))

        let filePb = makeIsolatedPasteboard()
        filePb.clearContents()
        filePb.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertTrue(AgentTerminalShellIntegration.pasteboardHasTerminalPasteContent(filePb))

        let imagePb = makeIsolatedPasteboard()
        imagePb.declareTypes([.png], owner: nil)
        imagePb.setData(Self.oneByOnePNG, forType: .png)
        XCTAssertTrue(AgentTerminalShellIntegration.pasteboardHasTerminalPasteContent(imagePb))
    }
}
