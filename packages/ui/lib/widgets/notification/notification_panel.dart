import 'package:flutter/material.dart';
import 'package:core/notification/notification_state.dart';
import 'package:ui/theme/app_theme.dart';

class NotificationPanel extends StatelessWidget {
  final List<NotificationState> notifications;
  final ValueChanged<String> onNotificationTap;
  const NotificationPanel({super.key, required this.notifications, required this.onNotificationTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(left: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.notifications_outlined, size: 16, color: AppTheme.textSecondary),
                const SizedBox(width: 8),
                Text('Notifications', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.text)),
                const Spacer(),
                Text('${notifications.where((n) => !n.isRead).length} unread',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          const Divider(height: 1),
          // List
          Expanded(
            child: notifications.isEmpty
                ? Center(
                    child: Text('No notifications', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  )
                : ListView.separated(
                    itemCount: notifications.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: AppTheme.border),
                    itemBuilder: (_, i) {
                      final n = notifications[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          n.type == NotificationType.error
                              ? Icons.error_outline
                              : n.type == NotificationType.waiting
                                  ? Icons.hourglass_empty
                                  : Icons.check_circle_outline,
                          size: 16,
                          color: n.type == NotificationType.error
                              ? AppTheme.error
                              : n.type == NotificationType.waiting
                                  ? AppTheme.warning
                                  : AppTheme.success,
                        ),
                        title: Text(n.agentName, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                        subtitle: Text(n.message, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: !n.isRead
                            ? Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppTheme.accent, shape: BoxShape.circle))
                            : null,
                        onTap: () => onNotificationTap(n.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
