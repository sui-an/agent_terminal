import AppKit
import AgentTerminalKit

// Detect CLI mode: either `AgentTerminal agent-forward <args>`
// or called via symlink as `agentforward <args>`.
let argv0 = CommandLine.arguments[0] as NSString
if argv0.lastPathComponent == "agentforward"
    || (CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "agent-forward")
{
    let args = argv0.lastPathComponent == "agentforward"
        ? Array(CommandLine.arguments.dropFirst(1))
        : Array(CommandLine.arguments.dropFirst(2))
    AgentForwardCLI.main(args)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
