enum NotificationType { waiting, error, idle }

class NotificationState {
  final String id;
  final String agentId;
  final String agentName;
  final NotificationType type;
  final String message;
  final bool isRead;
  final DateTime createdAt;

  NotificationState({
    required this.id,
    required this.agentId,
    required this.agentName,
    required this.type,
    required this.message,
    this.isRead = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  NotificationState markAsRead() {
    return NotificationState(
      id: id,
      agentId: agentId,
      agentName: agentName,
      type: type,
      message: message,
      isRead: true,
      createdAt: createdAt,
    );
  }

  factory NotificationState.fromJson(Map<String, dynamic> json) {
    return NotificationState(
      id: json['id'] as String,
      agentId: json['agentId'] as String,
      agentName: json['agentName'] as String,
      type: NotificationType.values.firstWhere((e) => e.name == json['type']),
      message: json['message'] as String,
      isRead: json['isRead'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'agentId': agentId,
        'agentName': agentName,
        'type': type.name,
        'message': message,
        'isRead': isRead,
        'createdAt': createdAt.toIso8601String(),
      };
}
