import AppKit
import Foundation
import SwiftUI

/// A named profile that turns into a `TerminalSessionConfig` when the user
/// picks it from the "+" menu. The shell starts under our wrapper `.zshrc`
/// (AgentTerminalShellIntegration), which sources the user's config, then — if
/// `AGENTTERMINAL_AGENT` is set — invokes the agent inline. The user never sees the
/// shell prompt or the command echo, and on agent exit they land in a clean
/// shell prompt with their full PATH/aliases intact.
struct AgentTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    /// SF Symbol used when `iconAsset` is nil or fails to load.
    let symbol: String
    /// Filename (without extension) of a bundled PNG in `Resources/Icons/`.
    /// Sourced from github.com/lobehub/lobe-icons (MIT).
    let iconAsset: String?
    /// Brand-derived hue used for compact indicators (sidebar status pips).
    /// Picked from each lobe-icon's dominant fill so a row's pip group reads as
    /// the same family of marks shown elsewhere. sRGB hex.
    let tintHex: String?
    let initialCommand: String?
    /// For custom templates only — snapshot of `CustomAgentData.baseAgentId`
    /// taken at `fromCustom` time. Nil for builtins. Lives on the template
    /// (not on Session) because the wrapper-end revert in `applyHookEvent`
    /// must use the value present when the session *started*, not whatever
    /// the user has since changed in Settings → Agents (a mid-run
    /// edit/delete would otherwise leave the tab stuck in the custom-agent
    /// state forever).
    let baseAgentId: String?
    /// CLI flag the agent's binary expects when receiving a prompt argument.
    /// Nil = positional (`claude "<prompt>"`, the most common shape). Agents
    /// that need a flag set it on their builtin definition below — see the
    /// Copilot / Amp wirings. Drives the right-click "Ask <agent>" launch
    /// path via `makeSessionConfig(initialPrompt:)`. Templates with
    /// `initialCommand == nil` (Terminal) ignore this entirely.
    let promptLaunchFlag: String?
    /// CLI flag the agent's binary expects to resume a prior conversation.
    /// Nil = no resume support (agentterminal doesn't have an id-capture path for
    /// this agent yet). Claude Code = `--resume`; Grok = `--session`. Drives
    /// `makeSessionConfig(resumeId:)` and `supportsResume`.
    let resumeFlag: String?
    /// True when the agent feeds agentterminal per-tool-call activity — Claude via
    /// its `--settings` hooks (`PreToolUse` / `PostToolUse`), Pi via its
    /// extension's `tool_execution_start` / `_end` events. Drives the
    /// status-bar tool-call activity pill (`sessionWantsToolCallActivity`).
    /// Builtins set it explicitly; `fromCustom` inherits the base's value so
    /// a Claude-/Pi-based custom agent gets the pill too. Off for shells and
    /// agents without a tool feed (the pill simply never appears).
    let reportsToolCalls: Bool
    /// Environment the agent launches with — populated only for custom
    /// agents (`parseEnv(CustomAgentData.env)` in `fromCustom`); builtins
    /// are `[:]`. Snapshot-frozen at `fromCustom` like `baseAgentId`. v1
    /// consumes it for Claude-Code-based customs — `spawnSession` writes
    /// it into a per-agent Claude settings file.
    let extraEnv: [String: String]
    /// Pinned initial working directory snapshotted from `TerminalPreset.path`
    /// in `fromTerminalPreset`. Nil for builtins and customs. When set,
    /// `WorkspaceStore.addTab` uses it instead of the workspace cwd unless
    /// the caller passes an explicit `initialCwd` (right-click "Ask <agent>",
    /// `reopenLastClosedTab`). `~/` is expanded; a missing path falls back
    /// to `$HOME` via `resolvedSpawnCwd`.
    let extraCwd: String?
    /// Additional arguments to pass to the agent command.
    let args: [String]

    /// True when this template launches a plain shell instead of an agent
    /// binary. Covers the default `.terminal` and every materialised
    /// `TerminalPreset`. Use this rather than `id == "terminal"` checks at
    /// call sites that need to distinguish shells from agents (the Ask-
    /// <agent> right-click, the "based on" Picker, etc.) — once presets
    /// exist there are many shell templates, not one.
    var isShell: Bool { initialCommand == nil }

    init(
        id: String,
        title: String,
        symbol: String,
        iconAsset: String?,
        tintHex: String?,
        initialCommand: String?,
        baseAgentId: String? = nil,
        promptLaunchFlag: String? = nil,
        resumeFlag: String? = nil,
        reportsToolCalls: Bool = false,
        extraEnv: [String: String] = [:],
        extraCwd: String? = nil,
        args: [String] = []
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.iconAsset = iconAsset
        self.tintHex = tintHex
        self.initialCommand = initialCommand
        self.baseAgentId = baseAgentId
        self.promptLaunchFlag = promptLaunchFlag
        self.resumeFlag = resumeFlag
        self.reportsToolCalls = reportsToolCalls
        self.extraEnv = extraEnv
        self.extraCwd = extraCwd
        self.args = args
    }

    var tint: Color? {
        tintHex.flatMap(Color.init(hex:))
    }

    /// `extraOptions` is appended after `initialCommand` (space-separated)
    /// when forming `AGENTTERMINAL_AGENT`. The wrapper rc's `eval` splits on
    /// whitespace, so the caller handles its own quoting for tokens that
    /// contain spaces.
    ///
    /// `resumeId`, when present and the template declares a `resumeFlag`,
    /// prepends `<resumeFlag> <id>` to the launch command so the new tab
    /// continues an existing conversation. Other agents leave `resumeFlag`
    /// nil — their CLIs accept resume flags syntactically, but the
    /// id-capture path (a hook payload carrying the session id) is not
    /// implemented for them yet.
    ///
    /// `initialPrompt`, when non-empty, drives the right-click "Ask <agent>"
    /// path: the prompt is POSIX-quoted and inserted into `AGENTTERMINAL_AGENT` as
    /// the first argv after the binary name (or after `promptLaunchFlag`
    /// when that's set — Copilot's `-p`, Amp's `-x`). Mutually exclusive
    /// with `resumeId` — asking a fresh question shouldn't graft onto a
    /// stale conversation, so `initialPrompt` wins and `resumeId` is
    /// silently dropped when both are supplied.
    func makeSessionConfig(
        extraOptions: String? = nil,
        resumeId: String? = nil,
        initialPrompt: String? = nil
    ) -> TerminalSessionConfig {
        // Pick a shell that has a agentterminal integration wrapper. Plain terminal
        // sessions respect $SHELL where we have a wrapper (zsh/bash); other
        // shells (fish/nu/...) get $SHELL too, just without cwd tracking.
        // Agent sessions force a wrapped shell so AGENTTERMINAL_AGENT auto-launch
        // works — `.other` users get zsh as a working fallback.
        var config: TerminalSessionConfig
        switch (AgentTerminalShellIntegration.detectedUserShell, initialCommand) {
        case (.bash, _):
            config = .bashShell(launcher: AgentTerminalShellIntegration.bashLauncherPath)
        case (.zsh, _):
            config = .zshShell()
        case (.other, .none):
            config = .defaultShell()
        case (.other, .some):
            config = .zshShell()
        }
        if let initialCommand {
            let trimmedExtras = extraOptions?.trimmingCharacters(in: .whitespaces) ?? ""
            let trimmedPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Resume flag goes between binary name and options
            // (`claude --resume <id> --model opus`) — each CLI takes it as
            // a positional argument to its top-level command; appending
            // after extras would still work but reads worse in `ps`.
            // Suppressed when `initialPrompt` is present — "Ask <agent>"
            // is a fresh question, not a continuation.
            var resumeFragment = ""
            if trimmedPrompt.isEmpty, let flag = resumeFlag, let id = resumeId, !id.isEmpty {
                resumeFragment = " \(flag) \(id)"
            }
            var promptFragment = ""
            if !trimmedPrompt.isEmpty {
                let quoted = AgentTerminalShellIntegration.quote(trimmedPrompt)
                if let flag = promptLaunchFlag {
                    promptFragment = " \(flag) \(quoted)"
                } else {
                    // POSIX `--` separator stops the CLI's argparse from
                    // treating a prompt that starts with `-` as a flag.
                    // Right-clicking `ls -la` output and asking Codex /
                    // Claude would otherwise hit "unexpected argument
                    // '-rw-r--r--@...'" on the first dashed line.
                    promptFragment = " -- \(quoted)"
                }
            }
            let extrasFragment = trimmedExtras.isEmpty ? "" : " \(trimmedExtras)"
            config.environment["AGENTTERMINAL_AGENT"] = "\(initialCommand)\(resumeFragment)\(promptFragment)\(extrasFragment)"
        }
        return config
    }

    var supportsResume: Bool {
        resumeFlag != nil
    }

    /// Parses a `.env`-style block — one `KEY=VALUE` per line — into a
    /// dictionary. Blank lines and `#` comment lines are skipped, a leading
    /// `export` keyword is dropped (so a block pasted from `.zshrc` works),
    /// and the split is on the *first* `=` so values may contain `=`. A value
    /// wrapped in one matching pair of quotes is unwrapped. Keys that aren't
    /// valid shell identifiers are dropped, as are `AGENTTERMINAL_`-prefixed keys —
    /// letting a custom agent set `AGENTTERMINAL_SURFACE_ID` would misroute hook pings.
    static func parseEnv(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        // `\.isNewline` splits LF / CR / CRLF alike — `split(separator: "\n")`
        // misses the `\n` inside the `\r\n` grapheme cluster and would
        // collapse a CRLF block (Windows editor, web copy) into one bad value.
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("export"),
               let separator = trimmed.dropFirst("export".count).first, separator.isWhitespace {
                trimmed = String(trimmed.dropFirst("export".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidEnvKey(key) else { continue }
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, value.last == first,
               first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    /// `^[A-Za-z_][A-Za-z0-9_]*$`, and not agentterminal-internal (`AGENTTERMINAL_` prefix).
    private static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first, !key.hasPrefix("AGENTTERMINAL_") else { return false }
        guard first == "_" || (first.isASCII && first.isLetter) else { return false }
        return key.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }
}

extension AgentTemplate {
    /// The builtin Claude Code agent id. Call sites that gate Claude-
    /// specific behaviour (the custom-agent env block) compare against this
    /// rather than a bare `"claude-code"` literal.
    static let claudeCodeID = "claude-code"

    static let terminal = AgentTemplate(
        id: "terminal",
        title: "Terminal",
        symbol: "terminal",
        iconAsset: nil,
        tintHex: nil,
        initialCommand: nil
    )

    static let claudeCode = AgentTemplate(
        id: claudeCodeID,
        title: "Claude Code",
        symbol: "sparkle",
        iconAsset: "claudecode",
        tintHex: "D97757",
        initialCommand: "claude",
        resumeFlag: "--resume",
        reportsToolCalls: true
    )

    static let codex = AgentTemplate(
        id: "codex",
        title: "Codex",
        symbol: "chevron.left.forwardslash.chevron.right",
        iconAsset: "codex",
        tintHex: "7A9DFF",
        initialCommand: "codex"
    )

    static let gemini = AgentTemplate(
        id: "gemini",
        title: "Gemini CLI",
        symbol: "diamond",
        iconAsset: "gemini",
        tintHex: "3186FF",
        initialCommand: "gemini"
    )

    static let opencode = AgentTemplate(
        id: "opencode",
        title: "OpenCode",
        symbol: "curlybraces",
        iconAsset: "opencode",
        tintHex: "B0B0B0",
        initialCommand: "opencode"
    )

    static let amp = AgentTemplate(
        id: "amp",
        title: "Amp",
        symbol: "bolt.fill",
        iconAsset: "amp",
        tintHex: "E8B168",
        initialCommand: "amp",
        promptLaunchFlag: "-x"
    )

    static let cursor = AgentTemplate(
        id: "cursor",
        title: "Cursor CLI",
        symbol: "cube",
        iconAsset: "cursor",
        tintHex: "F54E00",
        initialCommand: "cursor-agent"
    )

    static let copilot = AgentTemplate(
        id: "copilot",
        title: "Copilot CLI",
        symbol: "hexagon.fill",
        iconAsset: "githubcopilot",
        tintHex: "6E40C9",
        initialCommand: "copilot",
        promptLaunchFlag: "-p"
    )

    static let grok = AgentTemplate(
        id: "grok",
        title: "Grok Build",
        symbol: "x.square.fill",
        iconAsset: "grok",
        tintHex: "E8E8E8",
        initialCommand: "grok"
    )

    /// Antigravity CLI — Google's Go-based successor to Gemini CLI; binary
    /// `agy`. The `.gemini` template stays in `builtin` alongside this one
    /// until 2026-06-18 when free/Pro access to Gemini CLI sunsets;
    /// Enterprise (Code Assist Standard/Enterprise) retains the old CLI.
    ///
    /// Naming-conflict footgun: Antigravity 2.0 IDE installs a VS-Code-
    /// style launcher *also* called `agy` at
    /// `~/.antigravity/antigravity/bin/agy`. With only the IDE installed,
    /// `agy` opens the GUI. The CLI installer puts its `agy` in
    /// `~/.local/bin/` (earlier on PATH), so installing the CLI resolves
    /// the conflict.
    ///
    /// `-i` (`--prompt-interactive`) is the right flag for Ask <agent>:
    /// runs the initial prompt and keeps the session alive. `-p`
    /// (`--print`) would single-shot exit.
    ///
    /// Resume / mid-run attention dot deferred: Antigravity has hooks
    /// (SessionStart / UserPromptSubmit / Stop per third-party docs) and
    /// `--conversation <id>`, but the JSON schema, settings-file location,
    /// and a system-inject env var (no `ANTIGRAVITY_CLI_SYSTEM_SETTINGS_PATH`
    /// analogue of Gemini's) are all undocumented. Revisit when
    /// antigravity.google/docs/hooks publishes the schema.
    static let antigravity = AgentTemplate(
        id: "antigravity",
        title: "Antigravity CLI",
        symbol: "arrow.up.circle.fill",
        iconAsset: "antigravity",
        tintHex: "4285F4",
        initialCommand: "agy",
        promptLaunchFlag: "-i"
    )

    /// Kimi Code — Moonshot AI's coding CLI; binary `kimi` (npm
    /// `@moonshot-ai/kimi-code`). Bracket wrapper only: Kimi ships a
    /// Claude-style lifecycle-hook system, but declares it in TOML
    /// (`~/.kimi-code/config.toml` `[[hooks]]`) with no system-settings
    /// env-var override (no `GEMINI_CLI_SYSTEM_SETTINGS_PATH` analogue), so
    /// agentterminal can't inject hooks non-invasively the way it does for
    /// Claude / Gemini. running/ended come from the wrapper; mid-run
    /// attention + tool-call pills are deferred until that TOML-merge path
    /// is built.
    ///
    /// `-p` (`--prompt`) is Kimi's only prompt-passing flag and is
    /// non-interactive (streams the answer to stdout, then exits) — there's
    /// no interactive-with-prompt flag like Antigravity's `-i`, so
    /// "Ask Kimi" single-shots rather than seeding a live session. Resume
    /// (`--session` / `--continue`) stays unwired: like every non-Claude
    /// agent, agentterminal has no id-capture path yet, so `resumeFlag` is nil.
    static let kimi = AgentTemplate(
        id: "kimi",
        title: "Kimi Code",
        symbol: "moon.fill",
        iconAsset: "kimi",
        tintHex: "C9C3D6",
        initialCommand: "kimi",
        promptLaunchFlag: "-p"
    )

    /// Pi — Earendil's minimal terminal coding harness; binary `pi` (npm
    /// `@earendil-works/pi-coding-agent`). No JSON lifecycle hooks, but pi
    /// auto-loads TypeScript extensions with a rich event API, so agentterminal ships a
    /// managed `~/.pi/agent/extensions/agentterminal.ts` (see `piExtensionScript`) that
    /// maps pi's session / turn events to running / attention / ended (same
    /// model as the OpenCode plugin) AND reports the session id back so resume
    /// works (below). The bracket wrapper stays as the running/ended fallback +
    /// not-installed message.
    ///
    /// `-p` is pi's one-off non-interactive prompt (streams output then exits),
    /// so "Ask Pi" single-shots rather than seeding a live session. Resume IS
    /// wired: pi takes a launch-time `--session <id>` (`resumeFlag`), and the
    /// extension hands agentterminal the current session id via
    /// `agentterminal-hook pi conversation <id>` — that reuses the generic
    /// `conversationId` path (persist on `Session` → prepend `--session <id>`
    /// next launch, gated by `agents.resumeConversations`), so the end result
    /// matches Claude's `--resume` without any Claude-specific JSON parsing.
    /// Model selection (`/model`) stays mid-session. The blocky π logo is
    /// monochrome (single fill, white-on-transparent) → registered in
    /// `AgentIcon.monochromeAssets` so it adapts to light themes.
    static let pi = AgentTemplate(
        id: "pi",
        title: "Pi",
        symbol: "pi",
        iconAsset: "pi",
        tintHex: "C2C5CE",
        initialCommand: "pi",
        promptLaunchFlag: "-p",
        resumeFlag: "--session",
        reportsToolCalls: true
    )

    /// Kiro CLI — AWS's agentic coding CLI, the terminal sibling of the Kiro
    /// IDE; binary `kiro-cli` (curl-installed into `~/.local/bin`). We wrap
    /// `kiro-cli`, NOT `kiro`: the bare `kiro` command launches the Kiro IDE
    /// (a VS Code fork), so shimming it would hijack the editor — the distinct
    /// binary name means no readlink guard is needed (unlike Antigravity's
    /// `agy`). Bracket wrapper only: Kiro's hooks are context-injection
    /// ("pre/post command" context fed to the model), not lifecycle events
    /// agentterminal can map to attention, so the dot comes from the wrapper's
    /// running/ended.
    ///
    /// Prompt is positional (`kiro-cli -- "<prompt>"`) — `kiro-cli` with no
    /// subcommand defaults to `kiro-cli chat`, which takes the prompt as its
    /// first positional. (`--no-interactive` exists but single-shots like
    /// Kimi's `-p`, so it's not used for Ask.) Resume stays unwired: Kiro has
    /// `--resume` / `--resume-id <id>`, but like every non-Claude/Pi agent
    /// agentterminal has no id-capture path, so `resumeFlag` is nil. The lobe-icon is
    /// the full-color brand mark (purple tile + white ghost), rendered as-is on
    /// every theme like the codex / gemini / amp / antigravity marks — so it's
    /// deliberately NOT in `AgentIcon.monochromeAssets`; `tintHex: "9046FF"`
    /// (brand purple) drives the sidebar pip.
    static let kiro = AgentTemplate(
        id: "kiro",
        title: "Kiro CLI",
        symbol: "cloud.fill",
        iconAsset: "kiro",
        tintHex: "9046FF",
        initialCommand: "kiro-cli"
    )

    /// MimoCode — AI coding assistant; binary `mimo`. Bracket wrapper with
    /// OSC 9/99/777 status detection. Supports resume via `--resume` flag.
    /// Reports tool calls for activity tracking.
    static let mimocode = AgentTemplate(
        id: "mimocode",
        title: "MimoCode",
        symbol: "sparkles",
        iconAsset: "mimocode",
        tintHex: "FF6B6B",
        initialCommand: "mimo",
        resumeFlag: "--resume",
        reportsToolCalls: true,
        args: ["--agent"]
    )

    /// The 14 templates shipped with AgentTerminal. User-defined custom agents are
    /// merged on top via `all` at runtime.
    static let builtin: [AgentTemplate] = [.terminal, .claudeCode, .codex, .gemini, .opencode, .amp, .cursor, .copilot, .grok, .antigravity, .kimi, .pi, .kiro, .mimocode]

    /// All templates available right now — `builtin` plus the user's custom
    /// agents from Settings → Agents. MainActor-isolated because it
    /// reads `AgentTerminalSettingsModel.shared` to materialise custom entries.
    @MainActor
    static var all: [AgentTemplate] {
        builtin + AgentTerminalSettingsModel.shared.customAgents.map(AgentTemplate.fromCustom)
    }

    /// Looks up a template by the slug an agent's hook system reports — the
    /// same string as the template's `initialCommand` (the binary name the
    /// user types). Returns nil for unknown slugs. MainActor because it
    /// pulls the live `all` (built-in + custom).
    @MainActor
    static func from(hookSlug: String) -> AgentTemplate? {
        all.first { $0.initialCommand == hookSlug }
    }

    /// All non-terminal templates resolved against the user's saved order.
    /// Templates absent from `model.agentOrder` (typically: a fresh agentterminal
    /// install, or an agent shipped in a newer version) are appended in
    /// their `AgentTemplate.all` position so nothing silently disappears.
    @MainActor
    static func ordered(model: AgentTerminalSettingsModel) -> [AgentTemplate] {
        // Filter by exact terminal id, NOT `!isShell`: this list backs
        // `AgentReorderList.rows` (Settings → Agents), which must keep
        // half-configured customs (initialCommand still nil) visible so
        // the user can finish editing them. `visibleOrdered` does the
        // `initialCommand != nil` gate downstream for the `+` menu.
        let nonTerminal = all.filter { $0.id != AgentTemplate.terminal.id }
        // Use `uniquingKeysWith` so a hand-edited settings.json that puts a
        // custom agent on a builtin id (or two customs on the same id) lands
        // on the first occurrence instead of crashing the launcher. Builtin
        // entries are appended first in `all`, so they win the tie.
        let byId = Dictionary(nonTerminal.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let userOrderIds = model.agentOrder.filter { byId.keys.contains($0) }
        let userOrderSet = Set(userOrderIds)
        let missing = nonTerminal.filter { !userOrderSet.contains($0.id) }
        return userOrderIds.compactMap { byId[$0] } + missing
    }

    /// `+` menu order: pinned Terminal → presets → agents. The
    /// `initialCommand != nil` gate on agents skips half-configured
    /// customs (just-added with no command set) so the launch surface
    /// never spawns a bare Terminal that gets recorded as that custom.
    /// Blank-path presets are skipped for the same reason — they'd
    /// duplicate the default Terminal under a misleading label.
    @MainActor
    static func visibleOrdered(model: AgentTerminalSettingsModel) -> [AgentTemplate] {
        let presets = model.terminalPresets
            .filter {
                !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !model.hiddenPresets.contains($0.id)
            }
            .map(AgentTemplate.fromTerminalPreset)
        let agents = ordered(model: model).filter {
            !model.hiddenAgents.contains($0.id) && $0.initialCommand != nil
        }
        return [.terminal] + presets + agents
    }

    /// Resolves the user's chosen default template for `+` / `⌘T`. Returns
    /// `nil` (meaning "no default, show the picker") when the saved id is
    /// missing, unknown, or points to an agent the user has since hidden.
    /// Looking the id up in `visibleOrdered` gives the stale-default-after-
    /// hide fallback for free; Terminal is always present there so it stays
    /// selectable even though it's not customisable from the Settings list.
    @MainActor
    static func defaultLaunchTemplate(model: AgentTerminalSettingsModel) -> AgentTemplate? {
        guard let id = model.defaultAgentId else { return nil }
        return visibleOrdered(model: model).first { $0.id == id }
    }

    /// Materialises a user-defined custom agent into a runtime `AgentTemplate`.
    /// When `baseAgentId` matches a builtin, the custom inherits that
    /// builtin's `iconAsset` / `symbol` / `tintHex` *and* its `initialCommand`
    /// when the user's own `command` is blank — so picking "Claude Code" as
    /// the base and leaving `command` empty launches the base's binary
    /// (`claude`) with the custom's options appended (`--model opus`). A
    /// `(none)` base with empty command stays nil so the `+` menu filter
    /// skips half-configured customs.
    static func fromCustom(_ data: CustomAgentData) -> AgentTemplate {
        let base = builtin.first { $0.id == data.baseAgentId }
        // `promptLaunchFlag` + `resumeFlag` + `reportsToolCalls` follow the
        // base unconditionally — they're properties of the binary (Copilot
        // needs `-p`, Amp needs `-x`; Claude needs `--resume`, Grok needs
        // `--session`; Claude / Pi feed tool-call activity), not something the
        // user could meaningfully override per custom. Without inheritance, a
        // "Copilot Beta" custom built on Copilot would lose the flag and
        // right-click Ask would feed the prompt as a positional argv that
        // Copilot ignores; a "Claude Opus" custom would lose conversation
        // resume on relaunch and its tool-call pill.
        return AgentTemplate(
            id: data.id,
            title: data.title.isEmpty ? data.id : data.title,
            symbol: data.symbol.isEmpty ? (base?.symbol ?? "wand.and.stars") : data.symbol,
            iconAsset: data.iconAsset.isEmpty ? base?.iconAsset : data.iconAsset,
            tintHex: data.tintHex.isEmpty ? base?.tintHex : data.tintHex,
            initialCommand: data.command.isEmpty ? base?.initialCommand : data.command,
            baseAgentId: data.baseAgentId.isEmpty ? nil : data.baseAgentId,
            promptLaunchFlag: base?.promptLaunchFlag,
            resumeFlag: base?.resumeFlag,
            reportsToolCalls: base?.reportsToolCalls ?? false,
            extraEnv: parseEnv(data.env)
        )
    }

    /// Materialises a `TerminalPreset` into a synthetic Terminal-flavored
    /// `AgentTemplate`. `initialCommand` stays nil so `isShell` is true —
    /// the Ask-<agent> right-click filter and the "based on" Picker both
    /// skip these correctly. Title falls through `TerminalPreset.displayTitle`.
    static func fromTerminalPreset(_ preset: TerminalPreset) -> AgentTemplate {
        AgentTemplate(
            id: preset.id,
            title: preset.displayTitle,
            symbol: AgentTemplate.terminal.symbol,
            iconAsset: AgentTemplate.terminal.iconAsset,
            tintHex: AgentTemplate.terminal.tintHex,
            initialCommand: nil,
            extraCwd: preset.path.isEmpty ? nil : preset.path
        )
    }
}

/// User-defined agent entry. Stored in `settings.json` under
/// `agents.custom`; round-tripped through `AgentTerminalSettingsModel.customAgents`.
struct CustomAgentData: Hashable, Identifiable {
    /// Slug — must be unique across builtin + custom. Generated as
    /// `custom-N` on creation; user-editable from Settings.
    var id: String
    /// Display title shown in the `+` menu and Settings row.
    var title: String
    /// Full launch command, e.g. `aichat --model gpt-4o`. Whitespace-split
    /// by the wrapper's `eval`, same as the `agents.options` field.
    var command: String
    /// `id` of a builtin agent whose icon / tint / SF Symbol the custom
    /// should inherit. Empty = no inheritance (generic `wand.and.stars` +
    /// no tint). Surfaced as the "based on" picker in Settings so a user
    /// can build "Claude Opus" variants that visually belong to the Claude
    /// family without touching iconAsset / tintHex directly.
    var baseAgentId: String
    /// Bundled PNG asset name (matches files in `Resources/Icons/`). Power-
    /// user override; UI doesn't expose this in v1. Empty falls back to
    /// the `baseAgentId` builtin's iconAsset, or nil if no base.
    var iconAsset: String
    /// SF Symbol override. Power-user; UI hides this. Empty falls back to
    /// the base's symbol, then to `wand.and.stars`.
    var symbol: String
    /// sRGB hex (no `#`) for the sidebar pip tint. Power-user; UI hides
    /// this. Empty falls back to base's tintHex, then nil.
    var tintHex: String
    /// Extra environment variables for the agent, in `.env` syntax (one
    /// `KEY=VALUE` per line). Parsed into `AgentTemplate.extraEnv` by
    /// `AgentTemplate.parseEnv` at `fromCustom` time. v1 only takes effect
    /// for Claude-Code-based customs — written into a per-agent Claude
    /// settings file (`--settings`), never exported to the shell.
    var env: String

    init(
        id: String,
        title: String = "",
        command: String = "",
        baseAgentId: String = "",
        iconAsset: String = "",
        symbol: String = "",
        tintHex: String = "",
        env: String = ""
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.baseAgentId = baseAgentId
        self.iconAsset = iconAsset
        self.symbol = symbol
        self.tintHex = tintHex
        self.env = env
    }
}

/// User-defined "Terminal at <path>" entry. Stored in `settings.json` under
/// `terminals.presets`; round-tripped through `AgentTerminalSettingsModel.terminalPresets`.
/// Materialised into a synthetic `AgentTemplate` by `AgentTemplate.fromTerminalPreset`
/// so the `+` menu and the spawn pipeline treat presets as Terminal-flavored
/// rows that happen to pin a cwd. Distinct from `CustomAgentData` on purpose
/// — presets aren't agents, they don't run a binary, they don't have hooks /
/// env / options; conflating them would put "Terminal at /foo" into the
/// "Custom Agents" mental model where it doesn't belong.
struct TerminalPreset: Hashable, Identifiable, Sendable {
    /// Slug — must be unique across builtin agents, custom agents, and other
    /// presets. Generated as `preset-N` on creation; user-editable from
    /// Settings is deferred (id stays stable, title carries the rename).
    var id: String
    /// Display name shown in the `+` menu. Falls back to the path's basename
    /// (or the preset id, if path is also empty) when blank.
    var title: String
    /// Initial working directory. Accepts `~/`-prefixed paths; expanded at
    /// spawn time. A missing path resolves to `$HOME` via `resolvedSpawnCwd`.
    var path: String

    init(id: String, title: String = "", path: String = "") {
        self.id = id
        self.title = title
        self.path = path
    }

    /// Effective name for both the Settings row's collapsed header and the
    /// `+` menu entry (via `AgentTemplate.fromTerminalPreset`): explicit
    /// title wins, else the path's basename, else the slug. Single source
    /// so a future tweak (e.g. trimming) can't drift between the two surfaces.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if !path.isEmpty {
            let basename = (path as NSString).lastPathComponent
            if !basename.isEmpty { return basename }
        }
        return id
    }
}
