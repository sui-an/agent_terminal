import 'package:test/test.dart';
import 'package:core/agent/agent_config_manager.dart';

void main() {
  test('should load default agents', () {
    final manager = AgentConfigManager();
    expect(manager.agents.length, greaterThan(0));
  });

  test('should get agent by id', () {
    final manager = AgentConfigManager();
    expect(manager.getAgentById('mimocode'), isNotNull);
  });
}