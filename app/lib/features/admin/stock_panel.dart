// "مخزن": stock per branch + transfers between branches.
// الأرصدة: how many pieces of each product sit in each branch store (and what is not given to a branch yet).
// التحويلات: send pieces to another branch; the other branch gets a notification and confirms what it really received, or rejects with a reason.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart' show staffContextProvider;

List<Map<String, dynamic>> _maps(Object? v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

String _stockError(BuildContext c, Object e) {
  final t = '$e';
  final ar = c.isAr;
  final m = RegExp(r'INSUFFICIENT_STOCK:([^\n,}"]*)').firstMatch(t);
  if (m != null) return ar ? 'الكمية في مخزن فرعك أقل من المطلوب: ${m.group(1)}' : 'Not enough in your branch store: ${m.group(1)}';
  if (t.contains('NOT_ENOUGH_UNALLOCATED')) return ar ? 'الرصيد غير الموزّع مش كفاية للكمية دي.' : 'Not enough unallocated stock.';
  if (t.contains('ALREADY_DECIDED')) return ar ? 'التحويل ده اتحسم قبل كده.' : 'This transfer was already decided.';
  if (t.contains('REASON_REQUIRED')) return ar ? 'اختار السبب (واكتبه لو «سبب آخر»).' : 'Pick a reason (and write it for "other").';
  if (t.contains('USE_REJECT')) return ar ? 'لو ما استلمتش حاجة اضغط «مستلمتش».' : 'If nothing arrived, use "Not received".';
  if (t.contains('FORBIDDEN')) return ar ? 'مش مسموحلك بالخطوة دي في الفرع ده.' : 'You are not allowed to do this for this branch.';
  return friendlyError(c, e);
}

final _viewBranchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('staff_view_branches')));
final _myBranchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('staff_my_branches')));
final _whereProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async =>
    Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('stock_product_where', params: {'p_product': id}) as Map));
final _transfersProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => _maps(await ref.watch(supabaseProvider).rpc('stock_transfers_list')));

class StockPanel extends ConsumerStatefulWidget {
  const StockPanel({super.key});
  @override
  ConsumerState<StockPanel> createState() => _StockPanelState();
}

class _StockPanelState extends ConsumerState<StockPanel> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>[];
    final canTransfer = perms.contains('stock.transfer');
    final transfers = ref.watch(_transfersProvider).valueOrNull ?? const [];
    final waiting = transfers.where((t) => t['can_receive'] == true).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, icon: const Icon(Icons.inventory_2_outlined), label: Text(_t(context, 'الأرصدة', 'Stock'))),
                ButtonSegment(
                  value: 1,
                  icon: Badge(isLabelVisible: waiting > 0, label: Text('$waiting'), child: const Icon(Icons.local_shipping_outlined)),
                  label: Text(_t(context, 'التحويلات', 'Transfers')),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          if (canTransfer) ...[
            const SizedBox(width: 8),
            FilledButton.icon(onPressed: () => _newTransfer(context), icon: const Icon(Icons.swap_horiz_rounded), label: Text(_t(context, 'تحويل', 'Transfer'))),
          ],
        ]),
      ),
      Expanded(child: _tab == 0 ? _BalancesTab(onTransfer: (p) => _newTransfer(context, product: p)) : const _TransfersTab()),
    ]);
  }

  Future<void> _newTransfer(BuildContext context, {Map<String, dynamic>? product}) async {
    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _NewTransferSheet(product: product));
    if (ok == true && mounted) {
      ref.invalidate(_transfersProvider);
      setState(() => _tab = 1);
      showSnack(context, _t(context, 'التحويل اتبعت. فرع المستلم اتبلّغ.', 'Transfer sent. The other branch was notified.'));
    }
  }
}

// ------------------------------------------------------------------ balances
class _BalancesTab extends ConsumerStatefulWidget {
  const _BalancesTab({required this.onTransfer});
  final void Function(Map<String, dynamic> product) onTransfer;
  @override
  ConsumerState<_BalancesTab> createState() => _BalancesTabState();
}

