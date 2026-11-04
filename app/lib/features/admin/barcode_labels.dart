import 'package:flutter/material.dart';
import 'dart:typed_data';
import '../../shared/motion.dart';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

Future<(pw.Font, pw.Font)> _labelFonts() async {
  try {
    final r = await rootBundle.load('assets/google_fonts/Tajawal-Regular.ttf');
    final b = await rootBundle.load('assets/google_fonts/Tajawal-Bold.ttf');
    return (pw.Font.ttf(r), pw.Font.ttf(b));
  } catch (_) {
    return (await PdfGoogleFonts.tajawalRegular(), await PdfGoogleFonts.tajawalBold());
  }
}

String _price(num minor) => '${(minor / 100).toStringAsFixed(minor % 100 == 0 ? 0 : 2)} ج.م';

/// One label: product name, price and a Code 128 barcode of the SKU (the same code the scanner reads).
pw.Widget _label(Map<String, dynamic> p, pw.Font reg, pw.Font bold, {required double w, required double h}) {
  final sku = '${p['sku']}';
  return pw.Container(
    width: w,
    height: h,
    padding: const pw.EdgeInsets.all(3),
    decoration: const pw.BoxDecoration(),
    child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.center, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
      pw.Directionality(
        textDirection: pw.TextDirection.rtl,
        child: pw.Text('${p['name_ar'] ?? p['name_en'] ?? ''}', maxLines: 2, textAlign: pw.TextAlign.center, style: pw.TextStyle(font: reg, fontSize: 7.5)),
      ),
      pw.SizedBox(height: 1.5),
      pw.Directionality(textDirection: pw.TextDirection.rtl, child: pw.Text(_price((p['price_minor'] as num?) ?? 0), style: pw.TextStyle(font: bold, fontSize: 10))),
      pw.SizedBox(height: 2),
      pw.Expanded(
        child: pw.BarcodeWidget(
          barcode: pw.Barcode.code128(),
          data: sku,
          drawText: true,
          textStyle: const pw.TextStyle(fontSize: 6.5),
        ),
      ),
    ]),
  );
}

/// [items]: product + how many labels. [thermal] = one 50x30 mm label per page (label printer), otherwise an A4 sheet of labels.
Future<List<int>> barcodeLabelsPdf(List<(Map<String, dynamic>, int)> items, {required bool thermal}) async {
  final (reg, bold) = await _labelFonts();
  final doc = pw.Document();
  final labels = <Map<String, dynamic>>[
    for (final it in items)
      for (var i = 0; i < it.$2; i++) it.$1,
  ];
  if (thermal) {
    final fmt = PdfPageFormat(50 * PdfPageFormat.mm, 30 * PdfPageFormat.mm, marginAll: 1 * PdfPageFormat.mm);
    for (final p in labels) {
      doc.addPage(pw.Page(pageFormat: fmt, build: (_) => _label(p, reg, bold, w: 48 * PdfPageFormat.mm, h: 28 * PdfPageFormat.mm)));
    }
  } else {
    const w = 48 * PdfPageFormat.mm, h = 27 * PdfPageFormat.mm;
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 8 * PdfPageFormat.mm, marginRight: 8 * PdfPageFormat.mm, marginTop: 10 * PdfPageFormat.mm, marginBottom: 10 * PdfPageFormat.mm),
      build: (_) => [
        pw.Wrap(spacing: 0, runSpacing: 0, children: [
          for (final p in labels) pw.Container(decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300, width: .3)), child: _label(p, reg, bold, w: w, h: h)),
        ]),
      ],
    ));
  }
  return doc.save();
}

/// Pick products and how many labels of each, then print (system print window; thermal or A4).
Future<void> printBarcodeLabels(BuildContext context, WidgetRef ref) => showSmoothDialog<void>(context: context, builder: (_) => _LabelsDialog(ref: ref));

class _LabelsDialog extends StatefulWidget {
  const _LabelsDialog({required this.ref});
  final WidgetRef ref;
  @override
  State<_LabelsDialog> createState() => _LabelsDialogState();
}

class _LabelsDialogState extends State<_LabelsDialog> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _found = [];
  final Map<String, (Map<String, dynamic>, int)> _picked = {};
  bool _thermal = true, _busy = false;

  Future<void> _search(String v) async {
    try {
      final r = await widget.ref.read(adminRepoProvider).products(search: v);
      if (mounted) setState(() => _found = r.take(12).toList());
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  Future<void> _print() async {
    if (_picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      final bytes = await barcodeLabelsPdf(_picked.values.toList(), thermal: _thermal);
      final fmt = _thermal ? PdfPageFormat(50 * PdfPageFormat.mm, 30 * PdfPageFormat.mm) : PdfPageFormat.a4;
      await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes), name: 'barcode-labels', format: fmt);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, _t(context, 'مقدرتش أطبع: $e', 'Could not print: $e'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _picked.values.fold<int>(0, (a, b) => a + b.$2);
    return AlertDialog(
      title: Text(_t(context, 'طباعة ملصقات باركود', 'Print barcode labels')),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _q, onChanged: _search, decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: _t(context, 'ابحث باسم المنتج أو الكود', 'Search by name or code'))),
          if (_found.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 170),
              child: ListView(shrinkWrap: true, children: [
                for (final p in _found)
                  ListTile(
                    dense: true,
                    title: Text('${p['name_ar']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${p['sku']}', textDirection: TextDirection.ltr),
                    trailing: const Icon(Icons.add_circle_outline),
                    onTap: () => setState(() => _picked['${p['id']}'] = (p, (_picked['${p['id']}']?.$2 ?? 0) + 1)),
                  ),
              ]),
            ),
          const Divider(),
          if (_picked.isEmpty)
            Text(_t(context, 'اختار منتجات بالضغط عليها فوق', 'Tap products above to add them'), style: const TextStyle(color: BrandColors.gray))
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView(shrinkWrap: true, children: [
                for (final e in _picked.entries)
                  ListTile(
                    dense: true,
                    title: Text('${e.value.$1['name_ar']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() => e.value.$2 <= 1 ? _picked.remove(e.key) : _picked[e.key] = (e.value.$1, e.value.$2 - 1))),
                      Text('${e.value.$2}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => setState(() => _picked[e.key] = (e.value.$1, e.value.$2 + 1))),
                    ]),
                  ),
              ]),
            ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(_t(context, 'ملصق 50×30 (طابعة ملصقات)', 'Label 50×30 (label printer)'))),
              ButtonSegment(value: false, label: Text(_t(context, 'ورقة A4', 'A4 sheet'))),
            ],
            selected: {_thermal},
            onSelectionChanged: (s) => setState(() => _thermal = s.first),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
        FilledButton.icon(
          onPressed: (_picked.isEmpty || _busy) ? null : _print,
          icon: const Icon(Icons.print_rounded, size: 18),
          label: Text(_t(context, 'اطبع ($total)', 'Print ($total)')),
        ),
      ],
    );
  }
}
