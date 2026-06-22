import Darwin
import Foundation

/// Listens on a per-user unix socket for one-shot JSON event lines from
/// hooks (sent by the `AgentTerminalHook` CLI): agent lifecycle events and prompt-time
/// shell env snapshots. Wire format is one JSON object per line.
///
/// The hooks themselves run as short-lived child processes of the agent (e.g.
/// Claude Code spawns them per Stop / UserPromptSubmit / Notification). They
/// connect, write one line, close — we accept and read in a single pass.
/// Lifecycle signal an agent's hook fired. Wire format is the raw String
/// case names; the enum lets `WorkspaceStore` switch exhaustively.
enum HookEvent: String {
    case running, attention, idle, ended

    var activityState: SessionActivityState {
        switch self {
        case .running: return .running
        case .attention: return .attention
        case .idle, .ended: return .idle
        }
    }
}

/// PreToolUse / PostToolUse phase carried on `HookMessage.toolCall`. Pre
/// fires before Claude runs the tool; Post fires after — duration / orphan
/// timing are computed `WorkspaceStore`-side from the gap between matched
/// events (AgentTerminalHook is fork-per-event and can't keep state).
enum HookToolEvent: String {
    case pre, post
}

enum HookMessage {
    case agent(agent: AgentTemplate, event: HookEvent, sessionId: UUID)
    case shellEnvironment(env: [String: String], sessionId: UUID)
    /// Claude's hook input JSON carries `session_id` (its conversation id).
    /// `AgentTerminalHook` extracts it and emits this message so agentterminal can persist
    /// it on the originating Session and reuse it as `--resume <id>` on
    /// next launch. The agent slug is implicit in the routing (only Claude
    /// pipes session_id today) and the consumer doesn't dispatch per-agent
    /// — so the payload only carries surface + id.
    case conversationId(conversationId: String, sessionId: UUID)
    /// PreToolUse / PostToolUse event for the activity strip. `agent` is
    /// the base AgentTemplate the slug resolves to (Claude builtin today —
    /// custom Claude-based agents share its slug since `from(hookSlug:)`
    /// matches by `initialCommand`). `success` is non-nil only for
    /// `.post` events. `toolUseId` is Claude's per-call stable id when
    /// present (used by `Session.recordToolCallEnd` to match Pre/Post
    /// pairs even when two concurrent calls share `toolName` + truncated
    /// identifier).
    case toolCall(
        agent: AgentTemplate,
        toolName: String,
        identifier: String,
        event: HookToolEvent,
        success: Bool?,
        toolUseId: String?,
        sessionId: UUID
    )
    /// An agent-to-agent message sent via the hook protocol. `fromAgent`
    /// is the sending agent's slug (`initialCommand`), resolved at parse time.
    /// `toSessionId` identifies the target session; `content` is the message
    /// body. The consumer (`WorkspaceStore`) routes it through `MessageBus`.
    case message(fromAgent: AgentTemplate, content: String, toSessionId: UUID, sessionId: UUID)
    /// Query for running agents. CLI sends `kind:"list"`; the handler
    /// populates `pendingResponse` with JSON so `acceptOne` can write it
    /// back to the client socket.
    case listAgents(sessionId: UUID)
}

@MainActor
final class HookServer {
    typealias Handler = (_ message: HookMessage) -> Void

    private let handler: Handler
    private var listenFd: Int32 = -1
    private var source: DispatchSourceRead?
    /// Callback for `listAgents` queries. Receives the requesting session's
    /// surface ID so the caller can filter by workspace. Returns JSON data
    /// to write back to the client socket.
    var listHandler: ((UUID) -> Data?)?

    init(handler: @escaping Handler) { self.handler = handler }

    /// Path agents and the CLI both target. Public so the CLI doesn't have to
    /// hardcode the same string in two places — but agents run in their own
    /// processes and read it via `AgentTerminalHook` reaching into `Application
    /// Support`, not via this property.
    static let socketPath: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("agentterminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("socket").path
    }()

