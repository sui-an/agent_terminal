import AppKit
import Foundation

/// Sets up `~/.agentterminal/bin/agentforward` as a symlink to the app
/// bundle's `agentforward` CLI tool and ensures the bin directory is in the
/// user's shell PATH by adding an `export PATH=…` line to shell config files.
///
/// Called on every app launch — the symlink is recreated only when the
/// destination has changed (e.g. the user moved the .app bundle).
@MainActor
enum AgentPathSetup {
    private static var binDir: URL {
        AgentTerminalSettings.directory.appendingPathComponent("bin", isDirectory: true)
    }

    private static var symlinkPath: String {
        binDir.appendingPathComponent("agentforward").path
    }

    /// The app bundle's `agentforward` CLI entry point.
    private static var targetPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/agentforward"
    }

    static func setupIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let symlink = symlinkPath
        let target = targetPath

        if fm.fileExists(atPath: symlink) {
            if let currentDest = try? fm.destinationOfSymbolicLink(atPath: symlink),
               currentDest == target {
                return // already correct
            }
            try? fm.removeItem(atPath: symlink)
        }

        try? fm.createSymbolicLink(atPath: symlink, withDestinationPath: target)
        ensureShellPath()
    }

    // MARK: - Shell PATH

    private static func ensureShellPath() {
        let line = "\nexport PATH=\"$HOME/.agentterminal/bin:$PATH\"\n"
        let home = FileManager.default.homeDirectoryForCurrentUser
        // macOS default is zsh; bash as a secondary target.
        for rc in [home.appendingPathComponent(".zshrc"),
                   home.appendingPathComponent(".bash_profile")] {
            appendIfMissing(line, to: rc)
        }
    }

    /// Append `line` to `file` unless the file already contains
    /// `$HOME/.agentterminal/bin`.
    private static func appendIfMissing(_ line: String, to url: URL) {
        let content: String
        if let data = try? Data(contentsOf: url),
           let existing = String(data: data, encoding: .utf8) {
            content = existing
        } else {
            content = ""
        }

        guard !content.contains("$HOME/.agentterminal/bin") else { return }

        let newContent = content + line
        try? newContent.write(to: url, atomically: true, encoding: .utf8)
    }
}
