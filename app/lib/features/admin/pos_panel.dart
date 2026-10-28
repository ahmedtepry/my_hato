import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/appearance.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/barcode_scanner.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'pos_receipt.dart';
import 'shift_reports.dart';
import 'pos_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));

String _newKey() {
  final r = math.Random.secure();
  return 'pos-${DateTime.now().microsecondsSinceEpoch}-${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

// =====================================================================================================
// Cashier (POS). Design: products on one side, the cart + cash on the other. Everything the cashier
// sees is checked again by the database: prices, stock, discount limits, approvals, branch and shift.
// =====================================================================================================
class PosPanel extends ConsumerWidget {
  const PosPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(posShiftProvider);
    if (a.hasValue) {
      final s = a.value;
      return s == null ? const _OpenShiftCard() : _Register(key: ValueKey(s['id']), shift: s);
    }
    if (a.hasError) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_err(context, a.error!)),
          const SizedBox(height: 10),
          FilledButton(onPressed: () => ref.invalidate(posShiftProvider), child: Text(_t(context, 'حاول تاني', 'Try again'))),
        ]),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}

// ---------------------------------------------------------------- open a shift
class _OpenShiftCard extends ConsumerStatefulWidget {
  const _OpenShiftCard();
  @override
  ConsumerState<_OpenShiftCard> createState() => _OpenShiftCardState();
}

class _OpenShiftCardState extends ConsumerState<_OpenShiftCard> {
  static const _kLogin = 'pos_remembered_login';
  final _cash = TextEditingController(text: '0');
  final _login = TextEditingController();
  final _pass = TextEditingController();
  String? _branch;
  bool _busy = false;
  bool _remember = false;
  bool _obscure = true;

  bool get _mayRemember => ref.read(staffContextProvider).valueOrNull?.permissions.contains('pos.remember_login') ?? false;

  @override
  void initState() {
    super.initState();
    _loadRemembered();
  }

