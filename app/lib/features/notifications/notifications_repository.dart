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
    if (_db.auth.currentUser == null) return [];
    return List<Map<String, dynamic>>.from(
        await _db.from('notifications').select().isFilter('cleared_at', null).order('created_at', ascending: false).limit(100));
  }

  Future<void> markRead(String id) =>
      _db.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);

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
      controller.add(await repo.list());
    } catch (e, st) {
      controller.addError(e, st);
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
  ref.onDispose(() {
    db.removeChannel(channel);
    controller.close();
  });
  return controller.stream;
});

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
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('notifications')), actions: [
        IconButton(
          tooltip: context.isAr ? 'مسح الكل' : 'Clear all',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: visible.isEmpty ? null : () => _clearAll(visible),
        ),
        IconButton(tooltip: context.isAr ? 'قراءة الكل' : 'Mark all read', icon: const Icon(Icons.done_all_rounded), onPressed: repo.markAllRead),
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
                  final unread = n['read_at'] == null;
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
                    child: Card(
                    color: unread ? BrandColors.electric.withOpacity(0.06) : null,
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
                      onTap: () {
                        repo.markRead(n['id'] as String);
                        final link = n['deep_link'] as String?;
                        if (link != null) context.push(link);
                      },
                    ),
                  ),
                  );
                },
              ),
      ),
    );
  }
}
