import 'dart:async';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
    final bytes = await posReceiptPdf(sale, widthMm: mm);
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
    final bytes = await posReceiptPdf(sale, widthMm: p.getInt(_kWidth) ?? 80);
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
