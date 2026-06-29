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

  void addPanel(String wsId, PanelState panel) {
    state = state.map((w) {
      if (w.id == wsId) {
        return w.copyWith(panels: [...w.panels, panel]);
      }
      return w;
    }).toList();
    _persist();
  }

  void removePanel(String wsId, String panelId) {
    state = state.map((w) {
      if (w.id == wsId) {
        final matches = w.panels.where((p) => p.id == panelId).toList();
        if (matches.isEmpty) return w;
        final target = matches.first;
        final remaining = w.panels.where((p) => p.id != panelId).toList();
        if (remaining.isEmpty) {
          final merged = PanelState(
            id: 'default',
            tabs: target.tabs,
            selectedTabId: target.selectedTabId,
          );
          return w.copyWith(panels: [merged], splitDirection: null);
        }
        final last = remaining.last;
        remaining[remaining.length - 1] = last.copyWith(
          tabs: [...last.tabs, ...target.tabs],
          selectedTabId: last.selectedTabId ?? target.selectedTabId,
        );
        return w.copyWith(panels: remaining, splitDirection: null);
      }
      return w;
    }).toList();
    _persist();
  }

  void updatePanel(String wsId, String panelId,
      {List<TabState>? tabs, String? selectedTabId}) {
    state = state.map((w) {
      if (w.id == wsId) {
        final updated = w.panels.map((p) {
          if (p.id == panelId) {
            return p.copyWith(tabs: tabs, selectedTabId: selectedTabId);
          }
          return p;
        }).toList();
        return w.copyWith(panels: updated);
      }
      return w;
    }).toList();
    _persist();
  }

  void setSplitConfig(String wsId, {String? direction, double? ratio}) {
    state = state.map((w) {
      if (w.id == wsId) {
        return w.copyWith(splitDirection: direction, splitRatio: ratio);
      }
      return w;
    }).toList();
    _persist();
  }

  void moveTabBetweenPanels(String wsId, String fromPanelId, String toPanelId,
      String tabId, {int? insertIndex}) {
    state = state.map((w) {
      if (w.id == wsId) {
        PanelState? fromPanel;
        List<PanelState> panels = w.panels.map((p) {
          if (p.id == fromPanelId) {
            fromPanel = p;
            return p.copyWith(
                tabs: p.tabs.where((t) => t.id != tabId).toList());
          }
          return p;
        }).toList();
        if (fromPanel == null) return w;
        final tabMatches = fromPanel!.tabs.where((t) => t.id == tabId).toList();
        if (tabMatches.isEmpty) return w;
        final tab = tabMatches.first;
        panels = panels.map((p) {
          if (p.id == toPanelId) {
            final newTabs = List<TabState>.from(p.tabs);
            final idx = (insertIndex ?? newTabs.length).clamp(0, newTabs.length);
            newTabs.insert(idx, tab);
            return p.copyWith(tabs: newTabs);
          }
          return p;
        }).toList();
        return w.copyWith(panels: panels);
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
