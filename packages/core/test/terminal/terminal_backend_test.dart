import 'package:test/test.dart';
import 'package:core/terminal/terminal_backend.dart';
import 'package:core/terminal/terminal_session.dart';

class MockTerminalBackend implements TerminalBackend {
  bool _initialized = false;
  int _sessionCounter = 0;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async => _initialized = true;

  @override
  Future<int> createSession(String command, Map<String, String> env) async {
    return ++_sessionCounter;
  }

  @override
  Stream<TerminalOutput> readOutput(int sessionId) => const Stream.empty();

  @override
  Future<void> writeInput(int sessionId, String data) async {}

  @override
  Future<void> resize(int sessionId, int cols, int rows) async {}

  @override
  Future<void> destroy(int sessionId) async {}
}

void main() {
  late MockTerminalBackend backend;

  setUp(() => backend = MockTerminalBackend());

  test('should initialize', () async {
    expect(backend.isInitialized, false);
    await backend.initialize();
    expect(backend.isInitialized, true);
  });

  test('should create session', () async {
    await backend.initialize();
    final id = await backend.createSession('/bin/zsh', {});
    expect(id, greaterThan(0));
  });
}