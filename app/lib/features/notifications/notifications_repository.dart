import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

class NotificationsRepository {
  NotificationsRepository(this._db);
  final SupabaseClient _db;

  Future<List<Map<String, dynamic>>> list() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    // always the signed-in person's own notifications — staff accounts may read other customers'
    // rows through RLS, but they must never show up in their own inbox
    return List<Map<String, dynamic>>.from(await _db
        .from('notifications')
        .select()
        .eq('user_id', uid)
        .isFilter('cleared_at', null)
        .order('created_at', ascending: false)
        .limit(100));
  }

  Future<void> markRead(String id) => _db
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', id)
      .eq('user_id', _db.auth.currentUser?.id ?? '')
      .isFilter('read_at', null);

  /// Hides one notification (id) or all of them (null) for this customer.
  Future<void> clear([String? id]) => _db.rpc('customer_clear_notifications', params: {'p_id': id});

  Future<void> markAllRead() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    await _db.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('user_id', uid).isFilter('read_at', null);
  }
}

final notificationsRepoProvider = Provider((ref) => NotificationsRepository(ref.watch(supabaseProvider)));

/// Live notifications: initial fetch + Supabase Realtime (RLS limits events
/// to the signed-in user's own rows). The DB stays the source of truth.
final notificationsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final user = ref.watch(currentUserProvider);
  final db = ref.watch(supabaseProvider);
  final repo = ref.watch(notificationsRepoProvider);
  final controller = StreamController<List<Map<String, dynamic>>>();
  if (user == null) {
    controller.add(const []);
    return controller.stream;
  }
  Future<void> load() async {
    try {
      final rows = await repo.list();
      if (!controller.isClosed) controller.add(rows);
    } catch (e, st) {
      if (!controller.isClosed) controller.addError(e, st);
    }
  }

  load();
  final channel = db
      .channel('notifications:${user.id}')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'notifications',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: user.id),
        callback: (_) => load(),
      )
      .subscribe();
  // Safety nets so nothing is missed if the realtime socket silently drops (phone sleep, weak network):
  // reload when the app comes back to the foreground and every 45 s while it is open.
  final resume = _ResumeReload(load);
  WidgetsBinding.instance.addObserver(resume);
  final poll = Timer.periodic(const Duration(seconds: 45), (_) => load());
  ref.onDispose(() {
    poll.cancel();
    WidgetsBinding.instance.removeObserver(resume);
    db.removeChannel(channel);
    controller.close();
  });
  return controller.stream;
});

class _ResumeReload with WidgetsBindingObserver {
  _ResumeReload(this._reload);
  final Future<void> Function() _reload;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }
}

