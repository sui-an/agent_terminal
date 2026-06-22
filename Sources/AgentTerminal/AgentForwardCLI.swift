import Foundation
import Darwin
import AgentTerminalHookKit

/// CLI handler for `AgentTerminal agent-forward <subcommand>`.
///
/// Usage:
///   AgentTerminal agent-forward list
///   echo "@forward <target> <message>" | AgentTerminal agent-forward
///   AgentTerminal agent-forward send <target> <message> [--from <agent>]
///   AgentTerminal agent-forward --help
///
/// The subcommand forwards queries through the Unix socket to the running
/// AgentTerminal app's HookServer, reusing the same JSON wire format the
/// hook CLI uses.
enum AgentForwardCLI {
    static let surfaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - Entry Point

    static func main(_ args: [String]) {
        // Stdin mode: process "@forward" and "@list" lines from pipe
        if isatty(fileno(stdin)) == 0 {
            handleStdin()
            return
        }

        guard !args.isEmpty else {
            printHelp()
            exit(1)
        }

        switch args[0] {
        case "list":
            listAgents()
        case "send":
            handleSendCommand(Array(args.dropFirst()))
        case "--help", "-h":
            printHelp()
        default:
            printErr("Unknown command: \(args[0])")
            printErr("Usage: AgentTerminal agent-forward <list|send|--help>")
            exit(1)
        }
    }

    // MARK: - Commands

    /// `agent-forward list` — print running agents.
    private static func listAgents() {
        let socketPath = AgentTerminalHookKit.socketPath
        guard FileManager.default.fileExists(atPath: socketPath) else {
            printErr("AgentTerminal is not running (socket not found).")
            exit(1)
        }

        let payload = AgentTerminalHookKit.buildListPayload(surface: surfaceId.uuidString)

        guard let responseData = AgentTerminalHookKit.sendPayloadWithResponse(payload, to: socketPath)
        else {
            printErr("Failed to query agents — socket communication error.")
            exit(1)
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let agents = json["agents"] as? [[String: Any]],
              !agents.isEmpty
        else {
            print("No running agents.")
            exit(0)
        }

        print("Running agents:")
        print(String(repeating: "─", count: 60))
        for a in agents {
            let name = a["agent"] as? String ?? "?"
            let state = a["state"] as? String ?? "?"
            let title = a["title"] as? String ?? ""
            let id = a["id"] as? String ?? ""
            let prefix = id.prefix(8)
            print("  \(stateColor(state))\(state.padding(toLength: 10, withPad: " ", startingAt: 0))\(ANSINone) \(name) — \(title) [\(prefix)...]")
        }
        print(String(repeating: "─", count: 60))
    }

    /// `agent-forward send [--from <agent>] <target> <message...>`
    private static func handleSendCommand(_ args: [String]) {
        guard args.count >= 2 else {
            printErr("Usage: AgentTerminal agent-forward send <target> <message> [--from <agent-slug>]")
            exit(1)
        }

        var remaining = args
        var fromAgent: String?
        if remaining.first == "--from" {
            guard remaining.count >= 3 else {
                printErr("--from requires an agent slug (e.g. claude, codex)")
                exit(1)
            }
            fromAgent = remaining[1]
            remaining = Array(remaining.dropFirst(2))
        }

        guard remaining.count >= 2 else {
            printErr("Usage: AgentTerminal agent-forward send <target> <message>")
            exit(1)
        }

        let target = remaining[0]
        let message = remaining.dropFirst().joined(separator: " ")
        sendMessage(target: target, content: message, fromAgent: fromAgent)
    }

    /// Send a message to a target agent session.
    private static func sendMessage(target: String, content: String, fromAgent: String?) {
        let socketPath = AgentTerminalHookKit.socketPath
        guard FileManager.default.fileExists(atPath: socketPath) else {
            printErr("AgentTerminal is not running (socket not found).")
            exit(1)
        }

        // Resolve target: it's either a UUID or an agent name
        let targetId: String
        if UUID(uuidString: target) != nil {
            targetId = target
        } else {
            guard let resolved = resolveAgent(name: target) else {
                printErr("No running agent named '\(target)'. Use 'list' to see available agents.")
                exit(1)
            }
            targetId = resolved
        }

        // Resolve sending agent and surface
        let agentSlug: String
        var surface = surfaceId.uuidString
        if let fromAgent {
            agentSlug = fromAgent
            // Try to find a session for this agent to get a valid surface UUID
            if let sessionId = findSessionId(forAgent: fromAgent) {
                surface = sessionId
            }
        } else {
            // Auto-detect: find any running agent to use as sender
            guard let (slug, sessionId) = findAnyRunningAgent() else {
                printErr("No running agents to send from. Specify --from <agent-slug>.")
                exit(1)
            }
            agentSlug = slug
            surface = sessionId
        }

        let payload = AgentTerminalHookKit.buildMessagePayload(
            surface: surface,
            agent: agentSlug,
            toSessionId: targetId,
            content: content
        )

        if AgentTerminalHookKit.sendPayload(payload, to: socketPath) {
            print("[sent] \(agentSlug) → \(targetId): \(content)")
        } else {
            printErr("Failed to send message.")
            exit(1)
        }
    }

    // MARK: - Stdin Mode

    /// Parse `@forward` and `@list` commands from piped input.
    private static func handleStdin() {
        var messageCount = 0
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "@list" {
                listAgents()
                messageCount += 1
                continue
            }
            if parseForwardLine(trimmed) {
                messageCount += 1
            }
        }
        if messageCount == 0 {
            printErr("No messages to forward.")
            exit(1)
        }
    }

