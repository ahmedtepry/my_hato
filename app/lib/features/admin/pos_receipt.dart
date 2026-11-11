import 'dart:async';
import '../../shared/motion.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/appearance.dart';
import '../../core/config.dart';
import '../../core/save_file.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart' show staffContextProvider;
import 'documents.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

// Receipt printing for the cashier. Settings live on this computer only (the printer and paper width differ per till).
const _kPrinter = 'pos_printer_name';
const _kWidth = 'pos_receipt_mm';
const _kAuto = 'pos_auto_print';
const _kStyle = 'pos_receipt_style';

/// The invoice look chosen for the whole shop (kept on this computer too, so printing still works offline).
final receiptStyleProvider = FutureProvider.autoDispose<String>((ref) async {
  final p = await SharedPreferences.getInstance();
  try {
    final v = normReceiptStyle(await ref.watch(supabaseProvider).rpc('receipt_style_get') as String?);
    await p.setString(_kStyle, v);
    return v;
  } catch (_) {
    return normReceiptStyle(p.getString(_kStyle));
  }
});

/// VAT percent for the invoices (0 = off); kept on this computer too so printing works offline.
final receiptVatProvider = FutureProvider.autoDispose<double>((ref) async {
  final p = await SharedPreferences.getInstance();
  try {
    final v = ((await ref.watch(supabaseProvider).rpc('receipt_vat_get')) as num).toDouble();
    await p.setDouble(kReceiptVatKey, v);
    return v;
  } catch (_) {
    return p.getDouble(kReceiptVatKey) ?? 0;
  }
});

Future<String> _currentStyle(BuildContext context) => ProviderScope.containerOf(context).read(receiptStyleProvider.future);

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
    final bytes = await posReceiptPdf(sale, widthMm: mm, style: await _currentStyle(context));
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
    final bytes = await posReceiptPdf(sale, widthMm: p.getInt(_kWidth) ?? 80, style: await _currentStyle(context));
    if (context.mounted) await deliverFile(context, bytes, 'receipt-${sale['number']}.pdf', 'application/pdf');
  } catch (e) {
    if (context.mounted) showSnack(context, '$e', error: true);
  }
}

