import 'notification_state.dart';

class NotificationHistory {
  final List<NotificationState> _notifications = [];
  static const int _maxEntries = 1000;

  List<NotificationState> get notifications => List.unmodifiable(_notifications);

  void add(NotificationState notif) {
    _notifications.insert(0, notif);
    if (_notifications.length > _maxEntries) _notifications.removeRange(_maxEntries, _notifications.length);
  }

  void cleanOld() {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    _notifications.removeWhere((n) => n.createdAt.isBefore(cutoff));
  }
}
