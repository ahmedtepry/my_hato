import '../../core/save_file.dart';
import '../../core/appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/theme.dart';

// =====================================================================================
// Contact the customer: call / WhatsApp with a ready message that includes the reference
// =====================================================================================

/// Egyptian mobile -> international digits for wa.me (201XXXXXXXXX).
String waDigits(String phone) {
  var d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('00')) d = d.substring(2);
  if (d.startsWith('01') && d.length == 11) d = '2$d';
  return d;
}

class ContactButtons extends StatelessWidget {
  const ContactButtons({super.key, required this.phone, required this.message});
  final String phone;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ar = Directionality.of(context) == TextDirection.rtl;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
            icon: const Icon(Icons.call_rounded, size: 18),
            label: Text(ar ? 'اتصال' : 'Call'),
            onPressed: () => launchUrl(Uri.parse('tel:${phone.replaceAll(' ', '')}')),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366), minimumSize: const Size.fromHeight(42)),
            icon: const Icon(Icons.chat_rounded, size: 18),
            label: Text(ar ? 'واتساب' : 'WhatsApp'),
            onPressed: () => launchUrl(Uri.parse('https://wa.me/${waDigits(phone)}?text=${Uri.encodeComponent(message)}'),
                mode: LaunchMode.externalApplication),
          ),
        ),
      ]),
    );
  }
}

// =====================================================================================
// PDF documents: order invoice / repair receipt (Arabic, RTL) — share or print
// =====================================================================================

Future<(pw.Font, pw.Font)> _fonts() async {
  try {
    final r = await rootBundle.load('assets/google_fonts/Tajawal-Regular.ttf');
    final b = await rootBundle.load('assets/google_fonts/Tajawal-Bold.ttf');
    return (pw.Font.ttf(r), pw.Font.ttf(b));
  } catch (_) {
    return (await PdfGoogleFonts.tajawalRegular(), await PdfGoogleFonts.tajawalBold());
  }
}

String _egp(num minor) => '${(minor / 100).toStringAsFixed(minor % 100 == 0 ? 0 : 2)} ج.م';

String _date(String iso) {
  final d = DateTime.parse(iso).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}/${two(d.month)}/${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}

const _navy = PdfColor.fromInt(0xFF0B2D5B);
const _blue = PdfColor.fromInt(0xFF00A3FF);
const _grey = PdfColor.fromInt(0xFF6B7280);
const _line = PdfColor.fromInt(0xFFE4E7EC);

pw.Widget _header(String title, String reference, String date, pw.Font bold) => pw.Container(
      padding: const pw.EdgeInsets.all(16),
      decoration: const pw.BoxDecoration(color: _navy, borderRadius: pw.BorderRadius.all(pw.Radius.circular(10))),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(title, style: pw.TextStyle(font: bold, fontSize: 18, color: PdfColors.white)),
          pw.SizedBox(height: 4),
          pw.Text(date, style: const pw.TextStyle(fontSize: 10, color: PdfColors.white)),
        ]),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(AppName.en, style: pw.TextStyle(font: bold, fontSize: 20, color: _blue)),
          pw.SizedBox(height: 4),
          pw.Text(reference, textDirection: pw.TextDirection.ltr, style: pw.TextStyle(font: bold, fontSize: 13, color: PdfColors.white)),
        ]),
      ]),
    );

pw.Widget _kv(String k, String v, {pw.Font? bold}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(width: 90, child: pw.Text(k, style: const pw.TextStyle(color: _grey, fontSize: 11))),
        pw.Expanded(child: pw.Text(v, style: pw.TextStyle(font: bold, fontSize: 11))),
      ]),
    );

pw.Widget _footer() => pw.Column(children: [
      pw.Divider(color: _line),
      pw.Text('شكرًا لاختيارك ${AppName.ar} — للدعم واتساب ${AppConfig.supportPhone.replaceFirst('+20', '0')}',
          style: const pw.TextStyle(color: _grey, fontSize: 10)),
    ]);

