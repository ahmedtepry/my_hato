// Profit (permission profit.view): selling price minus the cost frozen on every sale line, per invoice and for any period.
// Counter sales and delivered online orders are both counted. A sale whose lines are not all costed is listed apart, never guessed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import 'pos_repository.dart' show posErrorText;

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

const _gain = BrandColors.success;
const _loss = BrandColors.error;

enum _Preset { today, week, month, lastMonth, custom }

class _Range {
  const _Range(this.from, this.to);
  final DateTime from, to; // [from, to)
}

class ProfitPanel extends ConsumerStatefulWidget {
  const ProfitPanel({super.key});
  @override
  ConsumerState<ProfitPanel> createState() => _ProfitPanelState();
}

class _ProfitPanelState extends ConsumerState<ProfitPanel> {
  _Preset _preset = _Preset.month;
  _Range _range = _rangeOf(_Preset.month);
  Future<Map<String, dynamic>>? _future;

  static _Range _rangeOf(_Preset p) {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    switch (p) {
      case _Preset.today:
        return _Range(today, today.add(const Duration(days: 1)));
      case _Preset.week:
        return _Range(today.subtract(Duration(days: (today.weekday + 1) % 7)), today.add(const Duration(days: 1)));
      case _Preset.month:
      case _Preset.custom:
        return _Range(DateTime(n.year, n.month), DateTime(n.year, n.month + 1));
      case _Preset.lastMonth:
        return _Range(DateTime(n.year, n.month - 1), DateTime(n.year, n.month));
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(supabaseProvider).rpc('profit_report', params: {
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
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: Text(_t(context, 'الأرباح', 'Profit'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
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
          return _Body(data: snap.data!);
        },
      ),
    ]);
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final tot = _m(data['totals']);
    final profit = (tot['profit_minor'] as num).toInt();
    final revenue = (tot['revenue_minor'] as num).toInt();
    final cost = (tot['cost_minor'] as num).toInt();
    final counted = (tot['sales_counted'] as num).toInt();
    final uncosted = (tot['sales_uncosted'] as num).toInt();
    final noCost = (data['products_without_cost'] as num?)?.toInt() ?? 0;
    final margin = revenue > 0 ? profit * 100 / revenue : 0.0;
    final color = profit >= 0 ? _gain : _loss;
    final sales = _l(data['sales']);
    final top = _l(data['top']);
    final worst = _l(data['worst']);
    final series = _l(data['series']);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        color: color.withValues(alpha: .08),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(profit >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded, color: color),
              const SizedBox(width: 8),
              Text(counted == 0 ? _t(context, 'مفيش مبيعات محسوب لها تكلفة في الفترة دي', 'No costed sales in this period') : (profit >= 0 ? _t(context, 'إنت كسبان', 'You are making money') : _t(context, 'إنت خسران', 'You are losing money')),
                  style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            ]),
            const SizedBox(height: 8),
            Text(_t(context, 'صافي الربح', 'Net profit'), style: const TextStyle(color: BrandColors.gray)),
            Text(_money(context, profit), style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 10),
            Wrap(spacing: 22, runSpacing: 10, children: [
              _Stat(_t(context, 'المبيعات (محسوبة)', 'Sales (costed)'), _money(context, revenue)),
              _Stat(_t(context, 'التكلفة', 'Cost'), _money(context, cost)),
              _Stat(_t(context, 'الهامش', 'Margin'), '${margin.toStringAsFixed(1)}%'),
              _Stat(_t(context, 'عدد الفواتير', 'Invoices'), '$counted'),
              _Stat(_t(context, 'فواتير بخسارة', 'Losing invoices'), '${tot['losing_sales']}', color: (tot['losing_sales'] as num) > 0 ? _loss : null),
            ]),
            const SizedBox(height: 10),
            Text('${_t(context, 'من الكاشير', 'Counter')}: ${_money(context, tot['pos_profit_minor'] as num)}   •   ${_t(context, 'من الأونلاين', 'Online')}: ${_money(context, tot['online_profit_minor'] as num)}',
                style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
          ]),
        ),
      ),
      if (uncosted > 0 || noCost > 0)
        Card(
          color: BrandColors.warning.withValues(alpha: .12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline_rounded, color: BrandColors.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  [
                    if (uncosted > 0)
                      _t(context, '$uncosted فاتورة (مبيعاتها ${_money(context, tot['revenue_uncosted_minor'] as num)}) فيها صنف من غير تكلفة، فمش داخلة في الربح.', '$uncosted invoices (sales ${_money(context, tot['revenue_uncosted_minor'] as num)}) have an item with no cost and are left out of the profit.'),
                    if (noCost > 0) _t(context, '$noCost منتج لسه من غير سعر تكلفة. املأهم من «المنتجات» أو استورد شيت التكلفة، والفواتير القديمة بتتحسب تلقائي.', '$noCost products still have no cost. Fill them in Products or import the cost sheet; old invoices are filled automatically.'),
                  ].join('\n'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ]),
          ),
        ),
      if (series.length > 1) ...[
        const SizedBox(height: 6),
        _Section(_t(context, 'الربح كل يوم', 'Profit per day')),
        _DayBars(series: series),
      ],
      if (worst.isNotEmpty) ...[
        const SizedBox(height: 14),
        _Section(_t(context, 'منتجات بتخسّرك', 'Products losing money')),
        for (final r in worst) _ProductRow(r: r),
      ],
      if (top.isNotEmpty) ...[
        const SizedBox(height: 14),
        _Section(_t(context, 'أكتر المنتجات ربحًا', 'Most profitable products')),
        for (final r in top) _ProductRow(r: r),
      ],
      const SizedBox(height: 14),
      _Section(_t(context, 'ربح كل فاتورة', 'Profit per invoice')),
      if (sales.isEmpty)
        Padding(padding: const EdgeInsets.all(30), child: Center(child: Text(_t(context, 'مفيش مبيعات في الفترة دي', 'No sales in this period'), style: const TextStyle(color: BrandColors.gray))))
      else
        for (final s in sales) _SaleRow(s: s),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)));
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.color});
  final String label, value;
  final Color? color;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
        Text(value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
      ]);
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.r});
  final Map<String, dynamic> r;
  @override
  Widget build(BuildContext context) {
    final p = (r['profit_minor'] as num).toInt();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${_t(context, 'كمية', 'Qty')} ${r['qty']}  •  ${_t(context, 'مبيعات', 'Sales')} ${_money(context, r['revenue_minor'] as num)}  •  ${_t(context, 'تكلفة', 'Cost')} ${_money(context, r['cost_minor'] as num)}',
                  style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            ]),
          ),
          Text('${p >= 0 ? '+' : ''}${_money(context, p)}', style: TextStyle(fontWeight: FontWeight.w900, color: p >= 0 ? _gain : _loss)),
        ]),
      ),
    );
  }
}

