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

class PanelState {
  final String id;
  final List<TabState> tabs;
  final String? selectedTabId;

  PanelState({
    required this.id,
    List<TabState>? tabs,
    this.selectedTabId,
  }) : tabs = tabs ?? [];

  PanelState copyWith({
    String? id,
    List<TabState>? tabs,
    String? selectedTabId,
  }) {
    return PanelState(
      id: id ?? this.id,
      tabs: tabs ?? this.tabs,
      selectedTabId: selectedTabId ?? this.selectedTabId,
    );
  }

  factory PanelState.fromJson(Map<String, dynamic> json) {
    return PanelState(
      id: json['id'] as String,
      tabs: (json['tabs'] as List?)
              ?.map((t) => TabState.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
      selectedTabId: json['selectedTabId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'tabs': tabs.map((t) => t.toJson()).toList(),
        if (selectedTabId != null) 'selectedTabId': selectedTabId,
      };
}

class WorkspaceState {
  final String id;
  final String name;
  final String path;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<PanelState> panels;
  final String? splitDirection;
  final double splitRatio;

  WorkspaceState({
    required this.id,
    required this.name,
    required this.path,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<PanelState>? panels,
    this.splitDirection,
    this.splitRatio = 0.5,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        panels = panels ?? [];

  WorkspaceState copyWith({
    String? name,
    String? path,
    List<PanelState>? panels,
    String? splitDirection,
    double? splitRatio,
  }) {
    return WorkspaceState(
      id: id,
      name: name ?? this.name,
      path: path ?? this.path,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      panels: panels ?? this.panels,
      splitDirection: splitDirection ?? this.splitDirection,
      splitRatio: splitRatio ?? this.splitRatio,
    );
  }

  factory WorkspaceState.fromJson(Map<String, dynamic> json) {
    return WorkspaceState(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      panels: (json['panels'] as List?)
              ?.map((p) => PanelState.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [],
      splitDirection: json['splitDirection'] as String?,
      splitRatio: (json['splitRatio'] as num?)?.toDouble() ?? 0.5,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'panels': panels.map((p) => p.toJson()).toList(),
        if (splitDirection != null) 'splitDirection': splitDirection,
        'splitRatio': splitRatio,
      };
}
