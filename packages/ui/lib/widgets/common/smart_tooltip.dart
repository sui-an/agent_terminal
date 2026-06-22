import 'dart:async';
import 'package:flutter/material.dart';

/// Placement of the tooltip bubble relative to its child.
enum TooltipDirection { above, below, left, right }

/// A hover tooltip that can be placed on any side of its child.
///
/// Flutter's built-in [Tooltip] only flips vertically (above/below) to stay
/// on screen, so buttons near the left/right window edges get clipped. This
/// widget anchors the bubble with a [LayerLink] and lets callers force the
/// side (e.g. right for bottom-left buttons, left for top-right buttons) so
/// the bubble always renders inside the window bounds.
class SmartTooltip extends StatefulWidget {
  final String message;
  final Widget child;

  /// Preferred side for the bubble. When null, falls back to [preferBelow].
  final TooltipDirection? direction;

  /// Backwards-compatible flag used when [direction] is null.
  final bool preferBelow;

  const SmartTooltip({
    super.key,
    required this.message,
    required this.child,
    this.direction,
    this.preferBelow = true,
  });

  @override
  State<SmartTooltip> createState() => _SmartTooltipState();
}

class _SmartTooltipState extends State<SmartTooltip> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();
  Timer? _showTimer;
  Timer? _hideTimer;

  TooltipDirection get _direction =>
      widget.direction ??
      (widget.preferBelow ? TooltipDirection.below : TooltipDirection.above);

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleShow() {
    _hideTimer?.cancel();
    if (_portal.isShowing) return;
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _portal.show();
    });
  }

  void _scheduleHide() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _portal.hide();
    });
  }

  ({Alignment target, Alignment follower, Offset offset}) _anchors() {
    const gap = 8.0;
    switch (_direction) {
      case TooltipDirection.right:
        return (
          target: Alignment.centerRight,
          follower: Alignment.centerLeft,
          offset: const Offset(gap, 0),
        );
      case TooltipDirection.left:
        return (
          target: Alignment.centerLeft,
          follower: Alignment.centerRight,
          offset: const Offset(-gap, 0),
        );
      case TooltipDirection.above:
        return (
          target: Alignment.topCenter,
          follower: Alignment.bottomCenter,
          offset: const Offset(0, -gap),
        );
      case TooltipDirection.below:
        return (
          target: Alignment.bottomCenter,
          follower: Alignment.topCenter,
          offset: const Offset(0, gap),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final anchors = _anchors();

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) {
          return Positioned(
            // Width is unconstrained so the bubble sizes to its text; the
            // follower handles positioning relative to the target.
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: anchors.target,
              followerAnchor: anchors.follower,
              offset: anchors.offset,
              child: MouseRegion(
                onEnter: (_) => _hideTimer?.cancel(),
                onExit: (_) => _scheduleHide(),
                child: _TooltipBubble(message: widget.message),
              ),
            ),
          );
        },
        child: MouseRegion(
          onEnter: (_) => _scheduleShow(),
          onExit: (_) => _scheduleHide(),
          child: widget.child,
        ),
      ),
    );
  }
}

class _TooltipBubble extends StatelessWidget {
  final String message;
  const _TooltipBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        constraints: const BoxConstraints(maxWidth: 240),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          message,
          style: TextStyle(fontSize: 12, color: scheme.onInverseSurface),
        ),
      ),
    );
  }
}
