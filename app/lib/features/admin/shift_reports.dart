import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'books_period.dart';
import 'pos_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));
String _when(Object? iso) => iso == null ? '—' : DateFormat('d/M/yyyy  HH:mm').format(DateTime.parse('$iso').toLocal());

final shiftReportsPeriodProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, Period>((ref, p) => ref.watch(posRepoProvider).booksReports(null, p.from, p.to));
final shiftReportsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, int>((ref, days) => ref.watch(posRepoProvider).shiftReports(days));

/// Closing reports (final, numbered) for the accountant, the manager and the owner. Visible only with the "shifts.reports" right,
/// which the owner gives or takes away.
class ShiftReportsList extends ConsumerWidget {
  const ShiftReportsList({super.key, required this.days, this.period, this.branchId});
  final int days;
  final Period? period; // when set, this exact period is shown instead of the last [days] days
  final String? branchId; // null = every branch

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return (period != null ? ref.watch(shiftReportsPeriodProvider(period!)) : ref.watch(shiftReportsProvider(days))).when(
          loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(_err(context, e)),
          data: (all) {
            final list = branchId == null ? all : all.where((r) => r['branch_id'] == branchId).toList();
            return list.isEmpty
              ? Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_t(context, 'مفيش تقارير إقفال في الفترة دي', 'No closing reports in this period'), style: const TextStyle(color: BrandColors.gray))))
              : Column(children: [
                  for (final r in list)
                    Builder(builder: (_) {
                      final v = (r['variance_minor'] as num).toInt();
                      final corr = (r['corrections_minor'] as num).toInt();
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.description_outlined, color: BrandColors.navy),
                          title: Text('${r['report_no']} · ${r['branch_name_ar']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            '${_t(context, 'الكاشير', 'Cashier')}: ${r['cashier_name']} · ${_t(context, 'قفلها', 'Closed by')}: ${r['closed_by_name']}\n'
                            '${_when(r['closed_at'])}${(r['closed_device'] ?? '') == '' ? '' : ' · ${r['closed_device']}'}',
                          ),
                          isThreeLine: true,
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(v == 0 ? _t(context, 'مظبوطة ✅', 'Matches ✅') : '${v < 0 ? _t(context, 'عجز', 'Short') : _t(context, 'زيادة', 'Over')} ${_money(context, v.abs())}',
                                style: TextStyle(fontWeight: FontWeight.w800, color: v == 0 ? BrandColors.success : BrandColors.error)),
                            if (corr != 0) Text(_t(context, 'فيها تصحيح', 'Corrected'), style: const TextStyle(fontSize: 11, color: BrandColors.warning)),
                          ]),
                          onTap: () => showDialog<void>(context: context, builder: (_) => ShiftReportDialog(shiftId: '${r['shift_id']}')).then((_) => ref.invalidate(shiftReportsProvider)),
                        ),
                      );
                    }),
                ]);
          },
        );
  }
}

/// One closing report in full: who closed it, when, where, on which device, the money, the invoices, and any later corrections.
class ShiftReportDialog extends ConsumerStatefulWidget {
  const ShiftReportDialog({super.key, required this.shiftId, this.justClosed = false});
  final String shiftId;
  final bool justClosed;
  @override
  ConsumerState<ShiftReportDialog> createState() => _ShiftReportDialogState();
}

class _ShiftReportDialogState extends ConsumerState<ShiftReportDialog> {
  late Future<Map<String, dynamic>> _future = ref.read(posRepoProvider).shiftReport(widget.shiftId);

