import Foundation
@testable import AgentTerminalKit

/// In-memory `Persistence` for tests — captures `save` calls so assertions
/// can inspect the most recent snapshot without touching the filesystem.
@MainActor
final class InMemoryPersistence: Persistence {
    var saved: PersistedState?
    private let initial: PersistedState?

    init(initial: PersistedState? = nil) {
        self.initial = initial
    }

    func load() -> PersistedState? {
        initial
    }

    func save(_ state: PersistedState) {
        saved = state
    }
}