    /// Parse a single `@forward <target> <message>` line.
    private static func parseForwardLine(_ line: String) -> Bool {
        let pattern = #/^@forward\s+(\S+)\s+(.+)$/#
        guard let match = try? pattern.firstMatch(in: line) else { return false }

        let target = String(match.1)
        let content = String(match.2).trimmingCharacters(in: .init(charactersIn: "\"'"))

        print("[forward] \(target): \(content)")
        sendMessage(target: target, content: content, fromAgent: nil)
        return true
    }

    // MARK: - Agent Resolution

    /// Query running agents from the socket.
    private static func queryAgents() -> [[String: Any]] {
        let socketPath = AgentTerminalHookKit.socketPath
        guard FileManager.default.fileExists(atPath: socketPath) else { return [] }

        let payload = AgentTerminalHookKit.buildListPayload(surface: surfaceId.uuidString)
        guard let data = AgentTerminalHookKit.sendPayloadWithResponse(payload, to: socketPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = json["agents"] as? [[String: Any]]
        else { return [] }
        return agents
    }

    /// Resolve an agent name to a session UUID string.
    private static func resolveAgent(name: String) -> String? {
        let agents = queryAgents()
        // Exact match first
        if let match = agents.first(where: { ($0["agent"] as? String) == name }) {
            return match["id"] as? String
        }
        // Prefix match
        if let match = agents.first(where: { ($0["agent"] as? String)?.hasPrefix(name) == true }) {
            return match["id"] as? String
        }
        return nil
    }

    /// Find a session UUID for a given agent slug (e.g. "claude").
    private static func findSessionId(forAgent slug: String) -> String? {
        let agents = queryAgents()
        if let match = agents.first(where: { ($0["agent"] as? String) == slug }) {
            return match["id"] as? String
        }
        return nil
    }

    /// Find any running agent to use as the sender.
    private static func findAnyRunningAgent() -> (slug: String, sessionId: String)? {
        let agents = queryAgents()
        guard let first = agents.first else { return nil }
        let slug = first["agent"] as? String ?? ""
        let sessionId = first["id"] as? String ?? ""
        return slug.isEmpty || sessionId.isEmpty ? nil : (slug, sessionId)
    }

    // MARK: - Helpers

    private static func printHelp() {
        print("""
        AgentForward — inter-agent messaging tool

        Usage:
          AgentTerminal agent-forward list
              List all running agents.

          AgentTerminal agent-forward send <target> <message> [--from <agent>]
              Send a message to a target agent (by name or session UUID).
              --from specifies the sending agent slug (auto-detected if omitted).

          echo "@forward <target> <message>" | AgentTerminal agent-forward
              Pipe mode: process @forward and @list commands from stdin.

        Examples:
          AgentTerminal agent-forward list
          AgentTerminal agent-forward send claude "Please review this code"
          echo '@forward mimo "检查一下"' | AgentTerminal agent-forward
        """)
    }

    private static func stateColor(_ state: String) -> String {
        switch state {
        case "attention": return "\u{001B}[33m"  // yellow
        case "failed":    return "\u{001B}[31m"  // red
        case "running":   return "\u{001B}[32m"  // green
        default:          return "\u{001B}[90m"  // gray
        }
    }

    private static let ANSINone = "\u{001B}[0m"

    private static func printErr(_ msg: String) {
        fputs(msg + "\n", stderr)
    }
}
