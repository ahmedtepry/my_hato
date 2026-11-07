// "اختصارات": four quick jobs, each shown only to the people who hold its permission.
//   استلام بضاعة (shortcut.goods_receipt) · جرد (shortcut.stocktake) · تعديل الأسعار (shortcut.price_edit) · تصدير البيانات (shortcut.export)
import 'dart:typed_data';
import '../../shared/motion.dart';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/save_file.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart' show staffContextProvider;
import 'app_banners_panel.dart';

List<Map<String, dynamic>> _maps(Object? v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(Object? minor) {
  final v = ((minor as num?) ?? 0) / 100;
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

String _err(BuildContext c, Object e) {
  final t = '$e';
  final ar = c.isAr;
  if (t.contains('FORBIDDEN')) return ar ? 'مش مسموحلك بالخطوة دي (أو الفرع ده مش فرعك).' : 'You are not allowed to do this here.';
  if (t.contains('INVALID_COMPARE')) return ar ? 'السعر قبل الخصم لازم يكون أعلى من السعر.' : 'The old price must be higher than the price.';
  if (t.contains('INVALID_INPUT')) return ar ? 'في رقم أو بيان مش مظبوط، راجع وجرب تاني.' : 'Something is not valid, check and try again.';
  return friendlyError(c, e);
}

final _branchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('staff_my_branches')).where((b) => b['is_hq'] != true).toList());
final _receiptsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('goods_receipts_list')));
final _stocktakesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('stocktakes_list')));
final _priceLogProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('price_changes_list')));

class ShortcutsPanel extends ConsumerWidget {
  const ShortcutsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>[];
    bool has(String p) => perms.contains(p);
    Widget card(IconData icon, Color color, String ar, String en, String subAr, String subEn, VoidCallback onTap) => Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: CircleAvatar(backgroundColor: color.withValues(alpha: .12), child: Icon(icon, color: color)),
            title: Text(_t(context, ar, en), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(_t(context, subAr, subEn)),
            trailing: const Icon(Icons.chevron_left_rounded),
            onTap: onTap,
          ),
        );
    Future<void> open(Widget sheet) =>
        showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, showDragHandle: true, builder: (_) => sheet);
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (has('shortcut.goods_receipt'))
        card(Icons.move_to_inbox_rounded, const Color(0xFF0E9384), 'استلام بضاعة من المورد', 'Receive goods', 'سجّل بضاعة وصلت وزوّد بيها المخزن', 'Record goods that arrived and add them to stock',
            () => open(const _ReceiptSheet())),
      if (has('shortcut.stocktake'))
        card(Icons.fact_check_rounded, const Color(0xFF6938EF), 'جرد المخزن', 'Stocktake', 'عدّ اللي في الفرع فعلًا وصحّح الأرقام', 'Count what the branch really holds and fix the numbers',
            () => open(const _StocktakeSheet())),
      if (has('shortcut.price_edit'))
        card(Icons.sell_rounded, const Color(0xFFDC6803), 'تعديل الأسعار', 'Edit prices', 'غيّر سعر البيع بسرعة، وكل تغيير بيتسجل', 'Change the selling price fast, every change is logged',
            () => open(const _PriceSheet())),
      if (has('shortcut.export'))
        card(Icons.download_rounded, const Color(0xFF1570EF), 'تصدير البيانات', 'Export data', 'نزّل المنتجات والمبيعات والطلبات والعملاء كملف إكسل',
            'Download products, sales, orders and customers as an Excel file', () => open(const _ExportSheet())),
      if (has('banners.manage'))
        card(Icons.view_carousel_rounded, const Color(0xFF00A3FF), 'بانرات التطبيق', 'App banners', 'أضف وعدّل البانرات اللي بتظهر للعملا', 'Add and edit the banners customers see',
            () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(appBar: AppBar(title: Text(_t(context, 'بانرات التطبيق', 'App banners'))), body: const AppBannersPanel())))),
      const SizedBox(height: 8),
      if (has('shortcut.goods_receipt')) const _Log(title: ('آخر الاستلامات', 'Recent receipts'), kind: _LogKind.receipts),
      if (has('shortcut.stocktake')) const _Log(title: ('آخر الجرد', 'Recent stocktakes'), kind: _LogKind.stocktakes),
      if (has('shortcut.price_edit')) const _Log(title: ('آخر تغييرات الأسعار', 'Recent price changes'), kind: _LogKind.prices),
    ]);
  }
}

