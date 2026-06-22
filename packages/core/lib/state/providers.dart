import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../agent/agent_state.dart';
import '../workspace/workspace_state.dart';
import '../notification/notification_state.dart';
import 'persistence_service.dart';

class AgentNotifier extends StateNotifier<List<AgentState>> {
  AgentNotifier() : super([]);

  void addAgent(AgentState agent) => state = [...state, agent];
  void updateAgent(String id, AgentState updated) =>
      state = state.map((a) => a.id == id ? updated : a).toList();
  void removeAgent(String id) => state = state.where((a) => a.id != id).toList();
}

final agentProvider = StateNotifierProvider<AgentNotifier, List<AgentState>>(
  (ref) => AgentNotifier(),
);

class WorkspaceNotifier extends StateNotifier<List<WorkspaceState>> {
  WorkspaceNotifier() : super([]);

  void addWorkspace(WorkspaceState ws) {
    state = [...state, ws];
    _persist();
  }
  
  void updateWorkspace(String id, {String? name, String? path}) {
    state = state.map((w) {
      if (w.id == id) {
        return w.copyWith(name: name, path: path);
      }
      return w;
    }).toList();
    _persist();
  }
  
  void removeWorkspace(String id) {
    state = state.where((w) => w.id != id).toList();
    _persist();
  }

  void addTab(String workspaceId, TabState tab) {
    state = state.map((w) {
      if (w.id == workspaceId) {
        return WorkspaceState(
          id: w.id,
          name: w.name,
          path: w.path,
          createdAt: w.createdAt,
          updatedAt: DateTime.now(),
          tabs: [...w.tabs, tab],
        );
      }
      return w;
    }).toList();
    _persist();
  }

  void removeTab(String workspaceId, String tabId) {
    state = state.map((w) {
      if (w.id == workspaceId) {
        return WorkspaceState(
          id: w.id,
          name: w.name,
          path: w.path,
          createdAt: w.createdAt,
          updatedAt: DateTime.now(),
          tabs: w.tabs.where((t) => t.id != tabId).toList(),
        );
      }
      return w;
    }).toList();
    _persist();
  }

  void updateTab(String workspaceId, String tabId, {String? title}) {
    state = state.map((w) {
      if (w.id == workspaceId) {
        return WorkspaceState(
          id: w.id,
          name: w.name,
          path: w.path,
          createdAt: w.createdAt,
          updatedAt: DateTime.now(),
          tabs: w.tabs.map((t) {
            if (t.id == tabId) {
              return TabState(
                id: t.id,
                title: title ?? t.title,
                agentId: t.agentId,
                workingDirectory: t.workingDirectory,
              );
            }
            return t;
          }).toList(),
        );
      }
      return w;
    }).toList();
    _persist();
  }

  Future<void> loadFromDisk() async {
    final workspaces = await PersistenceService.loadWorkspaces();
    state = workspaces;
  }

  void _persist() {
    PersistenceService.saveWorkspaces(state);
  }
}

final workspaceProvider =
    StateNotifierProvider<WorkspaceNotifier, List<WorkspaceState>>(
  (ref) {
    final notifier = WorkspaceNotifier();
    // Load from disk on initialization
    notifier.loadFromDisk();
    return notifier;
  },
);

class NotificationNotifier extends StateNotifier<List<NotificationState>> {
  NotificationNotifier() : super([]);

  void addNotification(NotificationState notif) => state = [notif, ...state];
  void markAsRead(String id) =>
      state = state.map((n) => n.id == id ? n.markAsRead() : n).toList();
  int get unreadCount => state.where((n) => !n.isRead).length;
}

final notificationProvider =
    StateNotifierProvider<NotificationNotifier, List<NotificationState>>(
  (ref) => NotificationNotifier(),
);

final selectedWorkspaceIdProvider = StateProvider<String?>((ref) => null);
final selectedTabIdProvider = StateProvider<String?>((ref) => null);
