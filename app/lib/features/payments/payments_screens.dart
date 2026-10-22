import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import '../orders/orders_screens.dart';
import 'payments_repository.dart';

Color paymentStatusColor(String s) => switch (s) {
      'succeeded' => BrandColors.success,
      'failed' => BrandColors.error,
      'cancelled' => BrandColors.gray,
      'refunded' || 'partially_refunded' => BrandColors.warning,
      _ => BrandColors.electric,
    };

String methodLabel(BuildContext context, Map<String, dynamic> p) {
  final type = p['payment_method_type'] as String?;
  final brand = (p['card_brand'] ?? p['brand']) as String?;
  final last4 = (p['card_last4'] ?? p['last4']) as String?;
  final wallet = switch (type ?? p['wallet']) { 'apple_pay' => 'Apple Pay', 'google_pay' => 'Google Pay', _ => null };
  final card = brand == null ? null : '${brand[0].toUpperCase()}${brand.substring(1)}${last4 != null ? ' •••• $last4' : ''}';
  return [wallet, card].whereType<String>().join(' · ').ifEmpty(context.tr('pay_online'));
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

IconData brandIcon(String? brand) => switch (brand) { 'visa' || 'mastercard' => Icons.credit_card_rounded, _ => Icons.payment_rounded };

class SavedCardsScreen extends ConsumerWidget {
  const SavedCardsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(savedCardsProvider);
    final repo = ref.read(paymentsRepoProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('saved_cards'))),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(savedCardsProvider)),
        data: (cards) => cards.isEmpty
            ? EmptyState(icon: Icons.credit_card_off_outlined, title: context.tr('no_saved_cards'), body: context.tr('saved_cards_hint'))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Text(context.tr('saved_cards_hint'), style: const TextStyle(color: BrandColors.gray)),
                const SizedBox(height: 12),
                for (final c in cards)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: ListTile(
                        leading: Icon(brandIcon(c['brand'] as String?), color: BrandColors.navy, size: 32),
                        title: Directionality(textDirection: TextDirection.ltr, child: Text(methodLabel(context, c), textAlign: context.isAr ? TextAlign.end : TextAlign.start, style: const TextStyle(fontWeight: FontWeight.w700))),
                        subtitle: Text([
                          if (c['expiry_month'] != null) '${context.tr('expires')} ${c['expiry_month'].toString().padLeft(2, '0')}/${c['expiry_year']}',
                          if (c['is_default'] == true) context.tr('default_card'),
                        ].join(' · ')),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            try {
                              if (v == 'default') await repo.setDefaultCard(c['id'] as String);
                              if (v == 'remove') {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (d) => AlertDialog(
                                    content: Text(context.tr('remove_card_confirm')),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('cancel'))),
                                      FilledButton(style: FilledButton.styleFrom(backgroundColor: BrandColors.error), onPressed: () => Navigator.pop(d, true), child: Text(context.tr('remove_card'))),
                                    ],
                                  ),
                                );
                                if (ok != true) return;
                                await repo.removeCard(c['id'] as String);
                              }
                              ref.invalidate(savedCardsProvider);
                            } catch (e) {
                              if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                            }
                          },
                          itemBuilder: (_) => [
                            if (c['is_default'] != true) PopupMenuItem(value: 'default', child: Text(context.tr('make_default_card'))),
                            PopupMenuItem(value: 'remove', child: Text(context.tr('remove_card'), style: const TextStyle(color: BrandColors.error))),
                          ],
                        ),
                      ),
                    ),
                  ),
              ]),
      ),
    );
  }
}

class PaymentsHistoryScreen extends ConsumerWidget {
  const PaymentsHistoryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(myPaymentsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('payments_history'))),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(myPaymentsProvider)),
        data: (list) => list.isEmpty
            ? EmptyState(icon: Icons.receipt_long_outlined, title: context.tr('no_payments'))
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(myPaymentsProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final p = list[i];
                    final st = p['status'] as String;
                    return Card(
                      child: ListTile(
                        onTap: () => context.push('/payments/${p['id']}'),
                        leading: Icon(brandIcon(p['card_brand'] as String?), color: BrandColors.navy),
                        title: Text('${(p['orders'] as Map?)?['reference'] ?? ''} · ${formatEgp((p['amount_minor'] as num).toInt(), context.lang)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${methodLabel(context, p)}\n${fmtDate(context, p['created_at'] as String)}'),
                        isThreeLine: true,
                        trailing: StatusChip(label: context.tr('pst_$st'), color: paymentStatusColor(st)),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class PaymentDetailsScreen extends ConsumerWidget {
  const PaymentDetailsScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(paymentWatchProvider(id));
    final lang = context.lang;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('payment_details'))),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(paymentWatchProvider(id))),
        data: (p) {
          final st = p['status'] as String;
          final order = (p['orders'] as Map?) ?? const {};
          Widget kv(String k, String v) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 140, child: Text(k, style: const TextStyle(color: BrandColors.gray))),
                  Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
                ]),
              );
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(formatEgp((p['amount_minor'] as num).toInt(), lang), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                    const Spacer(),
                    StatusChip(label: context.tr('pst_$st'), color: paymentStatusColor(st)),
                  ]),
                  const Divider(height: 24),
                  kv(context.tr('order_number'), '${order['reference'] ?? ''}'),
                  kv(context.tr('payment_method'), methodLabel(context, p)),
                  kv(context.tr('currency'), '${p['currency']}'),
                  kv(context.tr('transaction_id'), '${p['provider_transaction_id'] ?? '—'}'),
                  kv(context.tr('date'), fmtDate(context, p['created_at'] as String)),
                  if ((p['refunded_minor'] as num? ?? 0) > 0) kv(context.tr('refunded_amount'), formatEgp((p['refunded_minor'] as num).toInt(), lang)),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Text(context.tr(st == 'pending' || st == 'processing' ? 'pay_pending_b' : st == 'succeeded' ? 'pay_verified_note' : 'pay_failed_b'),
                style: const TextStyle(color: BrandColors.gray)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => context.push('/orders/${p['order_id']}'), child: Text(context.tr('view_order'))),
          ]);
        },
      ),
    );
  }
}
