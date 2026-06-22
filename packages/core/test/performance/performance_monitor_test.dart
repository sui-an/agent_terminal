import 'package:test/test.dart';
import 'package:core/performance/performance_monitor.dart';

void main() {
  test('PerformanceMonitor should track frame rate', () {
    final monitor = PerformanceMonitor.instance;
    for (var i = 0; i < 10; i++) {
      monitor.recordFrame();
    }
    final report = monitor.getReport();
    expect(report.frameRate, greaterThanOrEqualTo(0));
  });

  test('PerformanceMonitor should get memory usage', () {
    final report = PerformanceMonitor.instance.getReport();
    expect(report.memoryUsage, greaterThan(0));
  });
}
