import 'package:test/test.dart';
import 'package:core/notification/notification_state.dart';

void main() {
  test('NotificationState should create', () {
    final notif = NotificationState(
      id: '1',
      agentId: 'a1',
      agentName: 'Test',
      type: NotificationType.waiting,
      message: 'Test message',
    );
    expect(notif.isRead, false);
  });

  test('NotificationState should mark as read', () {
    final notif = NotificationState(
      id: '1',
      agentId: 'a1',
      agentName: 'Test',
      type: NotificationType.waiting,
      message: 'Test',
    );
    final read = notif.markAsRead();
    expect(read.isRead, true);
  });
}