Future<Uint8List> orderInvoicePdf(Map<String, dynamic> o) async {
  final (regular, bold) = await _fonts();
  final items = List<Map<String, dynamic>>.from(o['order_items'] as List? ?? const []);
  final total = (o['total_minor'] as num).toInt();
  final fee = (o['delivery_fee_minor'] as num?)?.toInt() ?? 0;
  final addr = o['delivery_address'] as Map<String, dynamic>?;
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    textDirection: pw.TextDirection.rtl,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _header('فاتورة طلب', o['reference'] as String, _date(o['created_at'] as String), bold),
      pw.SizedBox(height: 16),
      _kv('العميل', '${o['customer_name'] ?? ''}', bold: bold),
      _kv('الموبايل', '${o['customer_phone'] ?? ''}'),
      _kv('الاستلام', o['fulfillment'] == 'pickup' ? 'استلام من الفرع' : 'توصيل للعنوان'),
      if (addr != null)
        _kv('العنوان', [addr['governorate'], addr['city'], addr['street'], addr['building'], addr['landmark']].where((x) => x != null && '$x'.isNotEmpty).join(' — ')),
      if (addr != null && (addr['location_note'] as String?)?.isNotEmpty == true) _kv('الموقع', '${addr['location_note']}'),
      if ((o['delivery_notes'] as String?)?.isNotEmpty == true) _kv('ملاحظات', o['delivery_notes'] as String),
      _kv('الدفع', switch (o['payment_method']) { 'cash_on_delivery' => 'كاش عند الاستلام', 'online' => 'دفع أونلاين', _ => 'كاش' }),
      pw.SizedBox(height: 14),
      pw.TableHelper.fromTextArray(
        headers: ['المنتج', 'الكمية', 'سعر الوحدة', 'الإجمالي'],
        data: [
          for (final it in items)
            ['${it['name_ar']}', '${it['quantity']}', _egp(it['unit_price_minor'] as num), _egp(it['line_total_minor'] as num)],
        ],
        headerStyle: pw.TextStyle(font: bold, color: PdfColors.white, fontSize: 11),
        headerDecoration: const pw.BoxDecoration(color: _blue),
        cellStyle: const pw.TextStyle(fontSize: 11),
        cellAlignment: pw.Alignment.centerRight,
        columnWidths: {0: const pw.FlexColumnWidth(4), 1: const pw.FlexColumnWidth(1), 2: const pw.FlexColumnWidth(2), 3: const pw.FlexColumnWidth(2)},
        border: pw.TableBorder.all(color: _line),
        cellPadding: const pw.EdgeInsets.all(6),
      ),
      pw.SizedBox(height: 12),
      pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: pw.SizedBox(
          width: 220,
          child: pw.Column(children: [
            _kv('المنتجات', _egp(total - fee)),
            _kv('التوصيل', fee == 0 ? 'مجاني' : _egp(fee)),
            pw.Divider(color: _line),
            _kv('الإجمالي', _egp(total), bold: bold),
          ]),
        ),
      ),
      pw.Spacer(),
      _footer(),
    ]),
  ));
  return doc.save();
}

Future<Uint8List> repairReceiptPdf(Map<String, dynamic> r, String statusLabel) async {
  final (regular, bold) = await _fonts();
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
  final cost = (r['approved_cost_minor'] ?? r['estimated_cost_minor']) as num?;
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a5,
    textDirection: pw.TextDirection.rtl,
    margin: const pw.EdgeInsets.all(24),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _header('إيصال صيانة', r['reference'] as String, _date(r['created_at'] as String), bold),
      pw.SizedBox(height: 14),
      _kv('العميل', '${r['contact_name'] ?? ''}', bold: bold),
      _kv('الموبايل', '${r['contact_phone'] ?? ''}'),
      _kv('الجهاز', '${r['device_brand'] ?? ''} ${r['device_model'] ?? ''}', bold: bold),
      _kv('العطل', '${r['problem_description'] ?? ''}'),
      _kv('الحالة', statusLabel),
      if (cost != null) _kv('التكلفة', _egp(cost), bold: bold),
      pw.SizedBox(height: 18),
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8))),
        child: pw.Text('احتفظ بالإيصال ده — هتحتاج رقم الطلب علشان تتابع جهازك أو تستلمه.', style: const pw.TextStyle(fontSize: 10, color: _grey)),
      ),
      pw.Spacer(),
      _footer(),
    ]),
  ));
  return doc.save();
}

/// Share (WhatsApp, Drive, …) or print a generated PDF.
class DocumentButtons extends StatefulWidget {
  const DocumentButtons({super.key, required this.fileName, required this.build});
  final String fileName;
  final Future<Uint8List> Function() build;
  @override
  State<DocumentButtons> createState() => _DocumentButtonsState();
}

class _DocumentButtonsState extends State<DocumentButtons> {
  bool _busy = false;

