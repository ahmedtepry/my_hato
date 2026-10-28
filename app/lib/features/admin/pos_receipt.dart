import 'dart:async';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/appearance.dart';
import '../../core/save_file.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'documents.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

// Receipt printing for the cashier. Settings live on this computer only (the printer and paper width differ per till).
const _kPrinter = 'pos_printer_name';
const _kWidth = 'pos_receipt_mm';
const _kAuto = 'pos_auto_print';
const _kStyle = 'pos_receipt_style';

Future<bool> receiptAutoPrintOn() async {
  try {
    final p = await SharedPreferences.getInstance();
    return (p.getBool(_kAuto) ?? false) && (p.getString(_kPrinter) ?? '').isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Prints the receipt: straight to the printer chosen in the settings, or through the system print window.
Future<void> printReceipt(BuildContext context, Map<String, dynamic> sale) async {
  try {
    final p = await SharedPreferences.getInstance();
    final mm = p.getInt(_kWidth) ?? 80;
    final name = p.getString(_kPrinter) ?? '';
    final bytes = await posReceiptPdf(sale, widthMm: mm, style: p.getString(_kStyle) ?? 'classic');
    final format = posReceiptFormat(mm);
    final job = 'receipt-${sale['number']}';
    if (name.isNotEmpty) {
      final match = (await Printing.listPrinters()).where((x) => x.name == name);
      if (match.isNotEmpty) {
        final ok = await Printing.directPrintPdf(printer: match.first, onLayout: (_) async => bytes, name: job, format: format);
        if (ok) return;
      }
    }
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: job, format: format);
  } catch (e) {
    if (context.mounted) showSnack(context, _t(context, 'مقدرتش أطبع: $e', 'Could not print: $e'), error: true);
  }
}

Future<void> shareReceiptPdf(BuildContext context, Map<String, dynamic> sale) async {
  try {
    final p = await SharedPreferences.getInstance();
    final bytes = await posReceiptPdf(sale, widthMm: p.getInt(_kWidth) ?? 80, style: p.getString(_kStyle) ?? 'classic');
    if (context.mounted) await deliverFile(context, bytes, 'receipt-${sale['number']}.pdf', 'application/pdf');
  } catch (e) {
    if (context.mounted) showSnack(context, '$e', error: true);
  }
}

/// Asks for the customer's number and opens WhatsApp with the receipt text ready to send.
Future<void> sendReceiptWhatsApp(BuildContext context, String text) async {
  final ctl = TextEditingController();
  final phone = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(_t(ctx, 'ابعت الإيصال على واتساب', 'Send the receipt on WhatsApp')),
      content: TextField(
        controller: ctl,
        autofocus: true,
        keyboardType: TextInputType.phone,
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(labelText: _t(ctx, 'رقم موبايل العميل', 'Customer mobile'), hintText: '01xxxxxxxxx'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t(ctx, 'إلغاء', 'Cancel'))),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366)),
          icon: const Icon(Icons.chat_rounded, size: 18),
          label: Text(_t(ctx, 'افتح واتساب', 'Open WhatsApp')),
          onPressed: () => Navigator.pop(ctx, ctl.text),
        ),
      ],
    ),
  );
  ctl.dispose();
  if (phone == null || !context.mounted) return;
  final digits = waDigits(phone);
  if (digits.length < 11) {
    showSnack(context, _t(context, 'الرقم مش صحيح', 'That number is not valid'), error: true);
    return;
  }
  final ok = await launchUrl(Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showSnack(context, _t(context, 'مقدرتش أفتح واتساب', 'Could not open WhatsApp'), error: true);
}

/// Print / WhatsApp / PDF / settings, for a finished sale (after the sale and when looking up an old invoice).
class ReceiptButtons extends StatelessWidget {
  const ReceiptButtons({super.key, required this.sale, required this.text});
  final Map<String, dynamic> sale;
  final String text;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          icon: const Icon(Icons.print_rounded, size: 18),
          label: Text(_t(context, 'طباعة', 'Print')),
          onPressed: () => printReceipt(context, sale),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366)),
          icon: const Icon(Icons.chat_rounded, size: 18),
          label: Text(_t(context, 'واتساب', 'WhatsApp')),
          onPressed: () => sendReceiptWhatsApp(context, text),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
          label: const Text('PDF'),
          onPressed: () => shareReceiptPdf(context, sale),
        ),
        IconButton(
          tooltip: _t(context, 'إعدادات الطباعة', 'Print settings'),
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => showReceiptSettings(context),
        ),
      ]);
}

Future<void> showReceiptSettings(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _ReceiptSettings());

class _ReceiptSettings extends StatefulWidget {
  const _ReceiptSettings();
  @override
  State<_ReceiptSettings> createState() => _ReceiptSettingsState();
}