  Future<void> _loadRemembered() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getString(_kLogin) ?? '';
      if (saved.isEmpty) return;
      if (!_mayRemember) {
        await p.remove(_kLogin); // the owner switched the right off: forget it
        return;
      }
      if (mounted) {
        setState(() {
          _login.text = saved;
          _remember = true;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _cash.dispose();
    _login.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _open(List<Map<String, dynamic>> branches) async {
    final b = _branch ?? (branches.length == 1 ? branches.first['id'] as String : null);
    final minor = parseEgpToMinor(_cash.text);
    if (b == null || minor == null) {
      showSnack(context, _t(context, 'اختار الفرع واكتب العهدة (ممكن صفر)', 'Pick the branch and type the opening cash (0 is fine)'), error: true);
      return;
    }
    if (_login.text.trim().isEmpty || _pass.text.isEmpty) {
      showSnack(context, _t(context, 'اكتب اسم المستخدم والباسورد علشان تفتح الوردية', 'Type your username and password to open the shift'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(posRepoProvider);
      if (!await repo.verifyLogin(_login.text, _pass.text)) {
        if (mounted) showSnack(context, _t(context, 'اسم المستخدم أو الباسورد غلط، أو مش بتاعك', 'Wrong username or password, or not yours'), error: true);
        return;
      }
      try {
        final p = await SharedPreferences.getInstance();
        if (_remember && _mayRemember) {
          await p.setString(_kLogin, _login.text.trim());
        } else {
          await p.remove(_kLogin);
        }
      } catch (_) {}
      _pass.clear();
      await repo.openShift(b, minor);
      ref.invalidate(posShiftProvider);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final branches = ref.watch(posBranchesProvider);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Card(
          margin: const EdgeInsets.all(20),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: branches.when(
              loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => Text(_err(context, e)),
              data: (list) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.point_of_sale_rounded, size: 46, color: BrandColors.electric),
                const SizedBox(height: 10),
                Text(_t(context, 'ابدأ وردية جديدة', 'Start a new shift'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(_t(context, 'عدّ اللي في الدرج واكتبه. في آخر الوردية هنقارنه بالمبيعات.', 'Count the drawer and type it. At the end of the shift it is compared with the sales.'),
                    textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray)),
                const SizedBox(height: 16),
                if (list.isEmpty)
                  Text(_t(context, 'مفيش فرع متاح ليك. اطلب من المالك يحدد فروعك.', 'No branch is assigned to you. Ask the owner.'), style: const TextStyle(color: BrandColors.error))
                else ...[
                  if (list.length > 1)
                    DropdownButtonFormField<String>(
                      value: _branch,
                      decoration: InputDecoration(labelText: _t(context, 'الفرع', 'Branch')),
                      items: [for (final b in list) DropdownMenuItem(value: b['id'] as String, child: Text(_t(context, '${b['name_ar']}', '${b['name_en']}')))],
                      onChanged: (v) => setState(() => _branch = v),
                    )
                  else
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.store_mall_directory_outlined),
                      title: Text(_t(context, '${list.first['name_ar']}', '${list.first['name_en']}')),
                    ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _cash,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: _t(context, 'العهدة في الدرج (ج.م)', 'Opening cash (EGP)')),
                    onSubmitted: (_) => _open(list),
                  ),
                  const SizedBox(height: 14),
                  Text(_t(context, 'تأكيد هويتك', 'Confirm it is you'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _login,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    decoration: InputDecoration(labelText: _t(context, 'اسم المستخدم', 'Username'), prefixIcon: const Icon(Icons.person_outline_rounded)),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _pass,
                    obscureText: _obscure,
                    onSubmitted: (_) => _open(list),
                    decoration: InputDecoration(
                      labelText: _t(context, 'الباسورد', 'Password'),
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => _obscure = !_obscure)),
                    ),
                  ),
                  if (_mayRemember)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(_t(context, 'احفظ اسم المستخدم على الجهاز ده', 'Remember my username on this device')),
                      subtitle: Text(_t(context, 'الباسورد مبيتحفظش أبدًا', 'The password is never saved'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                      value: _remember,
                      onChanged: (v) => setState(() => _remember = v ?? false),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _busy ? null : () => _open(list), child: Text(_busy ? '…' : _t(context, 'فتح الوردية', 'Open shift'))),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- the register
class _Line {
  _Line(this.p, this.q);
  final Map<String, dynamic> p;
  int q;
  int get price => (p['price_minor'] as num).toInt();
}

class _Register extends ConsumerStatefulWidget {
  const _Register({super.key, required this.shift});
  final Map<String, dynamic> shift;
  @override
  ConsumerState<_Register> createState() => _RegisterState();
}

class _RegisterState extends ConsumerState<_Register> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _discount = TextEditingController();
  final _cash = TextEditingController();
  final _cart = <String, _Line>{};
  List<Map<String, dynamic>> _products = const [];
  bool _loadingProducts = true;
  String? _productsError;
  Timer? _debounce;
  bool _busy = false;
  bool _showCart = false; // narrow screens: products or cart
  bool _tip = false; // the customer left the change as a tip (recorded on the sale right after it is saved)
  String? _key; // idempotency key of the sale being sent (kept while the result is unknown)
  bool _unknown = false; // the last send may have reached the server: the cart is locked until it is re-sent
  String? _approvalId;
  int _approvalAmount = 0;

  String get _shiftId => widget.shift['id'] as String;
  String get _branchId => widget.shift['branch_id'] as String;

  @override
  void initState() {
    super.initState();
    _loadProducts('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _discount.dispose();
    _cash.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>?> _loadProducts(String q) async {
    setState(() {
      _loadingProducts = true;
      _productsError = null;
    });
    try {
      final r = await ref.read(posRepoProvider).searchProducts(q);
      if (!mounted || _search.text.trim() != q.trim()) return null;
      setState(() {
        _products = r;
        _loadingProducts = false;
      });
      return r;
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingProducts = false;
          _productsError = _err(context, e);
        });
      }
      return null;
    }
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () => _loadProducts(v));
  }

  /// Enter in the search box (or a barcode scanner typing + Enter): the exact code goes straight to the cart.
  Future<void> _submitSearch() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    final r = await _loadProducts(q);
    if (r == null || !mounted) return;
    final exact = r.where((p) => '${p['sku']}'.toLowerCase() == q.toLowerCase()).toList();
    final pick = exact.length == 1 ? exact.first : (r.length == 1 ? r.first : null);
    if (pick != null) {
      _add(pick);
      _search.clear();
      _loadProducts('');
      _searchFocus.requestFocus();
    } else if (r.isEmpty) {
      showSnack(context, _t(context, 'مفيش منتج بالكود أو الاسم ده', 'No product with this code or name'), error: true);
    }
  }

  Future<void> _scan() async {
    final code = await scanBarcode(context);
    if (code == null || !mounted) return;
    _search.text = code;
    await _submitSearch();
  }

  void _add(Map<String, dynamic> p) {
    if (_unknown) return;
    final id = p['id'] as String;
    final stock = (p['stock_quantity'] as num).toInt();
    final line = _cart[id];
    final limits = ref.read(posLimitsProvider).valueOrNull;
    final allowNeg = limits?['allow_negative_stock'] == true;
    if ((line?.q ?? 0) + 1 > stock && !allowNeg) {
      showSnack(context, _t(context, 'المتاح من ${p['name_ar']} هو $stock بس', 'Only $stock of ${p['name_en']} in stock'), error: true);
      return;
    }
    setState(() {
      if (line == null) {
        _cart[id] = _Line(p, 1);
      } else {
        line.q++;
      }
    });
  }

  void _change(String id, int d) {
    if (_unknown) return;
    final line = _cart[id];
    if (line == null) return;
    final stock = (line.p['stock_quantity'] as num).toInt();
    final allowNeg = ref.read(posLimitsProvider).valueOrNull?['allow_negative_stock'] == true;
    setState(() {
      final n = line.q + d;
      if (n <= 0) {
        _cart.remove(id);
      } else if (n <= stock || allowNeg || d < 0) {
        line.q = n;
      }
    });
  }

  int get _subtotal => _cart.values.fold(0, (s, l) => s + l.price * l.q);
  int get _discountMinor => parseEgpToMinor(_discount.text) ?? 0;
  int get _total => _subtotal - _discountMinor;

  void _reset() {
    _cart.clear();
    _discount.clear();
    _cash.clear();
    _key = null;
    _tip = false;
    _unknown = false;
    _approvalId = null;
    _approvalAmount = 0;
  }

  Future<void> _complete() async {
    if (_busy || _cart.isEmpty) return;
    final discount = _discountMinor;
    final cash = parseEgpToMinor(_cash.text);
    if (discount < 0 || discount > _subtotal) {
      showSnack(context, _t(context, 'الخصم مش مظبوط', 'Invalid discount'), error: true);
      return;
    }
    if (cash == null || cash < _total) {
      final missing = _total - (cash ?? 0);
      showSnack(context, _t(context, 'لسه ناقص ${_money(context, missing)}، خد المبلغ كامل من العميل', 'Still ${_money(context, missing)} short, take the full amount'), error: true);
      return;
    }
    // more than the total: the cashier must hand the change back, and confirms he did, before the sale is completed
    if (cash > _total && _key == null) {
      final r = await showDialog<String>(context: context, barrierDismissible: false, builder: (_) => _ChangeDialog(change: cash - _total));
      if (r == null || r == 'back' || !mounted) return;
      _tip = r == 'tip';
    }
    setState(() => _busy = true);
    try {
      _key ??= _newKey();
      String? approval = (_approvalId != null && _approvalAmount >= discount && discount > 0) ? _approvalId : null;
      Map<String, dynamic>? sale;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          sale = await ref.read(posRepoProvider).createSale(
                idempotencyKey: _key!,
                shiftId: _shiftId,
                items: [for (final e in _cart.entries) {'product_id': e.key, 'quantity': e.value.q}],
                discountMinor: discount,
                cashMinor: cash,
                approvalId: approval,
              );
          break;
        } on PostgrestException catch (e) {
          if (e.message.contains('APPROVAL_REQUIRED') && discount > 0 && attempt == 0) {
            approval = await askApproval(context, ref.read(posRepoProvider), kind: 'discount', amountMinor: discount, branchId: _branchId);
            if (approval == null) return; // asked and not approved: nothing was sold
            _approvalId = approval;
            _approvalAmount = discount;
            continue;
          }
          rethrow;
        }
      }
      if (sale == null || !mounted) return;
      var done = sale;
      if (_tip) {
        try {
          done = await ref.read(posRepoProvider).markTip('${sale['id']}');
        } catch (_) {
          if (mounted) showSnack(context, _t(context, 'البيعة اتسجلت لكن البقشيش ماتسجلش، سجّله من الفاتورة', 'The sale was saved but the tip was not recorded'), error: true);
        }
      }
      setState(_reset);
      ref.invalidate(posShiftProvider);
      _loadProducts(_search.text);
      if (await receiptAutoPrintOn() && mounted) unawaited(printReceipt(context, done));
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (_) => _ReceiptDialog(sale: done));
      if (mounted) _searchFocus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      if (posDefinitiveError(e)) {
        _key = null; // the server refused: nothing was saved, a new attempt gets a new key
        if ('$e'.contains('OUT_OF_STOCK')) _loadProducts(_search.text);
        showSnack(context, _err(context, e), error: true);
      } else {
        // no answer: the sale may or may not be saved. Lock the cart; re-sending with the same key can never double-sell.
        setState(() => _unknown = true);
        showSnack(context, _t(context, 'مفيش رد من السيرفر. اضغط «إعادة المحاولة» ومش هيتسجل البيع مرتين.', 'No answer from the server. Press Retry; the sale will never be recorded twice.'), error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeShift() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _CloseShiftDialog(shiftId: _shiftId));
    if (ok == true) {
      ref.invalidate(posShiftProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.shift;
    final bar = Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 6, children: [
          const Icon(Icons.circle, size: 10, color: BrandColors.success),
          Text(_t(context, 'وردية مفتوحة', 'Shift open'), style: const TextStyle(fontWeight: FontWeight.w800)),
          Text('· ${s['branch_name_ar'] ?? ''}', style: const TextStyle(color: BrandColors.gray)),
          Text('· ${_t(context, 'مبيعات', 'Sales')} ${_money(context, (s['sales_minor'] as num?) ?? 0)} (${s['sales_count'] ?? 0})', style: const TextStyle(color: BrandColors.gray)),
          Text('· ${_t(context, 'المفروض في الدرج', 'Expected in drawer')} ${_money(context, (s['expected_minor'] as num?) ?? 0)}', style: const TextStyle(color: BrandColors.gray)),
          OutlinedButton.icon(
            icon: const Icon(Icons.assignment_return_outlined, size: 18),
            label: Text(_t(context, 'مرتجع', 'Refund')),
            onPressed: _unknown ? null : () => showDialog<void>(context: context, builder: (_) => _RefundDialog(shiftId: _shiftId, branchId: _branchId)).then((_) => ref.invalidate(posShiftProvider)),
          ),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.lock_clock_outlined, size: 18),
            label: Text(_t(context, 'إقفال الوردية', 'Close shift')),
            onPressed: _unknown || _cart.isNotEmpty ? null : _closeShift,
          ),
        ]),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f2): () => _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f9): _complete,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 600; // products and cart together on one page; only a phone-sized window stacks them
          final cartW = c.maxWidth >= 900 ? 380.0 : 310.0;
          return Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              bar,
              const SizedBox(height: 12),
              if (!wide)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: false, icon: const Icon(Icons.grid_view_rounded), label: Text(_t(context, 'المنتجات', 'Products'))),
                      ButtonSegment(value: true, icon: const Icon(Icons.shopping_cart_outlined), label: Text('${_t(context, 'السلة', 'Cart')} (${_cart.length})')),
                    ],
                    selected: {_showCart},
                    onSelectionChanged: (v) => setState(() => _showCart = v.first),
                  ),
                ),
              Expanded(
                child: wide
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: _productsPane()),
                        const SizedBox(width: 14),
                        SizedBox(width: cartW, child: _cartPane()),
                      ])
                    : (_showCart ? _cartPane() : _productsPane()),
              ),
            ]),
          );
        }),
      ),
    );
  }

  // ---- products
  Widget _productsPane() {
    return Column(children: [
      TextField(
        controller: _search,
        focusNode: _searchFocus,
        autofocus: true,
        onChanged: _onSearchChanged,
        onSubmitted: (_) => _submitSearch(),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: _t(context, 'امسح الباركود أو اكتب اسم المنتج…  (F2)', 'Scan the barcode or type the product name…  (F2)'),
          prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
          suffixIcon: IconButton(icon: const Icon(Icons.camera_alt_outlined), tooltip: _t(context, 'مسح بالكاميرا', 'Scan with camera'), onPressed: _scan),
        ),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: _productsError != null
            ? Center(child: Text(_productsError!))
            : (_loadingProducts && _products.isEmpty)
                ? const Center(child: CircularProgressIndicator())
                : _products.isEmpty
                    ? Center(child: Text(_t(context, 'مفيش منتجات', 'No products'), style: const TextStyle(color: BrandColors.gray)))
                    : LayoutBuilder(builder: (_, g) {
                        // 4 products across and 3 rows fill the pane exactly; scroll for more
                        final rowH = ((g.maxHeight - 16) / 3).clamp(132.0, 230.0);
                        return GridView.builder(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisExtent: rowH, crossAxisSpacing: 8, mainAxisSpacing: 8),
                          itemCount: _products.length,
                          itemBuilder: (_, i) => _ProductCard(p: _products[i], inCart: _cart[_products[i]['id']]?.q ?? 0, onTap: () => _add(_products[i]), onMinus: () => _change(_products[i]['id'] as String, -1)),
                        );
                      }),
      ),
    ]);
  }

  // ---- cart + cash
  Widget _cartPane() {
    final sub = _subtotal;
    final disc = _discountMinor;
    final total = sub - disc;
    final cash = parseEgpToMinor(_cash.text);
    final change = cash == null ? null : cash - total;
    final limits = ref.watch(posLimitsProvider).valueOrNull;
    final pct = sub > 0 ? disc * 100 / sub : 0;
    final needsApproval = disc > 0 &&
        limits != null &&
        limits['is_owner'] != true &&
        (limits['can_discount'] != true || pct > ((limits['discount_approval_pct'] as num?) ?? 10));
    final quick = <int>{
      total,
      for (final step in const [5000, 10000, 20000, 50000]) ((total + step - 1) ~/ step) * step,
    }.where((v) => v >= total && total > 0).toList()
      ..sort();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(_t(context, 'السلة', 'Cart'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (_cart.isNotEmpty && !_unknown)
              TextButton.icon(
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: Text(_t(context, 'فضّي', 'Clear')),
                onPressed: () => setState(_reset),
              ),
          ]),
          if (_unknown)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFFFF3D6), borderRadius: BorderRadius.circular(10)),
              child: Text(_t(context, 'مش متأكدين إن البيع اتسجّل. السلة مقفولة لحد ما تعيد المحاولة (مش هيتكرر).', 'Not sure the sale was saved. The cart is locked until you retry (it cannot repeat).'),
                  style: const TextStyle(fontSize: 13)),
            ),
          Expanded(
            child: _cart.isEmpty
                ? Center(child: Text(_t(context, 'السلة فاضية. امسح منتج أو اضغط عليه.', 'Cart is empty. Scan or tap a product.'), style: const TextStyle(color: BrandColors.gray)))
                : ListView(children: [
                    for (final e in _cart.entries)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(_t(context, '${e.value.p['name_ar']}', '${e.value.p['name_en']}'), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${_money(context, e.value.price)}  ×  ${e.value.q}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove_circle_outline), onPressed: _unknown ? null : () => _change(e.key, -1)),
                          Text('${e.value.q}', style: const TextStyle(fontWeight: FontWeight.w800)),
                          IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline), onPressed: _unknown ? null : () => _change(e.key, 1)),
                          SizedBox(width: 74, child: Text(_money(context, e.value.price * e.value.q), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
                        ]),
                      ),
                  ]),
          ),
          const Divider(),
          TextField(
            controller: _discount,
            enabled: !_unknown,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              labelText: _t(context, 'خصم (ج.م)', 'Discount (EGP)'),
              helperText: needsApproval ? _t(context, 'الخصم ده محتاج موافقة مسؤول', 'This discount needs a manager approval') : null,
              helperStyle: const TextStyle(color: BrandColors.warning),
            ),
          ),
          const SizedBox(height: 8),
          _row(_t(context, 'المجموع', 'Subtotal'), _money(context, sub)),
          if (disc > 0) _row(_t(context, 'الخصم', 'Discount'), '- ${_money(context, disc)}'),
          _row(_t(context, 'الإجمالي', 'Total'), _money(context, total < 0 ? 0 : total), big: true),
          const SizedBox(height: 8),
          TextField(
            controller: _cash,
            enabled: !_unknown,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _complete(),
            decoration: InputDecoration(isDense: true, labelText: _t(context, 'المبلغ المستلم (ج.م)', 'Cash received (EGP)')),
          ),
          if (quick.isNotEmpty && !_unknown)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                for (final v in quick.take(4))
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(v == total ? _t(context, 'بالظبط', 'Exact') : _money(context, v)),
                    onPressed: () => setState(() => _cash.text = (v / 100).toStringAsFixed(v % 100 == 0 ? 0 : 2)),
                  ),
              ]),
            ),
          if (change != null && total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _row(change >= 0 ? _t(context, 'الباقي للعميل', 'Change') : _t(context, 'ناقص', 'Missing'), _money(context, change.abs()), color: change >= 0 ? BrandColors.success : BrandColors.error, big: true),
            ),
          const SizedBox(height: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Icon(_unknown ? Icons.refresh_rounded : Icons.check_circle_outline),
            label: Text(
              _unknown ? _t(context, 'إعادة المحاولة', 'Retry') : _t(context, 'إتمام البيع  (F9)', 'Complete sale  (F9)'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            onPressed: (_busy || _cart.isEmpty) ? null : _complete,
          ),
        ]),
      ),
    );
  }

  Widget _row(String l, String r, {bool big = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l, style: TextStyle(fontSize: big ? 18 : 14, fontWeight: big ? FontWeight.w800 : FontWeight.w500, color: color)),
          Text(r, style: TextStyle(fontSize: big ? 22 : 14, fontWeight: FontWeight.w800, color: color ?? (big ? BrandColors.navy : null))),
        ]),
      );
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.p, required this.inCart, required this.onTap, required this.onMinus});
  final Map<String, dynamic> p;
  final int inCart;
  final VoidCallback onTap, onMinus;

  @override
  Widget build(BuildContext context) {
    final stock = (p['stock_quantity'] as num).toInt();
    final low = stock <= 3;
    final sku = '${p['sku'] ?? ''}'.trim();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: inCart > 0 ? const Color(0xFFF0F8FF) : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), gradient: const LinearGradient(colors: [Color(0xFFDFF2FF), Color(0xFFE8EEFF)])),
                child: const Icon(Icons.shopping_bag_outlined, size: 17, color: BrandColors.electric),
              ),
              const Spacer(),
              if (inCart > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 26),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(color: BrandColors.electric, borderRadius: BorderRadius.circular(9)),
                  child: Text('$inCart', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                ),
            ]),
            const SizedBox(height: 5),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: _t(context, '${p['name_ar']}', '${p['name_en']}'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (sku.isNotEmpty) TextSpan(text: ' ($sku)', style: const TextStyle(color: BrandColors.gray, fontSize: 10.5)),
                ]),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, height: 1.25),
              ),
            ),
            Text(_money(context, p['price_minor'] as num), style: const TextStyle(color: BrandColors.navy, fontWeight: FontWeight.w800, fontSize: 14)),
            Text(
              stock <= 0 ? _t(context, 'خلصان', 'Out of stock') : _t(context, 'متاح $stock', '$stock in stock'),
              style: TextStyle(fontSize: 10.5, color: stock <= 0 ? BrandColors.error : (low ? BrandColors.warning : BrandColors.gray)),
            ),
            if (inCart > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: onMinus,
                  child: Container(
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: BrandColors.error.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.remove_rounded, size: 15, color: BrandColors.error),
                      Text(_t(context, 'ناقص', 'Less'), style: const TextStyle(color: BrandColors.error, fontSize: 12, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The customer paid more than the total: the cashier either hands the change back, or records that the customer left it as a tip.
class _ChangeDialog extends StatelessWidget {
  const _ChangeDialog({required this.change});
  final int change;

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.payments_rounded, color: BrandColors.warning, size: 44),
        title: Text(_t(context, 'الباقي للعميل', 'Change due'), textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_money(context, change), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: BrandColors.navy)),
          const SizedBox(height: 10),
          Text(_t(context, 'رجعت الباقي للعميل؟ ولا سابه بقشيش؟', 'Did you hand the change back, or did the customer leave it as a tip?'),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(_t(context, 'الدرج بيحسب قيمة المنتج بس، والبقشيش بيتسجل باسمك على الفاتورة.', 'The drawer counts the product value only; a tip is recorded on the invoice.'),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: BrandColors.gray)),
        ]),
        actionsAlignment: MainAxisAlignment.center,
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'back'), child: Text(_t(context, 'لأ، رجوع', 'No, go back'))),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, 'tip'),
            icon: const Icon(Icons.volunteer_activism_rounded),
            label: Text(_t(context, 'سابه بقشيش', 'Left as a tip')),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, 'returned'),
            child: Text(_t(context, 'أيوه رجعت', 'Yes, handed back')),
          ),
        ],
      );
}