  String _text(Map<String, dynamic> r) {
    String m(Object? x) => _money(context, x as num);
    final b = StringBuffer()
      ..writeln('${_t(context, 'تقرير إقفال وردية', 'Shift closing report')} ${r['report_no']}')
      ..writeln('${_t(context, 'الفرع', 'Branch')}: ${r['branch_name_ar']}')
      ..writeln('${_t(context, 'الكاشير', 'Cashier')}: ${r['cashier_name']}')
      ..writeln('${_t(context, 'قفلها', 'Closed by')}: ${r['closed_by_name']} (${r['closed_device'] ?? '—'})')
      ..writeln('${_t(context, 'من', 'From')} ${_when(r['opened_at'])} ${_t(context, 'إلى', 'to')} ${_when(r['closed_at'])}')
      ..writeln('---')
      ..writeln('${_t(context, 'العهدة', 'Opening')}: ${m(r['opening_minor'])}')
      ..writeln('${_t(context, 'المبيعات', 'Sales')} (${r['sales_count']}): ${m(r['sales_minor'])}')
      ..writeln('${_t(context, 'الخصومات', 'Discounts')}: ${m(r['discounts_minor'])}')
      ..writeln('${_t(context, 'المرتجعات', 'Refunds')}: ${m(r['refunds_minor'])}')
      ..writeln('${_t(context, 'المتوقع في الدرج', 'Expected')}: ${m(r['expected_minor'])}')
      ..writeln('${_t(context, 'الفعلي', 'Counted')}: ${m(r['counted_minor'])}')
      ..writeln('${_t(context, 'الفرق', 'Difference')}: ${m(r['variance_minor'])}');
    if ('${r['note'] ?? ''}'.isNotEmpty) b.writeln('${_t(context, 'السبب', 'Reason')}: ${r['note']}');
    for (final c in (r['corrections'] as List? ?? const []).cast<Map>()) {
      b.writeln('${_t(context, 'تصحيح', 'Correction')} ${m(c['amount_minor'])} — ${c['reason']} (${c['by']}, ${_when(c['at'])})');
    }
    return b.toString();
  }

  Future<void> _addCorrection() async {
    final done = await showDialog<bool>(context: context, builder: (_) => _CorrectionDialog(shiftId: widget.shiftId));
    if (done == true && mounted) {
      setState(() => _future = ref.read(posRepoProvider).shiftReport(widget.shiftId));
      ref.invalidate(shiftReportsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCorrect = ref.watch(staffContextProvider).valueOrNull?.permissions.contains('shifts.correct') ?? false;
    return AlertDialog(
      scrollable: true,
      icon: widget.justClosed ? const Icon(Icons.verified_rounded, color: BrandColors.success, size: 44) : null,
      title: Text(widget.justClosed ? _t(context, 'اتقفلت الوردية ✅', 'Shift closed ✅') : _t(context, 'تقرير إقفال الوردية', 'Shift closing report'), textAlign: TextAlign.center),
      content: SizedBox(
        width: 440,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (_, snap) {
            if (snap.hasError) return Text(_err(context, snap.error!));
            if (!snap.hasData) return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
            final r = snap.data!;
            final v = (r['variance_minor'] as num).toInt();
            final after = (r['variance_after_corrections_minor'] as num).toInt();
            final corrections = (r['corrections'] as List? ?? const []).cast<Map>();
            final invoices = (r['invoices'] as List? ?? const []).cast<Map>();
            final refunds = (r['refunds'] as List? ?? const []).cast<Map>();
            Widget row(String l, String val, {Color? c, bool b = false}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Flexible(child: Text(l, style: const TextStyle(color: BrandColors.gray))),
                    const SizedBox(width: 8),
                    Flexible(child: Text(val, textAlign: TextAlign.end, style: TextStyle(fontWeight: b ? FontWeight.w800 : FontWeight.w600, color: c))),
                  ]),
                );
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Text('${r['report_no']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: BrandColors.navy))),
              const SizedBox(height: 6),
              row(_t(context, 'الفرع', 'Branch'), '${r['branch_name_ar']}'),
              row(_t(context, 'الكاشير', 'Cashier'), '${r['cashier_name']}'),
              row(_t(context, 'اللي قفلها', 'Closed by'), '${r['closed_by_name']}', b: true),
              row(_t(context, 'الجهاز', 'Device'), '${r['closed_device'] ?? '—'}'),
              row(_t(context, 'فتحت', 'Opened'), _when(r['opened_at'])),
              row(_t(context, 'اتقفلت', 'Closed'), _when(r['closed_at'])),
              const Divider(),
              row(_t(context, 'العهدة أول الوردية', 'Opening cash'), _money(context, r['opening_minor'] as num)),
              row('${_t(context, 'المبيعات', 'Sales')} (${r['sales_count']})', _money(context, r['sales_minor'] as num)),
              row(_t(context, 'الخصومات', 'Discounts'), _money(context, r['discounts_minor'] as num)),
              row(_t(context, 'المرتجعات', 'Refunds'), '- ${_money(context, r['refunds_minor'] as num)}'),
              const Divider(),
              row(_t(context, 'المتوقع في الدرج', 'Expected in drawer'), _money(context, r['expected_minor'] as num), b: true),
              row(_t(context, 'اللي اتعدّ فعلاً', 'Counted'), _money(context, r['counted_minor'] as num), b: true),
              row(v == 0 ? _t(context, 'الدرج مظبوط ✅', 'Drawer matches ✅') : (v < 0 ? _t(context, 'عجز', 'Short') : _t(context, 'زيادة', 'Over')), v == 0 ? '' : _money(context, v.abs()),
                  c: v == 0 ? BrandColors.success : BrandColors.error, b: true),
              if ('${r['note'] ?? ''}'.isNotEmpty) row(_t(context, 'السبب', 'Reason'), '${r['note']}'),
              if (corrections.isNotEmpty) ...[
                const Divider(),
                Text(_t(context, 'التصحيحات (عمليات منفصلة، والوردية الأصلية زي ما هي)', 'Corrections (separate entries; the original shift is unchanged)'), style: const TextStyle(fontWeight: FontWeight.w700)),
                for (final c in corrections)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${_money(context, c['amount_minor'] as num)} — ${c['reason']}'),
                    subtitle: Text('${c['by']} · ${_when(c['at'])}'),
                  ),
                row(_t(context, 'الفرق بعد التصحيح', 'Difference after corrections'), after == 0 ? _t(context, 'صفر ✅', 'Zero ✅') : _money(context, after),
                    c: after == 0 ? BrandColors.success : BrandColors.error, b: true),
              ],
              if (invoices.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('${_t(context, 'الفواتير', 'Invoices')} (${invoices.length})'),
                  children: [
                    for (final i in invoices)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${i['number']}'),
                        subtitle: (i['refunded_minor'] as num) > 0 ? Text('${_t(context, 'اترجّع', 'Refunded')} ${_money(context, i['refunded_minor'] as num)}') : null,
                        trailing: Text(_money(context, i['total_minor'] as num)),
                      ),
                  ],
                ),
              if (refunds.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('${_t(context, 'المرتجعات', 'Refunds')} (${refunds.length})'),
                  children: [
                    for (final x in refunds)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${x['sale_number']} — ${x['reason']}'),
                        trailing: Text(_money(context, x['amount_minor'] as num)),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(_t(context, 'نسخ التقرير', 'Copy report')),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _text(r)));
                    if (context.mounted) showSnack(context, _t(context, 'اتنسخ', 'Copied'));
                  },
                ),
                if (canCorrect && !widget.justClosed)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_note_rounded, size: 18),
                    label: Text(_t(context, 'تسجيل تصحيح', 'Add a correction')),
                    onPressed: _addCorrection,
                  ),
              ]),
            ]);
          },
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'Done')))],
    );
  }
}

