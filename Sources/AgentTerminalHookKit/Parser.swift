import Darwin
import Foundation

/// Pure helpers for `AgentTerminalHook` CLI: builds the JSON payloads it ships to
/// `HookServer` and writes them across the unix socket the running app owns.
/// Lives in its own library target so unit tests can verify parsing logic
/// (malformed JSON, missing fields, wrong types, future PreToolUse /
/// PostToolUse payloads) without spawning a subprocess. Stays off
/// `AgentTerminalKit` on purpose — the CLI binary must remain dependency-free.
public enum AgentTerminalHookKit {
    public static var socketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("agentterminal/socket").path
    }

    /// One-shot socket write. Returns true on success. `HookServer` accepts
    /// one payload per connection so each call opens / writes / closes.
    public static func sendPayload(_ object: [String: String], to path: String) -> Bool {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return false }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard connected == 0 else { return false }

        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written >= 0
    }

    /// Send payload and read response. Used for query commands like `list`.
    /// Returns nil on connection failure or timeout.
    public static func sendPayloadWithResponse(_ object: [String: String], to path: String) -> Data? {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard connected == 0 else { return nil }

        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written >= 0 else { return nil }

        // Read response with 2-second timeout
        var buf = [UInt8](repeating: 0, count: 4096)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return Data(bytes: buf, count: n)
    }

    /// Build payload for the `list` query command.
    public static func buildListPayload(surface: String) -> [String: String] {
        [
            "kind": "list",
            "surface": surface,
        ]
    }

    /// Env-snapshot payload from positional args. Order follows the
    /// `agentterminal-hook env ...` calling convention in `ShellIntegration.swift`'s
    /// precmd hook: VIRTUAL_ENV, CONDA_DEFAULT_ENV, NVM_BIN, NVM_DIR,
    /// AGENTTERMINAL_NODE_VERSION, https_proxy, http_proxy, all_proxy.
    public static func buildEnvPayload(surface: String, args: [String]) -> [String: String] {
        func arg(_ index: Int) -> String { args.indices.contains(index) ? args[index] : "" }
        return [
            "kind": "env",
            "surface": surface,
            "VIRTUAL_ENV": arg(0),
            "CONDA_DEFAULT_ENV": arg(1),
            "NVM_BIN": arg(2),
            "NVM_DIR": arg(3),
            "AGENTTERMINAL_NODE_VERSION": arg(4),
            "https_proxy": arg(5),
            "http_proxy": arg(6),
            "all_proxy": arg(7),
        ]
    }

    /// Lifecycle payload (running / attention / idle / ended).
    public static func buildLifecyclePayload(agent: String, event: String, surface: String) -> [String: String] {
        [
            "agent": agent,
            "event": event,
            "surface": surface,
        ]
    }

    /// Message payload routed to `HookServer` so `WorkspaceStore` can
    /// record it on `MessageBus` — the target session's sidebar badge then
    /// lights up. Called by `agentterminal-hook <agent> message <to> <content>`.
    public static func buildMessagePayload(surface: String, agent: String, toSessionId: String, content: String) -> [String: String] {
        [
            "kind": "msg",
            "surface": surface,
            "agent": agent,
            "to": toSessionId,
            "content": content,
        ]
    }

    /// Pulls `session_id` out of Claude Code's hook stdin JSON. Returns nil
    /// on malformed input, missing field, wrong type, or empty string —
    /// callers should treat nil as "nothing to relay" and move on. Other
    /// agents either don't pipe stdin or don't expose a session id; the
    /// caller gates on `agent == "claude"` before invoking this.
    public static func parseClaudeConversationId(from data: Data) -> String? {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = parsed["session_id"] as? String,
              !sessionId.isEmpty
        else { return nil }
        return sessionId
    }

    /// ConversationId payload routed to `HookServer` so `WorkspaceStore`
    /// can persist it on `Session` and prepend `--resume <id>` to
    /// `AGENTTERMINAL_AGENT` on next launch.
    public static func buildConversationIdPayload(surface: String, conversationId: String) -> [String: String] {
        [
            "kind": "conversationId",
            "surface": surface,
            "conversationId": conversationId,
        ]
    }

    /// Maximum bytes / characters carried by the cross-boundary `identifier`
    /// field. Per `/plan-eng-review` D2 — AgentTerminalHook truncates at source so
    /// large `tool_input` payloads (Edit / Write file content) never reach
    /// the 4 KiB HookServer buffer. Counted in `Character`s, not UTF-8
    /// bytes — CJK identifiers stay readable instead of mid-codepoint cut.
    public static let identifierMaxLength = 80

    /// Parse a Claude Code PreToolUse / PostToolUse / PostToolUseFailure
    /// stdin JSON into a minimal tool-event payload routed to `HookServer`.
    /// Returns nil for any non-tool event (`SessionStart`,
    /// `UserPromptSubmit`, etc.) or malformed input — caller doesn't have
    /// to pre-filter.
    ///
    /// Payload shape:
    /// ```
    /// {
    ///   "kind": "tool",
    ///   "surface": <UUID>,
    ///   "agent":   <claude | claude-base custom agent slug>,
    ///   "tool_name": <Bash | Edit | Read | ...>,
    ///   "identifier": <truncated file path / command / url>,
    ///   "event":     <"pre" | "post">,
    ///   "success":   <"true" | "false">   (only on event=="post")
    ///   "tool_use_id": <Claude's per-call id>  (when present)
    /// }
    /// ```
    ///
    /// `identifier` is extracted from `tool_input` per tool kind, control
    /// characters collapsed to spaces, then truncated to 80 chars. Bulk
    /// data (full file content, Bash output) never crosses this boundary.
    ///
    /// `PostToolUseFailure` is recognised as a Post variant whose `success`
    /// is forced to `false` without inspecting `tool_response` — Claude
    /// fires this distinct event only when the tool itself errored, so
    /// the heuristic-free signal beats the `tool_response` text scan.
    public static func parseToolEventPayload(
        from data: Data,
        surface: String,
        agent: String
    ) -> [String: String]? {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = parsed["hook_event_name"] as? String,
              let toolName = parsed["tool_name"] as? String,
              !toolName.isEmpty
        else { return nil }

        let event: String
        let postSuccessOverride: Bool?  // nil → heuristic, true/false → forced
        switch hookEventName {
        case "PreToolUse":         event = "pre";  postSuccessOverride = nil
        case "PostToolUse":        event = "post"; postSuccessOverride = nil
        case "PostToolUseFailure": event = "post"; postSuccessOverride = false
        default:                   return nil  // not a tool event we handle
        }

        let toolInput = parsed["tool_input"] as? [String: Any] ?? [:]
        let rawIdentifier = extractIdentifier(toolName: toolName, toolInput: toolInput)

        // PostToolUseFailure forces success=false (Claude's own signal);
        // PostToolUse falls back to the heuristic over `tool_response`. Pre
        // carries no success.
        let success: Bool? = event == "post"
            ? (postSuccessOverride ?? detectSuccess(toolResponse: parsed["tool_response"]))
            : nil

        return buildToolEventPayload(
            surface: surface,
            agent: agent,
            toolName: toolName,
            identifier: rawIdentifier,
            event: event,
            toolUseId: parsed["tool_use_id"] as? String,
            success: success
        )
    }

    /// Assemble the agent-agnostic `kind:"tool"` payload routed to
    /// `HookServer` → `WorkspaceStore.applyToolCallEvent` → the status-bar
    /// pill. Single source for the wire shape so it can't drift between the
    /// two producers: `parseToolEventPayload` (Claude — extracts these
    /// fields from hook stdin JSON) and AgentTerminalHook's `tool` argv branch (Pi —
    /// the extension hands the fields straight from `tool_execution_*`
    /// events). `identifier` is control-stripped + truncated here, the one
    /// place it happens; `toolUseId` is emitted only when non-empty (Pi's
    /// `toolCallId` and Claude's `tool_use_id` both land here so Pre/Post
    /// match by stable id); `success` only rides `event == "post"`.
    public static func buildToolEventPayload(
        surface: String,
        agent: String,
        toolName: String,
        identifier: String,
        event: String,
        toolUseId: String?,
        success: Bool?
    ) -> [String: String] {
        var payload: [String: String] = [
            "kind":       "tool",
            "surface":    surface,
            "agent":      agent,
            "tool_name":  toolName,
            "identifier": truncateForPayload(identifier),
            "event":      event,
        ]
        if let toolUseId, !toolUseId.isEmpty {
            payload["tool_use_id"] = toolUseId
        }
        if event == "post", let success {
            payload["success"] = success ? "true" : "false"
        }
        return payload
    }

    /// Pick the most descriptive single string out of `tool_input` per
    /// tool kind — what pill UI shows as the "what" of the call. Unknown
    /// tools fall back to the first non-empty string value (alphabetised
    /// by key so the choice is deterministic across runs — Swift dict
    /// iteration order isn't stable). Empty if everything's empty.
    static func extractIdentifier(toolName: String, toolInput: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return toolInput["command"] as? String ?? ""
        case "Edit", "Write", "Read", "NotebookEdit", "MultiEdit":
            return toolInput["file_path"] as? String ?? ""
        case "Glob":
            return toolInput["pattern"] as? String ?? toolInput["path"] as? String ?? ""
        case "Grep":
            return toolInput["pattern"] as? String ?? ""
        case "WebFetch", "WebSearch":
            return (toolInput["url"] as? String) ?? (toolInput["query"] as? String) ?? ""
        case "Task":
            return (toolInput["description"] as? String) ?? (toolInput["prompt"] as? String) ?? ""
        default:
            // Unknown tool — pick the first non-empty String value, with
            // keys sorted alphabetically so the choice is deterministic
            // (Swift dictionary iteration order isn't stable across runs,
            // and the pill would otherwise show different identifiers for
            // the same payload between invocations). Common-case tools
            // above have explicit dispatch.
            for key in toolInput.keys.sorted() {
                if let str = toolInput[key] as? String, !str.isEmpty { return str }
            }
            return ""
        }
    }

    /// Collapse ALL C0 control bytes (0x00-0x1F) + DEL (0x7F) to single
    /// spaces, then truncate to `identifierMaxLength` characters. Strips
    /// the whole control range — not just `\n` `\r` `\t` — because pill
    /// UI is a single-line `Text` view and any embedded NUL / BEL / ESC /
    /// FS/GS/RS/US can perturb rendering, screen-reader output, or the
    /// Pre/Post match key used in `Session.recordToolCallEnd`. Truncates
    /// by `Character` count so CJK stays whole.
    static func truncateForPayload(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.map { scalar -> Character in
            // C0 controls (0x00-0x1F) + DEL (0x7F)
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return " "
            }
            return Character(scalar)
        })
        return String(cleaned.prefix(identifierMaxLength))
    }

    /// PostToolUse success heuristic — Claude doesn't expose a structured
    /// success/failure flag in PostToolUse hook stdin, so we read
    /// `tool_response` (when present + a String) and look for common
    /// error markers. Missing / non-string response → defaults to true
    /// (don't false-flag tools we can't read). Conservative for v1.
    static func detectSuccess(toolResponse: Any?) -> Bool {
        guard let response = toolResponse as? String, !response.isEmpty else { return true }
        let lowered = response.lowercased()
        let errorMarkers = [
            "error:",
            "failed:",
            "exception:",
            "fatal:",
            "<error>",
            "permission denied",
            "command not found",
            "no such file",
        ]
        return !errorMarkers.contains { lowered.contains($0) }
    }
}
