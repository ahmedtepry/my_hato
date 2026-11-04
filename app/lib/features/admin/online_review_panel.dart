// "الأونلاين": the accountant's page. Per employee (orders he confirmed, value, commission), where the money is (online wallet / delivery cash /
// paid at a branch till) and every online order with branch-pickup vs delivery. Orders paid at a branch that already show up as a till sale are
// flagged so the money is not counted twice. Windows team app only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/motion.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
num _n(Object? v) => v is num ? v : 0;
String _egp(BuildContext c, num minor) {
  final v = (minor / 100).round().toString();
  final b = StringBuffer();
  for (var i = 0; i < v.length; i++) {
    if (i > 0 && (v.length - i) % 3 == 0 && v[i - 1] != '-') b.write(',');
    b.write(v[i]);
  }
  return _t(c, '$b ج.م', '$b EGP');
}

final _periodProvider = StateProvider.autoDispose<DateTime>((ref) => DateTime(DateTime.now().year, DateTime.now().month, 1));
final _reportProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final p = ref.watch(_periodProvider);
  return Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('online_report', params: {'p_year': p.year, 'p_month': p.month}) as Map);
});
final _filterProvider = StateProvider.autoDispose<String>((ref) => 'all');

class OnlineReviewPanel extends ConsumerWidget {
  const OnlineReviewPanel({super.key});

  String _bucket(BuildContext c, String? b) => switch (b) {
        'online_money' => _t(c, 'فلوس أونلاين (محفظة/إلكتروني)', 'Online money (wallet / electronic)'),
        'branch_till' => _t(c, 'مدفوع في الفرع (بيتحسب في كاشير الفرع)', 'Paid at a branch (counted in the branch till)'),
        _ => _t(c, 'كاش توصيل', 'Delivery cash'),
      };

  String _state(BuildContext c, String? s) => switch (s) {
        'payable' => _t(c, 'مستحقة', 'Payable'),
        'waiting_payment' => _t(c, 'مسجلة، مستنية وصول التحويل', 'Recorded, waiting for the transfer'),
        'waiting_branch_sale' => _t(c, 'مسجلة، مستنية فاتورة الفرع', 'Recorded, waiting for the branch sale'),
        'refunded' => _t(c, 'مرتجع', 'Refunded'),
        _ => _t(c, 'لسه ما اتسلمش', 'Not delivered yet'),
      };

  Color _stateColor(String? s) => switch (s) {
        'payable' => const Color(0xFF12B76A),
        'waiting_payment' || 'waiting_branch_sale' => const Color(0xFFE8A317),
        'refunded' => BrandColors.error,
        _ => BrandColors.gray,
      };