class _BalancesTabState extends ConsumerState<_BalancesTab> {
  String? _branch;
  String _q = '';
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = _maps(await ref.read(supabaseProvider).rpc('stock_overview', params: {'p_branch': _branch, 'p_search': _q.isEmpty ? null : _q}));
      if (mounted) setState(() {
        _rows = r;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _stockError(context, e));
    }
  }

  Future<void> _allocate(Map<String, dynamic> p, List<Map<String, dynamic>> branches) async {
    final changed = await showDialog<bool>(context: context, builder: (_) => _AllocateDialog(product: p, branches: branches));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>[];
    final seeOthers = perms.contains('stock.others');
    final branches = (seeOthers ? ref.watch(_viewBranchesProvider) : ref.watch(_myBranchesProvider)).valueOrNull ?? const <Map<String, dynamic>>[];
    final names = {for (final b in branches) '${b['id']}': _t(context, '${b['name_ar']}', '${b['name_en']}')};
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: TextField(
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: _t(context, 'دوّر على منتج أو كود', 'Search a product or SKU'), isDense: true, border: const OutlineInputBorder()),
          onChanged: (v) {
            _q = v.trim();
            _load();
          },
        ),
      ),
      SizedBox(
        height: 52,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          Padding(padding: const EdgeInsets.all(6), child: ChoiceChip(label: Text(_t(context, 'كل الفروع', 'All')), selected: _branch == null, onSelected: (_) => setState(() { _branch = null; _load(); }))),
          for (final b in branches)
            Padding(padding: const EdgeInsets.all(6), child: ChoiceChip(label: Text(_t(context, '${b['name_ar']}', '${b['name_en']}')), selected: _branch == '${b['id']}', onSelected: (_) => setState(() { _branch = '${b['id']}'; _load(); }))),
        ]),
      ),
      Expanded(
        child: _error != null
            ? ErrorView(error: _error!, onRetry: _load)
            : _rows == null
                ? const Center(child: CircularProgressIndicator())
                : _rows!.isEmpty
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_branch == null ? (perms.contains('stock.others') ? _t(context, 'مفيش منتجات.', 'No products.') : _t(context, 'مفيش منتجات في مخزن فرعك دلوقتي. المالك لازم يوزّع لفرعك الأول، أو يديك صلاحية «يشوف الوير هاوس والفروع التانية».', 'Nothing in your branch store yet. The owner must allocate stock to your branch, or give you the warehouse view permission.')) : _t(context, 'مفيش منتجات في مخزن الفرع ده. دوّر باسم المنتج عشان توزّعه عليه.', 'Nothing in this branch store yet. Search a product to allocate it.'), textAlign: TextAlign.center)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: _rows!.length,
                        itemBuilder: (_, i) => _productCard(context, _rows![i], names, perms, branches),
                      ),
      ),
    ]);
  }

  Widget _productCard(BuildContext context, Map<String, dynamic> p, Map<String, String> names, Iterable<String> perms, List<Map<String, dynamic>> branches) {
    final bs = _maps(p['branches']);
    final unalloc = (p['unallocated'] as num?)?.toInt();
    return Card(
      child: InkWell(
       onTap: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _WhereSheet(product: p)),
       child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_t(context, '${p['name_ar']}', '${p['name_en']}'), style: const TextStyle(fontWeight: FontWeight.w800))),
            if (p['total'] != null) Text('${p['total']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          ]),
          Text('${p['sku']}${p['total'] != null ? ' · ${_t(context, 'الإجمالي في المتجر', 'store total')}' : ''}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final b in bs)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.store_mall_directory_outlined, size: 16),
                label: Text('${names['${b['branch_id']}'] ?? '—'}: ${b['qty']}'),
              ),
            if (unalloc != null)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.warehouse_outlined, size: 16),
                backgroundColor: unalloc > 0 ? BrandColors.warning.withValues(alpha: .15) : null,
                label: Text(_t(context, 'الوير هاوس: $unalloc', 'Warehouse: $unalloc')),
              ),
            if (bs.isEmpty && unalloc == null) Text(_t(context, 'مفيش منه في مخزن فرعك', 'None in your branch store'), style: Theme.of(context).textTheme.bodySmall),
          ]),
          if (perms.contains('stock.allocate') || perms.contains('stock.transfer'))
            Wrap(spacing: 8, children: [
              if (perms.contains('stock.allocate')) TextButton.icon(onPressed: () => _allocate(p, branches), icon: const Icon(Icons.call_split_rounded, size: 18), label: Text(_t(context, 'وزّع من الوير هاوس', 'Allocate from warehouse'))),
              if (perms.contains('stock.transfer')) TextButton.icon(onPressed: () => widget.onTransfer(p), icon: const Icon(Icons.swap_horiz_rounded, size: 18), label: Text(_t(context, 'حوّل', 'Transfer'))),
            ]),
        ]),
       ),
      ),
    );
  }
}

