import Foundation

/// A forwarded message between two agent sessions. Messages are created when
/// the user (or an agent via the hook protocol) sends context from one session
/// to another.
struct AgentMessage: Identifiable {
    let id = UUID()
    let fromSessionId: UUID
    let toSessionId: UUID
    let fromAgentTitle: String
    let toAgentTitle: String
    let content: String
    let timestamp = Date()
    var isRead = false
}

/// App-level singleton that tracks messages flowing between agent sessions.
/// `@Observable` so the sidebar badge and any future message panel re-render
/// automatically when a new message arrives.
@MainActor
@Observable
final class MessageBus {
    static let shared = MessageBus()
    private(set) var messages: [AgentMessage] = []

    /// Record a forwarded message. Callers supply the `toSessionId` and the
    /// display titles (resolved at send-time so the message survives session
    /// closure). Pushes onto `messages` for observation.
    func send(
        from fromSession: Session,
        toSessionId: UUID,
        toAgentTitle: String,
        content: String
    ) {
        let msg = AgentMessage(
            fromSessionId: fromSession.id,
            toSessionId: toSessionId,
            fromAgentTitle: fromSession.displayAgent.title,
            toAgentTitle: toAgentTitle,
            content: content
        )
        messages.append(msg)
    }

    /// Number of unread messages directed at the given session.
    func unreadCount(for sessionId: UUID) -> Int {
        messages.filter { $0.toSessionId == sessionId && !$0.isRead }.count
    }

    /// Mark all messages for a session as read (called when the tab is activated).
    func markRead(for sessionId: UUID) {
        for i in messages.indices where messages[i].toSessionId == sessionId {
            messages[i].isRead = true
        }
    }
}
