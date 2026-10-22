import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import '../repairs/repairs_screens.dart';
import 'orders_repository.dart';
import '../payments/payment_flow.dart';

Color orderStatusColor(String s) => switch (s) {
      'delivered' => BrandColors.success,
      'cancelled' => BrandColors.error,
      'pending_confirmation' => BrandColors.warning,
      _ => BrandColors.electric,
    };

String fmtDate(BuildContext context, String iso) =>
    DateFormat.yMMMd(context.lang).add_jm().format(DateTime.parse(iso).toLocal());

/// "Orders" tab: product orders + repair requests.
class OrdersTab extends StatelessWidget {
  const OrdersTab({super.key, this.initialIndex = 0});
  final int initialIndex;
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        initialIndex: initialIndex.clamp(0, 1).toInt(),
        child: Scaffold(
          appBar: AppBar(
            title: Text(context.tr('my_orders')),
            bottom: TabBar(tabs: [Tab(text: context.tr('my_orders')), Tab(text: context.tr('repairs'))]),
          ),
          body: const TabBarView(children: [MyOrdersList(), MyRepairsList()]),
        ),
      );
}

class MyOrdersList extends ConsumerWidget {
  const MyOrdersList({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(myOrdersProvider);
    return data.when(
      loading: () => ListView(padding: const EdgeInsets.all(16), children: List.generate(4, (_) => const Padding(padding: EdgeInsets.only(bottom: 10), child: Skeleton(height: 90)))),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(myOrdersProvider)),
      data: (list) => list.isEmpty
          ? EmptyState(icon: Icons.receipt_long_outlined, title: context.tr('no_orders'), action: context.tr('continue_shopping'), onAction: () => context.go('/'))
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(myOrdersProvider),
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final o = list[i];
                  final items = List<Map<String, dynamic>>.from(o['order_items'] ?? []);
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => context.push('/orders/${o['id']}'),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text(o['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                            const Spacer(),
                            StatusChip(label: context.tr('os_${o['status']}'), color: orderStatusColor(o['status'] as String)),
                          ]),
                          const SizedBox(height: 6),
                          Text(items.map((it) => '${context.pick(it, 'name')} × ${it['quantity']}').join('، '),
                              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BrandColors.gray)),
                          const SizedBox(height: 6),
                          Row(children: [
                            Text(fmtDate(context, o['created_at'] as String), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                            const Spacer(),
                            Text(formatEgp((o['total_minor'] as num).toInt(), context.lang), style: const TextStyle(fontWeight: FontWeight.w800)),
                          ]),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class OrderDetailsScreen extends ConsumerStatefulWidget {
  const OrderDetailsScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends ConsumerState<OrderDetailsScreen> {
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    // Live status: subscribe to this order's history rows (RLS-filtered), then refetch from DB.
    final db = ref.read(supabaseProvider);
    _channel = db
        .channel('order:${widget.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'order_status_history',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'order_id', value: widget.id),
          callback: (_) {
            ref.invalidate(orderProvider(widget.id));
            ref.invalidate(myOrdersProvider);
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (_channel != null) ref.read(supabaseProvider).removeChannel(_channel!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(orderProvider(widget.id));
    final lang = context.lang;
    return Scaffold(
      appBar: AppBar(leading: const BackOrHomeButton(), title: Text(context.tr('view_order'))),
      bottomNavigationBar: const BackHomeBar(),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(orderProvider(widget.id))),
        data: (o) {
          final items = List<Map<String, dynamic>>.from(o['order_items'] ?? []);
          final history = List<Map<String, dynamic>>.from(o['order_status_history'] ?? [])
            ..sort((a, b) => (a['created_at'] as String).compareTo(b['created_at'] as String));
          final status = o['status'] as String;
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(orderProvider(widget.id)),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(o['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                      const Spacer(),
                      StatusChip(label: context.tr('os_$status'), color: orderStatusColor(status)),
                    ]),
                    const SizedBox(height: 8),
                    Text(fmtDate(context, o['created_at'] as String), style: const TextStyle(color: BrandColors.gray)),
                    const Divider(height: 24),
                    _kv(context.tr('fulfillment'), o['fulfillment'] == 'pickup' ? context.tr('branch_pickup') : context.tr('home_delivery')),
                    if (o['branches'] != null) _kv(context.tr('choose_branch'), '${context.pick(o['branches'] as Map<String, dynamic>, 'name')}\n${context.pick(o['branches'] as Map<String, dynamic>, 'address')}'),
                    if (o['branches'] != null && status == 'ready_for_pickup') _kv('', context.pick(o['branches'] as Map<String, dynamic>, 'pickup_instructions')),
                    if (o['delivery_address'] != null)
                      _kv(context.tr('addresses'), () {
                        final a = Map<String, dynamic>.from(o['delivery_address'] as Map);
                        return [a['governorate'], a['city'], a['street'], a['building']].where((x) => x != null && '$x'.isNotEmpty).join(' — ');
                      }()),
                    _kv(context.tr('payment_method'), o['payment_method'] == 'online' ? context.tr('pay_online') : (o['payment_method'] == 'cash_on_delivery' ? context.tr('cod') : context.tr('pay_branch'))),
                    _kv(context.tr('payment_status'), context.tr('ps_${o['payment_status']}')),
                    if (o['payment_method'] == 'online' && status != 'cancelled' && ['unpaid', 'failed', 'pending'].contains(o['payment_status']))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton.icon(
                          icon: const Icon(Icons.lock_rounded, size: 18),
                          label: Text(context.tr('pay_now')),
                          onPressed: () => startOnlinePayment(context, ref, orderId: widget.id, saveCard: false),
                        ),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Text(context.tr('timeline'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Timeline(entries: [
                    for (final h in history)
                      TimelineEntry(
                        title: (h['customer_message'] != null && h['from_status'] == h['to_status'])
                            ? context.tr('order_update')
                            : context.tr('os_${h['to_status']}'),
                        subtitle: fmtDate(context, h['created_at'] as String),
                        body: h['customer_message'] as String?,
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Text(context.tr('items'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    for (final it in items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${context.pick(it, 'name')} × ${it['quantity']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text(it['sku'] as String, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                            ]),
                          ),
                          Text(formatEgp((it['line_total_minor'] as num).toInt(), lang)),
                        ]),
                      ),
                    const Divider(height: 20),
                    _kv(context.tr('subtotal'), formatEgp((o['subtotal_minor'] as num).toInt() + (o['discount_minor'] as num).toInt(), lang)),
                    if ((o['discount_minor'] as num) > 0) _kv(context.tr('discount'), '- ${formatEgp((o['discount_minor'] as num).toInt(), lang)}'),
                    _kv(context.tr('delivery_fee'), formatEgp((o['delivery_fee_minor'] as num).toInt(), lang)),
                    _kv(context.tr('total'), formatEgp((o['total_minor'] as num).toInt(), lang), bold: true),
                  ]),
                ),
              ),
              if (status == 'pending_confirmation') ...[
                const SizedBox(height: 16),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: BrandColors.error),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        content: Text(context.tr('cancel_confirm')),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.tr('cancel'))),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(context.tr('confirm'))),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    try {
                      await ref.read(ordersRepoProvider).cancel(widget.id);
                      ref.invalidate(orderProvider(widget.id));
                      ref.invalidate(myOrdersProvider);
                    } catch (e) {
                      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                    }
                  },
                  child: Text(context.tr('cancel_order')),
                ),
              ],
            ]),
          );
        },
      ),
    );
  }

  Widget _kv(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: const TextStyle(color: BrandColors.gray))),
          Expanded(child: Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w600))),
        ]),
      );
}

class TimelineEntry {
  const TimelineEntry({required this.title, this.subtitle, this.body});
  final String title;
  final String? subtitle;
  final String? body;
}

class Timeline extends StatelessWidget {
  const Timeline({super.key, required this.entries});
  final List<TimelineEntry> entries;
  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < entries.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Column(children: [
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == entries.length - 1 ? BrandColors.electric : BrandColors.navy,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: i == entries.length - 1 ? [BoxShadow(color: BrandColors.electric.withOpacity(0.5), blurRadius: 8)] : null,
                  ),
                ),
                if (i < entries.length - 1) Expanded(child: Container(width: 2, color: BrandColors.border)),
              ]),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(entries[i].title, style: TextStyle(fontWeight: i == entries.length - 1 ? FontWeight.w900 : FontWeight.w600)),
                    if (entries[i].body != null && entries[i].body!.isNotEmpty) Text(entries[i].body!),
                    if (entries[i].subtitle != null) Text(entries[i].subtitle!, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                  ]),
                ),
              ),
            ]),
          ),
      ]);
}
