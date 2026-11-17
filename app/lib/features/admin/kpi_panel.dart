// Employee commissions + KPIs (accountant / manager / owner, permission commission.view): for any period,
// every seller's sales, invoices, average ticket, refunds, discounts, tips, shifts and commission, with the commission log behind each one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../shared/motion.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import 'admin_repository.dart' show staffContextProvider;
import 'pos_repository.dart' show posErrorText;
import 'targets.dart' show TargetsPanel;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));
Map<String, dynamic> _m(Object? o) => Map<String, dynamic>.from(o as Map);
List<Map<String, dynamic>> _l(Object? o) => [for (final e in (o as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';
String _stamp(Object? iso) {
  final d = DateTime.tryParse('$iso')?.toLocal();
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

class _Range {
  const _Range(this.from, this.to);
  final DateTime from, to; // [from, to)
}

enum _Preset { today, week, month, lastMonth, custom }

class KpiPanel extends ConsumerStatefulWidget {
  const KpiPanel({super.key});
  @override
  ConsumerState<KpiPanel> createState() => _KpiPanelState();
}

class _KpiPanelState extends ConsumerState<KpiPanel> {
  _Preset _preset = _Preset.month;
  _Range _range = _rangeOf(_Preset.month);
  Future<Map<String, dynamic>>? _future;
  bool _showTargets = false;

  static _Range _rangeOf(_Preset p) {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    switch (p) {
      case _Preset.today:
        return _Range(today, today.add(const Duration(days: 1)));
      case _Preset.week:
        return _Range(today.subtract(Duration(days: (today.weekday + 1) % 7)), today.add(const Duration(days: 1))); // from Saturday
      case _Preset.month:
        return _Range(DateTime(n.year, n.month), DateTime(n.year, n.month + 1));
      case _Preset.lastMonth:
        return _Range(DateTime(n.year, n.month - 1), DateTime(n.year, n.month));
      case _Preset.custom:
        return _Range(DateTime(n.year, n.month), DateTime(n.year, n.month + 1));
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(supabaseProvider).rpc('kpi_employees', params: {
      'p_from': _range.from.toUtc().toIso8601String(),
      'p_to': _range.to.toUtc().toIso8601String(),
    }).then((v) => _m(v));
    setState(() {});
  }

  Future<void> _pick(_Preset p) async {
    if (p == _Preset.custom) {
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2024),
        lastDate: DateTime.now().add(const Duration(days: 1)),
        initialDateRange: DateTimeRange(start: _range.from, end: _range.to.subtract(const Duration(days: 1))),
      );
      if (r == null) return;
      _range = _Range(DateTime(r.start.year, r.start.month, r.start.day), DateTime(r.end.year, r.end.month, r.end.day).add(const Duration(days: 1)));
    } else {
      _range = _rangeOf(p);
    }
    _preset = p;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final label = <_Preset, String>{
      _Preset.today: _t(context, 'النهارده', 'Today'),
      _Preset.week: _t(context, 'الأسبوع ده', 'This week'),
      _Preset.month: _t(context, 'الشهر ده', 'This month'),
      _Preset.lastMonth: _t(context, 'الشهر اللي فات', 'Last month'),
      _Preset.custom: _t(context, 'فترة محددة…', 'Custom…'),
    };
    final canTargets = ref.watch(staffContextProvider).valueOrNull?.permissions.contains('targets.view') ?? false;
    final switcher = canTargets
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, icon: const Icon(Icons.leaderboard_rounded), label: Text(_t(context, 'العمولات والأداء', 'Commissions & KPIs'))),
                ButtonSegment(value: true, icon: const Icon(Icons.flag_rounded), label: Text(_t(context, 'التارجت (الفروع والموظفين)', 'Targets (branches & staff)'))),
              ],
              selected: {_showTargets},
              onSelectionChanged: (v) => setState(() => _showTargets = v.first),
            ),
          )
        : const SizedBox.shrink();
    return Column(children: [
      switcher,
      Expanded(child: _showTargets && canTargets ? const TargetsPanel() : _kpiList(context, label)),
    ]);
  }

  Widget _kpiList(BuildContext context, Map<_Preset, String> label) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: Text(_t(context, 'عمولات و KPI الموظفين', 'Employee commissions & KPIs'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
        IconButton(onPressed: _reload, tooltip: _t(context, 'تحديث', 'Refresh'), icon: const Icon(Icons.refresh_rounded)),
      ]),
      Text('${_day(_range.from)}  →  ${_day(_range.to.subtract(const Duration(days: 1)))}', style: const TextStyle(color: BrandColors.gray)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 6, children: [
        for (final p in _Preset.values) ChoiceChip(label: Text(label[p]!), selected: _preset == p, onSelected: (_) => _pick(p)),
      ]),
      const SizedBox(height: 14),
      FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
          if (snap.hasError) return Padding(padding: const EdgeInsets.all(20), child: Text(_err(context, snap.error!)));
          final rows = _l(snap.data!['employees']);
          if (rows.isEmpty) {
            return Padding(padding: const EdgeInsets.all(40), child: Center(child: Text(_t(context, 'مفيش مبيعات في الفترة دي', 'No sales in this period'), style: const TextStyle(color: BrandColors.gray))));
          }
          num sum(String k) => rows.fold<num>(0, (s, r) => s + ((r[k] as num?) ?? 0));
          final isMonth = _preset == _Preset.month;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Card(
              color: BrandColors.electric.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(spacing: 22, runSpacing: 10, children: [
                  _Stat(_t(context, 'صافي المبيعات', 'Net sales'), _money(context, sum('net_minor')), big: true),
                  _Stat(_t(context, 'إجمالي العمولات', 'Total commissions'), _money(context, sum('commission_minor')), big: true, color: const Color(0xFFE8A317)),
                  _Stat(_t(context, 'عدد الفواتير', 'Invoices'), '${sum('sales_count').toInt()}'),
                  _Stat(_t(context, 'البقشيش', 'Tips'), _money(context, sum('tips_minor'))),
                  _Stat(_t(context, 'الموظفين', 'Employees'), '${rows.length}'),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            for (final r in rows) _EmployeeCard(r: r, range: _range, showTarget: isMonth),
          ]);
        },
      ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.big = false, this.color});
  final String label, value;
  final bool big;
  final Color? color;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
        Text(value, style: TextStyle(fontSize: big ? 20 : 15, fontWeight: FontWeight.w800, color: color)),
      ]);
}

