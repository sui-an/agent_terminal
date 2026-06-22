class LatencyTracker {
  DateTime? _startTime;
  final List<double> _latencies = [];

  void start() => _startTime = DateTime.now();

  void end() {
    if (_startTime == null) return;
    final latency = DateTime.now().difference(_startTime!).inMicroseconds / 1000.0;
    _latencies.add(latency);
    if (_latencies.length > 100) _latencies.removeAt(0);
    _startTime = null;
  }

  double get average {
    if (_latencies.isEmpty) return 0;
    return _latencies.reduce((a, b) => a + b) / _latencies.length;
  }

  void reset() {
    _latencies.clear();
    _startTime = null;
  }
}