  Future<void> _settle(BuildContext context, WidgetRef ref, String reference) async {
    final note = TextEditingController();
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'تأكيد استلام فلوس الأوردر $reference', 'Confirm the money for $reference')),
        content: TextField(controller: note, decoration: InputDecoration(labelText: _t(d, 'ملاحظة (مثلا: اتدفع في فرع ١ ورقم الإيصال)', 'Note (e.g. paid at branch 1, receipt number)'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'تأكيد', 'Confirm'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(supabaseProvider).rpc('online_mark_settled', params: {'p_reference': reference, 'p_note': note.text.trim()});
      ref.invalidate(_reportProvider);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(_periodProvider);
    final filter = ref.watch(_filterProvider);
    final async = ref.watch(_reportProvider);
    final months = [for (var i = 0; i < 12; i++) DateTime(DateTime.now().year, DateTime.now().month - i, 1)];
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: friendlyError(context, e), onRetry: () => ref.invalidate(_reportProvider)),
      data: (r) {
        final emps = [for (final e in (r['employees'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        final money = [for (final e in (r['money'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        final all = [for (final e in (r['orders'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        final dups = all.where((o) => o['bucket'] == 'branch_till' && o['till_sale'] != null).toList();
        final waitingSale = all.where((o) => o['commission_state'] == 'waiting_branch_sale').toList();
        final shown = all.where((o) {
          switch (filter) {
            case 'pickup': return o['fulfillment'] == 'pickup';
            case 'delivery': return o['fulfillment'] == 'delivery';
            case 'warn': return o['till_sale'] != null && o['bucket'] == 'branch_till' || o['commission_state'] == 'waiting_branch_sale' || o['commission_state'] == 'waiting_payment';
            default: return true;
          }
        }).toList().reversed.take(300).toList();
        return ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Text(_t(context, 'الشهر', 'Month'), style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            DropdownButton<DateTime>(
              value: months.firstWhere((m) => m.year == period.year && m.month == period.month, orElse: () => months.first),
              items: [for (final m in months) DropdownMenuItem(value: m, child: Text('${m.year}-${m.month.toString().padLeft(2, '0')}'))],
              onChanged: (v) {
                if (v != null) ref.read(_periodProvider.notifier).state = v;
              },
            ),
          ]),
          const SizedBox(height: 8),
          if (dups.isNotEmpty || waitingSale.isNotEmpty)
            Card(
              color: const Color(0xFFFFF7E6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFE8A317)),
                    const SizedBox(width: 8),
                    Text(_t(context, 'تنبيه تكرار الفلوس', 'Double-counting alert'), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 6),
                  if (dups.isNotEmpty)
                    Text(_t(context, '${dups.length} أوردر أونلاين اتدفع في الفرع وليه فاتورة كاشير بنفس المبلغ (${_egp(context, dups.fold<num>(0, (a, o) => a + _n(o['total_minor'])))}). الفلوس دي اتحسبت في الفرع، ماتضيفهاش تاني على الأونلاين. العمولة بتفضل للموظف.',
                        '${dups.length} online order(s) were paid at a branch and have a till sale with the same amount (${_egp(context, dups.fold<num>(0, (a, o) => a + _n(o['total_minor'])))}). That money is already in the branch; do not add it to online again. The commission stays with the employee.')),
                  if (waitingSale.isNotEmpty)
                    Text(_t(context, '${waitingSale.length} أوردر تم تسليمه ومفيش له فاتورة في كاشير الفرع. اتأكد إن الفلوس اتدفعت، وبعدين اضغط «اتدفع».',
                        '${waitingSale.length} delivered order(s) have no till sale at the branch. Check the money was paid, then press "Paid".')),
                ]),
              ),
            ),
          const SizedBox(height: 8),
          Text(_t(context, 'الفلوس فين؟', 'Where is the money?'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 6),
          if (money.isEmpty) Text(_t(context, 'مفيش أوردرات متسلمة الشهر ده.', 'No delivered orders this month.')),
          for (final m in money)
            Card(
              child: ListTile(
                title: Text(_bucket(context, '${m['bucket']}'), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: _n(m['counted_again_minor']) > 0
                    ? Text(_t(context, 'منهم ${_egp(context, _n(m['counted_again_minor']))} اتحسبوا في كاشير الفرع (ماتتحسبش تاني)', '${_egp(context, _n(m['counted_again_minor']))} of it is already in a branch till (do not count again)'))
                    : null,
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(_egp(context, _n(m['total_minor'])), style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(_t(context, '${m['n']} أوردر', '${m['n']} order(s)'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                ]),
              ),
            ),
          const SizedBox(height: 14),
          Text(_t(context, 'الموظفين والعمولة', 'Employees and commission'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 6),
          if (emps.isEmpty) Text(_t(context, 'مفيش موظف أكّد أوردرات الشهر ده.', 'No employee confirmed orders this month.')),
          for (final e in emps)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${e['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 16, runSpacing: 4, children: [
                    Text(_t(context, 'أكّد: ${e['confirmed_n']}', 'Confirmed: ${e['confirmed_n']}')),
                    Text(_t(context, 'اتسلم: ${e['delivered_n']} (${_egp(context, _n(e['delivered_minor']))})', 'Delivered: ${e['delivered_n']} (${_egp(context, _n(e['delivered_minor']))})')),
                    Text(_t(context, 'عمولة مسجلة: ${_egp(context, _n(e['commission_minor']))}', 'Recorded commission: ${_egp(context, _n(e['commission_minor']))}')),
                    Text(_t(context, 'مستحقة دلوقتي: ${_egp(context, _n(e['payable_minor']))}', 'Payable now: ${_egp(context, _n(e['payable_minor']))}'), style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF12B76A))),
                    Text(_t(context, 'شيفتات: ${e['shifts_count']} (${e['shift_hours']} ساعة)', 'Shifts: ${e['shifts_count']} (${e['shift_hours']} h)')),
                  ]),
                ]),
              ),
            ),
          const SizedBox(height: 14),
          Row(children: [
            Text(_t(context, 'الأوردرات', 'Orders'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(width: 12),
            Wrap(spacing: 6, children: [
              for (final f in const [('all', 'الكل', 'All'), ('pickup', 'استلام من فرع', 'Branch pickup'), ('delivery', 'توصيل', 'Delivery'), ('warn', 'محتاج مراجعة', 'To review')])
                ChoiceChip(label: Text(_t(context, f.$2, f.$3)), selected: filter == f.$1, onSelected: (_) => ref.read(_filterProvider.notifier).state = f.$1),
            ]),
          ]),
          const SizedBox(height: 6),
          for (final o in shown)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${o['reference']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                    Text(_egp(context, _n(o['total_minor'])), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 4),
                  Wrap(spacing: 14, runSpacing: 2, children: [
                    Text(o['fulfillment'] == 'pickup'
                        ? _t(context, 'استلام من فرع: ${o['branch'] ?? 'لسه ما اتحددش'}', 'Branch pickup: ${o['branch'] ?? 'not set yet'}')
                        : _t(context, 'توصيل', 'Delivery')),
                    Text(_bucket(context, '${o['bucket']}')),
                    Text(_t(context, 'الموظف: ${o['employee'] ?? '—'}', 'Employee: ${o['employee'] ?? '—'}')),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.circle, size: 10, color: _stateColor('${o['commission_state']}')),
                    const SizedBox(width: 6),
                    Expanded(child: Text('${_t(context, 'العمولة', 'Commission')} ${_egp(context, _n(o['commission_minor']))} - ${_state(context, '${o['commission_state']}')}')),
                    if (o['commission_state'] == 'waiting_branch_sale')
                      TextButton(onPressed: () => _settle(context, ref, '${o['reference']}'), child: Text(_t(context, 'اتدفع', 'Paid'))),
                  ]),
                  if (o['till_sale'] != null && o['bucket'] == 'branch_till')
                    Text(_t(context, 'اتحسب في كاشير الفرع (فاتورة ${o['till_sale']}) - مايتحسبش تاني', 'Counted in the branch till (sale ${o['till_sale']}) - do not count again'),
                        style: const TextStyle(color: Color(0xFFB54708), fontWeight: FontWeight.w700)),
                  if (o['settled'] == true) Text(_t(context, 'المحاسب أكّد استلام الفلوس', 'The accountant confirmed the money'), style: const TextStyle(color: Color(0xFF12B76A))),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