class _ReceiptSettingsState extends State<_ReceiptSettings> {
  SharedPreferences? _p;
  List<String> _printers = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    var names = <String>[];
    try {
      names = [for (final x in await Printing.listPrinters()) x.name];
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _p = p;
      _printers = names;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final printer = p?.getString(_kPrinter) ?? '';
    final mm = p?.getInt(_kWidth) ?? 80;
    return AlertDialog(
      title: Text(_t(context, 'إعدادات طباعة الإيصال', 'Receipt printing')),
      content: SizedBox(
        width: 380,
        child: _loading || p == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_t(context, 'الطابعة', 'Printer'), style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: _printers.contains(printer) ? printer : '',
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(value: '', child: Text(_t(context, 'اسأل في كل مرة (نافذة الطباعة)', 'Ask every time (print window)'))),
                    for (final n in _printers) DropdownMenuItem(value: n, child: Text(n, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) async {
                    await p.setString(_kPrinter, v ?? '');
                    if ((v ?? '').isEmpty) await p.setBool(_kAuto, false);
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 14),
                Text(_t(context, 'عرض الورق', 'Paper width'), style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: 80, label: Text('80 mm')), ButtonSegment(value: 58, label: Text('58 mm'))],
                  selected: {mm == 58 ? 58 : 80},
                  onSelectionChanged: (v) async {
                    await p.setInt(_kWidth, v.first);
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 14),
                Text(_t(context, 'شكل الفاتورة', 'Receipt look'), style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final e in receiptStyles.entries)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: e.key,
                    groupValue: p.getString(_kStyle) ?? 'classic',
                    title: Text(_t(context, e.value.$1, e.value.$2), style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(e.value.$3, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                    onChanged: (v) async {
                      await p.setString(_kStyle, v ?? 'classic');
                      if (mounted) setState(() {});
                    },
                  ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: Text(_t(context, 'معاينة الشكل المختار', 'Preview')),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => Dialog(
                        child: SizedBox(
                          width: 420,
                          height: 620,
                          child: PdfPreview(
                            build: (_) => posReceiptPdf(sampleReceiptSale(), widthMm: mm, style: p.getString(_kStyle) ?? 'classic'),
                            pageFormats: {'receipt': posReceiptFormat(mm)},
                            canChangePageFormat: false,
                            canChangeOrientation: false,
                            canDebug: false,
                            allowPrinting: false,
                            allowSharing: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_t(context, 'اطبع تلقائي بعد كل بيع', 'Print automatically after every sale')),
                  subtitle: Text(printer.isEmpty ? _t(context, 'اختار طابعة الأول', 'Choose a printer first') : _t(context, 'بيطبع على الطابعة المختارة من غير نافذة', 'Prints on the chosen printer without a window'),
                      style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                  value: (p.getBool(_kAuto) ?? false) && printer.isNotEmpty,
                  onChanged: printer.isEmpty
                      ? null
                      : (v) async {
                          await p.setBool(_kAuto, v);
                          if (mounted) setState(() {});
                        },
                ),
              ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'Done')))],
    );
  }
}

/// The invoice as a nice paper on the screen, in the look the cashier chose (classic / modern / compact). The look can be switched right here.
class ReceiptPaper extends StatefulWidget {
  const ReceiptPaper({super.key, required this.sale});
  final Map<String, dynamic> sale;
  @override
  State<ReceiptPaper> createState() => _ReceiptPaperState();
}

class _ReceiptPaperState extends State<ReceiptPaper> {
  String _style = 'classic';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _style = p.getString(_kStyle) ?? 'classic');
    }).catchError((_) {});
  }

  Future<void> _pick(String v) async {
    setState(() => _style = v);
    try {
      (await SharedPreferences.getInstance()).setString(_kStyle, v);
    } catch (_) {}
  }

  String _egp(BuildContext c, num minor) => '${(minor / 100).toStringAsFixed(minor % 100 == 0 ? 0 : 2)} ${_t(c, 'ج.م', 'EGP')}';

  @override
  Widget build(BuildContext context) {
    final sale = widget.sale;
    final items = [for (final i in (sale['items'] as List? ?? const [])) Map<String, dynamic>.from(i as Map)];
    final discount = (sale['discount_minor'] as num?) ?? 0;
    final refunded = (sale['refunded_minor'] as num?) ?? 0;
    final tip = (sale['tip_minor'] as num?) ?? 0;
    final change = ((sale['change_minor'] as num?) ?? 0) - tip;
    final modern = _style == 'modern';
    final compact = _style == 'compact';
    final dt = DateTime.tryParse('${sale['created_at']}')?.toLocal();
    final when = dt == null ? '' : '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}  ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    final brand = AppName.ar;
    const navy = BrandColors.navy;
    TextStyle t(double s, {bool b = false, Color? c}) => TextStyle(fontSize: s, fontWeight: b ? FontWeight.w800 : FontWeight.w500, color: c ?? const Color(0xFF111827), height: 1.35);
    Widget kv(String k, String v, {bool strong = false}) => Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 1 : 2.5),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(k, style: t(strong ? 15 : (compact ? 12 : 13.5), b: strong)),
            Text(v, style: t(strong ? 15 : (compact ? 12 : 13.5), b: strong)),
          ]),
        );
    Widget rule() => Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 5 : 9),
          child: modern
              ? Row(children: [for (var i = 0; i < 40; i++) Expanded(child: Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 1.5), color: i.isEven ? BrandColors.border : Colors.transparent))])
              : const Divider(height: 1, color: BrandColors.border),
        );

    final header = modern
        ? Column(children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: navy, borderRadius: BorderRadius.circular(12)),
              child: Center(child: Text(brand, textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 0.5))),
            ),
            const SizedBox(height: 8),
            if ('${sale['branch_name_ar'] ?? ''}'.isNotEmpty) Text('${sale['branch_name_ar']}', style: t(14, b: true)),
            Text(when, textDirection: TextDirection.ltr, style: t(12, c: BrandColors.gray)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xFFEEF2F7), borderRadius: BorderRadius.circular(20)),
              child: Text('${sale['number']}', textDirection: TextDirection.ltr, style: t(13, b: true)),
            ),
          ])
        : Column(children: [
            Text(brand, textDirection: TextDirection.ltr, style: t(compact ? 17 : 21, b: true, c: navy)),
            if ('${sale['branch_name_ar'] ?? ''}'.isNotEmpty) Text('${sale['branch_name_ar']}', style: t(compact ? 12 : 13.5)),
            const SizedBox(height: 4),
            Text('${_t(context, 'فاتورة', 'Invoice')} ${sale['number']}', textDirection: TextDirection.ltr, style: t(compact ? 12.5 : 14, b: true)),
            Text(when, textDirection: TextDirection.ltr, style: t(12, c: BrandColors.gray)),
          ]);

    Widget itemRow(Map<String, dynamic> i) {
      final qty = '${i['quantity']}';
      final line = _egp(context, i['line_total_minor'] as num);
      final unit = _egp(context, i['unit_price_minor'] as num);
      if (modern) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 26,
              padding: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFEEF2F7), borderRadius: BorderRadius.circular(6)),
              child: Center(child: Text(qty, style: t(13, b: true))),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${i['name_ar']}', style: t(14, b: true)), Text(unit, style: t(12, c: BrandColors.gray))])),
            Text(line, style: t(14, b: true)),
          ]),
        );
      }
      if (compact) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(children: [Expanded(child: Text('$qty × ${i['name_ar']}', style: t(12.5))), Text(line, style: t(12.5, b: true))]),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text('${i['name_ar']}', style: t(14, b: true))), Text(line, style: t(14, b: true))]),
          Text('$qty × $unit', style: t(12, c: BrandColors.gray)),
        ]),
      );
    }

    final total = modern
        ? Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFEEF2F7), borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(_t(context, 'الإجمالي', 'Total'), style: t(16, b: true)),
              Text(_egp(context, sale['total_minor'] as num), style: t(22, b: true, c: navy)),
            ]),
          )
        : kv(_t(context, 'الإجمالي', 'Total'), _egp(context, sale['total_minor'] as num), strong: true);

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 12 : 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrandColors.border),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 3))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: header),
          rule(),
          for (final i in items) itemRow(i),
          rule(),
          if (discount > 0) kv(_t(context, 'خصم', 'Discount'), '- ${_egp(context, discount)}'),
          total,
          kv(_t(context, 'المستلم', 'Cash'), _egp(context, sale['cash_received_minor'] as num)),
          if (change > 0) kv(_t(context, 'الباقي', 'Change'), _egp(context, change)),
          if (tip > 0) kv(_t(context, 'بقشيش', 'Tip'), _egp(context, tip)),
          if (refunded > 0) kv(_t(context, 'مرتجع', 'Refunded'), _egp(context, refunded)),
          rule(),
          Center(child: Text(_t(context, 'شكرًا لثقتكم 💙', 'Thank you 💙'), style: t(compact ? 12.5 : 14.5, b: true, c: navy))),
          if (!compact)
            Center(child: Text(_t(context, 'الاسترجاع والاستبدال بالفاتورة', 'Returns and exchanges need this invoice'), style: t(11.5, c: BrandColors.gray))),
        ]),
      ),
      const SizedBox(height: 10),
      SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: [for (final e in receiptStyles.entries) ButtonSegment(value: e.key, label: Text(_t(context, e.value.$1, e.value.$2)))],
        selected: {_style},
        onSelectionChanged: (v) => _pick(v.first),
      ),
    ]);
  }
}
