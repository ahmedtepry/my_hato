import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/save_file.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/glass.dart';
import '../../shared/motion.dart';
import '../../shared/states.dart';
import 'documents.dart' show pdfFonts;
import 'pos_panel.dart' show receiptText;
import 'pos_receipt.dart';
import 'pos_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _payLabel(BuildContext c, String m) => switch (m) { 'card' => _t(c, 'فيزا', 'Card'), 'wallet' => _t(c, 'محفظة', 'Wallet'), 'split' => _t(c, 'مقسّم', 'Split'), _ => _t(c, 'كاش', 'Cash') };
String _when(Object? iso) => iso == null ? '—' : DateFormat('d/M/yyyy  HH:mm').format(DateTime.parse('$iso').toLocal());

/// "All invoices" for the cashier: paid, cancelled and held, for his own branch only. The database decides who may open it
/// (the "invoices.view" right) and which branch he sees; the app only shows what comes back.
class InvoicesPanel extends ConsumerStatefulWidget {
  const InvoicesPanel({super.key});
  @override
  ConsumerState<InvoicesPanel> createState() => _InvoicesPanelState();
}

class _InvoicesPanelState extends ConsumerState<InvoicesPanel> {
  String _tab = 'paid'; // paid | cancelled | held
  String _range = 'today'; // today | week | month | all
  final _q = TextEditingController();
  Future<List<Map<String, dynamic>>>? _list;
  Future<List<Map<String, dynamic>>>? _held;
  ThemeData? _base; // the normal theme: dialogs keep it even when the page itself is dark glass

  Future<T?> _dlg<T>(WidgetBuilder b) => showSmoothDialog<T>(context: context, builder: (c) => Theme(data: _base ?? Theme.of(c), child: Builder(builder: b)));

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  (DateTime?, DateTime?) get _span {
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    switch (_range) {
      case 'today':
        return (d0, d0.add(const Duration(days: 1)));
      case 'week':
        return (d0.subtract(const Duration(days: 6)), d0.add(const Duration(days: 1)));
      case 'month':
        return (d0.subtract(const Duration(days: 29)), d0.add(const Duration(days: 1)));
      default:
        return (null, null);
    }
  }

