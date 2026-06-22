import 'package:flutter/material.dart';
import 'package:core/workspace/workspace_state.dart';
import '../common/smart_tooltip.dart';
import 'workspace_list.dart';

class Sidebar extends StatelessWidget {
  final List<WorkspaceState> workspaces;
  final String? selectedWorkspaceId;
  final ValueChanged<String> onWorkspaceSelected;
  final Function(String name, String path) onWorkspaceCreated;
  final ValueChanged<String> onWorkspaceDeleted;
  final Function(String id, String newName) onWorkspaceRenamed;
  final VoidCallback? onSettings;

  const Sidebar({
    super.key,
    required this.workspaces,
    this.selectedWorkspaceId,
    required this.onWorkspaceSelected,
    required this.onWorkspaceCreated,
    required this.onWorkspaceDeleted,
    required this.onWorkspaceRenamed,
    this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(right: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('Workspaces', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                _IconButton(icon: Icons.add, tooltip: 'New Workspace', onPressed: () => _showCreateDialog(context)),
              ],
            ),
          ),
          const Divider(height: 1),
          // Workspace list
          Expanded(
            child: WorkspaceList(
              workspaces: workspaces,
              selectedWorkspaceId: selectedWorkspaceId,
              onWorkspaceSelected: onWorkspaceSelected,
              onWorkspaceDeleted: onWorkspaceDeleted,
              onWorkspaceRenamed: onWorkspaceRenamed,
            ),
          ),
          const Divider(height: 1),
          // Settings at bottom
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.settings, size: 16, color: Theme.of(context).iconTheme.color),
                const SizedBox(width: 8),
                Text('Settings', style: Theme.of(context).textTheme.bodyMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 18),
                  onPressed: onSettings,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => _CreateWorkspaceDialog(onCreated: onWorkspaceCreated),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _IconButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SmartTooltip(
      message: tooltip,
      direction: TooltipDirection.right,
      child: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          icon: Icon(icon, size: 16),
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ),
    );
  }
}

class _CreateWorkspaceDialog extends StatefulWidget {
  final Function(String name, String path) onCreated;
  const _CreateWorkspaceDialog({required this.onCreated});
  @override
  State<_CreateWorkspaceDialog> createState() => _CreateWorkspaceDialogState();
}

class _CreateWorkspaceDialogState extends State<_CreateWorkspaceDialog> {
  final _nameCtrl = TextEditingController();
  String _selectedPath = '';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Workspace'),
      content: SizedBox(
        width: 350,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'My Project'),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedPath.isEmpty ? 'No path selected' : _selectedPath,
                    style: TextStyle(
                      color: _selectedPath.isEmpty
                          ? Theme.of(context).colorScheme.onSurface.withOpacity(0.5)
                          : Theme.of(context).colorScheme.onSurface,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _selectPath,
                  child: const Text('Browse'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: (_nameCtrl.text.isNotEmpty && _selectedPath.isNotEmpty)
              ? () => widget.onCreated(_nameCtrl.text, _selectedPath)
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }

  void _selectPath() async {
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Select Path'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: '/Users/username/projects'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Select'),
            ),
          ],
        );
      },
    );
    if (path != null && path.isNotEmpty) {
      setState(() => _selectedPath = path);
    }
  }
}
