import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/widgets/sidebar/sidebar.dart';
import 'package:core/workspace/workspace_state.dart';

void main() {
  testWidgets('should display workspaces', (tester) async {
    final workspaces = [
      WorkspaceState(id: 'ws-1', name: 'Project 1', path: '/path/1'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Sidebar(
          workspaces: workspaces,
          onWorkspaceSelected: (_) {},
          onWorkspaceCreated: (_, __) {},
          onWorkspaceDeleted: (_) {},
          onWorkspaceRenamed: (_, __) {},
        ),
      ),
    ));

    expect(find.text('Project 1'), findsOneWidget);
  });

  testWidgets('should display multiple workspaces', (tester) async {
    final workspaces = [
      WorkspaceState(id: 'ws-1', name: 'Project 1', path: '/path/1'),
      WorkspaceState(id: 'ws-2', name: 'Project 2', path: '/path/2'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Sidebar(
          workspaces: workspaces,
          onWorkspaceSelected: (_) {},
          onWorkspaceCreated: (_, __) {},
          onWorkspaceDeleted: (_) {},
          onWorkspaceRenamed: (_, __) {},
        ),
      ),
    ));

    expect(find.text('Project 1'), findsOneWidget);
    expect(find.text('Project 2'), findsOneWidget);
  });

  testWidgets('should highlight selected workspace', (tester) async {
    final workspaces = [
      WorkspaceState(id: 'ws-1', name: 'Project 1', path: '/path/1'),
      WorkspaceState(id: 'ws-2', name: 'Project 2', path: '/path/2'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Sidebar(
          workspaces: workspaces,
          selectedWorkspaceId: 'ws-2',
          onWorkspaceSelected: (_) {},
          onWorkspaceCreated: (_, __) {},
          onWorkspaceDeleted: (_) {},
          onWorkspaceRenamed: (_, __) {},
        ),
      ),
    ));

    // Check that selected workspace has different styling
    final project2Text = tester.widget<Text>(find.text('Project 2'));
    expect(project2Text.style?.fontWeight, FontWeight.w500);
  });

  testWidgets('should call onWorkspaceSelected when tapped', (tester) async {
    String? selectedId;
    final workspaces = [
      WorkspaceState(id: 'ws-1', name: 'Project 1', path: '/path/1'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Sidebar(
          workspaces: workspaces,
          onWorkspaceSelected: (id) => selectedId = id,
          onWorkspaceCreated: (_, __) {},
          onWorkspaceDeleted: (_) {},
          onWorkspaceRenamed: (_, __) {},
        ),
      ),
    ));

    await tester.tap(find.text('Project 1'));
    expect(selectedId, 'ws-1');
  });

  testWidgets('should show add button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Sidebar(
          workspaces: [],
          onWorkspaceSelected: (_) {},
          onWorkspaceCreated: (_, __) {},
          onWorkspaceDeleted: (_) {},
          onWorkspaceRenamed: (_, __) {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.add), findsOneWidget);
  });
}
