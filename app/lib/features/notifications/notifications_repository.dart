import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
        await _db.from('notifications').select().order('created_at', ascending: false).limit(100));
  }

  Future<void> markRead(String id) =>
      _db.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);

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

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(notificationsProvider);
    final repo = ref.read(notificationsRepoProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('notifications')), actions: [
        IconButton(icon: const Icon(Icons.done_all_rounded), onPressed: repo.markAllRead),
      ]),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(notificationsProvider)),
        data: (list) => list.isEmpty
            ? EmptyState(icon: Icons.notifications_off_outlined, title: context.tr('no_notifications'))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final n = list[i];
                  final unread = n['read_at'] == null;
                  return Card(
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
                  );
                },
              ),
      ),
    );
  }
}