enum _LogKind { receipts, stocktakes, prices }

class _Log extends ConsumerWidget {
  const _Log({required this.title, required this.kind});
  final (String, String) title;
  final _LogKind kind;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = switch (kind) {
      _LogKind.receipts => ref.watch(_receiptsProvider),
      _LogKind.stocktakes => ref.watch(_stocktakesProvider),
      _LogKind.prices => ref.watch(_priceLogProvider),
    };
    final rows = async.valueOrNull ?? const <Map<String, dynamic>>[];
    String date(Object? v) {
      final d = DateTime.tryParse('$v')?.toLocal();
      return d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        title: Text(_t(context, title.$1, title.$2)),
        subtitle: Text(rows.isEmpty ? _t(context, 'لسه مفيش', 'Nothing yet') : '${rows.length}'),
        children: [
          for (final r in rows)
            switch (kind) {
              _LogKind.receipts => ListTile(
                  dense: true,
                  title: Text('${r['number']} · ${r['supplier']}'),
                  subtitle: Text('${r['branch_name'] ?? _t(context, 'الوير هاوس', 'Warehouse')} · ${r['created_by_name']} · ${date(r['created_at'])}\n'
                      '${_maps(r['items']).map((i) => '${i['name_ar']} × ${i['qty']}').join('، ')}'),
                  isThreeLine: true,
                ),
              _LogKind.stocktakes => ListTile(
                  dense: true,
                  title: Text('${r['number']} · ${r['branch_name']}'),
                  subtitle: Text('${r['created_by_name']} · ${date(r['created_at'])}\n'
                      '${_t(context, 'صافي الفرق', 'Net difference')}: ${r['diff_pieces']}'
                      '${_maps(r['differences']).isEmpty ? '' : '\n${_maps(r['differences']).map((i) => '${i['name_ar']}: ${i['expected']}→${i['counted']}').join('، ')}'}'),
                  isThreeLine: true,
                ),
              _LogKind.prices => ListTile(
                  dense: true,
                  title: Text('${r['name_ar']}'),
                  subtitle: Text('${_money(r['old_price_minor'])} → ${_money(r['new_price_minor'])} · ${r['changed_by_name']} · ${date(r['changed_at'])}'),
                ),
            },
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- shared pieces
/// A search box + results; [builder] draws one result row.
class _ProductSearch extends ConsumerStatefulWidget {
  const _ProductSearch({super.key, required this.branch, required this.builder, this.onResults});
  final String? branch;
  final Widget Function(BuildContext, Map<String, dynamic>) builder;
  final void Function(List<Map<String, dynamic>>)? onResults;
  @override
  ConsumerState<_ProductSearch> createState() => _ProductSearchState();
}

class _ProductSearchState extends ConsumerState<_ProductSearch> {
  List<Map<String, dynamic>> _rows = const [];
  String _q = '';
  int _seq = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ProductSearch old) {
    super.didUpdateWidget(old);
    if (old.branch != widget.branch) _load();
  }

  Future<void> _load() async {
    final my = ++_seq;
    setState(() => _loading = true);
    try {
      final r = _maps(await ref.read(supabaseProvider).rpc('shortcut_products', params: {'p_search': _q.isEmpty ? null : _q, 'p_branch': widget.branch}));
      if (!mounted || my != _seq) return;
      setState(() {
        _rows = r;
        _loading = false;
      });
      widget.onResults?.call(r);
    } catch (e) {
      if (!mounted || my != _seq) return;
      setState(() => _loading = false);
      showSnack(context, _err(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        TextField(
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: _t(context, 'دوّر على منتج أو كود', 'Search a product or SKU'), isDense: true, border: const OutlineInputBorder()),
          onChanged: (v) {
            _q = v.trim();
            _load();
          },
        ),
        const SizedBox(height: 6),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        for (final r in _rows) widget.builder(context, r),
        if (!_loading && _rows.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(_t(context, 'مفيش منتجات بالاسم ده', 'No products found'))),
      ]);
}

Widget _sheetFrame(BuildContext context, String title, List<Widget> children, {Widget? bottom}) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: children)),
        if (bottom != null) SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: bottom)),
      ]),
    );

