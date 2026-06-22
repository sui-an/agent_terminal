import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/widgets/terminal/terminal_pane.dart';
import 'package:ui/widgets/terminal/terminal_view.dart';

void main() {
  testWidgets('should display terminal', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TerminalPane(sessionId: 1)),
    ));
    expect(find.byType(TerminalView), findsOneWidget);
  });
}
