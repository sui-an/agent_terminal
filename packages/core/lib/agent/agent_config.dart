class StatusDetectionConfig {
  final String method;
  final List<int>? oscCodes;

  StatusDetectionConfig({required this.method, this.oscCodes});

  factory StatusDetectionConfig.fromJson(Map<String, dynamic> json) {
    return StatusDetectionConfig(
      method: json['method'] as String,
      oscCodes: (json['oscCodes'] as List?)?.cast<int>(),
    );
  }

  Map<String, dynamic> toJson() => {
        'method': method,
        if (oscCodes != null) 'oscCodes': oscCodes,
      };
}

class AgentConfig {
  final String id;
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final StatusDetectionConfig statusDetection;

  AgentConfig({
    required this.id,
    required this.name,
    required this.command,
    this.args = const [],
    this.env = const {},
    StatusDetectionConfig? statusDetection,
  }) : statusDetection = statusDetection ?? StatusDetectionConfig(method: 'exitCode');

  factory AgentConfig.fromJson(Map<String, dynamic> json) {
    return AgentConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      command: json['command'] as String,
      args: (json['args'] as List?)?.cast<String>() ?? [],
      env: (json['env'] as Map?)?.cast<String, String>() ?? {},
      statusDetection: json['statusDetection'] != null
          ? StatusDetectionConfig.fromJson(json['statusDetection'])
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'command': command,
        'args': args,
        'env': env,
        'statusDetection': statusDetection.toJson(),
      };

  static List<AgentConfig> parseAgentsJson(Map<String, dynamic> json) {
    return (json['agents'] as List)
        .map((a) => AgentConfig.fromJson(a as Map<String, dynamic>))
        .toList();
  }
}
