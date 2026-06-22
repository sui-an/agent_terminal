import Foundation

/// Private terminal-title marker the ssh wrapper emits when a plain
/// interactive `ssh` connection is established. Like `AgentStatusMarker`, it
/// rides the terminal byte stream (OSC 2) so an ssh remote can be surfaced
/// locally without reaching agentterminal's unix socket.
///
/// Wire title shape:
///   agentterminal-remote-login:<destination>
///
/// where `<destination>` is the ssh argument verbatim (`user@host` if a user
/// was given, else bare `host`). Delivered via OSC 2 and intercepted before it
/// becomes a visible tab title.
enum RemoteLoginMarker {
    /// `internal` so the ssh wrapper emit interpolates the same constant the
    /// parse reads — one source of truth for the wire prefix.
    static let titlePrefix = "agentterminal-remote-login:"

    /// Returns the SSH destination (`user@host` or bare `host`), or nil when
    /// `raw` isn't a remote-login marker (or its payload is empty). No separate
    /// `isMarkerTitle`: unlike `AgentStatusMarker` (whose `parseTitle` is
    /// `@MainActor` + returns a tuple), this is non-isolated and already returns
    /// the optional a caller branches on.
    static func parseTitle(_ raw: String) -> String? {
        guard let title = normalizedTitle(raw),
              title.hasPrefix(titlePrefix)
        else { return nil }

        let host = String(title.dropFirst(titlePrefix.count))
        return host.isEmpty ? nil : host
    }
}
