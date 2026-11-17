// Direct chat between a team member and the office (migration 0077).
// The member's side: a live panel with the manager that closes together with his shift.
// The office's side: pick a member, talk to him in the same panel; every conversation is kept in the logs until the owner deletes it.
import 'dart:async';
import '../../shared/motion.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'pos_repository.dart' show posErrorText;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));
Map<String, dynamic> _m(Object? o) => Map<String, dynamic>.from(o as Map);
List<Map<String, dynamic>> _l(Object? o) => [for (final e in (o as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
DateTime? _dt(Object? o) => o == null ? null : DateTime.tryParse('$o')?.toLocal();
String _two(int n) => n.toString().padLeft(2, '0');
String _clock(Object? iso) {
  final d = _dt(iso);
  return d == null ? '' : '${_two(d.hour)}:${_two(d.minute)}';
}

String _stamp(Object? iso) {
  final d = _dt(iso);
  return d == null ? '—' : '${_two(d.day)}/${_two(d.month)} ${_two(d.hour)}:${_two(d.minute)}';
}

const _roleNames = <String, (String, String)>{
  'owner': ('المالك', 'Owner'),
  'manager': ('مدير', 'Manager'),
  'sales': ('مبيعات', 'Sales'),
  'technician': ('فني صيانة', 'Technician'),
  'support': ('دعم', 'Support'),
  'cashier': ('كاشير', 'Cashier'),
  'accountant': ('محاسب', 'Accountant'),
};

class ChatRepository {
  ChatRepository(this._db);
  final SupabaseClient _db;
  Future<Map<String, dynamic>> unread() async => _m(await _db.rpc('chat_unread'));
  Future<Map<String, dynamic>> staffFetch() async => _m(await _db.rpc('chat_staff_fetch'));
  Future<void> staffSend(String body) async => _db.rpc('chat_staff_send', params: {'p_body': body});
  Future<void> staffClear() async => _db.rpc('chat_staff_clear');
  Future<List<Map<String, dynamic>>> directory() async => _l(await _db.rpc('chat_directory'));
  Future<Map<String, dynamic>> managerFetch(String staff) async => _m(await _db.rpc('chat_manager_fetch', params: {'p_staff': staff}));
  Future<void> managerSend(String staff, String body) async => _db.rpc('chat_manager_send', params: {'p_staff': staff, 'p_body': body});
  Future<List<Map<String, dynamic>>> logs() async => _l(await _db.rpc('chat_logs', params: {'p_limit': 300}));
  Future<List<Map<String, dynamic>>> threadMessages(String id) async => _l(await _db.rpc('chat_thread_messages', params: {'p_thread': id}));
  Future<int> deleteLogs({List<String>? ids, bool all = false}) async =>
      ((await _db.rpc('chat_logs_delete', params: {'p_threads': ids, 'p_all': all})) as num).toInt();
}

final chatRepoProvider = Provider((ref) => ChatRepository(ref.watch(supabaseProvider)));

class _Flag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

class _Peer extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

/// Floating mode: the panel is lifted off the left strip and can be dragged anywhere inside the window by its title bar.
final chatFloatProvider = NotifierProvider<_Flag, bool>(_Flag.new);

class _Pos extends Notifier<Offset> {
  @override
  Offset build() => const Offset(40, 70);
  void set(Offset o) => state = o;
}

final chatPosProvider = NotifierProvider<_Pos, Offset>(_Pos.new);

/// Whether the chat panel is showing, and (for the office) which member it is open with.
final chatOpenProvider = NotifierProvider<_Flag, bool>(_Flag.new);
final chatPeerProvider = NotifierProvider<_Peer, String?>(_Peer.new);

/// New messages waiting (badge + opens the panel by itself), re-read every few seconds.
final chatUnreadProvider = StreamProvider<Map<String, dynamic>>((ref) async* {
  final repo = ref.watch(chatRepoProvider);
  while (true) {
    try {
      yield await repo.unread();
    } catch (_) {/* offline for a moment */}
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

int chatUnreadCount(WidgetRef ref) => ((ref.watch(chatUnreadProvider).valueOrNull?['count'] as num?) ?? 0).toInt();

/// Invisible: opens the panel by itself when a new message arrives.
class ChatWatcher extends ConsumerWidget {
  const ChatWatcher({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(chatUnreadProvider, (prev, next) {
      final n = next.valueOrNull;
      if (n == null) return;
      final c = (n['count'] as num?)?.toInt() ?? 0;
      final pc = (prev?.valueOrNull?['count'] as num?)?.toInt() ?? 0;
      if (c <= pc || ref.read(chatOpenProvider)) return;
      if (n['mode'] == 'manager') ref.read(chatPeerProvider.notifier).set(n['staff_id'] as String?);
      ref.read(chatOpenProvider.notifier).set(true);
    });
    return const SizedBox.shrink();
  }
}

/// Width reserved at the far left of the console while the chat is open.
const double chatPanelSpace = 374;

/// The panel in the free space on the left. [manager] = the office's side.
class DirectChatPanel extends ConsumerWidget {
  const DirectChatPanel({super.key, required this.manager});
  final bool manager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(chatRepoProvider);
    void close() => ref.read(chatOpenProvider.notifier).set(false);
    final Widget body;
    if (!manager) {
      body = _ChatBody(
        key: const ValueKey('staff'),
        title: _t(context, 'شات مباشر مع المدير', 'Direct chat with the manager'),
        subtitle: _t(context, 'بيتقفل مع الوردية', 'Closes with your shift'),
        load: repo.staffFetch,
        send: repo.staffSend,
        onClose: close,
        chips: [_t(context, 'محتاج موافقة خصم', 'Need a discount approved'), _t(context, 'محتاج مساعدة', 'Need help'), _t(context, 'عميل مستني', 'A customer is waiting')],
        onClear: () async {
          final ok = await showSmoothDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: Text(_t(d, 'مسح المحادثة؟', 'Clear the chat?')),
              content: Text(_t(d, 'هتتمسح من عندك بس. الإدارة محتفظة بالسجل.', 'It disappears for you only. The office keeps the record.')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'لأ', 'No'))),
                FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(90, 44)), onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'امسح', 'Clear'))),
              ],
            ),
          );
          if (ok == true) await repo.staffClear();
        },
      );
    } else {
      final peer = ref.watch(chatPeerProvider);
      body = peer == null
          ? _Directory(onPick: (id) => ref.read(chatPeerProvider.notifier).set(id), onClose: close)
          : _ChatBody(
              key: ValueKey('peer-$peer'),
              title: null,
              subtitle: _t(context, 'رسالة مباشرة · محفوظة في السجل', 'Direct message · kept in the log'),
              load: () => repo.managerFetch(peer),
              send: (t) => repo.managerSend(peer, t),
              onClose: close,
              onBack: () => ref.read(chatPeerProvider.notifier).set(null),
              chips: [_t(context, 'تمام', 'OK'), _t(context, 'موافق على الخصم', 'Discount approved'), _t(context, 'ماينفعش', 'Not possible')],
            );
    }
    return Material(
      elevation: 10,
      color: panelColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: panelLine(context))),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.title, this.subtitle, this.onBack, required this.onClose, this.actions = const []});
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final VoidCallback onClose;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floating = ref.watch(chatFloatProvider);
    final bar = Container(
      color: BrandColors.navy,
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      child: Row(children: [
        if (onBack != null) IconButton(onPressed: onBack, tooltip: _t(context, 'رجوع للقائمة', 'Back to the list'), icon: const Icon(Icons.arrow_back_rounded, color: Colors.white)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
              if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFB8C4D9), fontSize: 11)),
            ]),
          ),
        ),
        ...actions,
        IconButton(
          onPressed: () => ref.read(chatFloatProvider.notifier).set(!floating),
          tooltip: floating ? _t(context, 'تثبيت على الشمال', 'Dock to the left') : _t(context, 'فكّها واسحبها في أي مكان', 'Undock and drag anywhere'),
          icon: Icon(floating ? Icons.push_pin_outlined : Icons.open_with_rounded, color: Colors.white),
        ),
        IconButton(onPressed: onClose, tooltip: _t(context, 'إخفاء (الرسايل بتتسجل)', 'Hide (messages are saved)'), icon: const Icon(Icons.close_rounded, color: Colors.white)),
      ]),
    );
    if (!floating) return bar;
    // floating: dragging the title bar moves the whole panel (kept inside the window)
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) {
          final size = MediaQuery.sizeOf(context);
          final cur = ref.read(chatPosProvider);
          ref.read(chatPosProvider.notifier).set(Offset(
                // the panel lives inside the centred 1100px column: keep it fully inside that column (it used to slide under the white margin)
                (cur.dx + d.delta.dx).clamp(0.0, (size.width < 1100 ? size.width : 1100.0) - (chatPanelSpace - 24)),
                (cur.dy + d.delta.dy).clamp(0.0, size.height - 60),
              ));
        },
        child: bar,
      ),
    );
  }
}

