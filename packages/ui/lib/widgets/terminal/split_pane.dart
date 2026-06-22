import 'package:flutter/material.dart';

enum SplitDirection { horizontal, vertical }

class SplitPane extends StatefulWidget {
  final SplitDirection direction;
  final double initialRatio;
  final Widget child1;
  final Widget child2;

  const SplitPane({
    super.key,
    required this.direction,
    this.initialRatio = 0.5,
    required this.child1,
    required this.child2,
  });

  @override
  State<SplitPane> createState() => _SplitPaneState();
}

class _SplitPaneState extends State<SplitPane> {
  late double _ratio;

  @override
  void initState() {
    super.initState();
    _ratio = widget.initialRatio;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isH = widget.direction == SplitDirection.horizontal;

        return Flex(
          direction: isH ? Axis.horizontal : Axis.vertical,
          children: [
            Expanded(
              flex: (_ratio * 1000).toInt(),
              child: widget.child1,
            ),
            GestureDetector(
              onPanUpdate: (d) {
                setState(() {
                  final total = isH ? constraints.maxWidth : constraints.maxHeight;
                  final delta = isH ? d.delta.dx : d.delta.dy;
                  _ratio = (_ratio + delta / total).clamp(0.1, 0.9);
                });
              },
              child: Container(
                width: isH ? 4 : constraints.maxWidth,
                height: isH ? constraints.maxHeight : 4,
                color: Theme.of(context).dividerColor,
              ),
            ),
            Expanded(
              flex: ((1 - _ratio) * 1000).toInt(),
              child: widget.child2,
            ),
          ],
        );
      },
    );
  }
}
