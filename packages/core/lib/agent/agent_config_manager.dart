import 'agent_config.dart';

class AgentConfigManager {
  final List<AgentConfig> _agents = [];

  List<AgentConfig> get agents => List.unmodifiable(_agents);

  AgentConfigManager() {
    _agents.addAll([
      AgentConfig(id: 'mimocode', name: 'MiMoCode', command: 'mimocode',
          args: ['--agent'], statusDetection: StatusDetectionConfig(method: 'osc', oscCodes: [9, 99, 777])),
      AgentConfig(id: 'claude-code', name: 'Claude Code', command: 'claude',
          statusDetection: StatusDetectionConfig(method: 'osc', oscCodes: [9, 99, 777])),
      AgentConfig(id: 'codex', name: 'Codex', command: 'codex'),
      AgentConfig(id: 'gemini', name: 'Gemini CLI', command: 'gemini'),
      AgentConfig(id: 'opencode', name: 'OpenCode', command: 'opencode'),
    ]);
  }

  AgentConfig? getAgentById(String id) {
    for (final agent in _agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }

  void addAgent(AgentConfig agent) => _agents.add(agent);
  void removeAgent(String id) => _agents.removeWhere((a) => a.id == id);
}