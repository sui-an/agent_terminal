import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/widgets/tabs/tab_bar.dart';
import 'package:core/workspace/workspace_state.dart';

void main() {
  testWidgets('should display tabs', (tester) async {
    final tabs = [
      TabState(id: 'tab-1', title: 'Terminal 1'),
      TabState(id: 'tab-2', title: 'Terminal 2'),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TabBarWidget(
          tabs: tabs,
          selectedTabId: 'tab-1',
          panelId: 'panel-1',
          onTabSelected: (_) {},
          onTabClosed: (_) {},
        ),
      ),
    ));

    expect(find.text('Terminal 1'), findsOneWidget);
    expect(find.text('Terminal 2'), findsOneWidget);
  });
}