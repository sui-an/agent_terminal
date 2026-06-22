import 'package:test/test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/state/providers.dart';

void main() {
  test('agentProvider should provide empty list', () {
    final container = ProviderContainer();
    expect(container.read(agentProvider), isEmpty);
  });

  test('workspaceProvider should provide empty list', () {
    final container = ProviderContainer();
    expect(container.read(workspaceProvider), isEmpty);
  });
}
