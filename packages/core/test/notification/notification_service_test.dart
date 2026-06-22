import 'package:test/test.dart';
import 'package:core/notification/notification_service.dart';
import 'package:core/notification/notification_state.dart';

void main() {
  test('should create notification', () {
    final service = NotificationService();
    final notif = service.createNotification(
      agentId: 'a1', agentName: 'Test', type: NotificationType.waiting, message: 'Test',
    );
    expect(notif.id, isNotEmpty);
    expect(service.getNotifications().length, 1);
  });

  test('should mark as read', () {
    final service = NotificationService();
    final notif = service.createNotification(
      agentId: 'a1', agentName: 'Test', type: NotificationType.waiting, message: 'Test',
    );
    service.markAsRead(notif.id);
    expect(service.getNotificationById(notif.id)!.isRead, true);
  });

  test('should get unread count', () {
    final service = NotificationService();
    service.createNotification(agentId: 'a1', agentName: 'Test', type: NotificationType.waiting, message: 'Test');
    expect(service.unreadCount, 1);
  });
}
