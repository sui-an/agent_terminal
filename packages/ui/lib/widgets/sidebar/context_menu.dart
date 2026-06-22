import 'package:flutter/material.dart';

class ContextMenuItem {
  final String label;
  final IconData icon;

  ContextMenuItem({required this.label, required this.icon});
}

class ContextMenu extends StatelessWidget {
  final List<ContextMenuItem> items;
  final ValueChanged<ContextMenuItem> onSelected;
  final Widget child;

  const ContextMenu({
    super.key,
    required this.items,
    required this.onSelected,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) {
        showMenu<ContextMenuItem>(
          context: context,
          position: RelativeRect.fromLTRB(
            details.globalPosition.dx,
            details.globalPosition.dy,
            details.globalPosition.dx + 1,
            details.globalPosition.dy + 1,
          ),
          items: items
              .map((item) => PopupMenuItem(value: item, child: Row(
                    children: [Icon(item.icon, size: 18), const SizedBox(width: 8), Text(item.label)],
                  )))
              .toList(),
        ).then((item) {
          if (item != null) onSelected(item);
        });
      },
      child: child,
    );
  }
}
