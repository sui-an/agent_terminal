import Foundation

/// Tracks performance metrics for agent sessions.
@MainActor
final class AgentPerformanceTracker {
    static let shared = AgentPerformanceTracker()
    
    private var sessionMetrics: [UUID: SessionMetrics] = [:]
    
    struct SessionMetrics {
        let sessionId: UUID
        let agentId: String
        var startTime: Date
        var commandCount: Int = 0
        var totalDuration: TimeInterval = 0
        var lastCommandTime: Date?
    }
    
    func startTracking(sessionId: UUID, agentId: String) {
        sessionMetrics[sessionId] = SessionMetrics(
            sessionId: sessionId,
            agentId: agentId,
            startTime: Date()
        )
    }
    
    func recordCommand(sessionId: UUID) {
        guard var metrics = sessionMetrics[sessionId] else { return }
        
        let now = Date()
        if let lastTime = metrics.lastCommandTime {
            metrics.totalDuration += now.timeIntervalSince(lastTime)
        }
        metrics.commandCount += 1
        metrics.lastCommandTime = now
        sessionMetrics[sessionId] = metrics
    }
    
    func stopTracking(sessionId: UUID) -> SessionMetrics? {
        return sessionMetrics.removeValue(forKey: sessionId)
    }
    
    func getMetrics(for sessionId: UUID) -> SessionMetrics? {
        return sessionMetrics[sessionId]
    }
    
    func getAverageCommandDuration(for agentId: String) -> TimeInterval? {
        let agentMetrics = sessionMetrics.values.filter { $0.agentId == agentId }
        guard !agentMetrics.isEmpty else { return nil }
        
        let totalDuration = agentMetrics.reduce(0) { $0 + $1.totalDuration }
        let totalCommands = agentMetrics.reduce(0) { $0 + $1.commandCount }
        
        guard totalCommands > 0 else { return nil }
        return totalDuration / Double(totalCommands)
    }
}
