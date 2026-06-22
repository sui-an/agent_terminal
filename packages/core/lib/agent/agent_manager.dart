import '../terminal/terminal_backend.dart';
import 'agent_config.dart';
import 'agent_state.dart';

class AgentSession {
  final int sessionId;
  final AgentConfig config;
  final DateTime startedAt;

  AgentSession({required this.sessionId, required this.config, DateTime? startedAt})
      : startedAt = startedAt ?? DateTime.now();
}

class AgentManager {
  final TerminalBackend _backend;
  final Map<int, AgentSession> _sessions = {};
  final Map<int, AgentState> _states = {};

  AgentManager(this._backend);

  Future<AgentSession> launchAgent(AgentConfig config) async {
    if (!_backend.isInitialized) await _backend.initialize();
    final fullCommand = [config.command, ...config.args].join(' ');
    final sessionId = await _backend.createSession(fullCommand, config.env);
    final session = AgentSession(sessionId: sessionId, config: config);
    _sessions[sessionId] = session;
    _states[sessionId] = AgentState(id: config.id, name: config.name, status: AgentStatus.running);
    return session;
  }

  AgentState? getStatus(int sessionId) => _states[sessionId];

  void updateStatus(int sessionId, AgentStatus status, {int? exitCode, String? errorMessage}) {
    final current = _states[sessionId];
    if (current != null) {
      _states[sessionId] = current.copyWith(
        status: status,
        exitCode: exitCode,
        errorMessage: errorMessage,
      );
    }
  }

  Future<void> destroySession(int sessionId) async {
    await _backend.destroy(sessionId);
    _sessions.remove(sessionId);
    _states.remove(sessionId);
  }
}
