// المشتريات والموردين: suppliers, purchase orders (draft -> ordered -> partial -> received), receiving into stock, payments to the supplier.
// Search works like Odoo: words + filters + group-by + saved favourites (shared/odoo_search.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/odoo_search.dart';
import '../../shared/states.dart';
import 'admin_repository.dart' show staffContextProvider;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
List<Map<String, dynamic>> _maps(Object? v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
String _money(BuildContext c, Object? minor) => formatEgp(((minor as num?) ?? 0).toInt(), c.lang);

final _posProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('purchases_list')));
final _suppliersProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('suppliers_list')));
final _pBranchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('staff_my_branches')).where((b) => b['is_hq'] != true).toList());
final _pProductsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
    (ref) async => _maps(await ref.watch(supabaseProvider).from('products').select('id, name_ar, name_en, sku').order('name_ar').limit(500)));

String _statusAr(String s) => switch (s) { 'draft' => 'مسودة', 'ordered' => 'اتطلب', 'partial' => 'استلام جزئي', 'received' => 'اتستلم', _ => 'ملغي' };
String _statusEn(String s) => switch (s) { 'draft' => 'Draft', 'ordered' => 'Ordered', 'partial' => 'Partly received', 'received' => 'Received', _ => 'Cancelled' };
Color _statusColor(String s) => switch (s) { 'draft' => const Color(0xFF667085), 'ordered' => const Color(0xFF1570EF), 'partial' => const Color(0xFFF79009), 'received' => const Color(0xFF12B76A), _ => const Color(0xFFD92D20) };

String _err(BuildContext c, Object e) {
  final t = '$e';
  final ar = c.isAr;
  if (t.contains('FORBIDDEN')) return ar ? 'مش مسموحلك بالخطوة دي.' : 'You are not allowed to do this.';
  if (t.contains('OVERPAY')) return ar ? 'المبلغ أكبر من المتبقي على الأمر.' : 'The amount is more than what is left to pay.';
  if (t.contains('RECEIVE_EXCEEDS_ORDER')) return ar ? 'الكمية أكبر من المتبقي في الأمر.' : 'More than what is left to receive.';
  if (t.contains('INVALID_STATE') || t.contains('NOT_DRAFT')) return ar ? 'حالة الأمر مش بتسمح بالخطوة دي.' : 'The order status does not allow this.';
  if (t.contains('SUPPLIER_EXISTS')) return ar ? 'المورد ده موجود بنفس الاسم.' : 'A supplier with this name already exists.';
  if (t.contains('INVALID_INPUT')) return ar ? 'في رقم أو بيان مش مظبوط، راجع وجرب تاني.' : 'Something is not valid, check and try again.';
  return friendlyError(c, e);
}

class PurchasesPanel extends ConsumerStatefulWidget {
  const PurchasesPanel({super.key});
  @override
  ConsumerState<PurchasesPanel> createState() => _PurchasesPanelState();
}

class _PurchasesPanelState extends ConsumerState<PurchasesPanel> {
  int _tab = 0;
  final _poSearch = OdooSearchState();
  final _supSearch = OdooSearchState();