class _AllocateDialog extends ConsumerStatefulWidget {
  const _AllocateDialog({required this.product, required this.branches});
  final Map<String, dynamic> product;
  final List<Map<String, dynamic>> branches;
  @override
  ConsumerState<_AllocateDialog> createState() => _AllocateDialogState();
}

class _AllocateDialogState extends ConsumerState<_AllocateDialog> {
  String? _branch;
  final _qty = TextEditingController();
  String? _error;
  bool _busy = false;

  int _current() {
    final b = _maps(widget.product['branches']).where((e) => '${e['branch_id']}' == _branch);
    return b.isEmpty ? 0 : (b.first['qty'] as num).toInt();
  }

  Future<void> _save() async {
    final q = int.tryParse(_qty.text.trim());
    if (_branch == null || q == null || q < 0) {
      setState(() => _error = _t(context, 'اختار الفرع واكتب الكمية.', 'Pick a branch and a quantity.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc('stock_allocate', params: {'p_branch': _branch, 'p_product': widget.product['product_id'], 'p_qty': q});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = _stockError(context, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final unalloc = (widget.product['unallocated'] as num?)?.toInt() ?? 0;   // allocators normally also see the warehouse
    return AlertDialog(
      title: Text(_t(context, 'توزيع ${widget.product['name_ar']}', 'Allocate ${widget.product['name_en']}')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.product['unallocated'] != null) Text(_t(context, 'في الوير هاوس دلوقتي: $unalloc', 'In the warehouse now: $unalloc')),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _branch,
          decoration: InputDecoration(labelText: _t(context, 'الفرع', 'Branch')),
          items: [for (final b in widget.branches) DropdownMenuItem(value: '${b['id']}', child: Text(_t(context, '${b['name_ar']}', '${b['name_en']}')))],
          onChanged: (v) => setState(() {
            _branch = v;
            _qty.text = '${_current()}';
          }),
        ),
        TextField(controller: _qty, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _t(context, 'الكمية الجديدة في مخزن الفرع', 'New quantity in the branch store'))),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BrandColors.error))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t(context, 'إلغاء', 'Cancel'))),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'احفظ', 'Save'))),
      ],
    );
  }
}

// ------------------------------------------------------------------ transfers list
class _TransfersTab extends ConsumerWidget {
  const _TransfersTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(_transfersProvider);
    return st.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_transfersProvider)),
      data: (list) {
        if (list.isEmpty) return Center(child: Text(_t(context, 'مفيش تحويلات لسه.', 'No transfers yet.')));
        final incoming = list.where((t) => t['can_receive'] == true).toList();
        final rest = list.where((t) => t['can_receive'] != true).toList();
        return RefreshIndicator(
          onRefresh: () async => ref.refresh(_transfersProvider.future),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            if (incoming.isNotEmpty) ...[
              Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_t(context, '📦 مستنية استلامك (${incoming.length})', '📦 Waiting for you (${incoming.length})'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              for (final t in incoming) _TransferCard(t: t),
              const Divider(height: 28),
            ],
            for (final t in rest) _TransferCard(t: t),
          ]),
        );
      },
    );
  }
}

