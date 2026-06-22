import 'dart:math';
import 'notification_state.dart';
import 'notification_history.dart';

class NotificationService {
  final List<NotificationState> _notifications = [];
  final NotificationHistory _history = NotificationHistory();

  NotificationHistory get history => _history;

  NotificationState createNotification({
    required String agentId,
    required String agentName,
    required NotificationType type,
    required String message,
  }) {
    final notif = NotificationState(
      id: 'notif-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1000)}',
      agentId: agentId,
      agentName: agentName,
      type: type,
      message: message,
    );
    _notifications.insert(0, notif);
    _history.add(notif);
    return notif;
  }

  List<NotificationState> getNotifications() => List.unmodifiable(_notifications);

  NotificationState? getNotificationById(String id) {
    for (final n in _notifications) {
      if (n.id == id) return n;
    }
    return null;
  }

  void markAsRead(String id) {
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index != -1) _notifications[index] = _notifications[index].markAsRead();
  }

  int get unreadCount => _notifications.where((n) => !n.isRead).length;
}
