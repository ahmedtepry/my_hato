import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'documents.dart' show pdfFonts;

/// Everything the accountant's Excel / PDF needs: one branch or all of them, for a period.
class BooksData {
  BooksData({
    required this.ar,
    required this.periodLabel,
    required this.branchLabel,
    required this.branches,
    required this.shifts,
    required this.sales,
    this.reports = const [],
  });
  final bool ar;
  final String periodLabel;
  final String branchLabel;
  final List<Map<String, dynamic>> branches; // pos_branch_report rows
  final List<Map<String, dynamic>> shifts; // pos_shift_list rows
  final List<Map<String, dynamic>> sales; // books_sales rows
  final List<Map<String, dynamic>> reports; // pos_shift_report_list rows (only with the right)

  String t(String a, String e) => ar ? a : e;
  num sum(List<Map<String, dynamic>> l, String k) => l.fold<num>(0, (a, b) => a + ((b[k] as num?) ?? 0));
}

double _p(Object? minor) => (((minor as num?) ?? 0) / 100).toDouble();
String _m(Object? minor) => _p(minor).toStringAsFixed(2);
String _dt(Object? iso) => iso == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(DateTime.parse('$iso').toLocal());

// ---------------------------------------------------------------------------------- Excel
Uint8List booksXlsx(BooksData d) {
  final book = xl.Excel.createExcel();
  xl.TextCellValue tx(Object? v) => xl.TextCellValue('${v ?? ''}');
  xl.DoubleCellValue db(Object? minor) => xl.DoubleCellValue(_p(minor));

  void sheet(String name, List<String> head, List<List<xl.CellValue>> rows) {
    final s = book[name];
    s.appendRow([for (final h in head) tx(h)]);
    for (final r in rows) {
      s.appendRow(r);
    }
  }

  final first = book.getDefaultSheet();
  // summary
  final sumName = d.t('ملخص', 'Summary');
  if (first != null) book.rename(first, sumName);
  final s = book[sumName];
  s.appendRow([tx(d.t('تقرير المحاسبة', 'Accounting report'))]);
  s.appendRow([tx(d.t('الفترة', 'Period')), tx(d.periodLabel)]);
  s.appendRow([tx(d.t('الفرع', 'Branch')), tx(d.branchLabel)]);
  s.appendRow([tx(d.t('تاريخ التقرير', 'Generated')), tx(_dt(DateTime.now().toIso8601String()))]);
  s.appendRow([]);
  s.appendRow([tx(d.t('إجمالي المبيعات (ج.م)', 'Total sales (EGP)')), db(d.sum(d.branches, 'sales_minor'))]);
  s.appendRow([tx(d.t('المرتجعات (ج.م)', 'Refunds (EGP)')), db(d.sum(d.branches, 'refunds_minor'))]);
  s.appendRow([tx(d.t('صافي المبيعات (ج.م)', 'Net sales (EGP)')), db(d.sum(d.branches, 'net_minor'))]);
  s.appendRow([tx(d.t('عدد الفواتير', 'Invoices')), xl.IntCellValue(d.sum(d.branches, 'sales_count').toInt())]);
  s.appendRow([tx(d.t('ورديات مقفولة', 'Closed shifts')), xl.IntCellValue(d.sum(d.branches, 'shifts_closed').toInt())]);
  s.appendRow([tx(d.t('فرق الدرج (ج.م)', 'Drawer difference (EGP)')), db(d.sum(d.branches, 'variance_minor'))]);

  sheet(d.t('الفروع', 'Branches'), [
    d.t('الفرع', 'Branch'), d.t('عدد الفواتير', 'Invoices'), d.t('المبيعات', 'Sales'), d.t('المرتجعات', 'Refunds'), d.t('الصافي', 'Net'),
    d.t('ورديات مقفولة', 'Closed shifts'), d.t('فرق الدرج', 'Drawer difference'), d.t('كاشيرات', 'Cashiers'),
  ], [
    for (final b in d.branches)
      [tx(b['branch_name_ar']), xl.IntCellValue(((b['sales_count'] as num?) ?? 0).toInt()), db(b['sales_minor']), db(b['refunds_minor']), db(b['net_minor']),
        xl.IntCellValue(((b['shifts_closed'] as num?) ?? 0).toInt()), db(b['variance_minor']), xl.IntCellValue(((b['cashiers'] as num?) ?? 0).toInt())],
  ]);

  sheet(d.t('الورديات', 'Shifts'), [
    d.t('فتح', 'Opened'), d.t('قفل', 'Closed'), d.t('الفرع', 'Branch'), d.t('الكاشير', 'Cashier'), d.t('الحالة', 'Status'), d.t('عهدة أول الوردية', 'Opening cash'),
    d.t('عدد الفواتير', 'Invoices'), d.t('المبيعات', 'Sales'), d.t('المرتجعات', 'Refunds'), d.t('المتوقع', 'Expected'), d.t('الفعلي', 'Counted'),
    d.t('الفرق', 'Difference'), d.t('ملاحظة', 'Note'),
  ], [
    for (final x in d.shifts)
      [tx(_dt(x['opened_at'])), tx(_dt(x['closed_at'])), tx(x['branch_name_ar']), tx(x['cashier_name']),
        tx(x['status'] == 'open' ? d.t('مفتوحة', 'Open') : d.t('مقفولة', 'Closed')), db(x['opening_minor']),
        xl.IntCellValue(((x['sales_count'] as num?) ?? 0).toInt()), db(x['sales_minor']), db(x['refunds_minor']), db(x['expected_minor']), db(x['counted_minor']),
        db(x['variance_minor']), tx(x['note'])],
  ]);

  sheet(d.t('الفواتير', 'Sales'), [
    d.t('رقم الفاتورة', 'Invoice'), d.t('الوقت', 'Time'), d.t('الفرع', 'Branch'), d.t('الكاشير', 'Cashier'), d.t('قبل الخصم', 'Subtotal'), d.t('الخصم', 'Discount'),
    d.t('الإجمالي', 'Total'), d.t('مرتجع', 'Refunded'),
  ], [
    for (final x in d.sales)
      [tx(x['number']), tx(_dt(x['created_at'])), tx(x['branch_name_ar']), tx(x['cashier_name']), db(x['subtotal_minor']), db(x['discount_minor']), db(x['total_minor']), db(x['refunded_minor'])],
  ]);

  if (d.reports.isNotEmpty) {
    sheet(d.t('تقارير الإقفال', 'Closing reports'), [
      d.t('رقم التقرير', 'Report'), d.t('الفرع', 'Branch'), d.t('الكاشير', 'Cashier'), d.t('اللي قفل', 'Closed by'), d.t('الجهاز', 'Device'), d.t('فتح', 'Opened'),
      d.t('قفل', 'Closed'), d.t('المبيعات', 'Sales'), d.t('المرتجعات', 'Refunds'), d.t('المتوقع', 'Expected'), d.t('الفعلي', 'Counted'), d.t('الفرق', 'Difference'),
      d.t('تصحيحات', 'Corrections'), d.t('ملاحظة', 'Note'),
    ], [
      for (final x in d.reports)
        [tx(x['report_no']), tx(x['branch_name_ar']), tx(x['cashier_name']), tx(x['closed_by_name']), tx(x['closed_device']), tx(_dt(x['opened_at'])), tx(_dt(x['closed_at'])),
          db(x['sales_minor']), db(x['refunds_minor']), db(x['expected_minor']), db(x['counted_minor']), db(x['variance_minor']), db(x['corrections_minor']), tx(x['note'])],
    ]);
  }

  final bytes = book.save();
  if (bytes == null) throw StateError('empty file');
  return Uint8List.fromList(bytes);
}

