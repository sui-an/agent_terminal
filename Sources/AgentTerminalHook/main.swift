import Darwin
import Foundation
import AgentTerminalHookKit

// agentterminal-hook: invoked by an agent's hook system (Claude Code's `--settings`
// hooks, Codex equivalents, …) and the shell precmd hook (`env` mode) to
// ping the running agentterminal app over a unix socket. Payload building +
// stdin parsing live in `AgentTerminalHookKit` so they're unit-testable; this
// file stays a thin dispatcher.
//
// Exit codes:
//   0 — IPC succeeded, OR caller is outside agentterminal (no surface id) / args
//       malformed (programmer error). Both are "no retry needed."
//   1 — IPC failed (agentterminal not listening, socket gone, write error). Shell
//       callers use this to keep their dedup cache un-advanced so the next
//       prompt re-attempts. Without this distinction, a single transient
//       failure (agentterminal restarting, socket recreated) would freeze the env
//       cache permanently.
//
// Usage: agentterminal-hook <agent> <event>
//   <agent> ∈ claude | codex | pi (or any AgentTemplate.id)
//   <event> ∈ running | attention | idle    (lifecycle events)
//           | PreToolUse | PostToolUse      (Claude tool events — stdin JSON)
//           | conversation <id>             (extension-reported resume id — Pi)
//           | message <to> <content…>       (agent-to-agent message)
//           | tool <pre|post> <id> <name> <identifier> [ok|fail]
//                                            (extension-reported tool call — Pi)
// Usage: agentterminal-hook env <VIRTUAL_ENV> <CONDA_DEFAULT_ENV> <NVM_BIN> <NVM_DIR> <NODE_VERSION> <https_proxy> <http_proxy> <all_proxy>
// Reads:  $AGENTTERMINAL_SURFACE_ID       UUID of the originating session
// Reads:  stdin                   Claude pipes a JSON object on every
//                                 hook event. For PreToolUse/PostToolUse
//                                 it's the primary input; for lifecycle
//                                 events we use it to mirror `session_id`
//                                 back as a separate `kind: conversationId`
//                                 payload so agentterminal can prepend
//                                 `--resume <id>` on next launch.

let surface = ProcessInfo.processInfo.environment["AGENTTERMINAL_SURFACE_ID"] ?? ""
guard !surface.isEmpty else { exit(0) }

let socketPath = AgentTerminalHookKit.socketPath

// Drain stdin once up-front so the tool-event parser (PreToolUse /
// PostToolUse) and the conversationId mirror — both reading the same
// Claude-supplied JSON — don't double-read a single-pass stream. Gated on
// `agent == "claude"`: only Claude pipes JSON here, and it always writes one
// object then closes. Every other caller (codex/bracket lifecycle pings, Pi's
// argv modes, env snapshots) sends nothing on stdin, so draining is pointless
// — and a detached caller can hand us a stdin pipe that never EOFs (a broker's
// JSON-RPC stream that a spawned `app-server` inherits, pinged via the
// wrapper), where readToEnd() would block forever. `isatty == 0` still guards
// the tty case so the "binary not installed" branch never strands the tab.
let agentArg = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : ""
let stdinData: Data = (agentArg == "claude" && isatty(fileno(stdin)) == 0)
    ? ((try? FileHandle.standardInput.readToEnd()) ?? Data())
    : Data()

