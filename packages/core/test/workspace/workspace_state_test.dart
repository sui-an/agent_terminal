import 'package:test/test.dart';
import 'package:core/workspace/workspace_state.dart';

void main() {
  test('WorkspaceState should create', () {
    final ws = WorkspaceState(id: '1', name: 'Test', path: '/test');
    expect(ws.id, '1');
    expect(ws.name, 'Test');
  });

  test('WorkspaceState should serialize to JSON', () {
    final ws = WorkspaceState(id: '1', name: 'Test', path: '/test');
    final json = ws.toJson();
    expect(json['id'], '1');
  });

  test('WorkspaceState should deserialize from JSON', () {
    final json = {
      'id': '1',
      'name': 'Test',
      'path': '/test',
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
      'tabs': [],
    };
    final ws = WorkspaceState.fromJson(json);
    expect(ws.id, '1');
  });
}
