import Foundation

/// Single source of truth for product metadata — surfaced by the About panel,
/// Help menu, and window title. Bump `displayVersion` on every release so the
/// About panel matches the latest CHANGELOG `vX.Y` tag.
enum AgentTerminalApp {
    static let name = "AgentTerminal"
    static let displayVersion = "1.0.0"
    static let tagline = "AI Agent Orchestration Terminal"
    static let author = "AgentTerminal Contributors"
    static let authorURL = URL(string: "https://github.com/sui-an/agent_terminal")!
    static let copyrightYear = "2026"

    static let repositoryURL = URL(string: "https://github.com/sui-an/agent_terminal")!
    static let issuesURL = URL(string: "https://github.com/sui-an/agent_terminal/issues")!
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/sui-an/agent_terminal/releases/latest")!
}