  Future<List<Map<String, dynamic>>> _fetch(String status) async {
    final (from, to) = _span;
    final r = await ref.read(supabaseProvider).rpc('pos_invoices_list', params: {
      'p_status': status,
      'p_from': from?.toUtc().toIso8601String(),
      'p_to': to?.toUtc().toIso8601String(),
      'p_q': _q.text.trim().isEmpty ? null : _q.text.trim(),
      'p_limit': 500,
    });
    return [for (final e in (r as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
  }

  Future<List<Map<String, dynamic>>> _loadHeld() async {
    // held invoices live on this computer only, per shift (see the cashier screen)
    final shift = await ref.read(posRepoProvider).currentShift();
    if (shift == null) return const [];
    final raw = (await SharedPreferences.getInstance()).getString('pos_drafts_${shift['id']}');
    if (raw == null) return const [];
    final out = <Map<String, dynamic>>[];
    for (final j in (jsonDecode(raw) as List)) {
      final m = Map<String, dynamic>.from(j as Map);
      final lines = [for (final l in (m['lines'] as List)) Map<String, dynamic>.from(l as Map)];
      var total = 0;
      var count = 0;
      for (final l in lines) {
        final q = (l['q'] as num).toInt();
        total += q * ((l['p'] as Map)['price_minor'] as num).toInt();
        count += q;
      }
      out.add({'at': m['at'], 'lines': lines, 'total_minor': total, 'count': count});
    }
    out.sort((a, b) => '${b['at']}'.compareTo('${a['at']}'));
    return out;
  }

  void _reload() {
    setState(() {
      if (_tab == 'held') {
        _held = _loadHeld();
      } else {
        _list = _fetch(_tab);
      }
    });
  }

  Future<void> _open(Map<String, dynamic> row) => _dlg<void>((_) => _InvoiceDialog(id: '${row['id']}'));

  /// The whole history for the chosen period (paid and cancelled together) as a printable / savable PDF.
  Future<void> _history({required bool print}) async {
    try {
      final rows = await _fetch('all');
      if (!mounted) return;
      final ar = context.isAr;
      final bytes = await _historyPdf(rows, ar: ar, range: _rangeLabel(context, _range));
      if (!mounted) return;
      if (print) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'invoices-history', format: PdfPageFormat.a4);
      } else {
        await deliverFile(context, bytes, 'invoices-history.pdf', 'application/pdf');
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  static String _rangeLabel(BuildContext c, String r) => switch (r) {
        'today' => _t(c, 'النهارده', 'Today'),
        'week' => _t(c, 'آخر 7 أيام', 'Last 7 days'),
        'month' => _t(c, 'آخر 30 يوم', 'Last 30 days'),
        _ => _t(c, 'الكل', 'All'),
      };

  Color get _muted => _glass ? Colors.white60 : BrandColors.gray;
  bool _glass = false;

  @override
  Widget build(BuildContext context) {
    _base ??= Theme.of(context);
    _glass = ref.watch(glassLookProvider);
    return _page(context);
  }

  Widget _page(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
        Expanded(child: SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'paid', icon: const Icon(Icons.check_circle_outline), label: Text(_t(context, 'المدفوعة', 'Paid'))),
            ButtonSegment(value: 'cancelled', icon: const Icon(Icons.cancel_outlined), label: Text(_t(context, 'الملغية', 'Cancelled'))),
            ButtonSegment(value: 'held', icon: const Icon(Icons.pause_circle_outline), label: Text(_t(context, 'المعلّقة', 'Held'))),
          ],
          selected: {_tab},
          onSelectionChanged: (v) {
            _tab = v.first;
            _reload();
          },
        )),
        IconButton(tooltip: _t(context, 'طباعة سجل الفواتير', 'Print invoices history'), icon: const Icon(Icons.print_rounded), onPressed: () => _history(print: true)),
        IconButton(tooltip: _t(context, 'حفظ سجل الفواتير PDF', 'Save invoices history as PDF'), icon: const Icon(Icons.picture_as_pdf_rounded), onPressed: () => _history(print: false)),
        ]),
        const SizedBox(height: 10),
        if (_tab != 'held')
          Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _reload(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: _t(context, 'ابحث برقم الفاتورة', 'Search by invoice number'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _q.text.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () { _q.clear(); _reload(); }),
                ),
              ),
            ),
            const SizedBox(width: 10),
            for (final r in const ['today', 'week', 'month', 'all'])
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6),
                child: ChoiceChip(label: Text(_rangeLabel(context, r)), selected: _range == r, onSelected: (_) { _range = r; _reload(); }),
              ),
          ]),
        const SizedBox(height: 10),
        Expanded(child: _tab == 'held' ? _heldBody() : _listBody()),
      ]),
    );
  }

  Widget _card(Widget child) => DecoratedBox(
        decoration: BoxDecoration(
          color: _glass ? Colors.white.withValues(alpha: .07) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _glass ? Colors.white12 : BrandColors.border),
        ),
        child: child,
      );

  Widget _listBody() => FutureBuilder<List<Map<String, dynamic>>>(
        future: _list,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return Center(child: Text(friendlyError(context, snap.error!)));
          final rows = snap.data ?? const [];
          if (rows.isEmpty) return Center(child: Text(_t(context, 'مفيش فواتير', 'No invoices'), style: TextStyle(color: _muted)));
          final sum = rows.fold<int>(0, (a, r) => a + (r['total_minor'] as num).toInt());
          return Column(children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${rows.length} ${_t(context, 'فاتورة', 'invoices')} · ${_money(context, sum)}', style: TextStyle(color: _muted, fontWeight: FontWeight.w700)),
              ),
            ),
            Expanded(
              child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final partial = (r['refunded_minor'] as num) > 0 && r['status'] != 'cancelled';
                  return _card(ListTile(
                    onTap: () => _open(r),
                    leading: Icon(r['status'] == 'cancelled' ? Icons.cancel_outlined : Icons.receipt_long_rounded, color: r['status'] == 'cancelled' ? Colors.redAccent : BrandColors.electric),
                    title: Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: .5)),
                    subtitle: Text('${_t(context, 'البائع', 'Seller')}: ${r['seller_code'] ?? '—'}${r['seller_name'] == null ? '' : ' · ${r['seller_name']}'}\n${_when(r['created_at'])}  ·  ${_payLabel(context, '${r['payment_method']}')}${partial ? '  ·  ${_t(context, 'مرتجع جزئي', 'Partly refunded')}' : ''}'),
                    isThreeLine: true,
                    trailing: Text(_money(context, r['total_minor'] as num), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  ));
                },
              ),
            ),
          ]);
        },
      );

  Widget _heldBody() => FutureBuilder<List<Map<String, dynamic>>>(
        future: _held,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          final rows = snap.data ?? const [];
          if (rows.isEmpty) return Center(child: Text(_t(context, 'مفيش فواتير معلّقة', 'No held invoices'), style: TextStyle(color: _muted)));
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final r = rows[i];
              return _card(ListTile(
                leading: const Icon(Icons.pause_circle_outline, color: Colors.orange),
                title: Text('${_t(context, 'فاتورة معلّقة', 'Held invoice')} · ${r['count']} ${_t(context, 'قطعة', 'items')}', style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(_when(r['at'])),
                trailing: Text(_money(context, r['total_minor'] as num), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                onTap: () => _dlg<void>(
                  (_) => AlertDialog(
                    title: Text(_t(context, 'فاتورة معلّقة', 'Held invoice')),
                    content: SizedBox(
                      width: 380,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final l in (r['lines'] as List))
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${((l as Map)['p'] as Map)['name_ar'] ?? ((l['p'] as Map)['name_en'] ?? '')}'),
                            trailing: Text('× ${l['q']}'),
                          ),
                        const Divider(),
                        Text('${_t(context, 'الإجمالي', 'Total')}: ${_money(context, r['total_minor'] as num)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Text(_t(context, 'كمّلها من شاشة الكاشير (شريط "معلّقة").', 'Resume it from the cashier screen ("Held" bar).'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                      ]),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إغلاق', 'Close')))],
                  ),
                ),
              ));
            },
          );
        },
      );
}