  static final _poFilters = <OdooFilter>[
    OdooFilter('draft', 'مسودة', 'Draft', (r) => r['status'] == 'draft', exclusiveWith: 'st'),
    OdooFilter('ordered', 'اتطلب', 'Ordered', (r) => r['status'] == 'ordered', exclusiveWith: 'st'),
    OdooFilter('partial', 'استلام جزئي', 'Partly received', (r) => r['status'] == 'partial', exclusiveWith: 'st'),
    OdooFilter('received', 'اتستلم', 'Received', (r) => r['status'] == 'received', exclusiveWith: 'st'),
    OdooFilter('cancelled', 'ملغي', 'Cancelled', (r) => r['status'] == 'cancelled', exclusiveWith: 'st'),
    OdooFilter('owed', 'عليا فلوس', 'Money owed', (r) => r['status'] != 'cancelled' && ((r['total_minor'] as num) - (r['paid_minor'] as num)) > 0),
    OdooFilter('late', 'متأخر عن الموعد', 'Late', (r) {
      final d = DateTime.tryParse('${r['expected_date'] ?? ''}');
      return d != null && d.isBefore(DateTime.now().subtract(const Duration(days: 1))) && (r['status'] == 'ordered' || r['status'] == 'partial');
    }),
    OdooFilter('month', 'الشهر ده', 'This month', (r) {
      final d = DateTime.tryParse('${r['created_at'] ?? ''}')?.toLocal();
      final n = DateTime.now();
      return d != null && d.year == n.year && d.month == n.month;
    }),
  ];
  static final _poGroups = <OdooGroup>[
    OdooGroup('status', 'الحالة', 'Status', (r) => _statusAr('${r['status']}')),
    OdooGroup('supplier', 'المورد', 'Supplier', (r) => '${r['supplier']}'),
    OdooGroup('month', 'الشهر', 'Month', (r) => '${r['created_at']}'.substring(0, 7)),
  ];
  static final _supFilters = <OdooFilter>[
    OdooFilter('active', 'شغّال', 'Active', (r) => r['is_active'] == true),
    OdooFilter('owed', 'عليا له فلوس', 'I owe him', (r) => ((r['owed_minor'] as num?) ?? 0) > 0),
    OdooFilter('orders', 'ليه أوامر', 'Has orders', (r) => ((r['orders'] as num?) ?? 0) > 0),
  ];

  bool _can(String p) => ref.read(staffContextProvider).valueOrNull?.permissions.contains(p) ?? false;

  Future<void> _openPo([Map<String, dynamic>? existing]) async {
    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, showDragHandle: true, builder: (_) => _PoForm(poId: existing?['id'] as String?));
    if (ok == true) {
      ref.invalidate(_posProvider);
      ref.invalidate(_suppliersProvider);
    }
  }

  Future<void> _openSupplier([Map<String, dynamic>? s]) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _SupplierDialog(row: s));
    if (ok == true) ref.invalidate(_suppliersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canManage = _can('purchases.manage');
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          Expanded(
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, icon: const Icon(Icons.receipt_long_outlined), label: Text(_t(context, 'أوامر الشراء', 'Purchase orders'))),
                ButtonSegment(value: 1, icon: const Icon(Icons.local_shipping_outlined), label: Text(_t(context, 'الموردين', 'Suppliers'))),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          if (canManage) ...[
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => _tab == 0 ? _openPo() : _openSupplier(),
              icon: const Icon(Icons.add_rounded),
              label: Text(_tab == 0 ? _t(context, 'أمر شراء', 'New order') : _t(context, 'مورد', 'Supplier')),
            ),
          ],
        ]),
      ),
      if (_tab == 0)
        OdooSearchBar(state: _poSearch, filters: _poFilters, groups: _poGroups, storeKey: 'po', hintAr: 'ابحث برقم الأمر أو المورد...', hintEn: 'Search by number or supplier...', onChanged: () => setState(() {}))
      else
        OdooSearchBar(state: _supSearch, filters: _supFilters, groups: const [], storeKey: 'sup', hintAr: 'ابحث باسم المورد أو تليفونه...', hintEn: 'Search by name or phone...', onChanged: () => setState(() {})),
      Expanded(child: _tab == 0 ? _orders(context) : _suppliers(context)),
    ]);
  }

  Widget _orders(BuildContext context) {
    final st = ref.watch(_posProvider);
    return st.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_posProvider)),
      data: (all) {
        final rows = _poSearch.apply(all, defs: _poFilters, textOf: (r) => '${r['number']} ${r['supplier']} ${_statusAr('${r['status']}')} ${_statusEn('${r['status']}')}');
        if (rows.isEmpty) return Center(child: Text(all.isEmpty ? _t(context, 'مفيش أوامر شراء لسه.', 'No purchase orders yet.') : _t(context, 'مفيش نتايج للبحث ده.', 'No results for this search.')));
        final groups = _poSearch.group(rows, _poGroups);
        final total = rows.fold<num>(0, (a, r) => a + (r['status'] == 'cancelled' ? 0 : (r['total_minor'] as num)));
        final owed = rows.fold<num>(0, (a, r) => a + (r['status'] == 'cancelled' ? 0 : (r['total_minor'] as num) - (r['paid_minor'] as num)));
        return RefreshIndicator(
          onRefresh: () async => ref.refresh(_posProvider.future),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${rows.length} ${_t(context, 'أمر', 'orders')} · ${_t(context, 'الإجمالي', 'Total')} ${_money(context, total)} · ${_t(context, 'المتبقي عليك', 'You owe')} ${_money(context, owed)}',
                  style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
            ),
            for (final g in groups) ...[
              if (g.$1.isNotEmpty)
                Padding(padding: const EdgeInsets.fromLTRB(2, 10, 2, 6), child: Text('${g.$1} (${g.$2.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: BrandColors.navy))),
              for (final r in g.$2) _PoTile(row: r, onChanged: () {
                ref.invalidate(_posProvider);
                ref.invalidate(_suppliersProvider);
              }, onEdit: () => _openPo(r)),
            ],
          ]),
        );
      },
    );
  }

  Widget _suppliers(BuildContext context) {
    final st = ref.watch(_suppliersProvider);
    return st.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_suppliersProvider)),
      data: (all) {
        final rows = _supSearch.apply(all, defs: _supFilters, textOf: (r) => '${r['name']} ${r['phone'] ?? ''} ${r['note'] ?? ''}');
        if (rows.isEmpty) return Center(child: Text(all.isEmpty ? _t(context, 'مفيش موردين لسه.', 'No suppliers yet.') : _t(context, 'مفيش نتايج للبحث ده.', 'No results for this search.')));
        return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          for (final s in rows)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(backgroundColor: const Color(0xFF0E9384).withValues(alpha: .12), child: const Icon(Icons.local_shipping_rounded, color: Color(0xFF0E9384))),
                title: Text('${s['name']}${s['is_active'] == true ? '' : _t(context, ' (موقوف)', ' (inactive)')}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${s['phone'] ?? ''}${(s['phone'] ?? '').toString().isEmpty ? '' : ' · '}${s['orders']} ${_t(context, 'أمر', 'orders')} · ${_t(context, 'إجمالي', 'Total')} ${_money(context, s['total_minor'])}'),
                trailing: ((s['owed_minor'] as num?) ?? 0) > 0
                    ? Chip(label: Text('${_t(context, 'عليك', 'You owe')} ${_money(context, s['owed_minor'])}', style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w700, fontSize: 12)), visualDensity: VisualDensity.compact)
                    : null,
                onTap: _can('purchases.manage') ? () => _openSupplier(s) : null,
              ),
            ),
        ]);
      },
    );
  }
}