/// Asks for the customer's number and opens WhatsApp with the receipt text ready to send.
Future<void> sendReceiptWhatsApp(BuildContext context, String text) async {
  final ctl = TextEditingController();
  final phone = await showSmoothDialog<String>(
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

Future<void> showReceiptSettings(BuildContext context) => showSmoothDialog<void>(context: context, builder: (_) => const _ReceiptSettings());

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
                _StylePicker(mm: mm),
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

/// The invoice look as its own page (inside the Appearance section).
class InvoiceLookPanel extends StatelessWidget {
  const InvoiceLookPanel({super.key});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: const [_StylePicker(mm: 80)]);
}

/// Lets the owner (receipt.style) choose the invoice look for the whole shop; everybody else just sees which one is on.
class _StylePicker extends ConsumerWidget {
  const _StylePicker({required this.mm});
  final int mm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(receiptStyleProvider).valueOrNull ?? 'clean';
    final can = ref.watch(staffContextProvider).valueOrNull?.permissions.contains('receipt.style') ?? false;
    Future<void> choose(String v) async {
      try {
        await ref.read(supabaseProvider).rpc('receipt_style_set', params: {'p_style': v});
        ref.invalidate(receiptStyleProvider);
        if (context.mounted) showSnack(context, _t(context, 'اتغيّر شكل الفاتورة لكل الكاشيرات ✅', 'Invoice look changed for every cashier ✅'));
      } catch (e) {
        if (context.mounted) showSnack(context, '$e', error: true);
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _VatBox(canEdit: can),
      const SizedBox(height: 16),
      Text(_t(context, 'شكل الفاتورة', 'Invoice look'), style: const TextStyle(fontWeight: FontWeight.w700)),
      if (!can)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${_t(context, receiptStyles[current]!.$1, receiptStyles[current]!.$2)} — ${_t(context, 'المالك هو اللي بيغيّره', 'the owner changes it')}', style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
        )
      else
        for (final e in receiptStyles.entries)
          RadioListTile<String>(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: e.key,
            groupValue: current,
            title: Text(_t(context, e.value.$1, e.value.$2), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(e.value.$3, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            onChanged: (v) => v == null ? null : choose(v),
          ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: Text(_t(context, 'معاينة الشكل الحالي', 'Preview')),
          onPressed: () => showSmoothDialog<void>(
            context: context,
            builder: (_) => Dialog(
              child: SizedBox(
                width: 420,
                height: 620,
                child: PdfPreview(
                  build: (_) => posReceiptPdf(sampleReceiptSale(), widthMm: mm, style: current),
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
    ]);
  }
}

/// Owner: turn VAT on the invoice on/off and set its percent. Prices already include it, so the total never changes: the invoice just shows how much of it is VAT.
class _VatBox extends ConsumerStatefulWidget {
  const _VatBox({required this.canEdit});
  final bool canEdit;
  @override
  ConsumerState<_VatBox> createState() => _VatBoxState();
}

class _VatBoxState extends ConsumerState<_VatBox> {
  final _ctl = TextEditingController();
  bool _on = false;
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pct = _on ? double.tryParse(_ctl.text.trim().replaceAll(',', '.')) : 0.0;
    if (pct == null || pct < 0 || pct > 100) {
      showSnack(context, _t(context, 'اكتب نسبة من 0 إلى 100', 'Enter a percent from 0 to 100'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('receipt_vat_set', params: {'p_pct': pct});
      ref.invalidate(receiptVatProvider);
      if (mounted) showSnack(context, _t(context, 'اتحفظت الضريبة ✅', 'VAT saved ✅'));
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(receiptVatProvider).valueOrNull;
    if (v != null && !_loaded) {
      _loaded = true;
      _on = v > 0;
      _ctl.text = v > 0 ? vatPctText(v) : '14';
    }
    final pct = double.tryParse(_ctl.text.trim().replaceAll(',', '.')) ?? 0;
    final (net, vat) = vatSplit(10000, pct);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: BrandColors.border), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(_t(context, 'تطبيق الضريبة (VAT) على الفاتورة', 'Apply VAT on the invoice'), style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(_t(context, 'السعر شامل الضريبة: بتتقص من إجمالي المنتجات وبتظهر في الفاتورة، والإجمالي مابيتغيرش', 'Prices include VAT: it is taken out of the products total and shown; the total does not change'),
              style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
          value: _on,
          onChanged: widget.canEdit ? (x) => setState(() => _on = x) : null,
        ),
        if (_on)
          Row(children: [
            SizedBox(
              width: 110,
              child: TextField(
                controller: _ctl,
                enabled: widget.canEdit,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: _t(context, 'النسبة %', 'Percent %'), isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_t(context, 'مثال: 100 ج.م → صافي ${net / 100} + ضريبة ${vat / 100}', 'e.g. 100 EGP → net ${net / 100} + VAT ${vat / 100}'),
                  style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            ),
          ]),
        if (widget.canEdit)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'حفظ', 'Save'))),
            ),
          ),
      ]),
    );
  }
}

/// The invoice as a paper on the screen, in the look chosen for the shop (clean / banner / cards).
class ReceiptPaper extends ConsumerWidget {
  const ReceiptPaper({super.key, required this.sale});
  final Map<String, dynamic> sale;

  static String _egp(BuildContext c, num minor) => '${(minor / 100).toStringAsFixed(minor % 100 == 0 ? 0 : 2)} ${_t(c, 'ج.م', 'EGP')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(receiptStyleProvider).valueOrNull ?? 'clean';
    final vatPct = ref.watch(receiptVatProvider).valueOrNull ?? 0;
    final items = [for (final i in (sale['items'] as List? ?? const [])) Map<String, dynamic>.from(i as Map)];
    final discount = (sale['discount_minor'] as num?) ?? 0;
    final refunded = (sale['refunded_minor'] as num?) ?? 0;
    final tip = (sale['tip_minor'] as num?) ?? 0;
    final change = ((sale['change_minor'] as num?) ?? 0) - tip;
    final subtotal = items.fold<num>(0, (a, i) => a + ((i['line_total_minor'] as num?) ?? 0));
    final dt = DateTime.tryParse('${sale['created_at']}')?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final when = dt == null ? '' : '${dt.year}/${two(dt.month)}/${two(dt.day)}  ${two(dt.hour)}:${two(dt.minute)}';
    final brand = AppName.ar;
    final branch = '${sale['branch_name_ar'] ?? ''}';
    final cashier = '${sale['cashier_name'] ?? ''}';
    final number = '${sale['number']}';
    const navy = BrandColors.navy;
    const ink = Color(0xFF111827);
    const soft = Color(0xFFEEF2F7);
    TextStyle t(double s, {bool b = false, Color? c}) => TextStyle(fontSize: s, fontWeight: b ? FontWeight.w800 : FontWeight.w500, color: c ?? ink, height: 1.35);
    Widget kv(String k, String v, {bool b = false, double s = 13.5, Color? c}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k, style: t(s, b: b, c: c)), Text(v, style: t(s, b: b, c: c))]),
        );
    Widget ltr(String v, TextStyle st) => Text(v, textDirection: TextDirection.ltr, style: st);
    Widget dashed() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [for (var i = 0; i < 44; i++) Expanded(child: Container(height: 1.2, margin: const EdgeInsets.symmetric(horizontal: 1.2), color: i.isEven ? BrandColors.border : Colors.transparent))]),
        );
    Widget solid() => const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(height: 1.5, thickness: 1.5, color: ink));
    Widget vatRows() {
      if (vatPct <= 0) return const SizedBox.shrink();
      final (net, vat) = vatSplit(sale['total_minor'] as num, vatPct);
      return Column(children: [
        kv(_t(context, 'الصافي قبل الضريبة', 'Net before VAT'), _egp(context, net), s: 11.5, c: BrandColors.gray),
        kv(_t(context, 'ضريبة ${vatPctText(vatPct)}% (شاملة)', 'VAT ${vatPctText(vatPct)}% (incl.)'), _egp(context, vat), s: 11.5, c: BrandColors.gray),
      ]);
    }
    Widget pay() => Column(children: [
          vatRows(),
          kv(_t(context, 'المدفوع', 'Paid'), _egp(context, (sale['cash_received_minor'] as num) - tip)),
          if (change > 0) kv(_t(context, 'الباقي', 'Change'), _egp(context, change)),
          if (refunded > 0) kv(_t(context, 'مرتجع', 'Refunded'), _egp(context, refunded)),
        ]);
    Widget footer({Color? c}) => Column(children: [
          Text(_t(context, 'شكرًا لثقتكم', 'Thank you'), style: t(15, b: true, c: c)),
          Text('${_t(context, 'واتساب', 'WhatsApp')} ${AppConfig.supportPhone.replaceFirst('+20', '0')}', style: t(11.5, c: BrandColors.gray)),
          Text(_t(context, 'الاسترجاع والاستبدال بالفاتورة', 'Returns and exchanges need this invoice'), style: t(11.5, c: BrandColors.gray)),
        ]);

    List<Widget> body;
    if (style == 'banner') {
      body = [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: navy, borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            ltr(brand, t(23, b: true, c: Colors.white)),
            Text('${branch.isEmpty ? '' : '$branch · '}${_t(context, 'خدمة جوالات', 'Mobile service')}', style: t(12, c: Colors.white70)),
          ]),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_t(context, 'رقم الفاتورة', 'Invoice'), style: t(10.5, c: BrandColors.gray)), ltr(number, t(12.5, b: true))])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_t(context, 'التاريخ', 'Date'), style: t(10.5, c: BrandColors.gray)), ltr(when, t(12.5))])),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_t(context, 'الكاشير', 'Cashier'), style: t(10.5, c: BrandColors.gray)), Text(cashier.isEmpty ? '-' : cashier, style: t(12.5))])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_t(context, 'الدفع', 'Payment'), style: t(10.5, c: BrandColors.gray)), Text(_t(context, 'كاش', 'Cash'), style: t(12.5))])),
        ]),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++)
          Container(
            color: i.isEven ? soft : null,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${items[i]['quantity']}×', style: t(14, b: true, c: navy)),
              const SizedBox(width: 8),
              Expanded(child: Text('${items[i]['name_ar']}', style: t(14))),
              Text(_egp(context, items[i]['line_total_minor'] as num), style: t(14, b: true)),
            ]),
          ),
        const SizedBox(height: 6),
        if (discount > 0) ...[kv(_t(context, 'المجموع', 'Subtotal'), _egp(context, subtotal)), kv(_t(context, 'خصم', 'Discount'), '- ${_egp(context, discount)}')],
        Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: navy, borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_t(context, 'الإجمالي', 'Total'), style: t(15, b: true, c: Colors.white)),
            Text(_egp(context, sale['total_minor'] as num), style: t(23, b: true, c: Colors.white)),
          ]),
        ),
        pay(),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_t(context, 'كلّمنا على واتساب', 'Chat with us'), style: t(13, b: true)),
            ltr(AppConfig.supportPhone.replaceFirst('+20', '0'), t(12.5)),
            Text(_t(context, 'الاسترجاع والاستبدال بالفاتورة', 'Returns need this invoice'), style: t(11, c: BrandColors.gray)),
          ])),
        ]),
      ];
    } else if (style == 'cards') {
      Widget chip(String v, {bool isLtr = false}) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(20), border: Border.all(color: panelLine(context))),
            child: isLtr ? ltr(v, t(11.5)) : Text(v, style: t(11.5)),
          );
      Widget card(List<Widget> c) => Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(12), border: Border.all(color: panelLine(context))),
            child: Column(children: c),
          );
      body = [
        Center(child: ltr(brand, t(23, b: true, c: navy))),
        if (branch.isNotEmpty) Center(child: Text(branch, style: t(12, c: BrandColors.gray))),
        const SizedBox(height: 6),
        Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 4, children: [chip(number, isLtr: true), chip(when, isLtr: true), if (cashier.isNotEmpty) chip(cashier)]),
        card([
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: soft),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Container(width: 26, height: 26, alignment: Alignment.center, decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(8)), child: Text('${items[i]['quantity']}', style: t(13, b: true))),
                const SizedBox(width: 9),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${items[i]['name_ar']}', style: t(14)), Text(_egp(context, items[i]['unit_price_minor'] as num), style: t(11, c: BrandColors.gray))])),
                Text(_egp(context, items[i]['line_total_minor'] as num), style: t(14, b: true)),
              ]),
            ),
          ],
        ]),
        if (discount > 0)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(color: const Color(0xFFE7F6EE), borderRadius: BorderRadius.circular(10)),
            child: Text(_t(context, 'وفّرت ${_egp(context, discount)} في الفاتورة دي', 'You saved ${_egp(context, discount)} on this invoice'), textAlign: TextAlign.center, style: t(13, b: true, c: BrandColors.success)),
          ),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: navy, borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_t(context, 'الإجمالي', 'Total'), style: t(15, b: true, c: Colors.white)),
            Text(_egp(context, sale['total_minor'] as num), style: t(23, b: true, c: Colors.white)),
          ]),
        ),
        card([if (discount > 0) kv(_t(context, 'المجموع', 'Subtotal'), _egp(context, subtotal)), pay()]),
        const SizedBox(height: 6),
        footer(c: navy),
      ];
    } else {
      body = [
        Center(child: ltr(brand, t(26, b: true))),
        if (branch.isNotEmpty) Center(child: Text(branch, style: t(12.5, c: BrandColors.gray))),
        dashed(),
        kv(_t(context, 'فاتورة', 'Invoice'), number, b: true),
        kv(_t(context, 'التاريخ', 'Date'), when, s: 12, c: BrandColors.gray),
        if (cashier.isNotEmpty) kv(_t(context, 'الكاشير', 'Cashier'), cashier, s: 12, c: BrandColors.gray),
        dashed(),
        Row(children: [
          Expanded(child: Text(_t(context, 'الصنف', 'Item'), style: t(11, c: BrandColors.gray))),
          SizedBox(width: 34, child: Center(child: Text(_t(context, 'كمية', 'Qty'), style: t(11, c: BrandColors.gray)))),
          SizedBox(width: 80, child: Align(alignment: AlignmentDirectional.centerEnd, child: Text(_t(context, 'الإجمالي', 'Total'), style: t(11, c: BrandColors.gray)))),
        ]),
        solid(),
        for (final i in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${i['name_ar']}', style: t(14, b: true)), Text('${_egp(context, i['unit_price_minor'] as num)} ${_t(context, 'للقطعة', 'each')}', style: t(11, c: BrandColors.gray))])),
              SizedBox(width: 34, child: Center(child: Text('${i['quantity']}', style: t(14)))),
              SizedBox(width: 80, child: Align(alignment: AlignmentDirectional.centerEnd, child: Text(_egp(context, i['line_total_minor'] as num), style: t(14, b: true)))),
            ]),
          ),
        solid(),
        if (discount > 0) ...[kv(_t(context, 'المجموع', 'Subtotal'), _egp(context, subtotal)), kv(_t(context, 'خصم', 'Discount'), '- ${_egp(context, discount)}')],
        Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: kv(_t(context, 'الإجمالي', 'Total'), _egp(context, sale['total_minor'] as num), b: true, s: 20)),
        solid(),
        pay(),
        dashed(),
        footer(),
      ];
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: style == 'cards' ? const Color(0xFFF6F8FB) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrandColors.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
    );
  }
}