class _TransferCard extends ConsumerWidget {
  const _TransferCard({required this.t});
  final Map<String, dynamic> t;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = context.isAr;
    final status = '${t['status']}';
    final items = _maps(t['items']);
    final (label, color) = switch (status) {
      'pending' => (ar ? 'في الطريق' : 'On the way', BrandColors.warning),
      'received' => (ar ? 'اتستلم' : 'Received', BrandColors.success),
      'partial' => (ar ? 'اتستلم جزئيًا' : 'Partly received', BrandColors.warning),
      'rejected' => (ar ? 'اترفض' : 'Rejected', BrandColors.error),
      _ => (ar ? 'اتلغى' : 'Cancelled', BrandColors.gray),
    };
    final reasonText = t['reject_kind'] == null ? null : (t['reject_kind'] == 'other' ? '${t['reject_reason']}' : (ar ? 'القطع ما وصلتش' : 'Pieces did not arrive'));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${t['number']}', style: const TextStyle(fontWeight: FontWeight.w800))),
            Chip(visualDensity: VisualDensity.compact, label: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)), side: BorderSide(color: color)),
          ]),
          Row(children: [
            Flexible(child: Text('${t['from_name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(ar ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded, size: 18)),
            Flexible(child: Text('${t['to_name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          Text(ar ? 'حوّلها: ${t['created_by_name']} · ${'${t['created_at']}'.split('T').first}' : 'By ${t['created_by_name']} · ${'${t['created_at']}'.split('T').first}', style: Theme.of(context).textTheme.bodySmall),
          if (t['decided_by_name'] != null && status != 'pending')
            Text(ar ? 'الرد: ${t['decided_by_name']}' : 'Answered by ${t['decided_by_name']}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          for (final i in items)
            Text('• ${i['name_ar']} × ${i['qty_sent']}${i['qty_received'] != null && i['qty_received'] != i['qty_sent'] ? (ar ? '  (وصل ${i['qty_received']})' : '  (got ${i['qty_received']})') : ''}'),
          if (t['note'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('📝 ${t['note']}', style: Theme.of(context).textTheme.bodySmall)),
          if (reasonText != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text((ar ? 'السبب: ' : 'Reason: ') + reasonText, style: const TextStyle(color: BrandColors.error))),
          if (t['can_receive'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                Expanded(child: FilledButton.icon(onPressed: () => _receive(context, ref), icon: const Icon(Icons.check_circle_outline), label: Text(ar ? 'استلمت' : 'Received'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: () => _reject(context, ref), icon: const Icon(Icons.cancel_outlined), label: Text(ar ? 'مستلمتش' : 'Not received'))),
              ]),
            ),
          if (t['can_cancel'] == true && t['can_receive'] != true)
            Align(alignment: AlignmentDirectional.centerEnd, child: TextButton.icon(onPressed: () => _cancel(context, ref), icon: const Icon(Icons.undo_rounded, size: 18), label: Text(ar ? 'الغي التحويل' : 'Cancel'))),
        ]),
      ),
    );
  }

  Future<void> _receive(BuildContext context, WidgetRef ref) async {
    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _ReceiveSheet(t: t));
    if (ok == true) ref.invalidate(_transfersProvider);
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _ReasonSheet(t: t));
    if (ok == true) ref.invalidate(_transfersProvider);
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t(ctx, 'نلغي التحويل؟', 'Cancel the transfer?')),
        content: Text(_t(ctx, 'القطع هترجع لمخزن فرعك والفرع التاني هيتبلّغ.', 'The pieces return to your store and the other branch is told.')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'لأ', 'No'))), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'أيوه، الغيه', 'Yes, cancel')))],
      ),
    );
    if (yes != true || !context.mounted) return;
    try {
      await ref.read(supabaseProvider).rpc('stock_transfer_cancel', params: {'p_id': t['id']});
      ref.invalidate(_transfersProvider);
    } catch (e) {
      if (context.mounted) showSnack(context, _stockError(context, e), error: true);
    }
  }
}

