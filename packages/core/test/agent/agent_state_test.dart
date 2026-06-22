import 'package:test/test.dart';
import 'package:core/agent/agent_state.dart';

void main() {
  test('AgentState should create with required fields', () {
    final state = AgentState(id: '1', name: 'Test', status: AgentStatus.idle);
    expect(state.id, '1');
    expect(state.name, 'Test');
    expect(state.status, AgentStatus.idle);
  });

  test('AgentState should copy with changes', () {
    final original = AgentState(id: '1', name: 'Test', status: AgentStatus.running);
    final copied = original.copyWith(status: AgentStatus.waiting);
    expect(copied.status, AgentStatus.waiting);
  });
}
