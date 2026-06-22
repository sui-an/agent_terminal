class TerminalOutput {
  final String data;
  final DateTime timestamp;

  TerminalOutput({required this.data, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}