  Future<void> _run(bool print) async {
    setState(() => _busy = true);
    try {
      final bytes = await widget.build();
      if (print) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: widget.fileName);
      } else {
        if (mounted) await deliverFile(context, bytes, '${widget.fileName}.pdf', 'application/pdf');
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = Directionality.of(context) == TextDirection.rtl;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42), foregroundColor: BrandColors.navy),
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: Text(ar ? 'مشاركة PDF' : 'Share PDF'),
            onPressed: _busy ? null : () => _run(false),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42), foregroundColor: BrandColors.navy),
            icon: const Icon(Icons.print_rounded, size: 18),
            label: Text(ar ? 'طباعة' : 'Print'),
            onPressed: _busy ? null : () => _run(true),
          ),
        ),
      ]),
    );
  }
}

// =====================================================================================
// Cashier receipt: a narrow thermal-roll slip (80 mm or 58 mm), Arabic RTL
// =====================================================================================

PdfPageFormat posReceiptFormat(int mm) => (mm <= 58 ? PdfPageFormat.roll57 : PdfPageFormat.roll80).copyWith(marginLeft: 3 * PdfPageFormat.mm, marginRight: 3 * PdfPageFormat.mm, marginTop: 3 * PdfPageFormat.mm, marginBottom: 6 * PdfPageFormat.mm);

/// The invoice looks. One of them is chosen for the whole shop by whoever has the receipt.style permission.
const receiptStyles = <String, (String, String, String)>{
  'clean': ('نظيف', 'Clean', 'أبيض وأسود وجدول بسيط، الأنسب للطابعة الحرارية'),
  'banner': ('الشريط', 'Banner', 'هيدر باسم المحل وإجمالي بارز وكود واتساب'),
  'cards': ('بطاقات', 'Cards', 'أقسام ناعمة ومبلغ التوفير ظاهر'),
};

/// Maps a stored value (including the old looks) to one that exists.
String normReceiptStyle(String? s) => receiptStyles.containsKey(s) ? s! : (s == 'modern' ? 'banner' : 'clean');

/// A made-up sale used for the preview in the settings.
Map<String, dynamic> sampleReceiptSale() => {
      'number': 'POS-000000-00001',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'branch_name_ar': 'فرع ١',
      'cashier_name': 'أحمد',
      'items': [
        {'name_ar': 'إسكرينة زجاج كاملة', 'quantity': 2, 'unit_price_minor': 4900, 'line_total_minor': 9800},
        {'name_ar': 'جراب شفاف', 'quantity': 1, 'unit_price_minor': 15000, 'line_total_minor': 15000},
      ],
      'discount_minor': 500,
      'total_minor': 24300,
      'cash_received_minor': 25000,
      'change_minor': 700,
      'tip_minor': 200,
    };

