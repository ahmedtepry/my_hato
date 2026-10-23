import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'support_chat_models.dart';

/// Thin data layer over the Supabase chat backend.
/// All writes go through RPCs (the tables are read-only for clients).
class SupportChatRepository {
  SupportChatRepository([SupabaseClient? client]) : _db = client ?? Supabase.instance.client;

  final SupabaseClient _db;
  static const _bucket = 'support-chat';
  static const maxAttachmentBytes = 10 * 1024 * 1024;
  static const allowedMimes = {
    'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf',
  };

  String get _uid => _db.auth.currentUser!.id;

  /// The customer's open conversation, or the latest one (to show rating).
  Future<SupportConversation?> currentConversation() async {
    final row = await _db
        .from('support_conversations')
        .select()
        .eq('customer_id', _uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : SupportConversation.fromMap(row);
  }

  Future<List<SupportMessage>> messages(String conversationId) async {
    final rows = await _db
        .from('support_messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true);
    return rows.map<SupportMessage>(SupportMessage.fromMap).toList();
  }

  Future<String> startConversation(String subject, String message, String clientId) async {
    final id = await _db.rpc('support_start_conversation', params: {
      'p_subject': subject,
      'p_message': message,
      'p_client_id': clientId,
    });
    return id as String;
  }

  Future<void> sendMessage(
    String conversationId,
    String body,
    String clientId, {
    String? attachmentPath,
    String? attachmentName,
    String? attachmentMime,
    int? attachmentSize,
  }) async {
    await _db.rpc('support_send_message', params: {
      'p_conversation_id': conversationId,
      'p_body': body,
      'p_client_id': clientId,
      'p_attachment_path': attachmentPath,
      'p_attachment_name': attachmentName,
      'p_attachment_mime': attachmentMime,
      'p_attachment_size': attachmentSize,
    });
  }

  /// Uploads to `<conversationId>/<uuid>-<name>` and returns the storage path.
  Future<String> uploadAttachment(String conversationId, Uint8List bytes, String name, String mime) async {
    if (!allowedMimes.contains(mime)) throw const FormatException('unsupported_type');
    if (bytes.length > maxAttachmentBytes) throw const FormatException('file_too_large');
    final safe = name.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final path = '$conversationId/${const Uuid().v4()}-$safe';
    await _db.storage.from(_bucket).uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));
    return path;
  }

  Future<String> signedUrl(String path) => _db.storage.from(_bucket).createSignedUrl(path, 3600);

  Future<void> markRead(String conversationId) =>
      _db.rpc('support_mark_read', params: {'p_conversation_id': conversationId});

  Future<void> close(String conversationId) =>
      _db.rpc('support_close_conversation', params: {'p_conversation_id': conversationId});

  Future<void> rate(String conversationId, int rating, String? comment) => _db.rpc('support_rate_conversation',
      params: {'p_conversation_id': conversationId, 'p_rating': rating, 'p_comment': comment});

  // ---------------- realtime ----------------

  /// Row changes for one conversation (new messages, read receipts, close/rating).
  RealtimeChannel subscribeToChanges(
    String conversationId, {
    required void Function(SupportMessage) onMessage,
    required void Function(SupportConversation) onConversation,
  }) {
    return _db
        .channel('support-db:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'support_messages',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'conversation_id', value: conversationId),
          callback: (p) {
            if (p.newRecord.isNotEmpty) onMessage(SupportMessage.fromMap(p.newRecord));
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'support_conversations',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: conversationId),
          callback: (p) => onConversation(SupportConversation.fromMap(p.newRecord)),
        )
        .subscribe();
  }

  /// Private broadcast channel used only for the typing indicator.
  RealtimeChannel subscribeToTyping(String conversationId, {required void Function() onStaffTyping}) {
    return _db
        .channel('support:$conversationId', opts: const RealtimeChannelConfig(private: true))
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            // Depending on the SDK version the sent payload is either the map itself or nested under 'payload'.
            final inner = payload['payload'];
            final data = inner is Map ? inner : payload;
            if (data['role'] == 'staff') onStaffTyping();
          },
        )
        .subscribe();
  }

  Future<void> sendTyping(RealtimeChannel channel) =>
      channel.sendBroadcastMessage(event: 'typing', payload: {'role': 'customer'});

  Future<void> dispose(RealtimeChannel? c) async {
    if (c != null) await _db.removeChannel(c);
  }
}