class _PoTile extends ConsumerWidget {
  const _PoTile({required this.row, required this.onChanged, required this.onEdit});
  final Map<String, dynamic> row;
  final VoidCallback onChanged, onEdit;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = '${row['status']}';
    final owed = (row['total_minor'] as num) - (row['paid_minor'] as num);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Row(children: [
          Text('${row['number']}', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: _statusColor(s).withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
            child: Text(_t(context, _statusAr(s), _statusEn(s)), style: TextStyle(color: _statusColor(s), fontWeight: FontWeight.w700, fontSize: 11.5)),
          ),
        ]),
        subtitle: Text('${row['supplier']} · ${row['items']} ${_t(context, 'صنف', 'items')} · ${_money(context, row['total_minor'])}${s != 'cancelled' && owed > 0 && s != 'draft' ? ' · ${_t(context, 'متبقي', 'left')} ${_money(context, owed)}' : ''}'),
        trailing: const Icon(Icons.chevron_left_rounded),
        onTap: () async {
          final changed = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, showDragHandle: true, builder: (_) => _PoDetail(id: '${row['id']}', onEdit: onEdit));
          if (changed == true) onChanged();
        },
      ),
    );
  }
}

class _PoDetail extends ConsumerStatefulWidget {
  const _PoDetail({required this.id, required this.onEdit});
  final String id;
  final VoidCallback onEdit;
  @override
  ConsumerState<_PoDetail> createState() => _PoDetailState();
}

