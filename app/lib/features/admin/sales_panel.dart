import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:share_plus/share_plus.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

final _salesPeriodProvider = StateProvider<String>((_) => 'day');
final _salesReportProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, period) => ref.watch(adminRepoProvider).salesReport(period));

/// Owner's sales page: today / last 7 days / this month, the change against the period before, and an Excel export.
class SalesPanel extends ConsumerStatefulWidget {
  const SalesPanel({super.key});
  @override
  ConsumerState<SalesPanel> createState() => _SalesPanelState();
}

class _SalesPanelState extends ConsumerState<SalesPanel> {
  bool _table = false;
  bool _exporting = false;
  int? _picked;

  String _label(BuildContext c, String period, String raw) {
    if (period == 'day') {
      final h = int.tryParse(raw) ?? 0;
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return c.isAr ? '$h12${h < 12 ? 'ص' : 'م'}' : '$h12${h < 12 ? 'a' : 'p'}';
    }
    final d = DateTime.tryParse(raw);
    if (d == null) return raw;
    return period == 'week' ? DateFormat.E(c.lang).format(d) : '${d.day}';
  }

  Future<void> _export(String period, String title) async {
    setState(() => _exporting = true);
    try {
      final data = await ref.read(adminRepoProvider).salesExport(period);
      final book = xl.Excel.createExcel();
      final summary = book['Sheet1'];
      book.rename('Sheet1', _t(context, 'ملخص', 'Summary'));
      final report = ref.read(_salesReportProvider(period)).valueOrNull;
      final total = ((report?['total_minor'] as num?) ?? 0) / 100;
      final prev = ((report?['prev_total_minor'] as num?) ?? 0) / 100;
      final orders = (data['orders'] as List).cast<Map>();
      summary.appendRow([xl.TextCellValue(title)]);
      summary.appendRow([xl.TextCellValue(_t(context, 'إجمالي المبيعات (ج.م)', 'Total sales (EGP)')), xl.DoubleCellValue(total.toDouble())]);
      summary.appendRow([xl.TextCellValue(_t(context, 'عدد الطلبات', 'Orders')), xl.IntCellValue(orders.length)]);
      summary.appendRow([
        xl.TextCellValue(_t(context, 'متوسط الطلب (ج.م)', 'Average order (EGP)')),
        xl.DoubleCellValue(orders.isEmpty ? 0 : (total / orders.length).toDouble()),
      ]);
      summary.appendRow([xl.TextCellValue(_t(context, 'الفترة اللي قبلها (ج.م)', 'Previous period (EGP)')), xl.DoubleCellValue(prev.toDouble())]);

      final os = book[_t(context, 'الطلبات', 'Orders')];
      os.appendRow([
        for (final h in [
          _t(context, 'رقم الطلب', 'Order'),
          _t(context, 'تاريخ التسليم', 'Delivered'),
          _t(context, 'العميل', 'Customer'),
          _t(context, 'الاستلام', 'Fulfillment'),
          _t(context, 'رسوم التوصيل (ج.م)', 'Delivery fee (EGP)'),
          _t(context, 'الإجمالي (ج.م)', 'Total (EGP)'),
        ])
          xl.TextCellValue(h)
      ]);
      for (final o in orders) {
        final at = DateTime.tryParse('${o['delivered_at']}')?.toLocal();
        os.appendRow([
          xl.TextCellValue('${o['reference']}'),
          xl.TextCellValue(at == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(at)),
          xl.TextCellValue('${o['customer_name']}'),
          xl.TextCellValue(o['fulfillment'] == 'pickup' ? _t(context, 'استلام من الفرع', 'Pickup') : _t(context, 'توصيل', 'Delivery')),
          xl.DoubleCellValue((((o['delivery_fee_minor'] as num?) ?? 0) / 100).toDouble()),
          xl.DoubleCellValue((((o['total_minor'] as num?) ?? 0) / 100).toDouble()),
        ]);
      }

      final ps = book[_t(context, 'المنتجات', 'Products')];
      ps.appendRow([for (final h in [_t(context, 'المنتج', 'Product'), _t(context, 'الكمية', 'Qty'), _t(context, 'إجمالي المبيعات (ج.م)', 'Sales (EGP)')]) xl.TextCellValue(h)]);
      for (final p in (data['products'] as List).cast<Map>()) {
        ps.appendRow([
          xl.TextCellValue('${p['name_ar']}'),
          xl.IntCellValue(((p['qty'] as num?) ?? 0).toInt()),
          xl.DoubleCellValue((((p['total_minor'] as num?) ?? 0) / 100).toDouble()),
        ]);
      }
      final bytes = book.save();
      if (bytes == null) throw StateError('empty file');
      final name = 'myhato-sales-$period-${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx';
      await Share.shareXFiles(
        [XFile.fromData(Uint8List.fromList(bytes), name: name, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
        fileNameOverrides: [name],
      );
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final period = ref.watch(_salesPeriodProvider);
    final data = ref.watch(_salesReportProvider(period));
    final lang = context.lang;
    final titles = {
      'day': _t(context, 'مبيعات النهارده', 'Sales today'),
      'week': _t(context, 'مبيعات آخر ٧ أيام', 'Sales, last 7 days'),
      'month': _t(context, 'مبيعات الشهر حتى النهارده', 'Sales this month'),
    };
    final prevNames = {
      'day': _t(context, 'امبارح', 'yesterday'),
      'week': _t(context, 'الأسبوع اللي قبله', 'the week before'),
      'month': _t(context, 'الشهر اللي فات', 'last month'),
    };
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(_salesReportProvider(period)),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'day', label: Text(_t(context, 'اليوم', 'Today'))),
            ButtonSegment(value: 'week', label: Text(_t(context, 'الأسبوع', 'Week'))),
            ButtonSegment(value: 'month', label: Text(_t(context, 'الشهر', 'Month'))),
          ],
          selected: {period},
          onSelectionChanged: (s) {
            setState(() => _picked = null);
            ref.read(_salesPeriodProvider.notifier).state = s.first;
          },
        ),
        const SizedBox(height: 14),
        data.when(
          loading: () => const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_salesReportProvider(period))),
          data: (r) {
            final total = (r['total_minor'] as num).toInt();
            final prev = (r['prev_total_minor'] as num).toInt();
            final n = (r['orders'] as num).toInt();
            final deliv = (r['delivery_orders'] as num).toInt();
            final pick = (r['pickup_orders'] as num).toInt();
            final series = (r['series'] as List).cast<Map>();
            final values = [for (final s in series) (s['total_minor'] as num).toInt()];
            final labels = [for (final s in series) _label(context, period, '${s['label']}')];
            final top = (r['top'] as List).cast<Map>();
            final pct = prev == 0 ? null : (total - prev) / prev * 100;
            final up = (pct ?? 0) >= 0;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(titles[period]!, style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(formatEgp(total, lang), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    if (pct != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: (up ? BrandColors.success : BrandColors.error).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: up ? BrandColors.success : BrandColors.error),
                          const SizedBox(width: 4),
                          Text(
                            _t(context, '${up ? 'أعلى' : 'أقل'} بنسبة ${pct.abs().round()}٪ عن ${prevNames[period]}',
                                '${pct.abs().round()}% ${up ? 'higher' : 'lower'} than ${prevNames[period]}'),
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: up ? BrandColors.success : BrandColors.error),
                          ),
                        ]),
                      )
                    else
                      Text(_t(context, 'مفيش مبيعات في الفترة اللي قبلها للمقارنة.', 'No sales in the period before to compare.'),
                          style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                    const SizedBox(height: 14),
                    if (_table)
                      Column(children: [
                        for (var i = 0; i < values.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(children: [Expanded(child: Text(labels[i])), Text(formatEgp(values[i], lang), style: const TextStyle(fontWeight: FontWeight.w700))]),
                          ),
                      ])
                    else
                      _BarChart(
                        values: values,
                        labels: labels,
                        picked: _picked,
                        format: (v) => formatEgp(v, lang),
                        onPick: (i) => setState(() => _picked = i == _picked ? null : i),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(onPressed: () => setState(() => _table = !_table), child: Text(_table ? _t(context, 'عرض كرسم', 'Show chart') : _t(context, 'عرض كجدول', 'Show table'))),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _Kpi(label: _t(context, 'عدد الطلبات', 'Orders'), value: '$n')),
                const SizedBox(width: 10),
                Expanded(child: _Kpi(label: _t(context, 'متوسط الطلب', 'Average order'), value: n == 0 ? '—' : formatEgp((total / n).round(), lang))),
              ]),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_t(context, 'التوصيل والاستلام', 'Delivery and pickup'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        height: 10,
                        child: Row(children: [
                          Expanded(flex: deliv == 0 && pick == 0 ? 1 : deliv, child: Container(color: BrandColors.electric)),
                          const SizedBox(width: 2),
                          Expanded(flex: deliv == 0 && pick == 0 ? 1 : pick, child: Container(color: BrandColors.navy)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('${_t(context, 'توصيل', 'Delivery')} $deliv', style: const TextStyle(fontSize: 13)),
                      Text('${_t(context, 'استلام من الفرع', 'Pickup')} $pick', style: const TextStyle(fontSize: 13)),
                    ]),
                  ]),
                ),
              ),
              if (top.isNotEmpty) ...[
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_t(context, 'الأكثر مبيعًا', 'Top sellers'), style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      for (final p in top)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text(context.isAr ? '${p['name_ar']}' : '${p['name_en']}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                              Text('${p['qty']} · ${formatEgp((p['total_minor'] as num).toInt(), lang)}', style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                            ]),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                minHeight: 7,
                                value: (p['total_minor'] as num) / ((top.first['total_minor'] as num).clamp(1, double.infinity)),
                                backgroundColor: BrandColors.border,
                                color: BrandColors.electric,
                              ),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: BrandColors.warning.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
                child: Text(
                  _t(context, '${r['pending_orders']} طلبات لسه ما اتسلّمتش بقيمة ${formatEgp((r['pending_minor'] as num).toInt(), lang)}. مش محسوبة في المبيعات لحد ما تتسلّم.',
                      '${r['pending_orders']} orders not delivered yet, worth ${formatEgp((r['pending_minor'] as num).toInt(), lang)}. They count as sales once delivered.'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: BrandColors.success),
                onPressed: _exporting ? null : () => _export(period, titles[period]!),
                icon: _exporting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.download_rounded),
                label: Text(_t(context, 'تصدير Excel', 'Export to Excel')),
              ),
              const SizedBox(height: 24),
            ]);
          },
        ),
      ]),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          ]),
        ),
      );
}

