import 'package:test/test.dart';
import 'package:core/workspace/workspace_manager.dart';

void main() {
  late WorkspaceManager manager;

  setUp(() => manager = WorkspaceManager());

  test('should create workspace', () {
    final ws = manager.createWorkspace(name: 'Test', path: '/test');
    expect(ws.id, isNotEmpty);
    expect(ws.name, 'Test');
  });

  test('should get workspace by id', () {
    final ws = manager.createWorkspace(name: 'Test', path: '/test');
    expect(manager.getWorkspace(ws.id), isNotNull);
  });

  test('should update workspace', () {
    final ws = manager.createWorkspace(name: 'Original', path: '/test');
    manager.updateWorkspace(ws.id, name: 'Updated');
    expect(manager.getWorkspace(ws.id)!.name, 'Updated');
  });

  test('should delete workspace', () {
    final ws = manager.createWorkspace(name: 'Test', path: '/test');
    manager.deleteWorkspace(ws.id);
    expect(manager.getWorkspace(ws.id), isNull);
  });
}
