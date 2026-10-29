// "المساعد الآلي": the automatic accountant and the customer-service robot.
// Each mode is switched on/off by whoever holds its permission (assistant.accountant / assistant.support), turning on asks "are you sure".
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/save_file.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
List<Map<String, dynamic>> _maps(Object? v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

final _assistantProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async =>
    Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('assistant_state') as Map));

String _err(BuildContext c, Object e) {
  final t = '$e';
  if (t.contains('MODE_OFF')) return _t(c, 'الوضع ده مقفول، شغّله الأول.', 'This mode is off, switch it on first.');
  if (t.contains('FORBIDDEN')) return _t(c, 'مش مسموحلك.', 'Not allowed.');
  return friendlyError(c, e);
}

class AssistantPanel extends ConsumerStatefulWidget {
  const AssistantPanel({super.key});
  @override
  ConsumerState<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends ConsumerState<AssistantPanel> {
  bool _busy = false;
  late int _year;
  late int _month;
  String? _runResult;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  Future<void> _switch(String key, bool on, String titleAr, String titleEn, String whatAr, String whatEn) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(_t(d, 'متأكد؟', 'Are you sure?')),
          content: Text(_t(d, 'هتشغّل «$titleAr». $whatAr', 'You are turning on "$titleEn". $whatEn')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'لأ', 'No'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'أيوه، شغّله', 'Yes, turn on'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('assistant_set', params: {'p_key': key, 'p_enabled': on, 'p_confirm': true});
      ref.invalidate(_assistantProvider);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runRobot() async {
    setState(() => _busy = true);
    try {
      final n = await ref.read(supabaseProvider).rpc('assistant_run_robot');
      ref.invalidate(_assistantProvider);
      if (mounted) setState(() => _runResult = _t(context, 'الروبوت خلّص وعمل $n حاجة جديدة.', 'The robot finished: $n new actions.'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report() async {
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('assistant_month_report', params: {'p_year': _year, 'p_month': _month}) as Map);
      final bytes = _buildZip(r);
      if (!mounted) return;
      await deliverFile(context, bytes, 'MyHato-$_year-${_month.toString().padLeft(2, '0')}.zip', 'application/zip');
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_assistantProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: _err(context, e), onRetry: () => ref.invalidate(_assistantProvider)),
      data: (s) {
        final acc = s['accountant'] is Map ? Map<String, dynamic>.from(s['accountant'] as Map) : null;
        final sup = s['support'] is Map ? Map<String, dynamic>.from(s['support'] as Map) : null;
        final months = [
          for (var i = 0; i < 12; i++) DateTime(DateTime.now().year, DateTime.now().month - i, 1),
        ];
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (acc == null && sup == null) Padding(padding: const EdgeInsets.all(24), child: Text(_t(context, 'مفيش وضع متاح لحسابك.', 'No mode is available for your account.'))),
          if (acc != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const CircleAvatar(backgroundColor: Color(0x1A6938EF), child: Icon(Icons.calculate_rounded, color: Color(0xFF6938EF))),
                    title: Text(_t(context, 'المحاسب الآلي', 'Automatic accountant'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(_t(context, 'بيجمع المبيعات والعمولات والورديات والمخزن في ملفات إكسل مترتبة', 'Collects sales, commissions, shifts and stock into sorted Excel files')),
                    value: acc['enabled'] == true,
                    onChanged: _busy
                        ? null
                        : (v) => _switch('accountant', v, 'المحاسب الآلي', 'the automatic accountant', 'هيقدر يطلّع تقارير الشهر بالمبيعات والأرباح والعمولات لكل فرع وموظف.',
                            'It will be able to produce monthly reports with sales, profit and commissions per branch and employee.'),
                  ),
                  if (acc['enabled'] == true) ...[
                    const Divider(),
                    Text(_t(context, 'تقرير شهر', 'Monthly report'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: months.indexWhere((d) => d.year == _year && d.month == _month).clamp(0, 11),
                      decoration: InputDecoration(labelText: _t(context, 'الشهر', 'Month'), border: const OutlineInputBorder(), isDense: true),
                      items: [for (var i = 0; i < months.length; i++) DropdownMenuItem(value: i, child: Text('${months[i].year}-${months[i].month.toString().padLeft(2, '0')}'))],
                      onChanged: (i) => setState(() {
                        _year = months[i ?? 0].year;
                        _month = months[i ?? 0].month;
                      }),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _busy ? null : _report,
                      icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.folder_zip_rounded),
                      label: Text(_t(context, 'نزّل ملفات الشهر (مضغوطة ومترتبة)', 'Download the month (sorted zip)')),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _t(context, 'جواها: ملخص الشهر · ملف لكل فرع · ملف لكل موظف بعمولاته وتارجته · المخزن والاستلام والجرد · الطلبات الأونلاين.',
                          'Inside: month summary · a file per branch · a file per employee with commission and target · stock, receipts and stocktakes · online orders.'),
                      style: const TextStyle(color: BrandColors.gray, fontSize: 13),
                    ),
                  ],
                ]),
              ),
            ),
          if (sup != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const CircleAvatar(backgroundColor: Color(0x1A0E9384), child: Icon(Icons.smart_toy_rounded, color: Color(0xFF0E9384))),
                    title: Text(_t(context, 'روبوت خدمة العملاء', 'Customer-service robot'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(_t(context, 'بيتابع الطلبات والصيانة والمخزن كل ربع ساعة وينبّه الفريق أو العميل', 'Follows orders, repairs and stock every 15 minutes and alerts the team or the customer')),
                    value: sup['enabled'] == true,
                    onChanged: _busy
                        ? null
                        : (v) => _switch('support', v, 'روبوت خدمة العملاء', 'the customer-service robot', 'هيبعت تنبيهات للفريق وتذكيرات للعملاء تلقائيًا.',
                            'It will send alerts to the team and reminders to customers automatically.'),
                  ),
                  const Divider(),
                  for (final line in [
                    ('طلب أونلاين مستني التأكيد أكتر من ساعة ← ينبّه الفريق', 'An online order unconfirmed for an hour → alerts the team'),
                    ('دفع أونلاين ما اكتملش يوم ← يفكّر العميل', 'Unfinished online payment for a day → reminds the customer'),
                    ('طلب جاهز للاستلام من يومين ← يفكّر العميل', 'Order ready for 2 days → reminds the customer'),
                    ('عرض صيانة من يوم من غير رد ← يفكّر العميل، وبعد 3 أيام ينبّه الفريق', 'Repair quote unanswered for a day → reminds the customer, after 3 days alerts the team'),
                    ('جهاز جاهز من 3 أيام ← يفكّر العميل', 'Device ready for 3 days → reminds the customer'),
                    ('منتج فاضل منه 3 أو أقل ← ينبّه مسؤولي المخزن', 'A product with 3 or fewer left → alerts the stock managers'),
                  ])
                    Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('• ${_t(context, line.$1, line.$2)}', style: const TextStyle(fontSize: 13))),
                  if (sup['enabled'] == true) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _runRobot,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(_t(context, 'شغّل الروبوت دلوقتي', 'Run the robot now')),
                    ),
                    if (_runResult != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_runResult!, style: const TextStyle(color: BrandColors.success))),
                    const SizedBox(height: 10),
                    Text(_t(context, 'آخر اللي عمله', 'Latest actions'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (_maps(sup['log']).isEmpty) Text(_t(context, 'لسه ما عملش حاجة.', 'Nothing yet.'), style: const TextStyle(color: BrandColors.gray)),
                    for (final e in _maps(sup['log']))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.bolt_rounded, size: 18),
                        title: Text('${e['text']}'),
                        subtitle: Text('${DateTime.tryParse('${e['at']}')?.toLocal().toString().substring(0, 16) ?? ''}'),
                      ),
                  ],
                ]),
              ),
            ),
        ]);
      },
    );
  }
}

