class FrameRateTracker {
  final List<DateTime> _frameTimes = [];

  void recordFrame() {
    final now = DateTime.now();
    _frameTimes.add(now);
    _frameTimes.removeWhere((t) => now.difference(t) > const Duration(seconds: 1));
  }

  double get current {
    if (_frameTimes.length < 2) return 0;
    final duration = _frameTimes.last.difference(_frameTimes.first);
    if (duration.inMilliseconds == 0) return 0;
    return (_frameTimes.length - 1) * 1000 / duration.inMilliseconds;
  }

  void reset() => _frameTimes.clear();
}
