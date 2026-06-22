import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/state/providers.dart';
import 'package:core/workspace/workspace_state.dart';
import 'package:core/agent/agent_config_manager.dart';
import '../widgets/sidebar/sidebar.dart';
import '../widgets/tabs/tab_bar.dart';
import '../widgets/terminal/terminal_pane.dart';
import '../widgets/terminal/split_pane.dart';
import '../widgets/notification/notification_panel.dart';
import '../widgets/common/smart_tooltip.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _sidebarVisible = true;
  bool _notifVisible = false;
  bool _splitHorizontal = false;
  int _splitCount = 1;
  double _sidebarWidth = 220;

  @override
  Widget build(BuildContext context) {
    final workspaces = ref.watch(workspaceProvider);
    final selectedWsId = ref.watch(selectedWorkspaceIdProvider);
    final selectedTabId = ref.watch(selectedTabIdProvider);
    final notifications = ref.watch(notificationProvider);
    final unreadCount = notifications.where((n) => !n.isRead).length;

    final ws = workspaces.isNotEmpty
        ? workspaces.where((w) => w.id == selectedWsId).firstOrNull ?? workspaces.firstOrNull
        : null;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Column(
        children: [
          // ── Title Bar ──
          Container(
            height: 28,
            decoration: BoxDecoration(
              color: Theme.of(context).appBarTheme.backgroundColor,
              border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 70), // traffic lights spacer
                Text('AgentTerminal', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                const Spacer(),
                // Sidebar toggle (right side)
                _SmallBtn(
                  icon: _sidebarVisible ? Icons.menu_open : Icons.menu,
                  tooltip: _sidebarVisible ? 'Hide Sidebar' : 'Show Sidebar',
                  onTap: () => setState(() => _sidebarVisible = !_sidebarVisible),
                ),
                const SizedBox(width: 4),
                // Notification (right side)
                _SmallBtn(
                  icon: Icons.notifications_outlined,
                  tooltip: 'Notifications',
                  onTap: () => setState(() => _notifVisible = !_notifVisible),
                  badge: unreadCount,
                ),
              ],
            ),
          ),
          // ── Body ──
          Expanded(
            child: Row(
              children: [
                // Sidebar with settings at bottom
                if (_sidebarVisible)
                  _ResizableSidebar(
                    width: _sidebarWidth,
                    onWidthChanged: (w) => setState(() => _sidebarWidth = w),
                    child: Sidebar(
                      workspaces: workspaces,
                      selectedWorkspaceId: selectedWsId,
                      onWorkspaceSelected: (id) {
                        ref.read(selectedWorkspaceIdProvider.notifier).state = id;
                        final w = workspaces.where((x) => x.id == id).firstOrNull;
                        if (w != null && w.tabs.isNotEmpty) {
                          ref.read(selectedTabIdProvider.notifier).state = w.tabs.first.id;
                        } else {
                          ref.read(selectedTabIdProvider.notifier).state = null;
                        }
                      },
                      onWorkspaceCreated: (name, path) {
                        final id = 'ws-${DateTime.now().millisecondsSinceEpoch}';
                        ref.read(workspaceProvider.notifier).addWorkspace(WorkspaceState(id: id, name: name, path: path));
                        ref.read(selectedWorkspaceIdProvider.notifier).state = id;
                      },
                      onWorkspaceDeleted: (id) {
                        ref.read(workspaceProvider.notifier).removeWorkspace(id);
                        if (ref.read(selectedWorkspaceIdProvider) == id) {
                          ref.read(selectedWorkspaceIdProvider.notifier).state = null;
                          ref.read(selectedTabIdProvider.notifier).state = null;
                        }
                      },
                      onWorkspaceRenamed: (id, name) {
                        ref.read(workspaceProvider.notifier).updateWorkspace(id, name: name);
                      },
                      onSettings: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                    ),
                  ),
                // Main content
                Expanded(
                  child: Column(
                    children: [
                      // Tab bar
                      TabBarWidget(
                        tabs: ws?.tabs ?? [],
                        selectedTabId: selectedTabId,
                        onTabSelected: (id) => ref.read(selectedTabIdProvider.notifier).state = id,
                        onTabClosed: (id) {
                          if (ws != null) {
                            ref.read(workspaceProvider.notifier).removeTab(ws.id, id);
                            if (ref.read(selectedTabIdProvider) == id) {
                              final rest = ws.tabs.where((t) => t.id != id).toList();
                              ref.read(selectedTabIdProvider.notifier).state =
                                  rest.isNotEmpty ? rest.first.id : null;
                            }
                          }
                        },
                        onNewTab: ws != null
                            ? () {
                                final tid = 'tab-${DateTime.now().millisecondsSinceEpoch}';
                                ref.read(workspaceProvider.notifier).addTab(
                                      ws.id,
                                      TabState(id: tid, title: 'Terminal ${ws.tabs.length + 1}'),
                                    );
                                ref.read(selectedTabIdProvider.notifier).state = tid;
                              }
                            : null,
                      ),
                      // Terminal area
                      Expanded(
                        child: selectedTabId != null
                            ? _buildTerminalContent()
                            : _EmptyState(onCreate: () => _showCreateDialog(context)),
                      ),
                    ],
                  ),
                ),
                // Notification panel
                if (_notifVisible)
                  NotificationPanel(
                    notifications: notifications,
                    onNotificationTap: (id) {},
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalContent() {
    final workspaces = ref.watch(workspaceProvider);
    final selectedWsId = ref.read(selectedWorkspaceIdProvider);
    final selectedTabId = ref.read(selectedTabIdProvider);

    String currentAgentName = 'Terminal';
    if (selectedWsId != null && selectedTabId != null) {
      final ws = workspaces.where((w) => w.id == selectedWsId).firstOrNull;
      if (ws != null) {
        final tab = ws.tabs.where((t) => t.id == selectedTabId).firstOrNull;
        if (tab?.agentId != null) {
          final agent = AgentConfigManager().getAgentById(tab!.agentId!);
          currentAgentName = agent?.name ?? 'Terminal';
        }
      }
    }

    if (_splitCount <= 1) {
      return TerminalPane(
        sessionId: 1,
        agentName: currentAgentName,
        onSplit: (direction) {
          setState(() {
            _splitHorizontal = direction == 'horizontal';
            _splitCount = 2;
          });
        },
        onClose: () {},
      );
    }

    Widget result = TerminalPane(
      sessionId: 1,
      agentName: '$currentAgentName 1',
      onSplit: (direction) {
        setState(() {
          _splitHorizontal = direction == 'horizontal';
          _splitCount = (_splitCount + 1).clamp(2, 4);
        });
      },
      onClose: () {
        setState(() => _splitCount = (_splitCount - 1).clamp(1, 4));
      },
    );

    for (int i = 1; i < _splitCount; i++) {
      final index = i;
      result = SplitPane(
        direction: _splitHorizontal ? SplitDirection.horizontal : SplitDirection.vertical,
        initialRatio: 1.0 / (index + 1),
        child1: result,
        child2: TerminalPane(
          sessionId: index + 1,
          agentName: 'Terminal',
          onSplit: (direction) {
            setState(() {
              _splitHorizontal = direction == 'horizontal';
              _splitCount = (_splitCount + 1).clamp(2, 4);
            });
          },
          onClose: () {
            setState(() => _splitCount = (_splitCount - 1).clamp(1, 4));
          },
        ),
      );
    }

    return result;
  }

  void _showCreateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CreateDialog(
        onCreated: (name, path) {
          final id = 'ws-${DateTime.now().millisecondsSinceEpoch}';
          ref.read(workspaceProvider.notifier).addWorkspace(WorkspaceState(id: id, name: name, path: path));
          ref.read(selectedWorkspaceIdProvider.notifier).state = id;
        },
      ),
    );
  }
}

// ── Resizable Sidebar ──
class _ResizableSidebar extends StatefulWidget {
  final double width;
  final ValueChanged<double> onWidthChanged;
  final Widget child;

  const _ResizableSidebar({
    required this.width,
    required this.onWidthChanged,
    required this.child,
  });

  @override
  State<_ResizableSidebar> createState() => _ResizableSidebarState();
}

class _ResizableSidebarState extends State<_ResizableSidebar> {
  static const double _minWidth = 150;
  static const double _maxWidth = 400;

  // While dragging holds the live ghost-line position; null when idle.
  double? _dragWidth;

  bool get _isDragging => _dragWidth != null;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return SizedBox(
      width: widget.width,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: widget.child),
          // Ghost line that tracks the cursor during a drag. Drawn in the
          // Stack (clip disabled) so it can move past the sidebar's current
          // right edge when enlarging.
          if (_isDragging)
            Positioned(
              top: 0,
              bottom: 0,
              left: _dragWidth! - 1,
              child: IgnorePointer(
                child: Container(width: 2, color: primary),
              ),
            ),
          // Drag handle pinned to the right edge.
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (_) =>
                  setState(() => _dragWidth = widget.width),
              onHorizontalDragUpdate: (details) {
                setState(() {
                  _dragWidth =
                      (_dragWidth! + details.delta.dx).clamp(_minWidth, _maxWidth);
                });
              },
              onHorizontalDragEnd: (_) {
                final target = _dragWidth;
                setState(() => _dragWidth = null);
                if (target != null) widget.onWidthChanged(target);
              },
              onHorizontalDragCancel: () => setState(() => _dragWidth = null),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: SizedBox(
                  width: 12,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      width: 2,
                      color: _isDragging
                          ? Colors.transparent
                          : Theme.of(context).dividerColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Small Button ──
class _SmallBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final int? badge;
  final String? tooltip;

  const _SmallBtn({required this.icon, required this.onTap, this.badge, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final btn = SizedBox(
      width: 24,
      height: 24,
      child: IconButton(
        icon: Icon(icon, size: 14),
        onPressed: onTap,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        tooltip != null ? SmartTooltip(message: tooltip!, direction: TooltipDirection.left, child: btn) : btn,
        if (badge != null && badge! > 0)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
              child: Text('$badge', style: const TextStyle(color: Colors.white, fontSize: 8)),
            ),
          ),
      ],
    );
  }
}

// ── Empty State ──
class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.terminal, size: 56, color: Theme.of(context).iconTheme.color?.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('Welcome to AgentTerminal', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Create a workspace to get started', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),
          FilledButton.icon(onPressed: onCreate, icon: const Icon(Icons.add, size: 18), label: const Text('New Workspace')),
        ],
      ),
    );
  }
}

// ── Create Dialog ──
class _CreateDialog extends StatefulWidget {
  final Function(String, String) onCreated;
  const _CreateDialog({required this.onCreated});
  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final _name = TextEditingController();
  String _path = '';

  @override
  void dispose() { _name.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Workspace'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', hintText: 'My Project'), autofocus: true),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(_path.isEmpty ? 'No path selected' : _path,
                      style: TextStyle(fontSize: 12, color: _path.isEmpty ? Theme.of(context).textTheme.bodySmall?.color : Theme.of(context).textTheme.bodyMedium?.color),
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(onPressed: _pickPath, child: const Text('Browse')),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: (_name.text.isNotEmpty && _path.isNotEmpty)
              ? () { widget.onCreated(_name.text, _path); Navigator.pop(context); }
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }

  void _pickPath() async {
    final p = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('Title'),
          content: TextField(controller: c, decoration: const InputDecoration(hintText: '/Users/...')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Select')),
          ],
        );
      },
    );
    if (p != null && p.isNotEmpty) setState(() => _path = p);
  }
}