class _EmployeeCard extends ConsumerWidget {
  const _EmployeeCard({required this.r, required this.range, required this.showTarget});
  final Map<String, dynamic> r;
  final _Range range;
  final bool showTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = _roleNames['${r['role']}'];
    final target = (r['target_minor'] as num?)?.toInt();
    final net = (r['net_minor'] as num).toInt();
    final pct = (showTarget && target != null && target > 0) ? net * 100 / target : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showSmoothDialog<void>(context: context, builder: (_) => _LogDialog(userId: '${r['user_id']}', name: '${r['name']}', range: range)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('${r['name']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
              if (role != null) Chip(visualDensity: VisualDensity.compact, label: Text(_t(context, role.$1, role.$2), style: const TextStyle(fontSize: 12))),
              const Icon(Icons.chevron_left_rounded, color: BrandColors.gray),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 22, runSpacing: 10, children: [
              _Stat(_t(context, 'صافي المبيعات', 'Net sales'), _money(context, net)),
              _Stat(_t(context, 'العمولة', 'Commission'), _money(context, (r['commission_minor'] as num)), color: const Color(0xFFE8A317), big: true),
              _Stat(_t(context, 'الفواتير', 'Invoices'), '${r['sales_count']}'),
              _Stat(_t(context, 'متوسط الفاتورة', 'Avg ticket'), _money(context, (r['avg_ticket_minor'] as num))),
              _Stat(_t(context, 'المرتجعات', 'Refunds'), _money(context, (r['refunds_minor'] as num))),
              _Stat(_t(context, 'الخصومات', 'Discounts'), _money(context, (r['discount_minor'] as num))),
              _Stat(_t(context, 'البقشيش', 'Tips'), _money(context, (r['tips_minor'] as num))),
              _Stat(_t(context, 'الورديات', 'Shifts'), '${r['shifts_count']}'),
            ]),
            if (pct != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                Text(_t(context, 'التارجت ${_money(context, target!)}', 'Target ${_money(context, target)}'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                const Spacer(),
                Text('${pct.toStringAsFixed(0)}%', style: TextStyle(fontWeight: FontWeight.w800, color: pct >= 100 ? BrandColors.success : BrandColors.navy)),
              ]),
              const SizedBox(height: 4),
              ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: (pct / 100).clamp(0, 1).toDouble(), minHeight: 8, color: pct >= 100 ? BrandColors.success : BrandColors.electric, backgroundColor: const Color(0xFFE4E7EC))),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Every commission line of one employee in the period.
class _LogDialog extends ConsumerWidget {
  const _LogDialog({required this.userId, required this.name, required this.range});
  final String userId, name;
  final _Range range;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SupabaseClient db = ref.watch(supabaseProvider);
    return AlertDialog(
      title: Text(_t(context, 'سجل عمولات $name', 'Commission log · $name')),
      content: SizedBox(
        width: 560,
        height: 420,
        child: FutureBuilder(
          future: db.rpc('kpi_commission_log', params: {'p_user': userId, 'p_from': range.from.toUtc().toIso8601String(), 'p_to': range.to.toUtc().toIso8601String()}),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) return Text(_err(context, snap.error!));
            final rows = _l(snap.data);
            if (rows.isEmpty) return Center(child: Text(_t(context, 'مفيش عمولات في الفترة دي', 'No commissions in this period'), style: const TextStyle(color: BrandColors.gray)));
            final total = rows.fold<num>(0, (s, r) => s + (r['total_minor'] as num));
            return Column(children: [
              Align(alignment: AlignmentDirectional.centerStart, child: Text(_t(context, 'الإجمالي ${_money(context, total)}', 'Total ${_money(context, total)}'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              const Divider(),
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final left = (r['quantity'] as num) - (r['refunded_qty'] as num);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${r['product_name_ar']}  ×$left', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('#${r['sale_number']} · ${r['branch_name_ar']} · ${_stamp(r['created_at'])}'),
                      trailing: Text(_money(context, (r['total_minor'] as num)), style: const TextStyle(fontWeight: FontWeight.w800)),
                    );
                  },
                ),
              ),
            ]);
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إغلاق', 'Close')))],
    );
  }
}