class _PoDetailState extends ConsumerState<_PoDetail> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _busy = false, _changed = false;
  final Map<String, TextEditingController> _recv = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _recv.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _can(String p) => ref.read(staffContextProvider).valueOrNull?.permissions.contains(p) ?? false;

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('purchase_get', params: {'p_id': widget.id}) as Map);
      if (mounted) {
        setState(() {
          _d = r;
          _error = null;
          for (final i in _maps(r['items'])) {
            _recv.putIfAbsent('${i['id']}', () => TextEditingController());
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _do(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      _changed = true;
      await _load();
      if (mounted) showSnack(context, done);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receive() async {
    final items = <Map<String, dynamic>>[];
    for (final i in _maps(_d!['items'])) {
      final q = int.tryParse(_recv['${i['id']}']!.text.trim()) ?? 0;
      if (q > 0) items.add({'item_id': i['id'], 'qty': q});
    }
    if (items.isEmpty) {
      showSnack(context, _t(context, 'اكتب الكمية المستلمة لصنف واحد على الأقل', 'Enter a received quantity for at least one item'), error: true);
      return;
    }
    await _do(() async {
      await ref.read(supabaseProvider).rpc('purchase_receive', params: {'p_id': widget.id, 'p_items': items});
      for (final c in _recv.values) {
        c.clear();
      }
    }, _t(context, 'اتسجل الاستلام وزاد المخزن ✅', 'Received and stock increased ✅'));
  }

  Future<void> _pay() async {
    final o = _d!['order'] as Map;
    final left = (o['total_minor'] as num) - (o['paid_minor'] as num);
    final amount = TextEditingController(text: (left / 100).toStringAsFixed(left % 100 == 0 ? 0 : 2));
    final note = TextEditingController();
    var method = 'cash';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(_t(ctx, 'دفعة للمورد', 'Pay supplier')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${_t(ctx, 'المبلغ (ج.م)', 'Amount (EGP)')} · ${_t(ctx, 'المتبقي', 'left')} ${_money(ctx, left)}')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: method,
              decoration: InputDecoration(labelText: _t(ctx, 'طريقة الدفع', 'Method')),
              items: [for (final m in const [('cash', 'كاش', 'Cash'), ('transfer', 'تحويل بنكي', 'Bank transfer'), ('wallet', 'محفظة', 'Wallet'), ('cheque', 'شيك', 'Cheque')]) DropdownMenuItem(value: m.$1, child: Text(_t(ctx, m.$2, m.$3)))],
              onChanged: (v) => set(() => method = v ?? 'cash'),
            ),
            const SizedBox(height: 8),
            TextField(controller: note, maxLength: 200, decoration: InputDecoration(labelText: _t(ctx, 'ملاحظة', 'Note'), counterText: '')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'إلغاء', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'سجّل الدفع', 'Record'))),
          ],
        ),
      ),
    );
    final minor = parseEgpToMinor(amount.text);
    final n = note.text.trim();
    amount.dispose();
    note.dispose();
    if (ok != true) return;
    if (minor == null || minor < 1) {
      if (mounted) showSnack(context, _t(context, 'المبلغ مش مظبوط', 'Invalid amount'), error: true);
      return;
    }
    await _do(() async => ref.read(supabaseProvider).rpc('purchase_pay', params: {'p_id': widget.id, 'p_amount_minor': minor, 'p_method': method, 'p_note': n.isEmpty ? null : n}), _t(context, 'اتسجلت الدفعة ✅', 'Payment recorded ✅'));
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return SizedBox(height: 240, child: ErrorView(error: _error!, onRetry: _load));
    final d = _d;
    if (d == null) return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
    final o = Map<String, dynamic>.from(d['order'] as Map);
    final s = '${o['status']}';
    final items = _maps(d['items']);
    final pays = _maps(d['payments']);
    final left = (o['total_minor'] as num) - (o['paid_minor'] as num);
    final receiving = s == 'ordered' || s == 'partial';
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {},
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), shrinkWrap: true, children: [
        Row(children: [
          Expanded(child: Text('${o['number']} · ${(d['supplier'] as Map?)?['name'] ?? ''}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: _statusColor(s).withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
            child: Text(_t(context, _statusAr(s), _statusEn(s)), style: TextStyle(color: _statusColor(s), fontWeight: FontWeight.w700)),
          ),
        ]),
        if ((o['expected_date'] ?? '').toString().isNotEmpty) Text('${_t(context, 'الموعد المتوقع', 'Expected')}: ${o['expected_date']}', style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
        if ((o['note'] ?? '').toString().isNotEmpty) Text('${o['note']}', style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
        const SizedBox(height: 10),
        for (final i in items)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.pick(i, 'name'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('${_t(context, 'مطلوب', 'Ordered')} ${i['qty']} · ${_t(context, 'استلمت', 'Received')} ${i['received_qty']} · ${_t(context, 'التكلفة', 'Cost')} ${_money(context, i['cost_minor'])}', style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                  ]),
                ),
                if (receiving && _can('purchases.receive') && (i['qty'] as int) > (i['received_qty'] as int))
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _recv['${i['id']}'],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(isDense: true, labelText: _t(context, 'استلم', 'Receive'), hintText: '${(i['qty'] as int) - (i['received_qty'] as int)}'),
                    ),
                  ),
              ]),
            ),
          ),
        const Divider(height: 24),
        Text('${_t(context, 'الإجمالي', 'Total')}: ${_money(context, o['total_minor'])}   ·   ${_t(context, 'اتدفع', 'Paid')}: ${_money(context, o['paid_minor'])}   ·   ${_t(context, 'المتبقي', 'Left')}: ${_money(context, left)}', style: const TextStyle(fontWeight: FontWeight.w800)),
        if (pays.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final p in pays)
            Text('• ${_money(context, p['amount_minor'])} · ${p['method']} · ${'${p['created_at']}'.substring(0, 10)}${(p['note'] ?? '').toString().isEmpty ? '' : ' · ${p['note']}'}', style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
        ],
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (s == 'draft' && _can('purchases.manage')) ...[
            OutlinedButton.icon(onPressed: _busy ? null : () { Navigator.pop(context, _changed); widget.onEdit(); }, icon: const Icon(Icons.edit_rounded), label: Text(_t(context, 'تعديل', 'Edit'))),
            FilledButton.icon(onPressed: _busy ? null : () => _do(() async => ref.read(supabaseProvider).rpc('purchase_set_status', params: {'p_id': widget.id, 'p_status': 'ordered'}), _t(context, 'اتأكد الأمر', 'Order confirmed')), icon: const Icon(Icons.check_circle_outline_rounded), label: Text(_t(context, 'تأكيد الطلب', 'Confirm order'))),
          ],
          if (receiving && _can('purchases.receive')) FilledButton.icon(onPressed: _busy ? null : _receive, icon: const Icon(Icons.move_to_inbox_rounded), label: Text(_t(context, 'سجّل الاستلام', 'Receive'))),
          if ((s == 'ordered' || s == 'partial' || s == 'received') && left > 0 && _can('purchases.pay')) OutlinedButton.icon(onPressed: _busy ? null : _pay, icon: const Icon(Icons.payments_outlined), label: Text(_t(context, 'دفعة للمورد', 'Pay supplier'))),
          if ((s == 'draft' || s == 'ordered') && (o['paid_minor'] as num) == 0 && _can('purchases.manage'))
            TextButton.icon(
              onPressed: _busy ? null : () => _do(() async => ref.read(supabaseProvider).rpc('purchase_set_status', params: {'p_id': widget.id, 'p_status': 'cancelled'}), _t(context, 'اتلغى الأمر', 'Order cancelled')),
              icon: const Icon(Icons.cancel_outlined, color: BrandColors.error),
              label: Text(_t(context, 'إلغاء الأمر', 'Cancel order'), style: const TextStyle(color: BrandColors.error)),
            ),
          TextButton(onPressed: () => Navigator.pop(context, _changed), child: Text(_t(context, 'إغلاق', 'Close'))),
        ]),
      ]),
    );
  }
}