/// One-series bar chart: the highest bar is solid and the rest softer; tap any bar to read its value.
class _BarChart extends StatelessWidget {
  const _BarChart({required this.values, required this.labels, required this.picked, required this.format, required this.onPick});
  final List<int> values;
  final List<String> labels;
  final int? picked;
  final String Function(int) format;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox(height: 120);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final peak = values.reduce((a, b) => a > b ? a : b);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      const h = 170.0;
      final slot = w / values.length;
      return SizedBox(
        height: h + 34,
        child: Stack(children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final x = rtl ? w - d.localPosition.dx : d.localPosition.dx;
              final i = (x / slot).floor().clamp(0, values.length - 1);
              onPick(i);
            },
            child: CustomPaint(
              size: Size(w, h + 34),
              painter: _BarPainter(values, labels, peak, picked, rtl, BrandColors.electric, BrandColors.gray, BrandColors.border),
            ),
          ),
          if (picked != null)
            Positioned(
              top: 0,
              left: ((rtl ? w - (picked! + 0.5) * slot : (picked! + 0.5) * slot) - 60).clamp(0, w - 120).toDouble(),
              width: 120,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
                decoration: BoxDecoration(color: BrandColors.navy, borderRadius: BorderRadius.circular(10)),
                child: Text('${labels[picked!]} · ${format(values[picked!])}',
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
        ]),
      );
    });
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.values, this.labels, this.peak, this.picked, this.rtl, this.color, this.text, this.grid);
  final List<int> values;
  final List<String> labels;
  final int peak;
  final int? picked;
  final bool rtl;
  final Color color, text, grid;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 26.0, bottom = 22.0;
    final ph = size.height - top - bottom;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var g = 0; g <= 4; g++) {
      final y = top + ph - ph * g / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final slot = size.width / values.length;
    final bw = (slot * 0.56).clamp(5.0, 26.0);
    final maxAt = values.indexOf(peak);
    final scale = peak == 0 ? 1 : peak * 1.05;
    for (var i = 0; i < values.length; i++) {
      final cx = rtl ? size.width - (i + 0.5) * slot : (i + 0.5) * slot;
      final bh = (ph * values[i] / scale).clamp(values[i] == 0 ? 0.0 : 3.0, ph);
      final isMain = i == maxAt || i == picked;
      final p = Paint()..color = isMain ? color : color.withValues(alpha: 0.35);
      canvas.drawRRect(RRect.fromRectAndCorners(Rect.fromLTWH(cx - bw / 2, top + ph - bh, bw, bh), topLeft: const Radius.circular(4), topRight: const Radius.circular(4)), p);
      final every = values.length > 14 ? (i % 5 == 4 || i == 0) : true;
      if (every) {
        final tp = TextPainter(text: TextSpan(text: labels[i], style: TextStyle(color: text, fontSize: 10.5)), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset(cx - tp.width / 2, size.height - 16));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => old.values != values || old.picked != picked || old.color != color;
}