// ------------------------------------------------------------------ receive / reject
class _ReceiveSheet extends ConsumerStatefulWidget {
  const _ReceiveSheet({required this.t});
  final Map<String, dynamic> t;
  @override
  ConsumerState<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends ConsumerState<_ReceiveSheet> {
  late final List<Map<String, dynamic>> _items = _maps(widget.t['items']);
  late final Map<String, int> _got = {for (final i in _items) '${i['product_id']}': (i['qty_sent'] as num).toInt()};
  String _kind = 'not_received';
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _short => _items.any((i) => _got['${i['product_id']}']! < (i['qty_sent'] as num).toInt());

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc('stock_transfer_receive', params: {
        'p_id': widget.t['id'],
        'p_items': [for (final i in _items) {'product_id': i['product_id'], 'qty': _got['${i['product_id']}']}],
        'p_kind': _short ? _kind : null,
        'p_reason': _short && _kind == 'other' ? _reason.text.trim() : null,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = _stockError(context, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ar ? 'استلام ${widget.t['number']} من ${widget.t['from_name']}' : 'Receive ${widget.t['number']} from ${widget.t['from_name']}', style: Theme.of(context).textTheme.titleMedium),
          Text(ar ? 'عدّل الكمية لو اللي وصل أقل من المكتوب.' : 'Lower the quantity if less arrived.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final i in _items)
            Row(children: [
              Expanded(child: Text('${i['name_ar']}  (${ar ? 'اتبعت' : 'sent'} ${i['qty_sent']})')),
              IconButton(onPressed: _got['${i['product_id']}']! > 0 ? () => setState(() => _got['${i['product_id']}'] = _got['${i['product_id']}']! - 1) : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('${_got['${i['product_id']}']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              IconButton(onPressed: _got['${i['product_id']}']! < (i['qty_sent'] as num).toInt() ? () => setState(() => _got['${i['product_id']}'] = _got['${i['product_id']}']! + 1) : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
          if (_short) ...[
            const Divider(),
            Text(ar ? 'ليه الكمية أقل؟' : 'Why less?', style: const TextStyle(fontWeight: FontWeight.w700)),
            RadioListTile<String>(dense: true, value: 'not_received', groupValue: _kind, onChanged: (v) => setState(() => _kind = v!), title: Text(ar ? 'القطع الناقصة ما وصلتش' : 'The missing pieces did not arrive')),
            RadioListTile<String>(dense: true, value: 'other', groupValue: _kind, onChanged: (v) => setState(() => _kind = v!), title: Text(ar ? 'سبب آخر' : 'Another reason')),
            if (_kind == 'other') TextField(controller: _reason, maxLength: 300, decoration: InputDecoration(labelText: ar ? 'اكتب السبب' : 'Write the reason', border: const OutlineInputBorder())),
            Text(ar ? 'القطع الناقصة هترجع لمخزن الفرع المُرسِل.' : 'Missing pieces go back to the sender branch.', style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BrandColors.error))),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(onPressed: _busy || _got.values.every((v) => v == 0) ? null : _send, icon: const Icon(Icons.check_rounded), label: Text(ar ? 'أكّد الاستلام' : 'Confirm receipt')),
          ),
        ]),
      ),
    );
  }
}

class _ReasonSheet extends ConsumerStatefulWidget {
  const _ReasonSheet({required this.t});
  final Map<String, dynamic> t;
  @override
  ConsumerState<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends ConsumerState<_ReasonSheet> {
  String _kind = 'not_received';
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc('stock_transfer_reject', params: {'p_id': widget.t['id'], 'p_kind': _kind, 'p_reason': _kind == 'other' ? _reason.text.trim() : null});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = _stockError(context, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ar ? 'رفض ${widget.t['number']}' : 'Reject ${widget.t['number']}', style: Theme.of(context).textTheme.titleMedium),
          Text(ar ? 'كل القطع هترجع لمخزن فرع ${widget.t['from_name']} ويتبلّغ.' : 'Everything goes back to ${widget.t['from_name']}, who is told.', style: Theme.of(context).textTheme.bodySmall),
          RadioListTile<String>(value: 'not_received', groupValue: _kind, onChanged: (v) => setState(() => _kind = v!), title: Text(ar ? 'مستلمتش التحويل ده' : 'I did not receive it')),
          RadioListTile<String>(value: 'other', groupValue: _kind, onChanged: (v) => setState(() => _kind = v!), title: Text(ar ? 'سبب آخر' : 'Another reason')),
          if (_kind == 'other') TextField(controller: _reason, maxLength: 300, decoration: InputDecoration(labelText: ar ? 'اكتب السبب' : 'Write the reason', border: const OutlineInputBorder())),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BrandColors.error))),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _busy ? null : _send, style: FilledButton.styleFrom(backgroundColor: BrandColors.error), icon: const Icon(Icons.close_rounded), label: Text(ar ? 'ارفض التحويل' : 'Reject'))),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ new transfer
class _NewTransferSheet extends ConsumerStatefulWidget {
  const _NewTransferSheet({this.product});
  final Map<String, dynamic>? product;
  @override
  ConsumerState<_NewTransferSheet> createState() => _NewTransferSheetState();
}

