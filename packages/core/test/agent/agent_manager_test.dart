import 'package:test/test.dart';
import 'package:core/agent/agent_manager.dart';
import 'package:core/agent/agent_config.dart';
import 'package:core/terminal/terminal_backend.dart';
import 'package:core/terminal/terminal_session.dart';

class MockBackend implements TerminalBackend {
  bool _initialized = false;
  int _counter = 0;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async => _initialized = true;

  @override
  Future<int> createSession(String cmd, Map<String, String> env) async => ++_counter;

  @override
  Stream<TerminalOutput> readOutput(int id) => const Stream.empty();

  @override
  Future<void> writeInput(int id, String data) async {}

  @override
  Future<void> resize(int id, int cols, int rows) async {}

  @override
  Future<void> destroy(int id) async {}
}

void main() {
  test('should launch agent', () async {
    final backend = MockBackend();
    final manager = AgentManager(backend);
    final session = await manager.launchAgent(AgentConfig(id: 'test', name: 'Test', command: 'echo'));
    expect(session.sessionId, greaterThan(0));
  });

  test('should get status', () async {
    final backend = MockBackend();
    final manager = AgentManager(backend);
    final session = await manager.launchAgent(AgentConfig(id: 'test', name: 'Test', command: 'echo'));
    expect(manager.getStatus(session.sessionId), isNotNull);
  });
}