class _SupplierDialog extends ConsumerStatefulWidget {
  const _SupplierDialog({this.row});
  final Map<String, dynamic>? row;
  @override
  ConsumerState<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends ConsumerState<_SupplierDialog> {
  late final _name = TextEditingController(text: '${widget.row?['name'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.row?['phone'] ?? ''}');
  late final _note = TextEditingController(text: '${widget.row?['note'] ?? ''}');
  late bool _active = widget.row?['is_active'] != false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showSnack(context, _t(context, 'اكتب اسم المورد', 'Enter the supplier name'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('supplier_save', params: {'p_id': widget.row?['id'], 'p_name': _name.text.trim(), 'p_phone': _phone.text.trim(), 'p_note': _note.text.trim(), 'p_active': _active});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, _err(context, e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.row == null ? _t(context, 'مورد جديد', 'New supplier') : _t(context, 'تعديل المورد', 'Edit supplier')),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'الاسم', 'Name'), counterText: '')),
            TextField(controller: _phone, maxLength: 30, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: _t(context, 'التليفون', 'Phone'), counterText: '')),
            TextField(controller: _note, maxLength: 300, decoration: InputDecoration(labelText: _t(context, 'ملاحظة', 'Note'), counterText: '')),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: Text(_t(context, 'شغّال', 'Active'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: Text(_t(context, 'إلغاء', 'Cancel'))),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'حفظ', 'Save'))),
        ],
      );
}