    func start() {
        let path = Self.socketPath
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("agentterminal: HookServer socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            NSLog("agentterminal: HookServer socket path too long")
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0 else {
            NSLog("agentterminal: HookServer bind() failed errno=\(errno)")
            close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            NSLog("agentterminal: HookServer listen() failed errno=\(errno)")
            close(fd)
            return
        }

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        try? FileManager.default.removeItem(atPath: Self.socketPath)
    }

    private func acceptOne() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }
        defer { close(clientFd) }

        // Single read up to 4 KiB. Hook payloads are < 200 B and unix
        // SOCK_STREAM kernel-buffers small writes whole, so partial reads
        // aren't a practical concern at our message size.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBufferPointer { read(clientFd, $0.baseAddress, $0.count) }
        guard n > 0 else { return }
        let data = Data(bytes: buffer, count: n)
        guard let message = Self.parseMessage(data) else { return }

        // Query-type messages: write response and skip main handler.
        // listHandler returns JSON; acceptOne writes it back to the client.
        if case .listAgents(let sessionId) = message {
            if let listHandler, let responseData = listHandler(sessionId) {
                _ = responseData.withUnsafeBytes { write(clientFd, $0.baseAddress, $0.count) }
            }
            return
        }

        handler(message)
    }

    private static let envKeys = [
        "VIRTUAL_ENV", "CONDA_DEFAULT_ENV",
        "NVM_BIN", "NVM_DIR", "AGENTTERMINAL_NODE_VERSION",
        "https_proxy", "http_proxy", "all_proxy",
    ]

    static func parseMessage(_ data: Data) -> HookMessage? {
        guard
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let surface = dict["surface"] as? String,
            let id = UUID(uuidString: surface)
        else { return nil }

        if dict["kind"] as? String == "env" {
            let env = Dictionary(uniqueKeysWithValues: envKeys.map { key in
                (key, dict[key] as? String ?? "")
            })
            return .shellEnvironment(env: env, sessionId: id)
        }

        if dict["kind"] as? String == "conversationId",
           let conversationId = dict["conversationId"] as? String,
           !conversationId.isEmpty {
            return .conversationId(conversationId: conversationId, sessionId: id)
        }

        if dict["kind"] as? String == "msg",
           let toRaw = dict["to"] as? String,
           let toId = UUID(uuidString: toRaw),
           let content = dict["content"] as? String,
           let agentSlug = dict["agent"] as? String,
           let agent = AgentTemplate.from(hookSlug: agentSlug),
           !content.isEmpty {
            return .message(fromAgent: agent, content: content, toSessionId: toId, sessionId: id)
        }

        if dict["kind"] as? String == "list" {
            return .listAgents(sessionId: id)
        }

        if dict["kind"] as? String == "tool" {
            guard
                let agentSlug = dict["agent"] as? String,
                let agent = AgentTemplate.from(hookSlug: agentSlug),
                let toolName = dict["tool_name"] as? String, !toolName.isEmpty,
                let identifier = dict["identifier"] as? String,
                let eventRaw = dict["event"] as? String,
                let event = HookToolEvent(rawValue: eventRaw)
            else { return nil }

            // success ships as a literal "true" / "false" string on .post;
            // .pre omits it. Strict equality with "true" — any other value
            // ("TRUE", "1", "yes", "") coerces to false. AgentTerminalHookKit owns
            // the wire shape and ships exactly "true" / "false", so the
            // strict check is a wire-protocol contract not a parse heuristic.
            // Missing field on .post leaves success nil — the consumer
            // (WorkspaceStore.applyToolCallEvent) treats nil as success
            // (rather than guess-fail an unparseable response).
            var success: Bool? = nil
            if event == .post, let s = dict["success"] as? String {
                success = (s == "true")
            }

            // tool_use_id ships only when Claude includes it (recent CLI);
            // nil-tolerant on the consumer side so old payloads still work.
            let toolUseId = (dict["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            return .toolCall(
                agent: agent,
                toolName: toolName,
                identifier: identifier,
                event: event,
                success: success,
                toolUseId: toolUseId,
                sessionId: id
            )
        }

        guard
            let agentSlug = dict["agent"] as? String,
            let eventName = dict["event"] as? String,
            let agent = AgentTemplate.from(hookSlug: agentSlug),
            let event = HookEvent(rawValue: eventName)
        else { return nil }
        return .agent(agent: agent, event: event, sessionId: id)
    }
}
