import 'dart:async';
import 'package:core/terminal/terminal_backend.dart';
import 'package:core/terminal/terminal_session.dart';
import 'simple_pty.dart';

class LibGhosttyBackend implements TerminalBackend {
  bool _initialized = false;
  final Map<int, _SessionData> _sessions = {};
  int _nextSessionId = 1;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Future<int> createSession(String command, Map<String, String> env) async {
    if (!_initialized) {
      throw StateError('Backend not initialized');
    }

    final sessionId = _nextSessionId++;

    // Parse command and args
    final parts = command.split(' ');
    final cmd = parts.first;
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];

    // Create PTY session
    final ptySession = await SimplePTY.create(
      command: cmd,
      args: args,
      env: env,
      cols: 80,
      rows: 24,
    );

    _sessions[sessionId] = _SessionData(
      ptySession: ptySession,
      command: command,
    );

    return sessionId;
  }

  @override
  Stream<TerminalOutput> readOutput(int sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      throw ArgumentError('Invalid session ID: $sessionId');
    }

    return session.ptySession.output.map((data) => TerminalOutput(data: data));
  }

  @override
  Future<void> writeInput(int sessionId, String data) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw ArgumentError('Invalid session ID: $sessionId');
    }

    session.ptySession.write(data);
  }

  @override
  Future<void> resize(int sessionId, int cols, int rows) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw ArgumentError('Invalid session ID: $sessionId');
    }

    await session.ptySession.resize(cols, rows);
  }

  @override
  Future<void> destroy(int sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session == null) {
      throw ArgumentError('Invalid session ID: $sessionId');
    }

    await session.ptySession.destroy();
  }
}

class _SessionData {
  final SimplePTYSession ptySession;
  final String command;

  _SessionData({
    required this.ptySession,
    required this.command,
  });
}
