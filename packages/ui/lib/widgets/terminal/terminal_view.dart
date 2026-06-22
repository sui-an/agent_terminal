import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TerminalView extends StatefulWidget {
  final int sessionId;
  final Function(String)? onInput;

  const TerminalView({super.key, required this.sessionId, this.onInput});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final FocusNode _focusNode = FocusNode();
  String _output = '';

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKey: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final char = event.character;
          if (char != null) {
            widget.onInput?.call(char);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        child: Container(
          color: Theme.of(context).colorScheme.surface,
          padding: const EdgeInsets.all(8),
          child: Text(
            _output,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  void updateOutput(String output) => setState(() => _output = output);
}
