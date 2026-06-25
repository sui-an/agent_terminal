import 'package:test/test.dart';
import 'package:core/agent/agent_config.dart';

void main() {
  test('AgentConfig should parse from JSON', () {
    final json = {
      'id': 'mimocode',
      'name': 'MiMoCode',
      'command': 'mimocode',
    };
    final config = AgentConfig.fromJson(json);
    expect(config.id, 'mimocode');
    expect(config.name, 'MiMoCode');
  });

  test('AgentConfig should parse agents.json', () {
    final json = {
      'agents': [
        {'id': 'test', 'name': 'Test', 'command': 'test'},
      ],
    };
    final agents = AgentConfig.parseAgentsJson(json);
    expect(agents.length, 1);
  });
}
