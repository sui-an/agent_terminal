import 'package:flutter_test/flutter_test.dart';
import 'package:terminal/ghostty/libghostty_backend.dart';

void main() {
  group('LibGhosttyBackend', () {
    late LibGhosttyBackend backend;

    setUp(() {
      backend = LibGhosttyBackend();
    });

    test('should initialize', () async {
      expect(backend.isInitialized, false);
      await backend.initialize();
      expect(backend.isInitialized, true);
    });

    test('should throw when creating session before initialization', () async {
      expect(
        () => backend.createSession('/bin/zsh', {}),
        throwsStateError,
      );
    });

    test('should create session after initialization', () async {
      await backend.initialize();
      final sessionId = await backend.createSession('echo', {});
      expect(sessionId, greaterThan(0));
    });

    test('should read output from session', () async {
      await backend.initialize();
      final sessionId = await backend.createSession('echo hello', {});

      final output = <String>[];
      final subscription = backend.readOutput(sessionId).listen((data) {
        output.add(data.data);
      });

      // Wait for output
      await Future.delayed(const Duration(seconds: 1));
      await subscription.cancel();

      expect(output, isNotEmpty);
    });

    test('should write input to session', () async {
      await backend.initialize();
      final sessionId = await backend.createSession('/bin/cat', {});

      // Should not throw
      await backend.writeInput(sessionId, 'test\n');

      // Wait a bit
      await Future.delayed(const Duration(milliseconds: 100));
    });

    test('should resize session', () async {
      await backend.initialize();
      final sessionId = await backend.createSession('echo', {});

      // Should not throw
      await backend.resize(sessionId, 120, 40);
    });

    test('should destroy session', () async {
      await backend.initialize();
      final sessionId = await backend.createSession('echo', {});

      // Should not throw
      await backend.destroy(sessionId);
    });

    test('should throw when accessing invalid session', () async {
      await backend.initialize();

      expect(
        () => backend.readOutput(999),
        throwsArgumentError,
      );
    });
  });
}