class _NewTransferSheetState extends ConsumerState<_NewTransferSheet> {
  String? _from, _to;
  final Map<String, ({Map<String, dynamic> p, int qty, int max})> _picked = {};
  final Map<String, TextEditingController> _qtyCtl = {};
  List<Map<String, dynamic>> _results = [];
  final _note = TextEditingController();
  final _search = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _qtyCtl.values) {
      c.dispose();
    }
    _note.dispose();
    _search.dispose();
    super.dispose();
  }

  int _qtyHere(Map<String, dynamic> p) {
    final b = _maps(p['branches']).where((e) => '${e['branch_id']}' == _from);
    return b.isEmpty ? 0 : (b.first['qty'] as num).toInt();
  }

  Future<void> _find() async {
    if (_from == null) return;
    try {
      final q = _search.text.trim();
      final r = _maps(await ref.read(supabaseProvider).rpc('stock_overview', params: {'p_branch': _from, 'p_search': q.isEmpty ? null : q, 'p_limit': 30}));
      if (mounted) setState(() => _results = r.where((p) => _qtyHere(p) > 0).toList());
    } catch (e) {
      if (mounted) setState(() => _error = _stockError(context, e));
    }
  }

  void _pick(Map<String, dynamic> p) {
    final max = _qtyHere(p);
    if (max <= 0) return;
    final id = '${p['product_id']}';
    _qtyCtl[id] ??= TextEditingController(text: '1');
    setState(() => _picked[id] = (p: p, qty: int.tryParse(_qtyCtl[id]!.text) ?? 1, max: max));
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc('stock_transfer_create', params: {
        'p_from': _from,
        'p_to': _to,
        'p_items': [for (final e in _picked.entries) {'product_id': e.key, 'qty': e.value.qty}],
        'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = _stockError(context, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final mine = ref.watch(_myBranchesProvider).valueOrNull ?? const [];
    final all = ref.watch(_viewBranchesProvider).valueOrNull ?? const [];
    if (_from == null && mine.length == 1) {
      _from = '${mine.first['id']}';
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _find();
        if (widget.product != null && mounted) {
          final hit = _results.where((r) => r['product_id'] == widget.product!['product_id']);
          if (hit.isNotEmpty) _pick(hit.first);
        }
      });
    }
    String nm(Map<String, dynamic> b) => ar ? '${b['name_ar']}' : '${b['name_en']}';
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .92),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ar ? 'تحويل منتجات لفرع تاني' : 'Transfer products to another branch', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _from,
              decoration: InputDecoration(labelText: ar ? 'من فرع' : 'From branch', border: const OutlineInputBorder()),
              items: [for (final b in mine) DropdownMenuItem(value: '${b['id']}', child: Text(nm(b)))],
              onChanged: (v) {
                setState(() {
                  _from = v;
                  _picked.clear();
                  _results = [];
                  if (_to == v) _to = null;
                });
                _find();
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _to,
              decoration: InputDecoration(labelText: ar ? 'إلى فرع' : 'To branch', border: const OutlineInputBorder()),
              items: [for (final b in all.where((b) => '${b['id']}' != _from)) DropdownMenuItem(value: '${b['id']}', child: Text(nm(b)))],
              onChanged: (v) => setState(() => _to = v),
            ),
            const SizedBox(height: 10),
            if (_from != null) ...[
              TextField(controller: _search, decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: ar ? 'دوّر في مخزن الفرع' : 'Search the branch store', isDense: true, border: const OutlineInputBorder()), onChanged: (_) => _find()),
              for (final p in _results.take(8))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${p['name_ar']}'),
                  subtitle: Text('${p['sku']} · ${ar ? 'في مخزن الفرع' : 'in store'}: ${_qtyHere(p)}'),
                  trailing: _picked.containsKey('${p['product_id']}') ? const Icon(Icons.check_circle, color: BrandColors.success) : const Icon(Icons.add_circle_outline),
                  onTap: () => _pick(p),
                ),
            ] else
              Text(ar ? 'اختار الفرع اللي بتحوّل منه الأول.' : 'Pick the branch you send from first.', style: Theme.of(context).textTheme.bodySmall),
            if (_picked.isNotEmpty) ...[
              const Divider(),
              Text(ar ? 'اللي هتحوّله' : 'To send', style: const TextStyle(fontWeight: FontWeight.w800)),
              for (final e in _picked.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text('${e.value.p['name_ar']}\n${ar ? 'المتاح في فرعك' : 'Available'}: ${e.value.max}', style: const TextStyle(height: 1.3))),
                    SizedBox(
                      width: 92,
                      child: TextField(
                        controller: _qtyCtl[e.key],
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                        decoration: InputDecoration(labelText: ar ? 'الكمية' : 'Qty', isDense: true, border: const OutlineInputBorder(), errorText: (e.value.qty < 1 || e.value.qty > e.value.max) ? (ar ? 'من 1 لـ ${e.value.max}' : '1 to ${e.value.max}') : null),
                        onChanged: (v) => setState(() => _picked[e.key] = (p: e.value.p, qty: int.tryParse(v.trim()) ?? 0, max: e.value.max)),
                      ),
                    ),
                    IconButton(
                      tooltip: ar ? 'شيل' : 'Remove',
                      onPressed: () => setState(() => _picked.remove(e.key)),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ]),
                ),
              TextField(controller: _note, maxLength: 300, decoration: InputDecoration(labelText: ar ? 'ملاحظة (اختياري)' : 'Note (optional)', border: const OutlineInputBorder())),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BrandColors.error))),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy || _from == null || _to == null || _picked.isEmpty || _picked.values.any((v) => v.qty < 1 || v.qty > v.max) ? null : _send,
                icon: const Icon(Icons.send_rounded),
                label: Text(ar ? 'ابعت التحويل' : 'Send transfer'),
              ),
            ),
            Text(ar ? 'القطع بتتشال من مخزن فرعك دلوقتي، والفرع التاني بيأكد استلامها.' : 'The pieces leave your store now; the other branch confirms receipt.', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}


