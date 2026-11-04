// Owner: each online employee's daily shift hours and monthly targets (orders handled and their value). Windows team app only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/motion.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

final _onlineProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final r = await ref.watch(supabaseProvider).rpc('online_overview') as Map;
  return [for (final e in (r['employees'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
});

class OnlinePlanPanel extends ConsumerWidget {
  const OnlinePlanPanel({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, Map<String, dynamic> e) async {
    final hours = TextEditingController(text: e['daily_hours'] == null ? '' : '${e['daily_hours']}');
    final orders = TextEditingController(text: e['orders_target'] == null ? '' : '${e['orders_target']}');
    final value = TextEditingController(text: e['value_target_minor'] == null ? '' : '${((e['value_target_minor'] as num) / 100).round()}');
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${e['name']}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: hours, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: _t(d, 'ساعات الشيفت في اليوم', 'Shift hours per day'))),
          const SizedBox(height: 8),
          TextField(controller: orders, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _t(d, 'تارجت الشهر: عدد الأوردرات', 'Monthly target: number of orders'))),
          const SizedBox(height: 8),
          TextField(controller: value, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _t(d, 'تارجت الشهر: قيمة الأوردرات (جنيه)', 'Monthly target: orders value (EGP)'))),
          const SizedBox(height: 8),
          Text(_t(d, 'سيب الخانة فاضية لو مش عايز تحدد.', 'Leave a field empty to not set it.'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'حفظ', 'Save'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final h = double.tryParse(hours.text.trim());
      final o = int.tryParse(orders.text.trim());
      final v = int.tryParse(value.text.trim());
      await ref.read(supabaseProvider).rpc('online_plan_set', params: {
        'p_user': e['user_id'],
        'p_daily_hours': h,
        'p_orders': o,
        'p_value_minor': v == null ? null : v * 100,
      });
      ref.invalidate(_onlineProvider);
      if (context.mounted) showSnack(context, _t(context, 'اتحفظ', 'Saved'));
    } catch (err) {
      if (context.mounted) showSnack(context, friendlyError(context, err), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_onlineProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(friendlyError(context, e))),
      data: (rows) => ListView(padding: const EdgeInsets.all(16), children: [
        Text(_t(context, 'الأوردر بيتحسب للموظف لما هو اللي يغيّر حالته لـ «تم التسليم». بيوصله إشعار لما يوصل 50% و75% و100% من التارجت.',
            'An order counts for the employee who sets it to Delivered. He is notified at 50%, 75% and 100% of his target.'), style: const TextStyle(color: BrandColors.gray, height: 1.5)),
        const SizedBox(height: 10),
        if (rows.isEmpty) Text(_t(context, 'مفيش موظفين.', 'No employees.')),
        for (final e in rows)
          Card(
            child: ListTile(
              title: Text('${e['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text([
                _t(context, 'ساعات: ${e['daily_hours'] ?? '—'}', 'Hours: ${e['daily_hours'] ?? '—'}'),
                _t(context, 'أوردرات: ${e['orders_done']} / ${e['orders_target'] ?? '—'}', 'Orders: ${e['orders_done']} / ${e['orders_target'] ?? '—'}'),
                _t(context, 'قيمة: ${((e['value_done_minor'] as num) / 100).round()} / ${e['value_target_minor'] == null ? '—' : ((e['value_target_minor'] as num) / 100).round()} ج.م',
                    'Value: ${((e['value_done_minor'] as num) / 100).round()} / ${e['value_target_minor'] == null ? '—' : ((e['value_target_minor'] as num) / 100).round()} EGP'),
              ].join('   •   ')),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => _edit(context, ref, e),
            ),
          ),
      ]),
    );
  }
}