/// One invoice: items, totals, seller, time — with print / PDF / WhatsApp.
class _InvoiceDialog extends ConsumerStatefulWidget {
  const _InvoiceDialog({required this.id});
  final String id;
  @override
  ConsumerState<_InvoiceDialog> createState() => _InvoiceDialogState();
}

class _InvoiceDialogState extends ConsumerState<_InvoiceDialog> {
  late Future<Map<String, dynamic>> _f = _load();
  Future<Map<String, dynamic>> _load() => ref.read(supabaseProvider).rpc('pos_invoice_detail', params: {'p_sale': widget.id}).then((r) => Map<String, dynamic>.from(r as Map));

  /// Fixes a wrong payment method while the shift is still open (the drawer / branch accounts follow it automatically).
  Future<void> _changePayment(Map<String, dynamic> s) async {
    final cur = '${s['payment_method']}';
    var pick = cur;
    final reason = TextEditingController();
    final total = (s['total_minor'] as num).toInt();
    String egp(Object? v) {
      final n = ((v as num?) ?? 0).toInt();
      return n == 0 ? '' : (n / 100).toStringAsFixed(n % 100 == 0 ? 0 : 2);
    }
    final kCtl = TextEditingController(text: cur == 'split' ? egp(s['paid_card_minor']) : '');
    final wCtl = TextEditingController(text: cur == 'split' ? egp(s['paid_wallet_minor']) : '');
    int part(TextEditingController c) => parseEgpToMinor(c.text.trim().isEmpty ? '0' : c.text) ?? -1;
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(_t(ctx, 'تغيير وسيلة الدفع', 'Change payment method')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${s['number']} · ${_money(ctx, s['total_minor'] as num)}', style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'cash', icon: const Icon(Icons.payments_outlined), label: Text(_t(ctx, 'كاش', 'Cash'))),
                ButtonSegment(value: 'card', icon: const Icon(Icons.credit_card), label: Text(_t(ctx, 'فيزا', 'Card'))),
                ButtonSegment(value: 'wallet', icon: const Icon(Icons.account_balance_wallet_outlined), label: Text(_t(ctx, 'محفظة', 'Wallet'))),
                ButtonSegment(value: 'split', icon: const Icon(Icons.call_split_rounded), label: Text(_t(ctx, 'مقسّم', 'Split'))),
              ],
              selected: {pick},
              onSelectionChanged: (v) => set(() => pick = v.first),
            ),
            if (pick == 'split') ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: kCtl, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => set(() {}), decoration: InputDecoration(isDense: true, labelText: _t(ctx, 'فيزا (ج.م)', 'Visa (EGP)')))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: wCtl, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => set(() {}), decoration: InputDecoration(isDense: true, labelText: _t(ctx, 'محفظة (ج.م)', 'Wallet (EGP)')))),
              ]),
              const SizedBox(height: 6),
              Builder(builder: (_) {
                final k = part(kCtl), w = part(wCtl), c = total - k - w;
                final bad = k < 0 || w < 0 || c < 0;
                return Text(bad ? _t(ctx, 'الفيزا والمحفظة أكبر من الإجمالي', 'Visa + wallet is more than the total') : '${_t(ctx, 'الباقي كاش', 'Cash part')}: ${_money(ctx, c)}',
                    style: TextStyle(fontWeight: FontWeight.w800, color: bad ? BrandColors.error : null));
              }),
            ],
            const SizedBox(height: 10),
            TextField(controller: reason, maxLength: 200, decoration: InputDecoration(labelText: _t(ctx, 'السبب (اختياري)', 'Reason (optional)'))),
            Text(_t(ctx, 'الدرج وحسابات الفرع بيتظبطوا لوحدهم. التعديل مسموح لحد قفل الوردية بس، وكل تعديل بيتسجّل.', 'The drawer and branch accounts follow automatically. Allowed until the shift is closed; every change is logged.'),
                style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'رجوع', 'Back'))),
            FilledButton(
                onPressed: (pick == cur && pick != 'split') || (pick == 'split' && (part(kCtl) < 0 || part(wCtl) < 0 || total - part(kCtl) - part(wCtl) < 0))
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: Text(_t(ctx, 'حفظ', 'Save'))),
          ],
        ),
      ),
    );
    final why = reason.text.trim();
    final k = part(kCtl), w = part(wCtl);
    disposeLater(reason);
    disposeLater(kCtl);
    disposeLater(wCtl);
    if (ok != true || !mounted) return;
    try {
      if (pick == 'split') {
        await ref.read(posRepoProvider).setSaleSplit('${s['id']}', cash: total - k - w, card: k, wallet: w, reason: why.isEmpty ? null : why);
      } else {
        await ref.read(posRepoProvider).setSalePayment('${s['id']}', pick, reason: why.isEmpty ? null : why);
      }
      if (!mounted) return;
      setState(() => _f = _load());
      showSnack(context, _t(context, 'اتغيّرت وسيلة الدفع ✅', 'Payment method changed ✅'));
    } catch (e) {
      if (mounted) showSnack(context, posErrorText(e, context.isAr, (x) => friendlyError(context, x)), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_t(context, 'تفاصيل الفاتورة', 'Invoice details')),
      content: SizedBox(
        width: 460,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _f,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
            if (snap.hasError) return Text(friendlyError(context, snap.error!));
            final s = snap.data!;
            final items = [for (final i in (s['items'] as List? ?? const [])) Map<String, dynamic>.from(i as Map)];
            Widget row(String k, String v, {bool bold = false}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [Expanded(child: Text(k, style: const TextStyle(color: BrandColors.gray))), Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600))]),
                );
            return SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${s['number']}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 1)),
                if (s['cancelled'] == true)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text(_t(context, 'فاتورة ملغية (اترجّعت بالكامل)', 'Cancelled (fully refunded)'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800))),
                const SizedBox(height: 8),
                row(_t(context, 'رقم البائع', 'Seller no.'), '${s['seller_code'] ?? '—'}'),
                row(_t(context, 'اسم البائع', 'Seller'), '${s['cashier_name'] ?? '—'}'),
                row(_t(context, 'الفرع', 'Branch'), '${s['branch_name_ar'] ?? '—'}'),
                row(_t(context, 'وقت البيع', 'Sold at'), _when(s['created_at'])),
                row(_t(context, 'وسيلة الدفع', 'Paid by'), _payLabel(context, '${s['payment_method']}')),
                if (s['payment_method'] == 'split') ...[
                  if (((s['paid_cash_minor'] as num?) ?? 0) > 0) row('   ${_t(context, 'كاش', 'Cash')}', _money(context, s['paid_cash_minor'] as num)),
                  if (((s['paid_card_minor'] as num?) ?? 0) > 0) row('   ${_t(context, 'فيزا', 'Visa')}', _money(context, s['paid_card_minor'] as num)),
                  if (((s['paid_wallet_minor'] as num?) ?? 0) > 0) row('   ${_t(context, 'محفظة', 'Wallet')}', _money(context, s['paid_wallet_minor'] as num)),
                ],
                if (s['can_edit_payment'] == true)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(icon: const Icon(Icons.edit_outlined, size: 18), label: Text(_t(context, 'تغيير وسيلة الدفع', 'Change payment method')), onPressed: () => _changePayment(s)),
                  ),
                const Divider(),
                for (final i in items)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${i['name_ar']}'),
                    subtitle: Text('${i['quantity']} × ${_money(context, i['unit_price_minor'] as num)}${(i['refunded_qty'] as num) > 0 ? '  ·  ${_t(context, 'اترجّع', 'Refunded')} ${i['refunded_qty']}' : ''}'),
                    trailing: Text(_money(context, i['line_total_minor'] as num), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                const Divider(),
                row(_t(context, 'المجموع', 'Subtotal'), _money(context, s['subtotal_minor'] as num)),
                if ((s['discount_minor'] as num) > 0) row(_t(context, 'الخصم', 'Discount'), '- ${_money(context, s['discount_minor'] as num)}'),
                row(_t(context, 'الإجمالي', 'Total'), _money(context, s['total_minor'] as num), bold: true),
                if ((s['refunded_minor'] as num) > 0) row(_t(context, 'المرتجع', 'Refunded'), _money(context, s['refunded_minor'] as num)),
                for (final r in (s['refunds'] as List? ?? const []))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${_when((r as Map)['at'])} · ${_money(context, r['amount_minor'] as num)} · ${switch ('${r['method']}') { 'card' => _t(context, 'فيزا', 'Card'), 'wallet' => _t(context, 'محفظة', 'Wallet'), _ => _t(context, 'كاش', 'Cash') }}\n${_t(context, 'السبب', 'Reason')}: ${r['reason']}',
                        style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                  ),
                const SizedBox(height: 10),
                ReceiptButtons(sale: s, text: receiptText(context, s)),
              ]),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إغلاق', 'Close')))],
    );
  }
}