// ---------------------------------------------------------------- receipt
String receiptText(BuildContext c, Map<String, dynamic> sale) {
  final lines = StringBuffer()
    ..writeln(AppName.of(c.lang))
    ..writeln('${sale['branch_name_ar'] ?? ''}')
    ..writeln('${_t(c, 'فاتورة', 'Invoice')} ${sale['number']}')
    ..writeln('${DateTime.tryParse('${sale['created_at']}')?.toLocal().toString().substring(0, 16) ?? ''}')
    ..writeln('--------------------');
  for (final i in (sale['items'] as List).cast<Map>()) {
    lines.writeln('${i['name_ar']} × ${i['quantity']}   ${_money(c, i['line_total_minor'] as num)}');
  }
  lines.writeln('--------------------');
  if ((sale['discount_minor'] as num) > 0) lines.writeln('${_t(c, 'خصم', 'Discount')}: ${_money(c, sale['discount_minor'] as num)}');
  lines
    ..writeln('${_t(c, 'الإجمالي', 'Total')}: ${_money(c, sale['total_minor'] as num)}')
    ..writeln('${_t(c, 'المستلم', 'Cash')}: ${_money(c, sale['cash_received_minor'] as num)}')
    ..writeln('${_t(c, 'الباقي', 'Change')}: ${_money(c, ((sale['change_minor'] as num) - ((sale['tip_minor'] as num?) ?? 0)))}')
    ..writeln(((sale['tip_minor'] as num?) ?? 0) > 0 ? '${_t(c, 'بقشيش', 'Tip')}: ${_money(c, sale['tip_minor'] as num)}' : '')
    ..writeln(_t(c, 'شكراً لثقتكم', 'Thank you'));
  return lines.toString();
}

