class SupportConversation {
  final String id;
  final String subject;
  final String status; // open | closed
  final int customerUnread;
  final DateTime? closedAt;
  final int? rating;

  const SupportConversation({
    required this.id,
    required this.subject,
    required this.status,
    required this.customerUnread,
    this.closedAt,
    this.rating,
  });

  bool get isOpen => status == 'open';
  bool get needsRating => status == 'closed' && rating == null;

  factory SupportConversation.fromMap(Map<String, dynamic> m) => SupportConversation(
        id: m['id'] as String,
        subject: (m['subject'] ?? '') as String,
        status: (m['status'] ?? 'open') as String,
        customerUnread: (m['customer_unread'] ?? 0) as int,
        closedAt: m['closed_at'] == null ? null : DateTime.parse(m['closed_at'] as String).toLocal(),
        rating: m['rating'] as int?,
      );
}

class SupportMessage {
  final String id;
  final String conversationId;
  final String senderRole; // customer | staff | system
  final String body;
  final String? attachmentPath;
  final String? attachmentName;
  final String? attachmentMime;
  final String? clientId;
  final DateTime? readAt;
  final DateTime createdAt;

  /// Local-only state for optimistic sending.
  final bool pending;
  final bool failed;

  const SupportMessage({
    required this.id,
    required this.conversationId,
    required this.senderRole,
    required this.body,
    required this.createdAt,
    this.attachmentPath,
    this.attachmentName,
    this.attachmentMime,
    this.clientId,
    this.readAt,
    this.pending = false,
    this.failed = false,
  });

  bool get isMine => senderRole == 'customer';
  bool get isSystem => senderRole == 'system';
  bool get hasAttachment => attachmentPath != null;
  bool get isImage => (attachmentMime ?? '').startsWith('image/');

  SupportMessage copyWith({DateTime? readAt, bool? pending, bool? failed, String? id}) => SupportMessage(
        id: id ?? this.id,
        conversationId: conversationId,
        senderRole: senderRole,
        body: body,
        createdAt: createdAt,
        attachmentPath: attachmentPath,
        attachmentName: attachmentName,
        attachmentMime: attachmentMime,
        clientId: clientId,
        readAt: readAt ?? this.readAt,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
      );

  factory SupportMessage.fromMap(Map<String, dynamic> m) => SupportMessage(
        id: m['id'] as String,
        conversationId: m['conversation_id'] as String,
        senderRole: m['sender_role'] as String,
        body: (m['body'] ?? '') as String,
        attachmentPath: m['attachment_path'] as String?,
        attachmentName: m['attachment_name'] as String?,
        attachmentMime: m['attachment_mime'] as String?,
        clientId: m['client_id'] as String?,
        readAt: m['read_at'] == null ? null : DateTime.parse(m['read_at'] as String).toLocal(),
        createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
      );
}
