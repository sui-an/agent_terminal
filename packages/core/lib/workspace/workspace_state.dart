class TabState {
  final String id;
  final String title;
  final String? agentId;
  final String? workingDirectory;

  TabState({
    required this.id,
    required this.title,
    this.agentId,
    this.workingDirectory,
  });

  factory TabState.fromJson(Map<String, dynamic> json) {
    return TabState(
      id: json['id'] as String,
      title: json['title'] as String,
      agentId: json['agentId'] as String?,
      workingDirectory: json['workingDirectory'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (agentId != null) 'agentId': agentId,
        if (workingDirectory != null) 'workingDirectory': workingDirectory,
      };
}

class WorkspaceState {
  final String id;
  final String name;
  final String path;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<TabState> tabs;

  WorkspaceState({
    required this.id,
    required this.name,
    required this.path,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<TabState>? tabs,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        tabs = tabs ?? [];

  WorkspaceState copyWith({String? name, String? path}) {
    return WorkspaceState(
      id: id,
      name: name ?? this.name,
      path: path ?? this.path,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      tabs: tabs,
    );
  }

  factory WorkspaceState.fromJson(Map<String, dynamic> json) {
    return WorkspaceState(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      tabs: (json['tabs'] as List?)
              ?.map((t) => TabState.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'tabs': tabs.map((t) => t.toJson()).toList(),
      };
}