class _ReceiptDialog extends StatelessWidget {
  const _ReceiptDialog({required this.sale});
  final Map<String, dynamic> sale;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.check_circle_rounded, color: BrandColors.success, size: 44),
      title: Text(_t(context, 'تم البيع ✅', 'Sale completed ✅'), textAlign: TextAlign.center),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: ReceiptPaper(sale: sale),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ReceiptButtons(sale: sale, text: receiptText(context, sale)),
        ),
        TextButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(_t(context, 'نسخ الإيصال', 'Copy receipt')),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: receiptText(context, sale)));
            if (context.mounted) showSnack(context, _t(context, 'اتنسخ', 'Copied'));
          },
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'بيع جديد', 'New sale'))),
      ],
    );
  }
}

// ---------------------------------------------------------------- approvals (cashier side)
/// Asks for the reason, sends the request and waits for ANOTHER person to approve it. Returns the approval id, or null.
Future<String?> askApproval(BuildContext context, PosRepository repo, {required String kind, required int amountMinor, required String branchId}) async {
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => _ReasonDialog(
      title: kind == 'discount' ? _t(context, 'طلب موافقة على خصم ${_money(context, amountMinor)}', 'Approval for a ${_money(context, amountMinor)} discount') : _t(context, 'طلب موافقة على مرتجع ${_money(context, amountMinor)}', 'Approval for a ${_money(context, amountMinor)} refund'),
      hint: _t(context, 'السبب (مطلوب)', 'Reason (required)'),
      action: _t(context, 'ابعت للمسؤول', 'Send to manager'),
    ),
  );
  if (reason == null || !context.mounted) return null;
  String id;
  try {
    id = await repo.requestApproval(kind: kind, amountMinor: amountMinor, reason: reason, branchId: branchId);
  } catch (e) {
    if (context.mounted) showSnack(context, _err(context, e), error: true);
    return null;
  }
  if (!context.mounted) return null;
  final res = await showDialog<String>(context: context, barrierDismissible: false, builder: (_) => _WaitApprovalDialog(repo: repo, id: id));
  if (!context.mounted) return null;
  if (res == 'approved') return id;
  if (res != null && res.startsWith('rejected')) {
    final note = res.length > 9 ? res.substring(9) : '';
    showSnack(context, _t(context, 'اترفض${note.isEmpty ? '' : ': $note'}', 'Rejected${note.isEmpty ? '' : ': $note'}'), error: true);
  }
  return null;
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.hint, required this.action});
  final String title, hint, action;
  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title, style: const TextStyle(fontSize: 17)),
        content: SizedBox(width: 380, child: TextField(controller: _c, autofocus: true, maxLength: 200, decoration: InputDecoration(labelText: widget.hint), onChanged: (_) => setState(() {}))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'رجوع', 'Back'))),
          FilledButton(onPressed: _c.text.trim().length < 3 ? null : () => Navigator.pop(context, _c.text.trim()), child: Text(widget.action)),
        ],
      );
}

