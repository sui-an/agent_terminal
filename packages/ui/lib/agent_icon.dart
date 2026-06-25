import 'package:flutter/material.dart';
import 'package:core/agent/agent_state.dart';

class AgentIcon {
  static Widget getIcon(String? agentId, {double size = 16, Color? color}) {
    if (agentId == null) {
      return Icon(Icons.terminal, size: size, color: color);
    }

    switch (agentId) {
      case 'mimocode':
        return Image.asset(
          'assets/icons/mimocode.png',
          width: size,
          height: size,
          errorBuilder: (context, error, stackTrace) {
            return Icon(Icons.code, size: size, color: color);
          },
        );
      case 'claude-code':
        return Icon(Icons.psychology, size: size, color: color ?? Colors.orange);
      case 'codex':
        return Icon(Icons.smart_toy, size: size, color: color ?? Colors.blue);
      case 'gemini':
        return Icon(Icons.auto_awesome, size: size, color: color ?? Colors.purple);
      case 'opencode':
        return Icon(Icons.code, size: size, color: color ?? Colors.green);
      default:
        return Icon(Icons.terminal, size: size, color: color);
    }
  }

  static Widget getStatusIcon(AgentStatus status, {double size = 8}) {
    switch (status) {
      case AgentStatus.running:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
          ),
        );
      case AgentStatus.waiting:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Colors.orange,
            shape: BoxShape.circle,
          ),
        );
      case AgentStatus.idle:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Colors.grey,
            shape: BoxShape.circle,
          ),
        );
      case AgentStatus.error:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Colors.red,
            shape: BoxShape.circle,
          ),
        );
    }
  }
}