Widget _branchPicker(BuildContext context, List<Map<String, dynamic>> branches, String? value, ValueChanged<String?> onChanged, {Map<String, String>? extra}) {
  return DropdownButtonFormField<String?>(
    value: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: _t(context, 'الفرع', 'Branch'), border: const OutlineInputBorder(), isDense: true),
    items: [
      if (extra != null) DropdownMenuItem<String?>(value: '', child: Text(_t(context, extra['ar']!, extra['en']!))),
      for (final b in branches) DropdownMenuItem<String?>(value: '${b['id']}', child: Text(_t(context, '${b['name_ar']}', '${b['name_en']}'))),
    ],
    onChanged: onChanged,
  );
}

// ---------------------------------------------------------------- 1) goods receipt
class _ReceiptSheet extends ConsumerStatefulWidget {
  const _ReceiptSheet();
  @override
  ConsumerState<_ReceiptSheet> createState() => _ReceiptSheetState();
}

class _ReceiptSheetState extends ConsumerState<_ReceiptSheet> {
  final _supplier = TextEditingController();
  final _note = TextEditingController();
  String? _branch; // '' = main warehouse
  final _lines = <String, ({Map<String, dynamic> p, TextEditingController qty, TextEditingController cost})>{};
  bool _busy = false;

  @override
  void dispose() {
    _supplier.dispose();
    _note.dispose();
    for (final l in _lines.values) {
      l.qty.dispose();
      l.cost.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final items = <Map<String, dynamic>>[];
    for (final l in _lines.values) {
      final q = int.tryParse(l.qty.text.trim());
      if (q == null || q < 1) {
        showSnack(context, _t(context, 'اكتب كمية صحيحة لكل منتج', 'Enter a valid quantity for every product'), error: true);
        return;
      }
      final c = double.tryParse(l.cost.text.trim());
      items.add({'product_id': l.p['product_id'], 'qty': q, if (c != null) 'cost_minor': (c * 100).round()});
    }
    if (_supplier.text.trim().isEmpty) {
      showSnack(context, _t(context, 'اكتب اسم المورد', 'Enter the supplier name'), error: true);
      return;
    }
    if (items.isEmpty) {
      showSnack(context, _t(context, 'ضيف منتج واحد على الأقل', 'Add at least one product'), error: true);
      return;
    }
    if (_branch == null) {
      showSnack(context, _t(context, 'اختار الفرع', 'Pick the branch'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await ref.read(supabaseProvider).rpc('goods_receipt_create', params: {
        'p_supplier': _supplier.text.trim(),
        'p_branch': _branch == '' ? null : _branch,
        'p_items': items,
        'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      });
      ref.invalidate(_receiptsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, _t(context, 'اتسجل الاستلام $n', 'Receipt $n recorded'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>[];
    final branches = ref.watch(_branchesProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    final canWarehouse = perms.contains('stock.allocate');
    final canCost = perms.contains('cost.manage');
    if (_branch == null && branches.length == 1 && !canWarehouse) _branch = '${branches.first['id']}';
    return _sheetFrame(
      context,
      _t(context, 'استلام بضاعة من المورد', 'Receive goods from a supplier'),
      [
        TextField(controller: _supplier, decoration: InputDecoration(labelText: _t(context, 'اسم المورد', 'Supplier'), border: const OutlineInputBorder(), isDense: true)),
        const SizedBox(height: 10),
        _branchPicker(context, branches, _branch, (v) => setState(() => _branch = v), extra: canWarehouse ? {'ar': 'الوير هاوس (غير موزّع)', 'en': 'Warehouse (unallocated)'} : null),
        const SizedBox(height: 10),
        TextField(controller: _note, decoration: InputDecoration(labelText: _t(context, 'ملاحظة (اختياري)', 'Note (optional)'), border: const OutlineInputBorder(), isDense: true)),
        const SizedBox(height: 14),
        if (_lines.isNotEmpty) Text(_t(context, 'اللي وصل', 'Received'), style: const TextStyle(fontWeight: FontWeight.w700)),
        for (final e in _lines.entries)
          Card(
            margin: const EdgeInsets.only(top: 6),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Expanded(child: Text('${e.value.p['name_ar']}\n${e.value.p['sku'] ?? ''}', style: const TextStyle(fontSize: 13))),
                SizedBox(
                  width: 70,
                  child: TextField(
                    controller: e.value.qty,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(labelText: _t(context, 'العدد', 'Qty'), isDense: true, border: const OutlineInputBorder()),
                  ),
                ),
                if (canCost) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: e.value.cost,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: _t(context, 'التكلفة', 'Cost'), isDense: true, border: const OutlineInputBorder()),
                    ),
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() {
                    final l = _lines.remove(e.key);
                    l?.qty.dispose();
                    l?.cost.dispose();
                  }),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 14),
        Text(_t(context, 'ضيف منتج', 'Add a product'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        _ProductSearch(
          branch: null,
          builder: (c, p) {
            final id = '${p['product_id']}';
            final added = _lines.containsKey(id);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${p['name_ar']}'),
              subtitle: Text('${p['sku'] ?? ''} · ${_t(c, 'الرصيد', 'Stock')} ${p['total']}'),
              trailing: added ? const Icon(Icons.check_circle, color: BrandColors.success) : const Icon(Icons.add_circle_outline),
              onTap: added ? null : () => setState(() => _lines[id] = (p: p, qty: TextEditingController(), cost: TextEditingController())),
            );
          },
        ),
      ],
      bottom: FilledButton.icon(
        onPressed: _busy ? null : _save,
        icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_rounded),
        label: Text(_t(context, 'سجّل الاستلام', 'Record the receipt')),
      ),
    );
  }
}

// ---------------------------------------------------------------- 2) stocktake
class _StocktakeSheet extends ConsumerStatefulWidget {
  const _StocktakeSheet();
  @override
  ConsumerState<_StocktakeSheet> createState() => _StocktakeSheetState();
}

class _StocktakeSheetState extends ConsumerState<_StocktakeSheet> {
  String? _branch;
  final _counts = <String, TextEditingController>{};
  final _names = <String, String>{};
  final _expected = <String, int>{};
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _counts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final items = <Map<String, dynamic>>[];
    for (final e in _counts.entries) {
      final t = e.value.text.trim();
      if (t.isEmpty) continue;
      final n = int.tryParse(t);
      if (n == null || n < 0) {
        showSnack(context, _t(context, 'في رقم مش صحيح في ${_names[e.key]}', 'Invalid number for ${_names[e.key]}'), error: true);
        return;
      }
      items.add({'product_id': e.key, 'counted': n});
    }
    if (_branch == null || items.isEmpty) {
      showSnack(context, _t(context, 'اختار الفرع واكتب عدّ منتج واحد على الأقل', 'Pick the branch and count at least one product'), error: true);
      return;
    }
    final diffs = [for (final i in items) if (_expected[i['product_id']] != i['counted']) i];
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'تأكيد الجرد', 'Confirm the stocktake')),
        content: Text(_t(d, 'هيتصحّح رصيد ${items.length} منتج، منهم ${diffs.length} فيهم فرق. الخطوة دي بتغيّر أرصدة المخزن وبتتسجل.',
            '${items.length} products will be set to your count, ${diffs.length} of them differ. This changes the stock and is logged.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'رجوع', 'Back'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'اعتمد الجرد', 'Apply'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('stocktake_apply', params: {'p_branch': _branch, 'p_items': items}) as Map);
      ref.invalidate(_stocktakesProvider);
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, _t(context, 'اتسجل الجرد ${r['number']}: ${r['changed']} منتج اتصحّح', 'Stocktake ${r['number']} saved: ${r['changed']} products corrected'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final branches = ref.watch(_branchesProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    if (_branch == null && branches.length == 1) _branch = '${branches.first['id']}';
    return _sheetFrame(
      context,
      _t(context, 'جرد المخزن', 'Stocktake'),
      [
        _branchPicker(context, branches, _branch, (v) => setState(() {
              _branch = v;
              for (final c in _counts.values) {
                c.dispose();
              }
              _counts.clear();
              _expected.clear();
            })),
        const SizedBox(height: 6),
        Text(_t(context, 'اكتب العدد اللي عديته فعلًا. المنتج اللي تسيبه فاضي مش هيتغيّر.', 'Type what you really counted. A product left empty is not touched.'),
            style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
        const SizedBox(height: 8),
        if (_branch == null)
          Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_t(context, 'اختار الفرع الأول', 'Pick the branch first'))))
        else
          _ProductSearch(
            key: ValueKey(_branch),
            branch: _branch,
            builder: (c, p) {
              final id = '${p['product_id']}';
              _names[id] = '${p['name_ar']}';
              _expected[id] = (p['branch_qty'] as num?)?.toInt() ?? 0;
              final ctl = _counts.putIfAbsent(id, () => TextEditingController());
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text('${p['name_ar']}\n${p['sku'] ?? ''}', style: const TextStyle(fontSize: 13))),
                  Text('${_t(c, 'في النظام', 'System')}: ${p['branch_qty']}', style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 76,
                    child: TextField(
                      controller: ctl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(labelText: _t(c, 'العدّ', 'Count'), isDense: true, border: const OutlineInputBorder()),
                    ),
                  ),
                ]),
              );
            },
          ),
      ],
      bottom: FilledButton.icon(
        onPressed: _busy ? null : _save,
        icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fact_check_rounded),
        label: Text(_t(context, 'اعتمد الجرد', 'Apply the stocktake')),
      ),
    );
  }
}