let payloadObject: [String: String]
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "env" {
    let envArgs = Array(CommandLine.arguments.dropFirst(2))
    payloadObject = AgentTerminalHookKit.buildEnvPayload(surface: surface, args: envArgs)
} else if CommandLine.arguments.count >= 3 {
    let agent = CommandLine.arguments[1]
    let event = CommandLine.arguments[2]
    if event == "conversation" {
        // Extension-reported conversation id (Pi): the agent's extension hands
        // agentterminal the session id directly as argv[3] — no stdin JSON to parse
        // (unlike Claude's hook mirror below). Reuses the same conversationId
        // payload, so WorkspaceStore persists it + prepends `--session <id>`
        // on next launch.
        let id = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : ""
        guard !id.isEmpty else { exit(0) }
        let payload = AgentTerminalHookKit.buildConversationIdPayload(surface: surface, conversationId: id)
        exit(AgentTerminalHookKit.sendPayload(payload, to: socketPath) ? 0 : 1)
    }
    if event == "message" {
        // agentterminal-hook <agent> message <to-session-id> <content…>
        // Sends an agent-to-agent message through the hook socket. The
        // remaining argv (4..end) is joined with spaces so multi-word
        // messages don't need shell quoting at the cost of trailing spaces.
        let toId = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : ""
        let content = CommandLine.arguments.count >= 5
            ? CommandLine.arguments.dropFirst(4).joined(separator: " ")
            : ""
        guard !toId.isEmpty, !content.isEmpty else { exit(0) }
        let payload = AgentTerminalHookKit.buildMessagePayload(
            surface: surface,
            agent: agent,
            toSessionId: toId,
            content: content
        )
        exit(AgentTerminalHookKit.sendPayload(payload, to: socketPath) ? 0 : 1)
    }

    if event == "list" {
        // agentterminal-hook <agent> list
        // Queries running agents over the hook socket and prints JSON response.
        let payload = AgentTerminalHookKit.buildListPayload(surface: surface)
        if let responseData = AgentTerminalHookKit.sendPayloadWithResponse(payload, to: socketPath),
           let responseString = String(data: responseData, encoding: .utf8) {
            print(responseString)
            exit(0)
        }
        exit(1)
    }

    if event == "tool" {
        // Extension-reported tool call (Pi): the extension hands the already-
        // extracted fields as argv — no stdin JSON to parse (unlike Claude's
        // `parseToolEventPayload`). Funnels through the same
        // `buildToolEventPayload` so the `kind:"tool"` wire shape is identical
        // across agents. argv layout:
        //   agentterminal-hook <agent> tool pre  <toolCallId> <toolName> <identifier>
        //   agentterminal-hook <agent> tool post <toolCallId> <toolName> <identifier> <ok|fail>
        let args = CommandLine.arguments
        func at(_ i: Int) -> String { args.indices.contains(i) ? args[i] : "" }
        let phase = at(3)
        let toolName = at(5)
        guard phase == "pre" || phase == "post", !toolName.isEmpty else { exit(0) }
        // Any value other than "fail" (incl. missing) is treated as success —
        // the extension sends "ok"/"fail" off pi's `isError`.
        let success: Bool? = phase == "post" ? (at(7) != "fail") : nil
        let toolUseId = at(4)
        let payload = AgentTerminalHookKit.buildToolEventPayload(
            surface: surface,
            agent: agent,
            toolName: toolName,
            identifier: at(6),
            event: phase,
            toolUseId: toolUseId.isEmpty ? nil : toolUseId,
            success: success
        )
        exit(AgentTerminalHookKit.sendPayload(payload, to: socketPath) ? 0 : 1)
    }
    if event == "PreToolUse" || event == "PostToolUse" || event == "PostToolUseFailure" {
        // Tool event: stdin JSON is mandatory. Bail silently if it's
        // missing or malformed — pill UI just won't render this call.
        guard let tool = AgentTerminalHookKit.parseToolEventPayload(
            from: stdinData,
            surface: surface,
            agent: agent
        ) else { exit(0) }
        payloadObject = tool
        // PreToolUse also triggers attention so the user gets notified when
        // Claude pauses for a permission prompt mid-turn. Send a separate
        // lifecycle payload after the tool payload.
        if event == "PreToolUse" {
            let attentionPayload = AgentTerminalHookKit.buildLifecyclePayload(
                agent: agent,
                event: "attention",
                surface: surface
            )
            _ = AgentTerminalHookKit.sendPayload(attentionPayload, to: socketPath)
        }
    } else {
        payloadObject = AgentTerminalHookKit.buildLifecyclePayload(
            agent: agent,
            event: event,
            surface: surface
        )
    }
} else {
    exit(0)
}

let eventSent = AgentTerminalHookKit.sendPayload(payloadObject, to: socketPath)

// Bonus payload: Claude pipes `session_id` on every hook (lifecycle +
// tool). Mirror it so `WorkspaceStore` can persist the conversation id
// on `Session` and prepend `--resume <id>` on next launch. Gated on:
//   1. `agent == "claude"` — non-Claude agents skip it
//   2. `kind != "tool"` — tool payloads fire 10-100× per Claude turn and
//      each one ALSO carries session_id; mirroring on every Pre/PostToolUse
//      would multiply IPC by N tool calls per turn. Lifecycle events
//      (SessionStart/UserPromptSubmit/Stop/Notification/SessionEnd) carry
//      the same id and fire 5× per turn — plenty to keep WorkspaceStore's
//      `--resume` field fresh. applyConversationId dedups same-value writes
//      but each call still pays a socket connect+write+close roundtrip.
if payloadObject["agent"] == "claude",
   payloadObject["kind"] != "tool",
   let conversationId = AgentTerminalHookKit.parseClaudeConversationId(from: stdinData) {
    let payload = AgentTerminalHookKit.buildConversationIdPayload(
        surface: surface,
        conversationId: conversationId
    )
    _ = AgentTerminalHookKit.sendPayload(payload, to: socketPath)
}

exit(eventSent ? 0 : 1)