class _Line {
  _Line(this.productId, this.name, int qty, String cost)
      : qty = TextEditingController(text: '$qty'),
        cost = TextEditingController(text: cost);
  final String productId, name;
  final TextEditingController qty, cost;
}

class _PoForm extends ConsumerStatefulWidget {
  const _PoForm({this.poId});
  final String? poId;
  @override
  ConsumerState<_PoForm> createState() => _PoFormState();
}

class _PoFormState extends ConsumerState<_PoForm> {
  String? _supplier, _branch;
  DateTime? _expected;
  final _note = TextEditingController();
  final List<_Line> _lines = [];
  bool _busy = false, _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.poId != null) _loadExisting();
  }

  @override
  void dispose() {
    _note.dispose();
    for (final l in _lines) {
      l.qty.dispose();
      l.cost.dispose();
    }
    super.dispose();
  }

  Future<void> _loadExisting() async {
    setState(() => _loading = true);
    try {
      final d = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('purchase_get', params: {'p_id': widget.poId}) as Map);
      final o = Map<String, dynamic>.from(d['order'] as Map);
      _supplier = o['supplier_id'] as String?;
      _branch = o['branch_id'] as String?;
      _expected = DateTime.tryParse('${o['expected_date'] ?? ''}');
      _note.text = '${o['note'] ?? ''}';
      for (final i in _maps(d['items'])) {
        final c = (i['cost_minor'] as num).toInt();
        _lines.add(_Line('${i['product_id']}', context.pick(i, 'name'), (i['qty'] as num).toInt(), (c / 100).toStringAsFixed(c % 100 == 0 ? 0 : 2)));
      }
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  num get _total {
    num t = 0;
    for (final l in _lines) {
      final q = int.tryParse(l.qty.text.trim()) ?? 0;
      final c = parseEgpToMinor(l.cost.text) ?? 0;
      t += q * c;
    }
    return t;
  }

  Future<void> _addProduct(List<Map<String, dynamic>> products) async {
    final q = TextEditingController();
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final t = q.text.trim().toLowerCase();
        final list = [for (final p in products) if (!_lines.any((l) => l.productId == p['id']) && (t.isEmpty || '${p['name_ar']} ${p['name_en']} ${p['sku'] ?? ''}'.toLowerCase().contains(t))) p].take(60).toList();
        return AlertDialog(
          title: Text(_t(ctx, 'اختار صنف', 'Pick an item')),
          content: SizedBox(
            width: 420,
            height: 420,
            child: Column(children: [
              TextField(controller: q, autofocus: true, onChanged: (_) => set(() {}), decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: _t(ctx, 'ابحث بالاسم أو الكود', 'Search by name or SKU'))),
              const SizedBox(height: 8),
              Expanded(child: ListView(children: [for (final p in list) ListTile(dense: true, title: Text(ctx.pick(p, 'name'), maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text('${p['sku'] ?? ''}'), onTap: () => Navigator.pop(ctx, p))])),
            ]),
          ),
        );
      }),
    );
    q.dispose();
    if (picked != null && mounted) setState(() => _lines.add(_Line('${picked['id']}', context.pick(picked, 'name'), 1, '')));
  }

  Future<void> _save() async {
    if (_supplier == null) {
      showSnack(context, _t(context, 'اختار المورد', 'Pick the supplier'), error: true);
      return;
    }
    if (_lines.isEmpty) {
      showSnack(context, _t(context, 'ضيف صنف واحد على الأقل', 'Add at least one item'), error: true);
      return;
    }
    final items = <Map<String, dynamic>>[];
    for (final l in _lines) {
      final q = int.tryParse(l.qty.text.trim());
      final c = parseEgpToMinor(l.cost.text);
      if (q == null || q < 1 || c == null) {
        showSnack(context, _t(context, 'راجع الكمية والتكلفة في "${l.name}"', 'Check quantity and cost for "${l.name}"'), error: true);
        return;
      }
      items.add({'product_id': l.productId, 'qty': q, 'cost_minor': c});
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('purchase_save', params: {
        'p_id': widget.poId,
        'p_supplier': _supplier,
        'p_branch': _branch,
        'p_expected': _expected == null ? null : '${_expected!.year}-${_expected!.month.toString().padLeft(2, '0')}-${_expected!.day.toString().padLeft(2, '0')}',
        'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'p_items': items,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, _err(context, e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = (ref.watch(_suppliersProvider).valueOrNull ?? const []).where((s) => s['is_active'] == true || s['id'] == _supplier).toList();
    final branches = ref.watch(_pBranchesProvider).valueOrNull ?? const [];
    final products = ref.watch(_pProductsProvider).valueOrNull ?? const [];
    if (_loading) return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
        Text(widget.poId == null ? _t(context, 'أمر شراء جديد', 'New purchase order') : _t(context, 'تعديل أمر الشراء', 'Edit purchase order'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: suppliers.any((s) => s['id'] == _supplier) ? _supplier : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: _t(context, 'المورد', 'Supplier')),
          items: [for (final s in suppliers) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}', overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _supplier = v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: branches.any((b) => b['id'] == _branch) ? _branch : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: _t(context, 'يتسلم في فرع (اختياري)', 'Deliver to branch (optional)')),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(_t(context, 'المخزن الرئيسي', 'Main warehouse'))),
            for (final b in branches) DropdownMenuItem<String?>(value: b['id'] as String, child: Text(context.pick(b, 'name'), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _branch = v),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: context, initialDate: _expected ?? DateTime.now(), firstDate: DateTime.now().subtract(const Duration(days: 30)), lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) setState(() => _expected = d);
              },
              icon: const Icon(Icons.event_rounded),
              label: Text(_expected == null ? _t(context, 'موعد التسليم المتوقع', 'Expected date') : '${_expected!.year}-${_expected!.month.toString().padLeft(2, '0')}-${_expected!.day.toString().padLeft(2, '0')}'),
            ),
          ),
          if (_expected != null) IconButton(onPressed: () => setState(() => _expected = null), icon: const Icon(Icons.close_rounded, size: 18)),
        ]),
        TextField(controller: _note, maxLength: 300, decoration: InputDecoration(labelText: _t(context, 'ملاحظة', 'Note'), counterText: '')),
        const SizedBox(height: 6),
        Text(_t(context, 'الأصناف', 'Items'), style: const TextStyle(fontWeight: FontWeight.w800)),
        for (var i = 0; i < _lines.length; i++)
          Card(
            margin: const EdgeInsets.only(top: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(children: [
                Expanded(child: Text(_lines[i].name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                SizedBox(width: 64, child: TextField(controller: _lines[i].qty, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: InputDecoration(isDense: true, labelText: _t(context, 'كمية', 'Qty')))),
                const SizedBox(width: 6),
                SizedBox(width: 84, child: TextField(controller: _lines[i].cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}), decoration: InputDecoration(isDense: true, labelText: _t(context, 'تكلفة', 'Cost')))),
                IconButton(onPressed: () => setState(() => _lines.removeAt(i)), icon: const Icon(Icons.delete_outline_rounded, size: 20, color: BrandColors.error)),
              ]),
            ),
          ),
        Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: () => _addProduct(products), icon: const Icon(Icons.add_rounded), label: Text(_t(context, 'أضف صنف', 'Add item')))),
        const Divider(),
        Text('${_t(context, 'الإجمالي', 'Total')}: ${_money(context, _total)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 10),
        FilledButton(onPressed: _busy ? null : _save, child: _busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_t(context, 'حفظ كمسودة', 'Save as draft'))),
      ]),
    );
  }
}