/// The conversation itself: polls every 3 seconds while it is on screen.
class _ChatBody extends StatefulWidget {
  const _ChatBody({super.key, required this.title, this.subtitle, required this.load, required this.send, required this.onClose, this.onBack, this.onClear, this.chips = const []});
  final String? title, subtitle;
  final Future<Map<String, dynamic>> Function() load;
  final Future<void> Function(String) send;
  final VoidCallback onClose;
  final VoidCallback? onBack;
  final Future<void> Function()? onClear;
  final List<String> chips;
  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  Timer? _timer;
  List<Map<String, dynamic>> _msgs = const [];
  String? _name;
  bool _loading = false, _sending = false, _first = true;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      });

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final r = await widget.load();
      if (!mounted) return;
      final msgs = _l(r['messages']);
      final changed = _first ||
          msgs.length != _msgs.length ||
          (msgs.isNotEmpty && (msgs.last['id'] != _msgs.last['id'] || msgs.last['read'] != _msgs.last['read'])) ||
          r['name'] != _name;
      if (changed) {
        final grew = msgs.length != _msgs.length;
        setState(() {
          _msgs = msgs;
          _name = r['name'] as String?;
          _first = false;
        });
        if (grew) _toEnd();
      }
    } catch (_) {/* keep what is on screen */} finally {
      _loading = false;
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.send(t);
      _text.clear();
      await _load();
      _toEnd();
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(
        title: widget.title ?? _name ?? '…',
        subtitle: widget.subtitle,
        onBack: widget.onBack,
        onClose: widget.onClose,
        actions: [
          if (widget.onClear != null)
            IconButton(
              tooltip: _t(context, 'مسح المحادثة من عندي', 'Clear the chat for me'),
              icon: const Icon(Icons.delete_sweep_outlined, color: Colors.white),
              onPressed: () async {
                await widget.onClear!();
                await _load();
              },
            ),
        ],
      ),
      Expanded(
        child: Container(
          color: Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFF4F6FA),
          child: _msgs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(_first ? '…' : _t(context, 'ابدأ المحادثة. الرسالة بتوصل لحظيًا.', 'Start the conversation. It arrives live.'), textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray)),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(10),
                  itemCount: _msgs.length,
                  itemBuilder: (_, i) => _Bubble(m: _msgs[i], staffSide: widget.onClear != null),
                ),
        ),
      ),
      if (widget.chips.isNotEmpty)
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            children: [
              for (final c in widget.chips)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ActionChip(visualDensity: VisualDensity.compact, label: Text(c, style: const TextStyle(fontSize: 12)), onPressed: () => setState(() => _text.text = c)),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _text,
              minLines: 1,
              maxLines: 3,
              maxLength: 1000,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(isDense: true, counterText: '', hintText: _t(context, 'اكتب رسالتك…', 'Type a message…')),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filled(
            onPressed: _sending ? null : _send,
            tooltip: _t(context, 'إرسال', 'Send'),
            icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded),
          ),
        ]),
      ),
    ]);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m, required this.staffSide});
  final Map<String, dynamic> m;
  final bool staffSide; // true: the viewer is the member
  @override
  Widget build(BuildContext context) {
    final fromStaff = m['from_staff'] == true;
    final mine = m['mine'] is bool ? m['mine'] as bool : fromStaff == staffSide;
    final read = m['read'] == true;
    return Align(
      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(11, 7, 11, 5),
        decoration: BoxDecoration(
          color: mine ? BrandColors.electric.withValues(alpha: 0.16) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: mine ? BrandColors.electric.withValues(alpha: 0.35) : BrandColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('${m['body']}', style: const TextStyle(fontSize: 14.5, height: 1.35)),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_clock(m['created_at']), style: const TextStyle(fontSize: 10, color: BrandColors.gray)),
            if (mine) ...[const SizedBox(width: 4), Icon(Icons.done_all_rounded, size: 14, color: read ? BrandColors.electric : BrandColors.gray)],
          ]),
        ]),
      ),
    );
  }
}

