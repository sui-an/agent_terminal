import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/widgets/terminal/split_pane.dart';

void main() {
  testWidgets('should display both children', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: SplitPane(
            direction: SplitDirection.horizontal,
            child1: const Text('Left'),
            child2: const Text('Right'),
          ),
        ),
      ),
    ));
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Right'), findsOneWidget);
  });
}
