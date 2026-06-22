import 'latency_tracker.dart';
import 'frame_rate_tracker.dart';
import 'memory_tracker.dart';

class PerformanceReport {
  final double inputLatency;
  final double frameRate;
  final int memoryUsage;

  PerformanceReport({
    required this.inputLatency,
    required this.frameRate,
    required this.memoryUsage,
  });
}

class PerformanceMonitor {
  PerformanceMonitor._();
  static final instance = PerformanceMonitor._();

  final _inputLatencyTracker = LatencyTracker();
  final _frameRateTracker = FrameRateTracker();
  final _memoryTracker = MemoryTracker();

  void startInputLatencyTracking() => _inputLatencyTracker.start();
  void endInputLatencyTracking() => _inputLatencyTracker.end();
  void recordFrame() => _frameRateTracker.recordFrame();

  void reset() {
    _inputLatencyTracker.reset();
    _frameRateTracker.reset();
  }

  PerformanceReport getReport() => PerformanceReport(
        inputLatency: _inputLatencyTracker.average,
        frameRate: _frameRateTracker.current,
        memoryUsage: _memoryTracker.current,
      );
}