/// The office picks who to talk to.
class _Directory extends ConsumerStatefulWidget {
  const _Directory({required this.onPick, required this.onClose});
  final void Function(String) onPick;
  final VoidCallback onClose;
  @override
  ConsumerState<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends ConsumerState<_Directory> {
  Timer? _timer;
  List<Map<String, dynamic>>? _rows;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(chatRepoProvider).directory();
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted && _rows == null) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(title: _t(context, 'الرسايل المباشرة مع الموظفين', 'Direct messages with members'), subtitle: _t(context, 'اختار الموظف', 'Pick a member'), onClose: widget.onClose),
      Expanded(
        child: _rows == null
            ? Center(child: _error != null ? Padding(padding: const EdgeInsets.all(16), child: Text(_err(context, _error!))) : const CircularProgressIndicator())
            : _rows!.isEmpty
                ? Center(child: Text(_t(context, 'مفيش موظفين', 'No members'), style: const TextStyle(color: BrandColors.gray)))
                : ListView(children: [
                    for (final r in _rows!)
                      ListTile(
                        onTap: () => widget.onPick('${r['staff_id']}'),
                        leading: Stack(clipBehavior: Clip.none, children: [
                          const CircleAvatar(backgroundColor: Color(0xFFE8EEFF), child: Icon(Icons.person_rounded, color: BrandColors.navy)),
                          PositionedDirectional(
                            end: -1,
                            bottom: -1,
                            child: Container(width: 12, height: 12, decoration: BoxDecoration(color: r['online'] == true ? BrandColors.success : const Color(0xFFB0B7C3), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2))),
                          ),
                        ]),
                        title: Text('${r['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text([
                          () {
                            final n = _roleNames['${r['role']}'];
                            return n == null ? '${r['role']}' : _t(context, n.$1, n.$2);
                          }(),
                          if (r['last_at'] != null) _stamp(r['last_at']),
                        ].join(' · ')),
                        trailing: ((r['unread'] as num?) ?? 0) > 0
                            ? CircleAvatar(radius: 12, backgroundColor: BrandColors.error, child: Text('${r['unread']}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)))
                            : const Icon(Icons.chat_bubble_outline_rounded, size: 20, color: BrandColors.gray),
                      ),
                  ]),
      ),
    ]);
  }
}