final unreadCountProvider = Provider<AsyncValue<int>>(
    (ref) => ref.watch(notificationsProvider).whenData((l) => l.where((n) => n['read_at'] == null).length));

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  /// Hidden right away on swipe / clear, before the server round-trip finishes.
  final _hidden = <String>{};
  bool _allHidden = false;

  /// Shown as read right away (before the server round-trip).
  final _read = <String>{};
  bool _autoReadDone = false;

  Future<void> _markAllRead(List<Map<String, dynamic>> list) async {
    final ids = [for (final n in list) if (n['read_at'] == null && !_read.contains(n['id'])) n['id'] as String];
    if (ids.isEmpty) return;
    setState(() => _read.addAll(ids));
    try {
      await ref.read(notificationsRepoProvider).markAllRead();
      ref.invalidate(notificationsProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _read.removeAll(ids));
        showSnack(context, friendlyError(context, e), error: true);
      }
    }
  }

  /// Opening the inbox counts as seeing the messages: after a short moment they all turn "read"
  /// (the highlight fades out), and the bell badge clears.
  void _autoRead(List<Map<String, dynamic>> list) {
    if (_autoReadDone || list.every((n) => n['read_at'] != null)) return;
    _autoReadDone = true;
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) _markAllRead(list);
    });
  }

  Future<void> _clearAll(List<Map<String, dynamic>> list) async {
    if (list.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_rounded, color: BrandColors.error, size: 36),
        title: Text(context.isAr ? 'تمسح كل الإشعارات؟' : 'Clear all notifications?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            onPressed: () => Navigator.pop(d, true),
            child: Text(context.isAr ? 'مسح الكل' : 'Clear all'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _allHidden = true);
    try {
      await ref.read(notificationsRepoProvider).clear();
      ref.invalidate(notificationsProvider);
      if (mounted) setState(() => _allHidden = false); // fresh list from the server (empty)
    } catch (e) {
      if (mounted) {
        setState(() => _allHidden = false);
        showSnack(context, friendlyError(context, e), error: true);
      }
    }
  }

  Future<void> _clearOne(String id) async {
    setState(() => _hidden.add(id));
    try {
      await ref.read(notificationsRepoProvider).clear(id);
      ref.invalidate(notificationsProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _hidden.remove(id));
        showSnack(context, friendlyError(context, e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(notificationsProvider);
    final repo = ref.read(notificationsRepoProvider);
    final visible = _allHidden ? <Map<String, dynamic>>[] : [for (final n in data.valueOrNull ?? const <Map<String, dynamic>>[]) if (!_hidden.contains(n['id'])) n];
    if (data.hasValue) _autoRead(visible);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('notifications')), actions: [
        IconButton(
          tooltip: context.isAr ? 'مسح الكل' : 'Clear all',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: visible.isEmpty ? null : () => _clearAll(visible),
        ),
        IconButton(
          tooltip: context.isAr ? 'قراءة الكل' : 'Mark all read',
          icon: const Icon(Icons.done_all_rounded),
          onPressed: visible.any((n) => n['read_at'] == null && !_read.contains(n['id'])) ? () => _markAllRead(visible) : null,
        ),
      ]),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(notificationsProvider)),
        data: (_) => visible.isEmpty
            ? EmptyState(icon: Icons.notifications_off_outlined, title: context.tr('no_notifications'))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: visible.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final n = visible[i];
                  final unread = n['read_at'] == null && !_read.contains(n['id']);
                  return Dismissible(
                    key: ValueKey(n['id']),
                    onDismissed: (_) => _clearOne(n['id'] as String),
                    background: Container(
                      alignment: AlignmentDirectional.centerStart,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(color: BrandColors.error.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                      child: const Icon(Icons.delete_outline_rounded, color: BrandColors.error),
                    ),
                    secondaryBackground: Container(
                      alignment: AlignmentDirectional.centerEnd,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(color: BrandColors.error.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                      child: const Icon(Icons.delete_outline_rounded, color: BrandColors.error),
                    ),
                    child: AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: unread ? const Color(0xFFEAF6FF) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: unread ? BrandColors.electric.withValues(alpha: 0.35) : BrandColors.border),
                    ),
                    child: Material(
                    type: MaterialType.transparency,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: Icon(
                          n['entity_type'] == 'repair' ? Icons.build_rounded : n['entity_type'] == 'order' ? Icons.receipt_long_rounded : Icons.campaign_outlined,
                          color: unread ? BrandColors.electric : BrandColors.gray),
                      title: Text(context.pick(n, 'title'), style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w500)),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(context.pick(n, 'body')),
                        const SizedBox(height: 4),
                        Text(DateFormat.yMMMd(context.lang).add_jm().format(DateTime.parse(n['created_at'] as String).toLocal()),
                            style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                      ]),
                      trailing: unread
                          ? Container(width: 9, height: 9, decoration: const BoxDecoration(color: BrandColors.electric, shape: BoxShape.circle))
                          : null,
                      onTap: () {
                        if (unread) {
                          setState(() => _read.add(n['id'] as String));
                          repo.markRead(n['id'] as String).then((_) => ref.invalidate(notificationsProvider), onError: (_) {});
                        }
                        final link = n['deep_link'] as String?;
                        if (link != null) context.push(link);
                      },
                    ),
                  ),
                  ),
                  );
                },
              ),
      ),
    );
  }
}