/// Tap a product: where is it? His own branch first; the warehouse and the other branches only with the "see stock elsewhere" permission.
class _WhereSheet extends ConsumerWidget {
  const _WhereSheet({required this.product});
  final Map<String, dynamic> product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = context.isAr;
    final fut = ref.watch(_whereProvider('${product['product_id']}'));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: fut.when(
          loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(_stockError(context, e)),
          data: (d) {
            final bs = _maps(d['branches']);
            final wh = (d['warehouse'] as num?)?.toInt();
            final mine = bs.where((b) => b['mine'] == true).toList();
            final others = bs.where((b) => b['mine'] != true).toList();
            Widget row(IconData icon, String name, int qty, {bool strong = false, Color? color}) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(icon, color: color),
                  title: Text(name, style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
                  trailing: Text('$qty', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: qty == 0 ? BrandColors.gray : null)),
                );
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ar ? '${d['name_ar']}' : '${d['name_en']}', style: Theme.of(context).textTheme.titleMedium),
              Text('${d['sku']}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(ar ? 'مخزن فرعك' : 'Your branch store', style: const TextStyle(fontWeight: FontWeight.w800)),
              if (mine.isEmpty) Text(ar ? 'مفيش.' : 'None.'),
              for (final b in mine) row(Icons.store_mall_directory_rounded, ar ? '${b['name_ar']}' : '${b['name_en']}', (b['qty'] as num).toInt(), strong: true, color: BrandColors.success),
              const Divider(),
              if (d['can_see_others'] == true) ...[
                Text(ar ? 'المتاح في أماكن تانية' : 'Available elsewhere', style: const TextStyle(fontWeight: FontWeight.w800)),
                if (wh != null) row(Icons.warehouse_rounded, ar ? 'الوير هاوس' : 'Warehouse', wh, color: BrandColors.warning),
                for (final b in others) row(Icons.store_outlined, ar ? '${b['name_ar']}' : '${b['name_en']}', (b['qty'] as num).toInt()),
                if (d['total'] != null) Text(ar ? 'إجمالي المتجر: ${d['total']}' : 'Store total: ${d['total']}', style: Theme.of(context).textTheme.bodySmall),
              ] else
                Text(ar ? 'بتشوف مخزون فرعك بس. لو محتاج منتج مش عندك، اسأل الإدارة.' : 'You see your own branch store only. Ask the management if you need a product you do not have.', style: Theme.of(context).textTheme.bodySmall),
            ]);
          },
        ),
      ),
    );
  }
}