/// The owner's record of every conversation: read it, delete chosen ones, or delete every closed one.
class ChatLogsDialog extends ConsumerStatefulWidget {
  const ChatLogsDialog({super.key, required this.canPurge});
  final bool canPurge;
  @override
  ConsumerState<ChatLogsDialog> createState() => _ChatLogsDialogState();
}

class _ChatLogsDialogState extends ConsumerState<ChatLogsDialog> {
  List<Map<String, dynamic>>? _rows;
  Object? _error;
  final _picked = <String>{};
  String? _open;
  List<Map<String, dynamic>> _msgs = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(chatRepoProvider).logs();
      if (mounted) setState(() {
        _rows = r;
        _error = null;
        _picked.removeWhere((id) => !r.any((x) => x['id'] == id));
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _show(String id) async {
    setState(() {
      _open = id;
      _msgs = const [];
    });
    try {
      final m = await ref.read(chatRepoProvider).threadMessages(id);
      if (mounted && _open == id) setState(() => _msgs = m);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    }
  }

  Future<void> _delete({List<String>? ids, bool all = false}) async {
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(all ? _t(d, 'مسح كل المحادثات المقفولة؟', 'Delete every closed conversation?') : _t(d, 'مسح ${ids!.length} محادثة؟', 'Delete ${ids.length} conversation(s)?')),
        content: Text(_t(d, 'هتتمسح نهائيًا من السيستم ومش هترجع. (المحادثات المفتوحة دلوقتي مش بتتمسح مع «مسح الكل».)', 'They are removed for good. (Conversations still open are not removed by "delete all".)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'لأ', 'No'))),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: BrandColors.error, minimumSize: const Size(100, 44)), onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'امسح', 'Delete'))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(chatRepoProvider).deleteLogs(ids: ids, all: all);
      if (mounted) {
        showSnack(context, _t(context, 'اتمسح $n محادثة', 'Deleted $n conversation(s)'));
        if (_open != null && (all || (ids?.contains(_open) ?? false))) _open = null;
      }
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(_t(context, 'سجل الرسايل المباشرة', 'Direct message log'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
              if (widget.canPurge && rows != null && rows.isNotEmpty) ...[
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(_t(context, 'مسح المحدد (${_picked.length})', 'Delete selected (${_picked.length})')),
                  onPressed: _busy || _picked.isEmpty ? null : () => _delete(ids: _picked.toList()),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), foregroundColor: BrandColors.error),
                  icon: const Icon(Icons.delete_forever_outlined, size: 18),
                  label: Text(_t(context, 'مسح كل المقفول', 'Delete all closed')),
                  onPressed: _busy ? null : () => _delete(all: true),
                ),
              ],
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: rows == null
                  ? Center(child: _error != null ? Text(_err(context, _error!)) : const CircularProgressIndicator())
                  : rows.isEmpty
                      ? Center(child: Text(_t(context, 'مفيش محادثات مسجلة', 'No recorded conversations'), style: const TextStyle(color: BrandColors.gray)))
                      : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(
                            flex: 5,
                            child: ListView(children: [
                              for (final r in rows)
                                Card(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  color: _open == r['id'] ? const Color(0xFFEAF4FF) : null,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () => _show('${r['id']}'),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                      child: Row(children: [
                                        if (widget.canPurge)
                                          Checkbox(
                                            value: _picked.contains(r['id']),
                                            onChanged: (v) => setState(() => v == true ? _picked.add('${r['id']}') : _picked.remove('${r['id']}')),
                                          ),
                                        Expanded(
                                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                            Row(children: [
                                              Flexible(child: Text(r['peer_name'] == null ? '${r['staff_name']}' : '${r['staff_name']}  ↔  ${r['peer_name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800))),
                                              if (r['closed_at'] == null)
                                                Container(
                                                  margin: const EdgeInsetsDirectional.only(start: 6),
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                                  decoration: BoxDecoration(color: BrandColors.success.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                                                  child: Text(_t(context, 'مفتوحة', 'Open'), style: const TextStyle(fontSize: 11, color: BrandColors.success, fontWeight: FontWeight.w800)),
                                                ),
                                            ]),
                                            Text(
                                              [
                                                if (r['branch_name_ar'] != null) '${r['branch_name_ar']}',
                                                '${_stamp(r['opened_at'])}${r['closed_at'] != null ? ' ← ${_stamp(r['closed_at'])}' : ''}',
                                                _t(context, '${r['msg_count']} رسالة', '${r['msg_count']} msgs'),
                                              ].join(' · '),
                                              style: const TextStyle(fontSize: 12, color: BrandColors.gray),
                                            ),
                                            Text('${r['last_body'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                                          ]),
                                        ),
                                      ]),
                                    ),
                                  ),
                                ),
                            ]),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 6,
                            child: Container(
                              decoration: BoxDecoration(color: const Color(0xFFF4F6FA), borderRadius: BorderRadius.circular(14), border: Border.all(color: BrandColors.border)),
                              child: _open == null
                                  ? Center(child: Text(_t(context, 'اختار محادثة تشوفها', 'Pick a conversation to read'), style: const TextStyle(color: BrandColors.gray)))
                                  : ListView(padding: const EdgeInsets.all(10), children: [
                                      for (final m in _msgs) _LogLine(m: m),
                                    ]),
                            ),
                          ),
                        ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.m});
  final Map<String, dynamic> m;
  @override
  Widget build(BuildContext context) {
    final fromStaff = m['from_staff'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${m['sender_name'] ?? (fromStaff ? _t(context, 'الموظف', 'Member') : _t(context, 'الإدارة', 'Office'))} · ${_stamp(m['created_at'])}', style: TextStyle(fontSize: 11, color: fromStaff ? BrandColors.warning : BrandColors.electric, fontWeight: FontWeight.w800)),
        Text('${m['body']}', style: const TextStyle(fontSize: 14)),
      ]),
    );
  }
}