class _WaitApprovalDialog extends StatefulWidget {
  const _WaitApprovalDialog({required this.repo, required this.id});
  final PosRepository repo;
  final String id;
  @override
  State<_WaitApprovalDialog> createState() => _WaitApprovalDialogState();
}

class _WaitApprovalDialogState extends State<_WaitApprovalDialog> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  Future<void> _check() async {
    try {
      final r = await widget.repo.approvalStatus(widget.id);
      final st = r?['status'];
      if (!mounted) return;
      if (st == 'approved') Navigator.pop(context, 'approved');
      if (st == 'rejected') Navigator.pop(context, 'rejected:${r?['decision_note'] ?? ''}');
    } catch (_) {/* keep waiting */}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t(context, 'مستني موافقة المسؤول…', 'Waiting for a manager…')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 14),
          Text(_t(context, 'المسؤول وصله إشعار. هتكمّل أول ما يوافق.', 'The manager has been notified. You continue as soon as it is approved.'), textAlign: TextAlign.center),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إلغاء الطلب', 'Stop waiting')))],
      );
}

// ---------------------------------------------------------------- refund
class _RefundDialog extends ConsumerStatefulWidget {
  const _RefundDialog({required this.shiftId, required this.branchId});
  final String shiftId, branchId;
  @override
  ConsumerState<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends ConsumerState<_RefundDialog> {
  final _number = TextEditingController();
  final _reason = TextEditingController();
  Map<String, dynamic>? _sale;
  final _qty = <String, int>{};
  bool _restock = true;
  bool _busy = false;
  late final Future<List<Map<String, dynamic>>> _recent = ref.read(posRepoProvider).recentSales(widget.shiftId);

  @override
  void dispose() {
    _number.dispose();
    _reason.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _items => [for (final i in (_sale?['items'] as List? ?? const [])) Map<String, dynamic>.from(i as Map)];

  int _amountFor(Map<String, dynamic> it, int q) {
    final qty = (it['quantity'] as num).toInt();
    final done = (it['refunded_qty'] as num).toInt();
    final net = (it['net_line_minor'] as num).toInt();
    final ra = (it['refunded_amount_minor'] as num).toInt();
    return q == qty - done ? net - ra : (net * q / qty).round();
  }

  int get _total => _items.fold(0, (s, it) => s + _amountFor(it, _qty[it['id']] ?? 0) * ((_qty[it['id']] ?? 0) > 0 ? 1 : 0));

  Future<void> _find([String? n]) async {
    final no = (n ?? _number.text).trim();
    if (no.isEmpty) return;
    setState(() => _busy = true);
    try {
      final s = await ref.read(posRepoProvider).findSale(no);
      if (mounted) {
        setState(() {
          _sale = s;
          _qty.clear();
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final items = [for (final it in _items) if ((_qty[it['id']] ?? 0) > 0) {'item_id': it['id'], 'quantity': _qty[it['id']]}];
    if (items.isEmpty) return;
    if (_reason.text.trim().length < 3) {
      showSnack(context, _t(context, 'اكتب سبب المرتجع', 'Write the refund reason'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(posRepoProvider);
      String? approval;
      Map<String, dynamic>? res;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          res = await repo.refund(saleId: _sale!['id'] as String, items: items, reason: _reason.text.trim(), restock: _restock, approvalId: approval);
          break;
        } on PostgrestException catch (e) {
          if (e.message.contains('APPROVAL_REQUIRED') && attempt == 0) {
            approval = await askApproval(context, repo, kind: 'refund', amountMinor: _total, branchId: widget.branchId);
            if (approval == null) return;
            continue;
          }
          rethrow;
        }
      }
      if (res == null || !mounted) return;
      // the message first: after the dialog is closed its context can no longer be used (that raised a false "error" after a saved refund)
      showSnack(context, _t(context, 'تم المرتجع ${_money(context, res['amount_minor'] as num)} — رجّعهم للعميل من الدرج', 'Refunded ${_money(context, res['amount_minor'] as num)} — pay it from the drawer'));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_t(context, 'مرتجع', 'Refund')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_sale == null) ...[
              TextField(
                controller: _number,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(labelText: _t(context, 'رقم الفاتورة (POS-…)', 'Invoice number (POS-…)'), suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => _find())),
                onSubmitted: (_) => _find(),
              ),
              const SizedBox(height: 10),
              Text(_t(context, 'فواتير وردتك', 'Your shift invoices'), style: const TextStyle(color: BrandColors.gray)),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _recent,
                builder: (_, snap) {
                  final l = snap.data ?? const [];
                  return Column(children: [
                    for (final s in l.take(8))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${s['number']}'),
                        trailing: Text(_money(context, s['total_minor'] as num)),
                        onTap: () => _find('${s['number']}'),
                      ),
                  ]);
                },
              ),
            ] else ...[
              Text('${_sale!['number']} · ${_money(context, _sale!['total_minor'] as num)}', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              ReceiptButtons(sale: _sale!, text: receiptText(context, _sale!)),
              const SizedBox(height: 6),
              for (final it in _items)
                Builder(builder: (_) {
                  final left = (it['quantity'] as num).toInt() - (it['refunded_qty'] as num).toInt();
                  final q = _qty[it['id']] ?? 0;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${it['name_ar']}'),
                    subtitle: Text(left == 0 ? _t(context, 'اترجّع بالكامل', 'Fully refunded') : _t(context, 'المتاح للإرجاع: $left', 'Refundable: $left')),
                    trailing: left == 0
                        ? null
                        : Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: q > 0 ? () => setState(() => _qty['${it['id']}'] = q - 1) : null),
                            Text('$q', style: const TextStyle(fontWeight: FontWeight.w800)),
                            IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: q < left ? () => setState(() => _qty['${it['id']}'] = q + 1) : null),
                          ]),
                  );
                }),
              TextField(controller: _reason, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'سبب المرتجع (مطلوب)', 'Reason (required)'))),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _restock, onChanged: (v) => setState(() => _restock = v), title: Text(_t(context, 'رجّع القطعة للمخزون', 'Put the item back in stock'))),
              Text('${_t(context, 'هتدفع للعميل', 'Pay the customer')}: ${_money(context, _total)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إغلاق', 'Close'))),
        if (_sale != null) FilledButton(onPressed: (_busy || _total <= 0) ? null : _submit, child: Text(_t(context, 'تنفيذ المرتجع', 'Refund'))),
      ],
    );
  }
}

