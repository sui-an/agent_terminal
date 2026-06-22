import 'package:flutter/material.dart';
import '../common/smart_tooltip.dart';
import '../common/split_icon.dart';
import 'terminal_view.dart';

class TerminalPane extends StatefulWidget {
  final int sessionId;
  final String? agentName;
  final Function(String direction)? onSplit;
  final VoidCallback? onClose;

  const TerminalPane({
    super.key,
    required this.sessionId,
    this.agentName,
    this.onSplit,
    this.onClose,
  });

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Header ──
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
          ),
          child: Row(
            children: [
              Text('Terminal ${widget.sessionId}', style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color)),
              const Spacer(),
              // Split menu
              SmartTooltip(
                message: 'Split',
                preferBelow: true,
                child: PopupMenuButton<String>(
                  icon: Icon(Icons.add, size: 16, color: Theme.of(context).iconTheme.color),
                  onSelected: (dir) => widget.onSplit?.call(dir),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'horizontal', child: Row(children: [SplitIcon(horizontal: true, size: 16), SizedBox(width: 8), Text('Split Right')])),
                    const PopupMenuItem(value: 'vertical', child: Row(children: [SplitIcon(horizontal: false, size: 16), SizedBox(width: 8), Text('Split Down')])),
                  ],
                ),
              ),
              // Close button
              if (widget.onClose != null)
                GestureDetector(
                  onTap: widget.onClose,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 14, color: Theme.of(context).iconTheme.color?.withOpacity(0.5)),
                  ),
                ),
            ],
          ),
        ),
        // ── Terminal ──
        Expanded(
          child: TerminalView(
            sessionId: widget.sessionId,
            onInput: (_) {},
          ),
        ),
        // ── Status Bar ──
        if (widget.agentName != null)
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
            ),
            child: Row(
              children: [
                Container(width: 6, height: 6, decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(widget.agentName!, style: TextStyle(fontSize: 11, color: Theme.of(context).textTheme.bodySmall?.color)),
              ],
            ),
          ),
      ],
    );
  }
}
