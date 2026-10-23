import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'support_chat_models.dart';
import 'support_chat_repository.dart';

/// Live chat between the signed-in customer and customer service only.
/// Route: /support/chat (also /support/chat/:id from push-notification deep links).
class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({super.key});

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  final _repo = SupportChatRepository();
  final _uuid = const Uuid();
  final _input = TextEditingController();
  final _subject = TextEditingController();
  final _scroll = ScrollController();

  SupportConversation? _conv;
  List<SupportMessage> _messages = [];
  bool _loading = true;
  bool _busy = false;
  bool _loadFailed = false;

  RealtimeChannel? _changes;
  RealtimeChannel? _typing;
  bool _staffTyping = false;
  Timer? _staffTypingTimer;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _readDebounce;
  final Map<String, Future<String>> _urlCache = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _staffTypingTimer?.cancel();
    _readDebounce?.cancel();
    _repo.dispose(_changes);
    _repo.dispose(_typing);
    _input.dispose();
    _subject.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ loading

  Future<void> _init() async {
    try {
      final conv = await _repo.currentConversation();
      if (conv != null && (conv.isOpen || conv.needsRating)) {
        await _attach(conv);
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _loadFailed = true; });
    }
  }

  Future<void> _attach(SupportConversation conv) async {
    final msgs = await _repo.messages(conv.id);
    await _repo.dispose(_changes);
    await _repo.dispose(_typing);
    _changes = _repo.subscribeToChanges(conv.id, onMessage: _onMessage, onConversation: _onConversation);
    _typing = _repo.subscribeToTyping(conv.id, onStaffTyping: _onStaffTyping);
    if (!mounted) return;
    setState(() {
      _conv = conv;
      _messages = msgs;
      _loading = false;
      _loadFailed = false;
    });
    _scheduleMarkRead();
  }

  // ------------------------------------------------------------ realtime

  void _onMessage(SupportMessage m) {
    if (!mounted) return;
    setState(() => _upsert(m));
    if (!m.isMine && !m.isSystem) {
      setState(() => _staffTyping = false);
      _scheduleMarkRead();
    }
  }

  void _onConversation(SupportConversation c) {
    if (!mounted) return;
    setState(() => _conv = c);
  }

  void _onStaffTyping() {
    if (!mounted) return;
    setState(() => _staffTyping = true);
    _staffTypingTimer?.cancel();
    _staffTypingTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _staffTyping = false);
    });
  }

  void _scheduleMarkRead() {
    _readDebounce?.cancel();
    _readDebounce = Timer(const Duration(milliseconds: 400), () {
      final id = _conv?.id;
      if (id != null) _repo.markRead(id).catchError((_) {});
    });
  }

  /// Merge by id, or replace the optimistic copy that has the same client_id.
  void _upsert(SupportMessage m) {
    final i = _messages.indexWhere((x) => x.id == m.id || (m.clientId != null && x.clientId == m.clientId));
    if (i >= 0) {
      _messages[i] = m;
    } else {
      _messages.add(m);
    }
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  // ------------------------------------------------------------ actions

  Future<void> _start() async {
    final subject = _subject.text.trim();
    final text = _input.text.trim();
    if (subject.length < 3) return showSnack(context, context.tr('chat_subject_short'), error: true);
    if (text.isEmpty) return showSnack(context, context.tr('chat_write_first'), error: true);
    setState(() => _busy = true);
    try {
      final id = await _repo.startConversation(subject, text, _uuid.v4());
      _input.clear();
      final conv = await _repo.currentConversation();
      if (conv != null && conv.id == id) await _attach(conv);
    } catch (_) {
      if (mounted) showSnack(context, context.tr('chat_start_failed'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send({String? attachmentPath, String? name, String? mime, int? size, String? existingClientId}) async {
    final conv = _conv;
    if (conv == null || !conv.isOpen) return;
    final text = attachmentPath == null ? _input.text.trim() : '';
    if (text.isEmpty && attachmentPath == null) return;

    final clientId = existingClientId ?? _uuid.v4();
    final optimistic = SupportMessage(
      id: 'local-$clientId',
      conversationId: conv.id,
      senderRole: 'customer',
      body: text,
      createdAt: DateTime.now(),
      attachmentPath: attachmentPath,
      attachmentName: name,
      attachmentMime: mime,
      clientId: clientId,
      pending: true,
    );
    setState(() {
      _upsert(optimistic);
      if (attachmentPath == null) _input.clear();
    });
    _scrollToEnd();

    try {
      await _repo.sendMessage(conv.id, text, clientId,
          attachmentPath: attachmentPath, attachmentName: name, attachmentMime: mime, attachmentSize: size);
      // The realtime INSERT replaces the optimistic copy (same client_id).
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _upsert(optimistic.copyWith(pending: false, failed: true)));
      if (e.message.contains('conversation_closed')) showSnack(context, context.tr('chat_closed_msg'), error: true);
      if (e.message.contains('rate_limited')) showSnack(context, context.tr('chat_rate_limited'), error: true);
    } catch (_) {
      if (mounted) setState(() => _upsert(optimistic.copyWith(pending: false, failed: true)));
    }
  }

  void _retry(SupportMessage m) {
    if (m.attachmentPath != null) {
      _send(attachmentPath: m.attachmentPath, name: m.attachmentName, mime: m.attachmentMime, existingClientId: m.clientId);
    } else {
      _input.text = m.body;
      setState(() => _messages.removeWhere((x) => x.id == m.id));
      _send();
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final x = await ImagePicker().pickImage(source: source, maxWidth: 1920, imageQuality: 85);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    final lower = x.name.toLowerCase();
    final mime = lower.endsWith('.png')
        ? 'image/png'
        : lower.endsWith('.webp')
            ? 'image/webp'
            : lower.endsWith('.heic')
                ? 'image/heic'
                : 'image/jpeg';
    await _uploadAndSend(bytes, x.name, mime);
  }

  Future<void> _pickPdf() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
    final f = r?.files.single;
    if (f == null || f.bytes == null) return;
    await _uploadAndSend(f.bytes!, f.name, 'application/pdf');
  }

  Future<void> _uploadAndSend(Uint8List bytes, String name, String mime) async {
    final conv = _conv;
    if (conv == null) return;
    if (bytes.length > SupportChatRepository.maxAttachmentBytes) {
      if (mounted) showSnack(context, context.tr('chat_file_too_large'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final path = await _repo.uploadAttachment(conv.id, bytes, name, mime);
      await _send(attachmentPath: path, name: name, mime: mime, size: bytes.length);
    } catch (_) {
      if (mounted) showSnack(context, context.tr('chat_upload_failed'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showAttachSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Wrap(children: [
          ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(context.tr('chat_camera')),
              onTap: () { Navigator.pop(sheet); _pickImage(ImageSource.camera); }),
          ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: Text(context.tr('chat_gallery')),
              onTap: () { Navigator.pop(sheet); _pickImage(ImageSource.gallery); }),
          ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: Text(context.tr('chat_pdf')),
              onTap: () { Navigator.pop(sheet); _pickPdf(); }),
        ]),
      ),
    );
  }

  void _onTextChanged(String _) {
    final ch = _typing;
    if (ch == null) return;
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) < const Duration(seconds: 2)) return;
    _lastTypingSent = now;
    _repo.sendTyping(ch).catchError((_) {});
  }

  Future<void> _closeChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.tr('chat_end')),
        content: Text(context.tr('chat_end_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('chat_cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.tr('chat_end'))),
        ],
      ),
    );
    if (ok != true || _conv == null) return;
    try {
      await _repo.close(_conv!.id);
      final c = await _repo.currentConversation();
      if (mounted && c != null) setState(() => _conv = c);
    } catch (_) {
      if (mounted) showSnack(context, context.tr('chat_end_failed'), error: true);
    }
  }

  Future<void> _submitRating(int stars, String comment) async {
    final id = _conv?.id;
    if (id == null) return;
    try {
      await _repo.rate(id, stars, comment.trim().isEmpty ? null : comment.trim());
      if (!mounted) return;
      showSnack(context, context.tr('chat_rate_thanks'));
      await _repo.dispose(_changes);
      await _repo.dispose(_typing);
      _changes = null;
      _typing = null;
      if (mounted) setState(() { _conv = null; _messages = []; });
    } catch (_) {
      if (mounted) showSnack(context, context.tr('chat_rate_failed'), error: true);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr(_conv == null ? 'help' : 'chat_title')),
        actions: [
          if (_conv?.isOpen == true)
            IconButton(tooltip: context.tr('chat_end'), icon: const Icon(Icons.check_circle_outline), onPressed: _closeChat),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(context.tr('chat_load_failed'), textAlign: TextAlign.center)))
              : _conv == null
                  ? _buildStart()
                  : _buildChat(),
    );
  }

  Widget _buildStart() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(context.tr('chat_start_title'), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(context.tr('chat_start_body'), style: const TextStyle(color: BrandColors.gray, height: 1.5)),
        const SizedBox(height: 16),
        TextField(
          controller: _subject,
          maxLength: 200,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: context.tr('support_subject')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _input,
          maxLength: 4000,
          minLines: 5,
          maxLines: 8,
          decoration: InputDecoration(labelText: context.tr('support_message'), alignLabelWithHint: true),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _start,
          child: _busy
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(context.tr('chat_start_btn')),
        ),
      ],
    );
  }

  Widget _buildChat() {
    final conv = _conv!;
    final items = _messages.reversed.toList();
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: BrandColors.offWhite,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(conv.subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, color: BrandColors.navy)),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (_, i) => _bubble(items[i]),
          ),
        ),
        if (_staffTyping && conv.isOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(context.tr('chat_typing'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            ),
          ),
        if (conv.isOpen) _composer() else _RatingCard(onSubmit: _submitRating),
      ],
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(onPressed: _busy ? null : _showAttachSheet, icon: const Icon(Icons.attach_file)),
            Expanded(
              child: TextField(
                controller: _input,
                onChanged: _onTextChanged,
                minLines: 1,
                maxLines: 5,
                maxLength: 4000,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                decoration: InputDecoration(
                  hintText: context.tr('chat_hint'),
                  filled: true,
                  fillColor: BrandColors.offWhite,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }

  Widget _bubble(SupportMessage m) {
    if (m.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(child: Text(m.body, style: const TextStyle(color: BrandColors.gray, fontSize: 12))),
      );
    }
    final mine = m.isMine;
    final fg = mine ? Colors.white : BrandColors.navy;
    return Align(
      // "start" follows the app language: customer on the start side, support on the end side.
      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: GestureDetector(
        onTap: m.failed ? () => _retry(m) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: mine ? BrandColors.navy : BrandColors.offWhite,
            border: mine ? null : Border.all(color: BrandColors.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m.hasAttachment) _attachment(m, fg),
              if (m.body.isNotEmpty) Text(m.body, style: TextStyle(color: fg, height: 1.35)),
              const SizedBox(height: 4),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_hhmm(m.createdAt), style: TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.7))),
                if (mine) ...[const SizedBox(width: 4), _status(m, fg)],
              ]),
              if (m.failed) Text(context.tr('chat_failed_retry'), style: const TextStyle(fontSize: 10, color: BrandColors.error)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status(SupportMessage m, Color fg) {
    if (m.failed) return const Icon(Icons.error_outline, size: 14, color: BrandColors.error);
    if (m.pending) return Icon(Icons.access_time, size: 12, color: fg.withValues(alpha: 0.7));
    if (m.readAt != null) return const Icon(Icons.done_all, size: 14, color: BrandColors.electric);
    return Icon(Icons.done, size: 14, color: fg.withValues(alpha: 0.7));
  }

  Widget _attachment(SupportMessage m, Color fg) {
    final path = m.attachmentPath!;
    final urlFuture = _urlCache.putIfAbsent(path, () => _repo.signedUrl(path));
    if (m.isImage) {
      return FutureBuilder<String>(
        future: urlFuture,
        builder: (_, s) {
          if (!s.hasData) return const SizedBox(height: 120, width: 180, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _ImageViewer(url: s.data!))),
              child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.network(s.data!, width: 220, fit: BoxFit.cover)),
            ),
          );
        },
      );
    }
    return FutureBuilder<String>(
      future: urlFuture,
      builder: (_, s) => InkWell(
        onTap: s.hasData ? () => launchUrl(Uri.parse(s.data!), mode: LaunchMode.externalApplication) : null,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.picture_as_pdf, color: fg),
            const SizedBox(width: 6),
            Flexible(child: Text(m.attachmentName ?? context.tr('chat_file'), style: TextStyle(color: fg, decoration: TextDecoration.underline))),
          ]),
        ),
      ),
    );
  }

  String _hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _RatingCard extends StatefulWidget {
  const _RatingCard({required this.onSubmit});
  final Future<void> Function(int stars, String comment) onSubmit;

  @override
  State<_RatingCard> createState() => _RatingCardState();
}

class _RatingCardState extends State<_RatingCard> {
  int _stars = 0;
  final _comment = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(context.tr('chat_rate_title'), style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                final on = i < _stars;
                return IconButton(
                  onPressed: () => setState(() => _stars = i + 1),
                  icon: Icon(on ? Icons.star_rounded : Icons.star_border_rounded, color: BrandColors.warning, size: 34),
                );
              }),
            ),
            TextField(controller: _comment, maxLength: 500, maxLines: 2, decoration: InputDecoration(hintText: context.tr('chat_rate_hint'))),
            const SizedBox(height: 4),
            FilledButton(
              onPressed: _stars == 0 || _sending
                  ? null
                  : () async {
                      setState(() => _sending = true);
                      await widget.onSubmit(_stars, _comment.text);
                      if (mounted) setState(() => _sending = false);
                    },
              child: Text(context.tr('chat_rate_send')),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(child: InteractiveViewer(child: Image.network(url))),
      );
}
