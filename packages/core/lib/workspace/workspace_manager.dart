import 'dart:convert';
import 'dart:io';
import 'workspace_state.dart';

class WorkspaceManager {
  final List<WorkspaceState> _workspaces = [];
  static const String _fileName = 'workspaces.json';
  String? _storagePath;

  List<WorkspaceState> get workspaces => List.unmodifiable(_workspaces);

  void setStoragePath(String path) => _storagePath = path;

  WorkspaceState createWorkspace({required String name, required String path}) {
    final ws = WorkspaceState(
      id: 'ws-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      path: path,
    );
    _workspaces.add(ws);
    return ws;
  }

  WorkspaceState? getWorkspace(String id) {
    for (final w in _workspaces) {
      if (w.id == id) return w;
    }
    return null;
  }

  void updateWorkspace(String id, {String? name, String? path}) {
    final index = _workspaces.indexWhere((w) => w.id == id);
    if (index != -1) {
      _workspaces[index] = _workspaces[index].copyWith(name: name, path: path);
    }
  }

  void deleteWorkspace(String id) => _workspaces.removeWhere((w) => w.id == id);

  Map<String, dynamic> toJson() => {
        'workspaces': _workspaces.map((w) => w.toJson()).toList(),
      };

  void fromJson(Map<String, dynamic> json) {
    _workspaces.clear();
    _workspaces.addAll(
      (json['workspaces'] as List)
          .map((w) => WorkspaceState.fromJson(w as Map<String, dynamic>)),
    );
  }

  Future<void> save() async {
    if (_storagePath == null) return;
    final file = File('$_storagePath/$_fileName');
    await file.writeAsString(jsonEncode(toJson()));
  }

  Future<void> load() async {
    if (_storagePath == null) return;
    try {
      final file = File('$_storagePath/$_fileName');
      if (await file.exists()) {
        fromJson(jsonDecode(await file.readAsString()));
      }
    } catch (e) {
      print('Warning: Failed to load workspaces: $e');
    }
  }
}