// ---------------------------------------------------------------------------------- PDF
Future<Uint8List> booksPdf(BooksData d) async {
  final (regular, bold) = await pdfFonts();
  final dir = d.ar ? pw.TextDirection.rtl : pw.TextDirection.ltr;
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
  const blue = PdfColor.fromInt(0xFF1F5BFF);
  const grey = PdfColor.fromInt(0xFF667085);
  const line = PdfColor.fromInt(0xFFD0D5DD);

  pw.Widget table(List<String> head, List<List<String>> rows) => pw.TableHelper.fromTextArray(
        headers: head,
        data: rows,
        headerStyle: pw.TextStyle(font: bold, color: PdfColors.white, fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: blue),
        cellStyle: const pw.TextStyle(fontSize: 8.5),
        cellAlignment: d.ar ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
        border: pw.TableBorder.all(color: line, width: 0.4),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      );
  pw.Widget h(String s) => pw.Padding(padding: const pw.EdgeInsets.only(top: 14, bottom: 6), child: pw.Text(s, style: pw.TextStyle(font: bold, fontSize: 13)));

  const cap = 400;
  doc.addPage(pw.MultiPage(
    pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4.landscape, textDirection: dir, margin: const pw.EdgeInsets.all(24), theme: pw.ThemeData.withFont(base: regular, bold: bold)),
    footer: (c) => pw.Align(
      alignment: pw.Alignment.center,
      child: pw.Text('${d.t('صفحة', 'Page')} ${c.pageNumber} / ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: grey)),
    ),
    build: (_) => [
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: const pw.BoxDecoration(color: blue, borderRadius: pw.BorderRadius.all(pw.Radius.circular(8))),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(d.t('تقرير المحاسبة', 'Accounting report'), style: pw.TextStyle(font: bold, fontSize: 18, color: PdfColors.white)),
          pw.Text('My Hatō', style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColors.white), textDirection: pw.TextDirection.ltr),
        ]),
      ),
      pw.SizedBox(height: 8),
      pw.Text('${d.t('الفترة', 'Period')}: ${d.periodLabel}     ${d.t('الفرع', 'Branch')}: ${d.branchLabel}     ${d.t('تاريخ التقرير', 'Generated')}: ${_dt(DateTime.now().toIso8601String())}',
          style: const pw.TextStyle(fontSize: 10, color: grey)),
      h(d.t('الملخص', 'Summary')),
      table([d.t('المبيعات', 'Sales'), d.t('المرتجعات', 'Refunds'), d.t('الصافي', 'Net'), d.t('الفواتير', 'Invoices'), d.t('ورديات مقفولة', 'Closed shifts'), d.t('فرق الدرج', 'Drawer difference')], [
        [_m(d.sum(d.branches, 'sales_minor')), _m(d.sum(d.branches, 'refunds_minor')), _m(d.sum(d.branches, 'net_minor')), '${d.sum(d.branches, 'sales_count')}',
          '${d.sum(d.branches, 'shifts_closed')}', _m(d.sum(d.branches, 'variance_minor'))],
      ]),
      h(d.t('الفروع', 'Branches')),
      table([d.t('الفرع', 'Branch'), d.t('الفواتير', 'Invoices'), d.t('المبيعات', 'Sales'), d.t('المرتجعات', 'Refunds'), d.t('الصافي', 'Net'), d.t('فرق الدرج', 'Difference')], [
        for (final b in d.branches) ['${b['branch_name_ar']}', '${b['sales_count']}', _m(b['sales_minor']), _m(b['refunds_minor']), _m(b['net_minor']), _m(b['variance_minor'])],
      ]),
      h(d.t('الورديات', 'Shifts')),
      table([d.t('فتح', 'Opened'), d.t('قفل', 'Closed'), d.t('الفرع', 'Branch'), d.t('الكاشير', 'Cashier'), d.t('المبيعات', 'Sales'), d.t('المرتجعات', 'Refunds'), d.t('المتوقع', 'Expected'), d.t('الفعلي', 'Counted'), d.t('الفرق', 'Diff')], [
        for (final x in d.shifts)
          [_dt(x['opened_at']), _dt(x['closed_at']), '${x['branch_name_ar']}', '${x['cashier_name']}', _m(x['sales_minor']), _m(x['refunds_minor']), _m(x['expected_minor']),
            x['counted_minor'] == null ? '' : _m(x['counted_minor']), x['variance_minor'] == null ? '' : _m(x['variance_minor'])],
      ]),
      if (d.reports.isNotEmpty) ...[
        h(d.t('تقارير إقفال الورديات', 'Shift closing reports')),
        table([d.t('رقم', 'No.'), d.t('الفرع', 'Branch'), d.t('الكاشير', 'Cashier'), d.t('اللي قفل', 'Closed by'), d.t('قفل', 'Closed'), d.t('المتوقع', 'Expected'), d.t('الفعلي', 'Counted'), d.t('الفرق', 'Diff'), d.t('تصحيحات', 'Corrections')], [
          for (final x in d.reports)
            ['${x['report_no']}', '${x['branch_name_ar']}', '${x['cashier_name']}', '${x['closed_by_name']}', _dt(x['closed_at']), _m(x['expected_minor']), _m(x['counted_minor']), _m(x['variance_minor']), _m(x['corrections_minor'])],
        ]),
      ],
      h(d.t('الفواتير', 'Sales')),
      table([d.t('الفاتورة', 'Invoice'), d.t('الوقت', 'Time'), d.t('الفرع', 'Branch'), d.t('الكاشير', 'Cashier'), d.t('الخصم', 'Discount'), d.t('الإجمالي', 'Total'), d.t('مرتجع', 'Refunded')], [
        for (final x in d.sales.take(cap)) ['${x['number']}', _dt(x['created_at']), '${x['branch_name_ar']}', '${x['cashier_name']}', _m(x['discount_minor']), _m(x['total_minor']), _m(x['refunded_minor'])],
      ]),
      if (d.sales.length > cap)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text(d.t('اتعرض أول $cap فاتورة من ${d.sales.length}. القايمة الكاملة في ملف Excel.', 'First $cap of ${d.sales.length} invoices shown. The full list is in the Excel file.'),
              style: const pw.TextStyle(fontSize: 9, color: grey)),
        ),
    ],
  ));
  return doc.save();
}