// ---------------------------------------------------------------- close shift
class _CloseShiftDialog extends ConsumerStatefulWidget {
  const _CloseShiftDialog({required this.shiftId});
  final String shiftId;
  @override
  ConsumerState<_CloseShiftDialog> createState() => _CloseShiftDialogState();
}

class _CloseShiftDialogState extends ConsumerState<_CloseShiftDialog> {
  final _counted = TextEditingController();
  final _note = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;
  late final Future<Map<String, dynamic>> _summary = ref.read(posRepoProvider).shiftSummary(widget.shiftId);
  bool _busy = false;

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _close(int counted) async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(posRepoProvider).closeShift(widget.shiftId, counted, _note.text.trim().isEmpty ? null : _note.text.trim(), _pass.text);
      if (!mounted) return;
      if (r['ok'] != true) {
        showSnack(context, _t(context, 'الباسورد غلط، الوردية لسه مفتوحة', 'Wrong password, the shift is still open'), error: true);
        _pass.clear();
        return;
      }
      _pass.clear();
      // the final closing report: shown at once, and kept for the accountant, the manager and the owner
      await showDialog<void>(context: context, builder: (_) => ShiftReportDialog(shiftId: widget.shiftId, justClosed: true));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(_t(context, 'إقفال الوردية', 'Close shift')),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _summary,
          builder: (_, snap) {
            if (snap.hasError) return Text(_err(context, snap.error!));
            if (!snap.hasData) return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
            final s = snap.data!;
            final expected = (s['expected_minor'] as num).toInt();
            final counted = parseEgpToMinor(_counted.text);
            final diff = counted == null ? null : counted - expected;
            Widget row(String l, String r, {Color? c, bool b = false}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l), Text(r, style: TextStyle(fontWeight: b ? FontWeight.w800 : FontWeight.w600, color: c))]),
                );
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              row(_t(context, 'العهدة أول الوردية', 'Opening cash'), _money(context, s['opening_minor'] as num)),
              row('${_t(context, 'المبيعات', 'Sales')} (${s['sales_count']})', _money(context, s['sales_minor'] as num)),
              row(_t(context, 'المرتجعات', 'Refunds'), '- ${_money(context, s['refunds_minor'] as num)}'),
              if (((s['tips_minor'] as num?) ?? 0) > 0)
                row(_t(context, 'بقشيش (خدته من الدرج)', 'Tips (taken from the drawer)'), _money(context, s['tips_minor'] as num), c: BrandColors.gray),
              const Divider(),
              row(_t(context, 'المفروض في الدرج', 'Expected in drawer'), _money(context, expected), b: true),
              const SizedBox(height: 10),
              TextField(
                controller: _counted,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: _t(context, 'اللي عدّيته فعلياً في الدرج (ج.م)', 'Cash you actually counted (EGP)')),
              ),
              if (diff != null) ...[
                const SizedBox(height: 8),
                row(diff == 0 ? _t(context, 'مظبوط ✅', 'Matches ✅') : (diff < 0 ? _t(context, 'عجز', 'Short') : _t(context, 'زيادة', 'Over')), diff == 0 ? '' : _money(context, diff.abs()),
                    c: diff == 0 ? BrandColors.success : BrandColors.error, b: true),
                if (diff != 0) TextField(controller: _note, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'سبب الفرق (مطلوب)', 'Reason for the difference (required)'))),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _t(context, 'الباسورد بتاعك (تأكيد الإقفال)', 'Your password (confirms the closing)'),
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => _obscure = !_obscure)),
                ),
              ),
              const SizedBox(height: 6),
              Text(_t(context, 'بعد القفل بيتعمل تقرير نهائي مبيتعدّلش ولا بيتمسح، واسمك والجهاز والوقت بيتسجّلوا.', 'Closing creates a final report that cannot be edited or deleted; your name, the device and the time are recorded.'),
                  style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            ]);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t(context, 'رجوع', 'Back'))),
        FilledButton(
          onPressed: _busy || parseEgpToMinor(_counted.text) == null || _pass.text.isEmpty ? null : () => _close(parseEgpToMinor(_counted.text)!),
          child: Text(_t(context, 'قفل الوردية', 'Close shift')),
        ),
      ],
    );
  }
}