class _SaleRow extends StatelessWidget {
  const _SaleRow({required this.s});
  final Map<String, dynamic> s;
  @override
  Widget build(BuildContext context) {
    final profit = (s['profit_minor'] as num?)?.toInt();
    final missing = (s['missing_lines'] as num?)?.toInt() ?? 0;
    final online = s['kind'] == 'online';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Directionality(textDirection: TextDirection.ltr, child: Text('${s['ref']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                  decoration: BoxDecoration(color: BrandColors.border.withValues(alpha: .6), borderRadius: BorderRadius.circular(10)),
                  child: Text(online ? _t(context, 'أونلاين', 'Online') : _t(context, 'كاشير', 'Counter'), style: const TextStyle(fontSize: 11)),
                ),
              ]),
              Text('${_stamp(s['at'])}  •  ${s['who'] ?? ''}', style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
              Text(profit == null
                  ? _t(context, 'مبيعات ${_money(context, s['revenue_minor'] as num)}', 'Sales ${_money(context, s['revenue_minor'] as num)}')
                  : '${_t(context, 'مبيعات', 'Sales')} ${_money(context, s['revenue_minor'] as num)}  −  ${_t(context, 'تكلفة', 'Cost')} ${_money(context, s['cost_minor'] as num)}',
                  style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            ]),
          ),
          if (profit == null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: BrandColors.warning.withValues(alpha: .15), borderRadius: BorderRadius.circular(10)),
              child: Text(_t(context, '$missing صنف من غير تكلفة', '$missing items without cost'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            )
          else
            Text('${profit >= 0 ? '+' : ''}${_money(context, profit)}', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: profit >= 0 ? _gain : _loss)),
        ]),
      ),
    );
  }
}

/// A bar for each day: green up for profit, red down for a loss, to one scale.
class _DayBars extends StatelessWidget {
  const _DayBars({required this.series});
  final List<Map<String, dynamic>> series;
  @override
  Widget build(BuildContext context) {
    final vals = [for (final s in series) (s['profit_minor'] as num).toDouble()];
    final maxAbs = vals.fold<double>(1, (a, v) => v.abs() > a ? v.abs() : a);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
        child: Column(children: [
          SizedBox(
            height: 120,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final v in vals)
                Expanded(
                  child: Tooltip(
                    message: _money(context, v),
                    child: Column(children: [
                      Expanded(child: Align(alignment: Alignment.bottomCenter, child: FractionallySizedBox(heightFactor: v > 0 ? v / maxAbs : 0, child: Container(margin: const EdgeInsets.symmetric(horizontal: 1.5), decoration: BoxDecoration(color: _gain, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))))))),
                      Container(height: 1, color: BrandColors.border),
                      Expanded(child: Align(alignment: Alignment.topCenter, child: FractionallySizedBox(heightFactor: v < 0 ? -v / maxAbs : 0, child: Container(margin: const EdgeInsets.symmetric(horizontal: 1.5), decoration: BoxDecoration(color: _loss, borderRadius: const BorderRadius.vertical(bottom: Radius.circular(3))))))),
                    ]),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${series.first['day']}'.substring(5), style: const TextStyle(color: BrandColors.gray, fontSize: 11)),
            Text('${series.last['day']}'.substring(5), style: const TextStyle(color: BrandColors.gray, fontSize: 11)),
          ]),
        ]),
      ),
    );
  }
}
