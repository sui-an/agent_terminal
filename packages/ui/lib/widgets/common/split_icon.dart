import 'package:flutter/material.dart';

/// macOS-native style split icons, mirroring the SF Symbols
/// `rectangle.split.2x1` (split right) and `rectangle.split.1x2` (split down)
/// used in the system Window menu: a rounded rectangle divided by a single
/// line, drawn as a thin stroke so it matches the toolbar icon weight.
class SplitIcon extends StatelessWidget {
  /// When true draws a vertical divider (two panes side-by-side → Split Right).
  /// When false draws a horizontal divider (two panes stacked → Split Down).
  final bool horizontal;
  final double size;
  final Color? color;

  const SplitIcon({
    super.key,
    required this.horizontal,
    this.size = 16,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? const Color(0xFF000000);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SplitIconPainter(horizontal: horizontal, color: c),
      ),
    );
  }
}

class _SplitIconPainter extends CustomPainter {
  final bool horizontal;
  final Color color;

  _SplitIconPainter({required this.horizontal, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = (size.shortestSide * 0.085).clamp(1.0, 1.6);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    // Inset so the stroke stays inside the box.
    final inset = stroke / 2 + size.shortestSide * 0.08;
    final rect = Rect.fromLTRB(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
    );
    final radius = Radius.circular(size.shortestSide * 0.18);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);

    // Divider line.
    if (horizontal) {
      final x = rect.center.dx;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
    } else {
      final y = rect.center.dy;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
  }

  @override
  bool shouldRepaint(_SplitIconPainter old) =>
      old.horizontal != horizontal || old.color != color;
}
