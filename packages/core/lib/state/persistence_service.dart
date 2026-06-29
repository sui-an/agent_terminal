import 'dart:convert';
import 'dart:io';
import '../workspace/workspace_state.dart';

class PersistenceService {
  static const String _workspacesFile = 'workspaces.json';
  static String? _storagePath;

  static void setStoragePath(String path) {
    _storagePath = path;
  }

  static String get _appDir {
    return _storagePath ?? Directory.current.path;
  }

  // ── Workspaces ──
  
  static Future<void> saveWorkspaces(List<WorkspaceState> workspaces) async {
    if (_storagePath == null) return;
    try {
      final file = File('$_appDir/$_workspacesFile');
      final json = jsonEncode({
        'workspaces': workspaces.map((w) => w.toJson()).toList(),
      });
      await file.writeAsString(json);
    } catch (e) {
      print('Warning: Failed to save workspaces: $e');
    }
  }

  static Future<List<WorkspaceState>> loadWorkspaces() async {
    if (_storagePath == null) return [];
    try {
      final file = File('$_appDir/$_workspacesFile');
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final workspaces = (json['workspaces'] as List)
            .map((w) => _migrateWorkspace(w as Map<String, dynamic>))
            .toList();
        return workspaces;
      }
    } catch (e) {
      print('Warning: Failed to load workspaces: $e');
    }
    return [];
  }

  static WorkspaceState _migrateWorkspace(Map<String, dynamic> json) {
    final ws = WorkspaceState.fromJson(json);
    if (ws.panels.isNotEmpty) return ws;
    final oldTabs = json['tabs'] as List?;
    if (oldTabs != null && oldTabs.isNotEmpty) {
      final tabs = oldTabs
          .map((t) => TabState.fromJson(t as Map<String, dynamic>))
          .toList();
      final firstTabId = tabs.first.id;
      return ws.copyWith(
        panels: [
          PanelState(
            id: '${ws.id}-panel-1',
            tabs: tabs,
            selectedTabId: firstTabId,
          ),
        ],
      );
    }
    final tabId = 'tab-${DateTime.now().millisecondsSinceEpoch}';
    return ws.copyWith(
      panels: [
        PanelState(
          id: '${ws.id}-panel-1',
          tabs: [TabState(id: tabId, title: 'Terminal 1')],
          selectedTabId: tabId,
        ),
      ],
    );
  }
}
