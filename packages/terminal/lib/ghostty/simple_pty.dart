import 'dart:async';
import 'dart:io';

class SimplePTYSession {
  final Process process;
  final StreamController<String> _outputController = StreamController<String>.broadcast();

  SimplePTYSession({required this.process});

  Stream<String> get output => _outputController.stream;

  void startReading() {
    process.stdout.listen(
      (data) {
        final text = String.fromCharCodes(data);
        _outputController.add(text);
      },
      onError: (error) {
        _outputController.addError(error);
      },
      onDone: () {
        _outputController.close();
      },
    );

    process.stderr.listen(
      (data) {
        final text = String.fromCharCodes(data);
        _outputController.add(text);
      },
    );
  }

  void write(String data) {
    process.stdin.write(data);
  }

  Future<void> resize(int cols, int rows) async {
    // Send SIGWINCH signal
    if (process.pid > 0) {
      Process.killPid(process.pid, ProcessSignal.sigwinch);
    }
  }

  Future<void> destroy() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode;
    _outputController.close();
  }
}

class SimplePTY {
  static Future<SimplePTYSession> create({
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    int cols = 80,
    int rows = 24,
  }) async {
    // Set environment variables for PTY size
    final processEnv = Map<String, String>.from(env);
    processEnv['COLUMNS'] = cols.toString();
    processEnv['LINES'] = rows.toString();
    processEnv['TERM'] = 'xterm-256color';

    final process = await Process.start(
      command,
      args,
      environment: processEnv,
      mode: ProcessStartMode.normal,
    );

    final session = SimplePTYSession(process: process);
    session.startReading();

    return session;
  }
}
