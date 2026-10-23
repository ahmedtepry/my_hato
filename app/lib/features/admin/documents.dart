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
          pw.Text('My Hatō', style: pw.TextStyle(font: bold, fontSize: 20, color: _blue)),
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
      pw.Text('شكرًا لاختيارك My Hatō — للدعم واتساب ${AppConfig.supportPhone.replaceFirst('+20', '0')}',
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
      if ((o['delivery_notes'] as String?)?.isNotEmpty == true) _kv('ملاحظات', o['delivery_notes'] as String),
      _kv('الدفع', switch (o['payment_method']) { 'cash_on_delivery' => 'كاش عند الاستلام', 'online' => 'دفع أونلاين', _ => 'الدفع في الفرع' }),
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
        await Printing.sharePdf(bytes: bytes, filename: '${widget.fileName}.pdf');
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
