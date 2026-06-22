enum AgentStatus { running, waiting, idle, error }

class AgentState {
  final String id;
  final String name;
  final AgentStatus status;
  final DateTime lastActive;
  final int? exitCode;
  final String? errorMessage;

  AgentState({
    required this.id,
    required this.name,
    required this.status,
    DateTime? lastActive,
    this.exitCode,
    this.errorMessage,
  }) : lastActive = lastActive ?? DateTime.now();

  AgentState copyWith({
    String? id,
    String? name,
    AgentStatus? status,
    int? exitCode,
    String? errorMessage,
  }) {
    return AgentState(
      id: id ?? this.id,
      name: name ?? this.name,
      status: status ?? this.status,
      lastActive: DateTime.now(),
      exitCode: exitCode ?? this.exitCode,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