// ---------------------------------------------------------------- 3) price edit
class _PriceSheet extends ConsumerStatefulWidget {
  const _PriceSheet();
  @override
  ConsumerState<_PriceSheet> createState() => _PriceSheetState();
}

class _PriceSheetState extends ConsumerState<_PriceSheet> {
  final _key = GlobalKey<_ProductSearchState>();

  Future<void> _edit(Map<String, dynamic> p) async {
    final price = TextEditingController(text: _money(p['price_minor']));
    final compare = TextEditingController(text: p['compare_minor'] == null ? '' : _money(p['compare_minor']));
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${p['name_ar']}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: price,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: _t(d, 'السعر الجديد', 'New price'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: compare,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: _t(d, 'السعر قبل الخصم (اختياري)', 'Old price before discount (optional)'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Text(_t(d, 'الطلبات والفواتير اللي اتعملت قبل كده ما بتتغيرش.', 'Existing orders and invoices are not changed.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'احفظ', 'Save'))),
        ],
      ),
    );
    final newPrice = double.tryParse(price.text.trim());
    final newCompare = compare.text.trim().isEmpty ? null : double.tryParse(compare.text.trim());
    price.dispose();
    compare.dispose();
    if (ok != true || !mounted) return;
    if (newPrice == null || newPrice < 0 || (compare.text.trim().isNotEmpty && newCompare == null)) {
      showSnack(context, _t(context, 'السعر مش صحيح', 'Invalid price'), error: true);
      return;
    }
    try {
      await ref.read(supabaseProvider).rpc('product_price_set', params: {
        'p_product': p['product_id'],
        'p_price_minor': (newPrice * 100).round(),
        'p_compare_minor': newCompare == null ? null : (newCompare * 100).round(),
      });
      ref.invalidate(_priceLogProvider);
      _key.currentState?._load();
      if (mounted) showSnack(context, _t(context, 'اتغيّر السعر', 'Price updated'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => _sheetFrame(context, _t(context, 'تعديل الأسعار', 'Edit prices'), [
        _ProductSearch(
          key: _key,
          branch: null,
          builder: (c, p) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${p['name_ar']}'),
            subtitle: Text('${p['sku'] ?? ''}'),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_money(p['price_minor']), style: const TextStyle(fontWeight: FontWeight.w800)),
              if (p['compare_minor'] != null)
                Text(_money(p['compare_minor']), style: const TextStyle(decoration: TextDecoration.lineThrough, color: BrandColors.gray, fontSize: 12)),
            ]),
            onTap: () => _edit(p),
          ),
        ),
      ]);
}

// ---------------------------------------------------------------- 4) export
class _ExportSheet extends ConsumerStatefulWidget {
  const _ExportSheet();
  @override
  ConsumerState<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<_ExportSheet> {
  String _kind = 'products';
  DateTime _from = DateTime.now().subtract(const Duration(days: 30));
  DateTime _to = DateTime.now();
  bool _busy = false;

  String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  CellValue _cell(Object? v) {
    if (v == null) return TextCellValue('');
    if (v is int) return IntCellValue(v);
    if (v is num) return DoubleCellValue(v.toDouble());
    return TextCellValue('$v');
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('export_data', params: {'p_kind': _kind, 'p_from': _d(_from), 'p_to': _d(_to)}) as Map);
      final rows = r['rows'] as List;
      if (rows.isEmpty) {
        if (mounted) showSnack(context, _t(context, 'مفيش بيانات في الفترة دي', 'No data in this period'));
        return;
      }
      final names = {'products': 'المنتجات', 'pos_sales': 'مبيعات الكاشير', 'orders': 'الطلبات', 'customers': 'العملاء'};
      final excel = Excel.createExcel();
      final sheetName = names[_kind]!;
      final sheet = excel[sheetName];
      excel.setDefaultSheet(sheetName);
      if (excel.sheets.containsKey('Sheet1')) excel.delete('Sheet1');
      sheet.appendRow([for (final h in r['headers'] as List) TextCellValue('$h')]);
      for (final row in rows) {
        sheet.appendRow([for (final v in row as List) _cell(v)]);
      }
      final stamp = _kind == 'products' || _kind == 'customers' ? _d(DateTime.now()) : '${_d(_from)}_${_d(_to)}';
      if (!mounted) return;
      await deliverFile(context, Uint8List.fromList(excel.save()!), 'hato-$_kind-$stamp.xlsx', xlsxMime);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(bool from) async {
    final d = await showDatePicker(context: context, initialDate: from ? _from : _to, firstDate: DateTime(2024), lastDate: DateTime.now().add(const Duration(days: 1)));
    if (d != null) setState(() => from ? _from = d : _to = d);
  }

  @override
  Widget build(BuildContext context) {
    final needsDates = _kind == 'pos_sales' || _kind == 'orders';
    final kinds = {
      'products': _t(context, 'المنتجات', 'Products'),
      'pos_sales': _t(context, 'مبيعات الكاشير', 'Counter sales'),
      'orders': _t(context, 'طلبات الأونلاين', 'Online orders'),
      'customers': _t(context, 'العملاء', 'Customers'),
    };
    return _sheetFrame(
      context,
      _t(context, 'تصدير البيانات', 'Export data'),
      [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in kinds.entries) ChoiceChip(label: Text(e.value), selected: _kind == e.key, onSelected: (_) => setState(() => _kind = e.key)),
        ]),
        if (needsDates) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () => _pick(true), icon: const Icon(Icons.event), label: Text('${_t(context, 'من', 'From')} ${_d(_from)}'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: () => _pick(false), icon: const Icon(Icons.event), label: Text('${_t(context, 'إلى', 'To')} ${_d(_to)}'))),
          ]),
        ],
        if (_kind == 'customers') ...[
          const SizedBox(height: 12),
          Text(_t(context, 'الملف فيه أرقام وإيميلات العملاء، احتفظ بيه في مكان آمن.', 'The file has customers\' phones and emails, keep it somewhere safe.'),
              style: const TextStyle(color: BrandColors.warning, fontSize: 13)),
        ],
        const SizedBox(height: 8),
        Text(_t(context, 'الملف إكسل (.xlsx). كل تصدير بيتسجل باسمك.', 'An Excel (.xlsx) file. Every export is logged under your name.'), style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
      ],
      bottom: FilledButton.icon(
        onPressed: _busy ? null : _export,
        icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_rounded),
        label: Text(_t(context, 'نزّل الملف', 'Download the file')),
      ),
    );
  }
}