Future<Uint8List> posReceiptPdf(Map<String, dynamic> sale, {int widthMm = 80, String style = 'clean'}) async {
  final (regular, bold) = await _fonts();
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
  final st = normReceiptStyle(style);
  final items = List<Map<String, dynamic>>.from(sale['items'] as List? ?? const []);
  final discount = (sale['discount_minor'] as num?) ?? 0;
  final refunded = (sale['refunded_minor'] as num?) ?? 0;
  final tip = (sale['tip_minor'] as num?) ?? 0;
  final change = ((sale['change_minor'] as num?) ?? 0) - tip;
  final subtotal = items.fold<num>(0, (a, i) => a + ((i['line_total_minor'] as num?) ?? 0));
  final phone = AppConfig.supportPhone.replaceFirst('+20', '0');
  // the Arabic font has no "ō": print the name with a plain o so no empty box shows
  final brand = AppName.ar.replaceAll('ō', 'o').replaceAll('Ō', 'O');
  final branch = '${sale['branch_name_ar'] ?? ''}';
  final cashier = '${sale['cashier_name'] ?? ''}';
  final number = '${sale['number']}';
  final when = _date('${sale['created_at']}');
  const ink = PdfColor.fromInt(0xFF111827);
  const soft = PdfColor.fromInt(0xFFEEF2F7);
  const green = PdfColor.fromInt(0xFF0F9D58);
  const greenSoft = PdfColor.fromInt(0xFFE7F6EE);

  pw.TextStyle ts(double size, {bool b = false, PdfColor? c}) => pw.TextStyle(font: b ? bold : regular, fontSize: size, color: c ?? ink);
  pw.Widget kv(String k, String v, {bool b = false, double size = 9.5, PdfColor? c}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.2),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(k, style: ts(size, b: b, c: c)),
          pw.Text(v, textDirection: pw.TextDirection.rtl, style: ts(size, b: b, c: c)),
        ]),
      );
  pw.Widget dashed() => pw.Divider(color: _grey, thickness: 0.6, height: 9, borderStyle: pw.BorderStyle.dashed);
  pw.Widget solid() => pw.Divider(color: ink, thickness: 0.9, height: 8);
  pw.Widget center(String t, pw.TextStyle s) => pw.Center(child: pw.Text(t, style: s, textAlign: pw.TextAlign.center));
  pw.Widget ltr(String t, pw.TextStyle s) => pw.Text(t, textDirection: pw.TextDirection.ltr, style: s);
  pw.Widget payRows() => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        kv('المستلم', _egp((sale['cash_received_minor'] as num) - tip)),
        if (change > 0) kv('الباقي', _egp(change)),
        if (refunded > 0) kv('مرتجع', _egp(refunded)),
      ]);
  pw.Widget footer({bool navy = false}) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        center('شكرًا لثقتكم', ts(11, b: true, c: navy ? _navy : ink)),
        pw.SizedBox(height: 2),
        center('واتساب $phone', ts(8, c: _grey)),
        center('الاسترجاع والاستبدال بالفاتورة', ts(8, c: _grey)),
      ]);

  // ---- 1: clean (black and white, thermal friendly)
  List<pw.Widget> clean() => [
        center(brand, ts(19, b: true)),
        if (branch.isNotEmpty) center(branch, ts(9, c: _grey)),
        dashed(),
        kv('فاتورة', number, b: true),
        kv('التاريخ', when, c: _grey, size: 8.5),
        if (cashier.isNotEmpty) kv('الكاشير', cashier, c: _grey, size: 8.5),
        dashed(),
        pw.Row(children: [
          pw.Expanded(child: pw.Text('الصنف', style: ts(8, c: _grey))),
          pw.SizedBox(width: 26, child: pw.Center(child: pw.Text('كمية', style: ts(8, c: _grey)))),
          pw.SizedBox(width: 50, child: pw.Align(alignment: pw.Alignment.centerLeft, child: pw.Text('الإجمالي', style: ts(8, c: _grey)))),
        ]),
        solid(),
        for (final it in items)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text('${it['name_ar']}', style: ts(10, b: true)),
                pw.Text('${_egp(it['unit_price_minor'] as num)} للقطعة', style: ts(7.5, c: _grey)),
              ])),
              pw.SizedBox(width: 26, child: pw.Center(child: pw.Text('${it['quantity']}', style: ts(10)))),
              pw.SizedBox(width: 50, child: pw.Align(alignment: pw.Alignment.centerLeft, child: pw.Text(_egp(it['line_total_minor'] as num), textDirection: pw.TextDirection.rtl, style: ts(10, b: true)))),
            ]),
          ),
        solid(),
        if (discount > 0) ...[kv('المجموع', _egp(subtotal)), kv('خصم', '- ${_egp(discount)}')],
        pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 3), child: kv('الإجمالي', _egp(sale['total_minor'] as num), b: true, size: 14)),
        solid(),
        payRows(),
        dashed(),
        footer(),
      ];

  // ---- 2: banner
  List<pw.Widget> banner() => [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 9),
          decoration: pw.BoxDecoration(color: _navy, borderRadius: pw.BorderRadius.circular(5)),
          child: pw.Column(children: [
            pw.Text(brand, textDirection: pw.TextDirection.ltr, style: ts(19, b: true, c: PdfColors.white)),
            pw.Text('${branch.isEmpty ? '' : '$branch · '}خدمة جوالات', style: ts(8.5, c: PdfColors.white)),
          ]),
        ),
        pw.SizedBox(height: 6),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('رقم الفاتورة', style: ts(7.5, c: _grey)), ltr(number, ts(9, b: true))])),
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('التاريخ', style: ts(7.5, c: _grey)), ltr(when, ts(9))])),
        ]),
        pw.SizedBox(height: 3),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('الكاشير', style: ts(7.5, c: _grey)), pw.Text(cashier.isEmpty ? '-' : cashier, style: ts(9))])),
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('طريقة الدفع', style: ts(7.5, c: _grey)), pw.Text('كاش', style: ts(9))])),
        ]),
        pw.SizedBox(height: 6),
        for (var i = 0; i < items.length; i++)
          pw.Container(
            color: i.isEven ? soft : null,
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('${items[i]['quantity']}×', style: ts(10, b: true, c: _navy)),
              pw.SizedBox(width: 5),
              pw.Expanded(child: pw.Text('${items[i]['name_ar']}', style: ts(10))),
              pw.Text(_egp(items[i]['line_total_minor'] as num), textDirection: pw.TextDirection.rtl, style: ts(10, b: true)),
            ]),
          ),
        pw.SizedBox(height: 5),
        if (discount > 0) ...[kv('المجموع', _egp(subtotal)), kv('خصم', '- ${_egp(discount)}')],
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 4),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: pw.BoxDecoration(color: _navy, borderRadius: pw.BorderRadius.circular(5)),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('الإجمالي', style: ts(11, b: true, c: PdfColors.white)),
            pw.Text(_egp(sale['total_minor'] as num), textDirection: pw.TextDirection.rtl, style: ts(16, b: true, c: PdfColors.white)),
          ]),
        ),
        payRows(),
        pw.SizedBox(height: 7),
        pw.Row(children: [
          pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: 'https://wa.me/2$phone', width: 46, height: 46, drawText: false),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('كلّمنا على واتساب', style: ts(9, b: true)),
            ltr(phone, ts(9)),
            pw.Text('الاسترجاع والاستبدال بالفاتورة', style: ts(7.5, c: _grey)),
          ])),
        ]),
      ];

  // ---- 5: cards
  pw.Widget chip(String t, {bool isLtr = false}) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _grey, width: 0.5), borderRadius: pw.BorderRadius.circular(8)),
        child: isLtr ? ltr(t, ts(8)) : pw.Text(t, style: ts(8)),
      );
  pw.Widget card(List<pw.Widget> children) => pw.Container(
        margin: const pw.EdgeInsets.symmetric(vertical: 3),
        padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _grey, width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: children),
      );
  List<pw.Widget> cards() => [
        center(brand, ts(19, b: true, c: _navy)),
        if (branch.isNotEmpty) center(branch, ts(9, c: _grey)),
        pw.SizedBox(height: 4),
        pw.Wrap(alignment: pw.WrapAlignment.center, spacing: 4, runSpacing: 3, children: [chip(number, isLtr: true), chip(when, isLtr: true), if (cashier.isNotEmpty) chip(cashier)]),
        card([
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) pw.Divider(color: _line, thickness: 0.5, height: 7),
            pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
              pw.Container(
                width: 17,
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                decoration: pw.BoxDecoration(color: soft, borderRadius: pw.BorderRadius.circular(3)),
                child: pw.Center(child: pw.Text('${items[i]['quantity']}', style: ts(9.5, b: true))),
              ),
              pw.SizedBox(width: 6),
              pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text('${items[i]['name_ar']}', style: ts(10)),
                pw.Text(_egp(items[i]['unit_price_minor'] as num), style: ts(7.5, c: _grey)),
              ])),
              pw.Text(_egp(items[i]['line_total_minor'] as num), textDirection: pw.TextDirection.rtl, style: ts(10, b: true)),
            ]),
          ],
        ]),
        if (discount > 0)
          pw.Container(
            margin: const pw.EdgeInsets.symmetric(vertical: 3),
            padding: const pw.EdgeInsets.symmetric(vertical: 4),
            decoration: pw.BoxDecoration(color: greenSoft, borderRadius: pw.BorderRadius.circular(5)),
            child: center('وفّرت ${_egp(discount)} في الفاتورة دي', ts(9, b: true, c: green)),
          ),
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 3),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: pw.BoxDecoration(color: _navy, borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('الإجمالي', style: ts(11, b: true, c: PdfColors.white)),
            pw.Text(_egp(sale['total_minor'] as num), textDirection: pw.TextDirection.rtl, style: ts(16, b: true, c: PdfColors.white)),
          ]),
        ),
        card([if (discount > 0) kv('المجموع', _egp(subtotal)), payRows()]),
        pw.SizedBox(height: 4),
        footer(navy: true),
      ];

  doc.addPage(pw.Page(
    pageFormat: posReceiptFormat(widthMm),
    textDirection: pw.TextDirection.rtl,
    build: (_) => pw.DefaultTextStyle(
      style: const pw.TextStyle(color: ink),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: st == 'banner' ? banner() : (st == 'cards' ? cards() : clean())),
    ),
  ));
  return doc.save();
}

/// Arabic PDF fonts for other documents (accountant reports).
Future<(pw.Font, pw.Font)> pdfFonts() => _fonts();
