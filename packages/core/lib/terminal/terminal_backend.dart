import 'terminal_session.dart';

abstract class TerminalBackend {
  bool get isInitialized;
  Future<void> initialize();
  Future<int> createSession(String command, Map<String, String> env);
  Stream<TerminalOutput> readOutput(int sessionId);
  Future<void> writeInput(int sessionId, String data);
  Future<void> resize(int sessionId, int cols, int rows);
  Future<void> destroy(int sessionId);
}