// ------------------------------------------------------------------------------------------ the zip
double _m(Object? minor) => (((minor as num?) ?? 0) / 100).toDouble();
String _day(Object? iso) {
  final d = DateTime.tryParse('$iso')?.toLocal();
  return d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

CellValue _c(Object? v) {
  if (v == null) return TextCellValue('');
  if (v is int) return IntCellValue(v);
  if (v is num) return DoubleCellValue(v.toDouble());
  return TextCellValue('$v');
}

/// One workbook: {sheet name: rows} (the first row of each is the header).
Uint8List _book(Map<String, List<List<Object?>>> sheets) {
  final x = Excel.createExcel();
  var first = true;
  for (final e in sheets.entries) {
    final name = e.key.length > 31 ? e.key.substring(0, 31) : e.key;
    if (first) {
      x.rename('Sheet1', name);
      first = false;
    }
    final s = x[name];
    for (final r in e.value) {
      s.appendRow([for (final v in r) _c(v)]);
    }
  }
  return Uint8List.fromList(x.save()!);
}

String _safe(Object? name) {
  final s = '$name'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').trim();
  return s.isEmpty ? 'بدون اسم' : s;
}

String _roleAr(Object? r) => const {
      'owner': 'مالك', 'manager': 'مدير', 'accountant': 'محاسب', 'cashier': 'كاشير', 'sales': 'مبيعات', 'technician': 'فني صيانة', 'support': 'خدمة عملاء',
    }['$r'] ?? '$r';

Uint8List _buildZip(Map<String, dynamic> r) {
  final tag = '${r['year']}-${(r['month'] as int).toString().padLeft(2, '0')}';
  final root = 'MyHato-$tag';
  final branches = _maps(r['branches']);
  final employees = _maps(r['employees']);
  final shifts = _maps(r['shifts']);
  final orders = _maps(r['orders']);
  final stock = _maps(r['stock']);
  final receipts = _maps(r['receipts']);
  final stocktakes = _maps(r['stocktakes']);
  final archive = Archive();
  void add(String path, Uint8List bytes) => archive.addFile(ArchiveFile('$root/$path', bytes.length, bytes));

  num sum(List<Map<String, dynamic>> l, String k) => l.fold<num>(0, (a, b) => a + ((b[k] as num?) ?? 0));
  final branchHead = ['الفرع', 'عدد الفواتير', 'المبيعات', 'الخصومات', 'المرتجعات', 'الصافي', 'التكلفة', 'الربح', 'العمولات'];
  List<Object?> branchRow(Map<String, dynamic> b) =>
      [b['name'], b['sales_count'], _m(b['gross_minor']), _m(b['discount_minor']), _m(b['refunds_minor']), _m(b['net_minor']), _m(b['cost_minor']), _m(b['profit_minor']), _m(b['commission_minor'])];
  final empHead = ['الموظف', 'الدور', 'عدد الفواتير', 'المبيعات', 'المرتجعات', 'الصافي', 'الخصومات', 'العمولة', 'عدد الورديات', 'التارجت', 'نسبة التارجت %'];
  List<Object?> empRow(Map<String, dynamic> e) {
    final target = (e['target_minor'] as num?) ?? 0;
    final net = (e['net_minor'] as num?) ?? 0;
    return [e['name'], _roleAr(e['role']), e['sales_count'], _m(e['gross_minor']), _m(e['refunds_minor']), _m(e['net_minor']), _m(e['discount_minor']), _m(e['commission_minor']), e['shifts_count'],
      target > 0 ? _m(target) : '', target > 0 ? (net / target * 100).round() : ''];
  }

  // 1) the month at a glance
  add('00-ملخص-الشهر.xlsx', _book({
    'ملخص': [
      ['البند', 'القيمة'],
      ['الشهر', tag],
      ['إجمالي مبيعات الكاشير', _m(sum(branches, 'gross_minor'))],
      ['المرتجعات', _m(sum(branches, 'refunds_minor'))],
      ['الصافي', _m(sum(branches, 'net_minor'))],
      ['التكلفة', _m(sum(branches, 'cost_minor'))],
      ['الربح', _m(sum(branches, 'profit_minor'))],
      ['إجمالي العمولات', _m(sum(branches, 'commission_minor'))],
      ['عدد طلبات الأونلاين', orders.length],
      ['إجمالي الأونلاين (من غير الملغي)', _m(orders.where((o) => o['status'] != 'cancelled').fold<num>(0, (a, o) => a + ((o['total_minor'] as num?) ?? 0)))],
    ],
    'الفروع': [branchHead, for (final b in branches) branchRow(b)],
    'الموظفين': [empHead, for (final e in employees) empRow(e)],
  }));

  // 2) a file per branch
  for (final b in branches) {
    final name = '${b['name']}';
    add('الفروع/${_safe(name)}.xlsx', _book({
      'ملخص': [branchHead, branchRow(b)],
      'الورديات': [
        ['الكاشير', 'فتح', 'قفل', 'عهدة الفتح', 'المتوقع', 'المعدود', 'الفرق', 'الحالة'],
        for (final s in shifts.where((s) => s['branch'] == name))
          [s['cashier'], _day(s['opened_at']), _day(s['closed_at']), _m(s['opening_minor']), _m(s['expected_minor']), _m(s['counted_minor']), _m(s['variance_minor']), s['status']],
      ],
    }));
  }

  // 3) a file per employee, with every commission line
  for (final e in employees) {
    add('الموظفين/${_safe(e['name'])}.xlsx', _book({
      'ملخص': [empHead, empRow(e)],
      'العمولات': [
        ['رقم الفاتورة', 'التاريخ', 'الفرع', 'المنتج', 'الكمية', 'المرتجع', 'عمولة القطعة', 'إجمالي العمولة'],
        for (final l in _maps(e['lines'])) [l['sale_number'], _day(l['at']), l['branch'], l['product'], l['quantity'], l['refunded_qty'], _m(l['unit_minor']), _m(l['total_minor'])],
      ],
    }));
  }

  // 4) stock
  add('المخزن.xlsx', _book({
    'الأرصدة': [
      ['الكود', 'المنتج', 'إجمالي المتجر', 'الوير هاوس (غير موزّع)', 'التوزيع على الفروع'],
      for (final p in stock) [p['sku'], p['name'], p['total'], p['unallocated'], _maps(p['branches']).map((b) => '${b['branch']}: ${b['qty']}').join('، ')],
    ],
    'استلام البضاعة': [
      ['الرقم', 'التاريخ', 'المورد', 'الفرع', 'سجّلها', 'الأصناف'],
      for (final x in receipts) [x['number'], _day(x['at']), x['supplier'], x['branch'], x['by'], _maps(x['items']).map((i) => '${i['name']} × ${i['qty']}').join('، ')],
    ],
    'الجرد': [
      ['الرقم', 'التاريخ', 'الفرع', 'اللي جرد', 'صافي الفرق', 'الفروقات'],
      for (final x in stocktakes) [x['number'], _day(x['at']), x['branch'], x['by'], x['diff_pieces'], _maps(x['differences']).map((i) => '${i['name']}: ${i['expected']}→${i['counted']}').join('، ')],
    ],
  }));

  // 5) online orders
  add('الأونلاين.xlsx', _book({
    'الطلبات': [
      ['رقم الطلب', 'التاريخ', 'الحالة', 'طريقة الدفع', 'حالة الدفع', 'الاستلام', 'الإجمالي'],
      for (final o in orders) [o['reference'], _day(o['at']), o['status'], o['payment_method'], o['payment_status'], o['fulfillment'], _m(o['total_minor'])],
    ],
  }));

  final out = ZipEncoder().encode(archive);
  return Uint8List.fromList(out!);
}