Future<Uint8List> _historyPdf(List<Map<String, dynamic>> rows, {required bool ar, required String range}) async {
  final (regular, bold) = await pdfFonts();
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
  String t(String a, String e) => ar ? a : e;
  String m(num v) => formatEgp(v.round(), ar ? 'ar' : 'en');
  final paid = rows.where((r) => r['status'] != 'cancelled').toList();
  final cancelled = rows.where((r) => r['status'] == 'cancelled').toList();
  final paidSum = paid.fold<int>(0, (a, r) => a + (r['total_minor'] as num).toInt() - (r['refunded_minor'] as num).toInt());
  const blue = PdfColor.fromInt(0xFF1F5BFF);
  final branch = rows.isEmpty ? '' : '${rows.first['branch_name_ar'] ?? ''}';
  doc.addPage(pw.MultiPage(
    pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4, textDirection: ar ? pw.TextDirection.rtl : pw.TextDirection.ltr, margin: const pw.EdgeInsets.all(24), theme: pw.ThemeData.withFont(base: regular, bold: bold)),
    footer: (c) => pw.Align(alignment: pw.Alignment.center, child: pw.Text('${t('صفحة', 'Page')} ${c.pageNumber} / ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700))),
    build: (_) => [
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: const pw.BoxDecoration(color: blue, borderRadius: pw.BorderRadius.all(pw.Radius.circular(8))),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(t('سجل فواتير المبيعات', 'Sales invoices history'), style: pw.TextStyle(font: bold, fontSize: 17, color: PdfColors.white)),
          pw.Text('My Hatō', style: pw.TextStyle(font: bold, fontSize: 15, color: PdfColors.white), textDirection: pw.TextDirection.ltr),
        ]),
      ),
      pw.SizedBox(height: 8),
      pw.Text('${t('الفرع', 'Branch')}: $branch   ·   ${t('الفترة', 'Period')}: $range   ·   ${t('تاريخ الطباعة', 'Printed')}: ${_when(DateTime.now().toIso8601String())}', style: const pw.TextStyle(fontSize: 9)),
      pw.Text('${t('مدفوعة', 'Paid')}: ${paid.length}  (${m(paidSum)})   ·   ${t('ملغية', 'Cancelled')}: ${cancelled.length}', style: pw.TextStyle(font: bold, fontSize: 10)),
      pw.SizedBox(height: 8),
      pw.TableHelper.fromTextArray(
        headers: [t('رقم الفاتورة', 'Invoice'), t('رقم البائع', 'Seller no.'), t('البائع', 'Seller'), t('القيمة', 'Amount'), t('الحالة', 'Status'), t('الوقت', 'Time')],
        data: [
          for (final r in rows)
            [
              '${r['number']}',
              '${r['seller_code'] ?? ''}',
              '${r['seller_name'] ?? ''}',
              m(r['total_minor'] as num),
              r['status'] == 'cancelled' ? t('ملغية', 'Cancelled') : ((r['refunded_minor'] as num) > 0 ? t('مرتجع جزئي', 'Partly refunded') : t('مدفوعة', 'Paid')),
              _when(r['created_at']),
            ],
        ],
        headerStyle: pw.TextStyle(font: bold, color: PdfColors.white, fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: blue),
        cellStyle: const pw.TextStyle(fontSize: 8.5),
        cellAlignment: ar ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      ),
    ],
  ));
  return doc.save();
}