class _CorrectionDialog extends ConsumerStatefulWidget {
  const _CorrectionDialog({required this.shiftId});
  final String shiftId;
  @override
  ConsumerState<_CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends ConsumerState<_CorrectionDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  /// "+50" / "-50" / "50.5" in pounds -> signed piasters.
  int? _parse() {
    final raw = _amount.text.trim();
    if (raw.isEmpty) return null;
    final neg = raw.startsWith('-');
    final m = parseEgpToMinor(raw.replaceFirst(RegExp(r'^[+-]'), ''));
    if (m == null || m == 0) return null;
    return neg ? -m : m;
  }

  Future<void> _save() async {
    final a = _parse();
    if (a == null || _reason.text.trim().length < 5) {
      showSnack(context, _t(context, 'اكتب المبلغ (موجب أو سالب) وسبب واضح', 'Type the amount (plus or minus) and a clear reason'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(posRepoProvider).addCorrection(widget.shiftId, a, _reason.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t(context, 'تسجيل تصحيح', 'Add a correction')),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_t(context, 'التصحيح عملية منفصلة بتتسجّل باسمك. الوردية والتقرير الأصلي مبيتغيّروش.', 'A correction is a separate entry recorded in your name. The shift and its report never change.'),
                style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
            const SizedBox(height: 10),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(labelText: _t(context, 'المبلغ (ج.م) — موجب يزوّد، وسالب ينقّص', 'Amount (EGP) — plus adds, minus removes')),
            ),
            const SizedBox(height: 8),
            TextField(controller: _reason, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'السبب (مطلوب)', 'Reason (required)'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t(context, 'إلغاء', 'Cancel'))),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? '…' : _t(context, 'سجّل التصحيح', 'Save correction'))),
        ],
      );
}
