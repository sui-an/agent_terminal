import 'package:flutter/material.dart';
import 'package:core/workspace/workspace_state.dart';
import 'workspace_tile.dart';

class WorkspaceList extends StatelessWidget {
  final List<WorkspaceState> workspaces;
  final String? selectedWorkspaceId;
  final ValueChanged<String> onWorkspaceSelected;
  final ValueChanged<String> onWorkspaceDeleted;
  final Function(String id, String newName) onWorkspaceRenamed;

  const WorkspaceList({
    super.key,
    required this.workspaces,
    this.selectedWorkspaceId,
    required this.onWorkspaceSelected,
    required this.onWorkspaceDeleted,
    required this.onWorkspaceRenamed,
  });

  @override
  Widget build(BuildContext context) {
    if (workspaces.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No workspaces yet\nClick + to create one',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      itemCount: workspaces.length,
      itemBuilder: (context, index) {
        final ws = workspaces[index];
        return WorkspaceTile(
          workspace: ws,
          isSelected: ws.id == selectedWorkspaceId,
          onTap: () => onWorkspaceSelected(ws.id),
          onDelete: () => onWorkspaceDeleted(ws.id),
          onRename: (newName) => onWorkspaceRenamed(ws.id, newName),
        );
      },
    );
  }
}
