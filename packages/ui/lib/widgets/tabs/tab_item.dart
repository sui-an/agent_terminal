import 'package:flutter/material.dart';
import 'package:core/workspace/workspace_state.dart';

class TabItem extends StatefulWidget {
  final TabState tab;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const TabItem({
    super.key,
    required this.tab,
    required this.isSelected,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<TabItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? Theme.of(context).colorScheme.surface
                : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: widget.isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.tab.title,
                style: TextStyle(
                  fontSize: 13,
                  color: widget.isSelected
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
              if (_isHovered) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: widget.onClose,
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
