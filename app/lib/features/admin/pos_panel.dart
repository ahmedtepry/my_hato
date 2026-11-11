import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../shared/motion.dart';

import '../../core/appearance.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/barcode_scanner.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'cashier_assistant.dart';
import 'pos_receipt.dart';
import 'robot_dock.dart';
import 'shift_flow.dart';
import 'shift_reports.dart';
import 'shift_robot.dart';
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
  bool _bioAvail = false, _bioOn = false;
  List<Map<String, dynamic>> _list = const [];

  String get _uid => ref.read(currentUserProvider)?.id ?? '';

  Future<void> _loadBio() async {
    final fl = await ref.read(assistantFlagsProvider.future);
    final a = fl['fingerprint'] == true && await ShiftBio.available();
    final e = a ? await ShiftBio.enabled(_uid) : false;
    if (mounted) setState(() {
      _bioAvail = a;
      _bioOn = e;
    });
  }

  Future<void> _openWithBio() async {
    final pw = await ShiftBio.secret(_uid, _t(context, 'تأكيد فتح الوردية', 'Confirm opening the shift'));
    if (!mounted) return;
    if (pw == null) {
      showSnack(context, _t(context, 'البصمة ماتأكدتش، اكتب الباسورد', 'Fingerprint did not match, type the password'), error: true);
      return;
    }
    _pass.text = pw;
    await _open(_list);
  }

  bool get _mayRemember => ref.read(staffContextProvider).valueOrNull?.permissions.contains('pos.remember_login') ?? false;

  @override
  void initState() {
    super.initState();
    _loadRemembered();
    _loadBio();
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
      // the cashier may keep the fingerprint for the next shift (the password stays in the device's encrypted storage)
      if (_bioAvail && !_bioOn && mounted) {
        final yes = await showSmoothDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text(_t(d, 'تفعّل البصمة؟', 'Turn on the fingerprint?')),
            content: Text(_t(d, 'المرة الجاية تفتح وتقفل الوردية بالبصمة. بصمتك بتفضل في جهازك بس.', 'Next time you open and close the shift with the fingerprint. It stays on your device.')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'لأ', 'No'))),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'فعّلها', 'Turn on'))),
            ],
          ),
        );
        if (yes == true && mounted) {
          if (await ShiftBio.save(_uid, _pass.text, _t(context, 'تفعيل البصمة', 'Turn on the fingerprint'))) _bioOn = true;
        }
      }
      final pw = _pass.text;
      _pass.clear();
      await repo.openShift(b, minor);
      if (pw.isNotEmpty && mounted) {
        final guard = (await ref.read(assistantFlagsProvider.future))['robot_open'] == true;
        if (guard && mounted) {
          final bn = branches.where((x) => x['id'] == b).map((x) => '${x['name_ar']}').firstOrNull ?? '';
          await ShiftRobotOpen.show(context, name: shiftUserName(ref.read(currentUserProvider)), openingMinor: minor, branch: bn);
          ref.read(robotWelcomeProvider.notifier).state = true;
        }
      }
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
              data: (list) {
                _list = list;
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                  if (_bioOn)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _openWithBio,
                        icon: const Icon(Icons.fingerprint_rounded),
                        label: Text(_t(context, 'افتح بالبصمة', 'Open with the fingerprint')),
                      ),
                    ),
                  FilledButton(onPressed: _busy ? null : () => _open(list), child: Text(_busy ? '…' : _t(context, 'فتح الوردية', 'Open shift'))),
                ],
              ]);
              },
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

/// A sale put on hold (customer went to fetch something): kept on this screen only, until it is resumed or the shift screen closes.
class _Held {
  _Held(this.lines, this.discount, this.pm, this.at, [this.customer]);
  final List<_Line> lines;
  final String discount, pm;
  final DateTime at;
  final Map<String, dynamic>? customer;

  Map<String, dynamic> toJson() => {
        'lines': [for (final l in lines) {'p': l.p, 'q': l.q}],
        'discount': discount,
        'pm': pm,
        'at': at.toIso8601String(),
        'customer': customer,
      };

  static _Held? fromJson(Object? j) {
    try {
      final m = Map<String, dynamic>.from(j as Map);
      return _Held(
        [for (final l in (m['lines'] as List)) _Line(Map<String, dynamic>.from((l as Map)['p'] as Map), (l['q'] as num).toInt())],
        '${m['discount'] ?? ''}',
        '${m['pm'] ?? 'cash'}',
        DateTime.parse('${m['at']}'),
        m['customer'] is Map ? Map<String, dynamic>.from(m['customer'] as Map) : null,
      );
    } catch (_) {
      return null;
    }
  }
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
  final _held = <_Held>[];
  Map<String, dynamic>? _customer; // the customer this sale is tied to (found by phone)
  final _custPhone = TextEditingController();
  bool _findingCustomer = false;
  List<Map<String, dynamic>> _products = const [];
  bool _loadingProducts = true;
  String? _productsError;
  Timer? _debounce;
  bool _busy = false;
  bool _showCart = false; // narrow screens: products or cart
  bool _tipInDrawer = false; // what the cashier said about the tip: left in the drawer, or taken out
  String _pm = 'cash'; // cash | card (visa) | wallet (e-wallet): the last two take no cash and give no change
  bool get _card => _pm != 'cash';
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
    _loadDrafts();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final f = await ref.read(assistantFlagsProvider.future);
        if (!mounted || f['reel'] != true) return;
        final u = ref.read(currentUserProvider);
        await CashierReel.maybeShow(context, uid: u?.id ?? '', name: shiftUserName(u), shift: widget.shift);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _discount.dispose();
    _cash.dispose();
    _custPhone.dispose();
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
    final exact = r.where((p) => '${p['sku']}'.toLowerCase() == q.toLowerCase() || '${p['barcode']}' == q).toList();
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
    _pm = 'cash';
    _customer = null;
    _custPhone.clear();
    _key = null;
    _tip = false;
    _unknown = false;
    _approvalId = null;
    _approvalAmount = 0;
  }

  /// Cash paid out of the drawer (cleaning, a delivery fee...): needs a reason and comes off the expected drawer.
  Future<void> _addExpense() async {
    final amount = TextEditingController();
    final reason = TextEditingController();
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'مصروف من الدرج', 'Expense from the drawer')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: amount, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: _t(d, 'المبلغ (ج.م)', 'Amount (EGP)'))),
          const SizedBox(height: 8),
          TextField(controller: reason, decoration: InputDecoration(labelText: _t(d, 'السبب', 'Reason'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'سجّل', 'Save'))),
        ],
      ),
    );
    final minor = parseEgpToMinor(amount.text);
    final why = reason.text.trim();
    amount.dispose();
    reason.dispose();
    if (ok != true || !mounted) return;
    if (minor == null || minor <= 0 || why.length < 3) {
      showSnack(context, _t(context, 'اكتب المبلغ والسبب', 'Enter the amount and a reason'), error: true);
      return;
    }
    try {
      await ref.read(posRepoProvider).addExpense(_shiftId, minor, why);
      ref.invalidate(posShiftProvider);
      if (mounted) showSnack(context, _t(context, 'اتسجّل المصروف واتخصم من الدرج', 'Expense saved and taken off the drawer'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    }
  }

  // Drafts survive closing the shift screen or the app: kept on this computer, per shift.
  String get _draftsKey => 'pos_drafts_$_shiftId';

  Future<void> _loadDrafts() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_draftsKey);
      if (raw == null || !mounted) return;
      final list = [for (final j in (jsonDecode(raw) as List)) _Held.fromJson(j)].whereType<_Held>().toList();
      if (list.isNotEmpty) setState(() => _held.addAll(list));
    } catch (_) {}
  }

  Future<void> _saveDrafts() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (_held.isEmpty) {
        await p.remove(_draftsKey);
      } else {
        await p.setString(_draftsKey, jsonEncode([for (final h in _held) h.toJson()]));
      }
    } catch (_) {}
  }

  Future<void> _findCustomer() async {
    final ph = _custPhone.text.trim();
    if (ph.replaceAll(RegExp(r'\D'), '').length < 8) {
      showSnack(context, _t(context, 'اكتب رقم العميل كامل', 'Enter the full phone number'), error: true);
      return;
    }
    setState(() => _findingCustomer = true);
    try {
      final c = await ref.read(posRepoProvider).findCustomer(ph);
      if (!mounted) return;
      if (c == null) {
        showSnack(context, _t(context, 'مفيش عميل مسجّل بالرقم ده', 'No customer with this number'), error: true);
      } else {
        setState(() {
          _customer = c;
          _custPhone.clear();
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _findingCustomer = false);
    }
  }

  static const _maxHeld = 4;

  void _hold({bool newInvoice = false}) {
    if (_cart.isEmpty || _unknown || _busy) return;
    if (_held.length >= _maxHeld) {
      showSnack(context, _t(context, 'أقصى حاجة $_maxHeld فواتير معلّقة. كمّل واحدة منهم أو الغي واحدة الأول.', 'Up to $_maxHeld held invoices. Resume or discard one first.'), error: true);
      return;
    }
    setState(() {
      _held.add(_Held([for (final l in _cart.values) _Line(l.p, l.q)], _discount.text, _pm, DateTime.now(), _customer));
      _reset();
    });
    _saveDrafts();
    showSnack(
        context,
        newInvoice
            ? _t(context, 'فتحنالك فاتورة جديدة. الفاتورة القديمة اتعلّقت وتلاقيها فوق السلة', 'New invoice opened. The previous one is on hold above the cart')
            : _t(context, 'الفاتورة اتعلّقت. كمّل بيع تاني وارجعلها من الفواتير المعلّقة اللي فوق', 'Invoice put on hold. Serve someone else and come back to it from the held invoices above'));
    _searchFocus.requestFocus();
  }

  Future<void> _discard(int i) async {
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'إلغاء الفاتورة المعلّقة؟', 'Discard this held invoice?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'لأ', 'No'))),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: BrandColors.error), onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'إلغاء الفاتورة', 'Discard'))),
        ],
      ),
    );
    if (ok == true && mounted && i < _held.length) {
      setState(() => _held.removeAt(i));
      _saveDrafts();
    }
  }

  void _resume(int i) {
    if (_cart.isNotEmpty) {
      showSnack(context, _t(context, 'خلّص الفاتورة الحالية أو علّقها الأول', 'Finish the current invoice or put it on hold first'), error: true);
      return;
    }
    final h = _held[i];
    setState(() {
      _held.removeAt(i);
      for (final l in h.lines) {
        _cart[l.p['id'] as String] = l;
      }
      _discount.text = h.discount;
      _pm = h.pm;
      _customer = h.customer;
    });
    _saveDrafts();
  }

  Future<void> _complete() async {
    if (_busy || _cart.isEmpty) return;
    final discount = _discountMinor;
    final cash = _card ? _total : parseEgpToMinor(_cash.text);
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
    if (!_card && cash > _total && _key == null) {
      final r = await showSmoothDialog<String>(context: context, barrierDismissible: false, builder: (_) => _ChangeDialog(change: cash - _total));
      if (r == null || r == 'back' || !mounted) return;
      _tip = r == 'tip';
      _tipInDrawer = false;
      if (_tip) {
        final where = await showSmoothDialog<String>(context: context, barrierDismissible: false, builder: (_) => const _TipWhereDialog());
        if (where == null) return;
        _tipInDrawer = where == 'drawer';
      }
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
                customerId: _customer?['id'] as String?,
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
      if (_card) {
        try {
          done = await ref.read(posRepoProvider).setSalePayment('${sale['id']}', _pm);
        } catch (_) {
          if (mounted) showSnack(context, _t(context, 'البيعة اتسجلت لكن طريقة الدفع ماتسجلتش، قول للمالك', 'The sale was saved but the payment method was not recorded'), error: true);
        }
      }
      if (_tip) {
        try {
          done = await ref.read(posRepoProvider).markTip('${sale['id']}', inDrawer: _tipInDrawer);
        } catch (_) {
          if (mounted) showSnack(context, _t(context, 'البيعة اتسجلت لكن البقشيش ماتسجلش، سجّله من الفاتورة', 'The sale was saved but the tip was not recorded'), error: true);
        }
      }
      // commission earned on this sale (products with a commission running today), for the cheer on the receipt
      var bonus = 0;
      if (ref.read(staffContextProvider).valueOrNull?.permissions.contains('commission.today') ?? false) {
        try {
          final list = await ref.read(commissionTodayProvider.future).timeout(const Duration(seconds: 3));
          final per = {for (final r in list) '${r['product_id']}': (r['amount_minor'] as num).toInt()};
          for (final e in _cart.entries) {
            bonus += (per[e.key] ?? 0) * e.value.q;
          }
        } catch (_) {}
      }
      setState(_reset);
      ref.invalidate(posShiftProvider);
      ref.invalidate(commissionTodayProvider);
      ref.invalidate(myChallengeProvider);
      _loadProducts(_search.text);
      if (await receiptAutoPrintOn() && mounted) unawaited(printReceipt(context, done));
      if (!mounted) return;
      await showSmoothDialog<void>(context: context, builder: (_) => _ReceiptDialog(sale: done, bonusMinor: bonus));
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
    final guard = (await ref.read(assistantFlagsProvider.future))['robot_close'] == true;
    if (!mounted) return;
    if (guard) {
      // the robot closes the shift (30-second review); the old dialog stays for when the guard is off
      await ShiftRobotClose.show(context, _shiftId);
      ref.invalidate(posShiftProvider); // also after the X: the shift may have been closed just before
      return;
    }
    final ok = await showSmoothDialog<bool>(context: context, builder: (_) => _CloseShiftDialog(shiftId: _shiftId));
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
          _SellerChip(shiftId: _shiftId, enabled: !_unknown && _cart.isEmpty),
          Text('· ${_t(context, 'مبيعات', 'Sales')} ${_money(context, (s['sales_minor'] as num?) ?? 0)} (${s['sales_count'] ?? 0})', style: const TextStyle(color: BrandColors.gray)),
          if ((((s['card_sales_minor'] as num?) ?? 0) + ((s['wallet_sales_minor'] as num?) ?? 0)) > 0)
            Text('· ${_t(context, 'كاش', 'Cash')} ${_money(context, (s['cash_sales_minor'] as num?) ?? 0)} · ${_t(context, 'فيزا', 'Visa')} ${_money(context, (s['card_sales_minor'] as num?) ?? 0)} · ${_t(context, 'محافظ', 'Wallets')} ${_money(context, (s['wallet_sales_minor'] as num?) ?? 0)}', style: const TextStyle(color: BrandColors.gray)),
          Text('· ${_t(context, 'المفروض في الدرج', 'Expected in drawer')} ${_money(context, (s['expected_minor'] as num?) ?? 0)}', style: const TextStyle(color: BrandColors.gray)),
          OutlinedButton.icon(
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: Text(_t(context, 'مصروف', 'Expense')),
            onPressed: _unknown ? null : _addExpense,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.assignment_return_outlined, size: 18),
            label: Text(_t(context, 'مرتجع', 'Refund')),
            onPressed: _unknown
                ? null
                : () => showSmoothDialog<List<Map<String, dynamic>>>(context: context, builder: (_) => _RefundDialog(shiftId: _shiftId, branchId: _branchId)).then((replacement) {
                      ref.invalidate(posShiftProvider);
                      // an exchange: the replacement products go straight into the cart, ready to be sold
                      if (replacement != null && mounted) {
                        for (final r in replacement) {
                          for (var i = 0; i < (r['q'] as int); i++) {
                            _add(Map<String, dynamic>.from(r['p'] as Map));
                          }
                        }
                      }
                    }),
          ),
          const AssistantModeSwitch(),
          AssistantButton(shiftId: _shiftId),
          DailyChallenge(sales: ((s['sales_count'] as num?) ?? 0).toInt()),
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
        child: Stack(children: [
         Positioned.fill(child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 600; // products and cart together on one page; only a phone-sized window stacks them
          final cartW = c.maxWidth >= 900 ? 380.0 : 310.0;
          return Padding(
            padding: const EdgeInsets.all(14),
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // the cart takes the whole height of the screen (top to bottom) so the total and the pay button are always visible
                    Expanded(child: Column(children: [bar, const SizedBox(height: 12), Expanded(child: _productsPane())])),
                    const SizedBox(width: 14),
                    SizedBox(width: cartW, child: _cartPane()),
                  ])
                : Column(children: [
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
              Expanded(child: _showCart ? _cartPane() : _productsPane()),
            ]),
          );
         })),
         Positioned.fill(
           child: RobotDock(
             canClose: _cart.isEmpty,
             onCloseShift: _closeShift,
             onFind: () => showCashierAssistant(context, shiftId: _shiftId, guard: false),
           ),
         ),
        ]),
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
        (limits['can_discount'] != true || (pct > ((limits['discount_approval_pct'] as num?) ?? 10) && disc > ((limits['discount_free_minor'] as num?) ?? 1000)));
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
                icon: const Icon(Icons.pause_circle_outline, size: 18),
                label: Text(_t(context, 'تعليق الفاتورة', 'Hold invoice')),
                onPressed: _hold,
              ),
            if (_cart.isNotEmpty && !_unknown)
              TextButton.icon(
                icon: const Icon(Icons.note_add_outlined, size: 18),
                label: Text(_t(context, 'فاتورة جديدة', 'New invoice')),
                onPressed: () => _hold(newInvoice: true),
              ),
          ]),
          if (_held.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              // all held invoices wrap onto rows, so none of them is hidden off-screen (at most 4 at a time)
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                for (var i = 0; i < _held.length; i++)
                  InputChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.edit_note_rounded, size: 18),
                    label: Text('${_t(context, 'معلّقة', 'Held')} ${i + 1} · ${_money(context, _held[i].lines.fold<int>(0, (a, l) => a + l.price * l.q))}'),
                    onPressed: () => _resume(i),
                    onDeleted: () => _discard(i),
                    deleteIconColor: BrandColors.error,
                    deleteButtonTooltipMessage: _t(context, 'إلغاء الفاتورة المعلّقة', 'Discard held invoice'),
                  ),
              ]),
            ),
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
          if (_customer != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InputChip(
                avatar: const Icon(Icons.person_rounded, size: 18),
                label: Text('${_customer!['name'] ?? ''} · ${_customer!['phone'] ?? ''}'),
                onDeleted: _unknown ? null : () => setState(() => _customer = null),
              ),
            )
          else if (!_unknown)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _custPhone,
                    keyboardType: TextInputType.phone,
                    textDirection: TextDirection.ltr,
                    onSubmitted: (_) => _findCustomer(),
                    decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.person_search_rounded, size: 18), labelText: _t(context, 'ربط عميل (رقم موبايله)', 'Link a customer (phone)')),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(onPressed: _findingCustomer ? null : _findCustomer, child: Text(_t(context, 'بحث', 'Find'))),
              ]),
            ),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'cash', icon: const Icon(Icons.payments_outlined, size: 18), label: Text(_t(context, 'كاش', 'Cash'))),
              ButtonSegment(value: 'card', icon: const Icon(Icons.credit_card_rounded, size: 18), label: Text(_t(context, 'فيزا', 'Visa'))),
              ButtonSegment(value: 'wallet', icon: const Icon(Icons.account_balance_wallet_outlined, size: 18), label: Text(_t(context, 'محفظة', 'Wallet'))),
            ],
            selected: {_pm},
            onSelectionChanged: _unknown ? null : (v) => setState(() => _pm = v.first),
          ),
          const SizedBox(height: 8),
          if (!_card)
          TextField(
            controller: _cash,
            enabled: !_unknown,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _complete(),
            decoration: InputDecoration(isDense: true, labelText: _t(context, 'المبلغ المستلم (ج.م)', 'Cash received (EGP)')),
          ),
          if (!_card && quick.isNotEmpty && !_unknown)
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
          if (!_card && change != null && total > 0)
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
    final sku = '${p['barcode'] ?? ''}'.trim();
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_t(context, '${p['name_ar']}', '${p['name_en']}'), maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, height: 1.25)),
                if (sku.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(sku, textDirection: TextDirection.ltr, style: const TextStyle(color: Color(0xFFCFE3FF), fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                  ),
              ]),
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
          Text(_t(context, 'البقشيش بيتسجل في السيستم باسمك، ومش بيظهر على فاتورة العميل.', 'The tip is recorded in the system under your name and never shown on the customer invoice.'),
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
    ..writeln('${_t(c, 'المستلم', 'Cash')}: ${_money(c, (sale['cash_received_minor'] as num) - ((sale['tip_minor'] as num?) ?? 0))}')
    ..writeln('${_t(c, 'الباقي', 'Change')}: ${_money(c, ((sale['change_minor'] as num) - ((sale['tip_minor'] as num?) ?? 0)))}')
    ..writeln(_t(c, 'شكراً لثقتكم', 'Thank you'));
  return lines.toString();
}

class _ReceiptDialog extends StatelessWidget {
  const _ReceiptDialog({required this.sale, this.bonusMinor = 0});
  final Map<String, dynamic> sale;
  final int bonusMinor;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.check_circle_rounded, color: BrandColors.success, size: 44),
      title: Text(_t(context, 'تم البيع ✅', 'Sale completed ✅'), textAlign: TextAlign.center),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(children: [
            if (bonusMinor > 0)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: BrandColors.success.withValues(alpha: .12), borderRadius: BorderRadius.circular(12), border: Border.all(color: BrandColors.success)),
                child: Text(_t(context, 'عاش كده! 🎉 كوميشن ${_money(context, bonusMinor)}، شد حيلك 💪', 'Well done! 🎉 ${_money(context, bonusMinor)} commission, keep it up 💪'),
                    textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.success, fontWeight: FontWeight.w900, fontSize: 16)),
              ),
            ReceiptPaper(sale: sale),
          ]),
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
  final reason = await showSmoothDialog<String>(
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
  final res = await showSmoothDialog<String>(context: context, barrierDismissible: false, builder: (_) => _WaitApprovalDialog(repo: repo, id: id));
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
  String _method = 'cash'; // how the money goes back: cash (from the drawer) / card / wallet
  final _repl = <String, _Line>{}; // replacement products for an exchange
  final _replSearch = TextEditingController();
  Future<List<Map<String, dynamic>>>? _replFound;
  late final Future<List<Map<String, dynamic>>> _recent = ref.read(posRepoProvider).recentSales(widget.shiftId);

  @override
  void dispose() {
    _number.dispose();
    _reason.dispose();
    _replSearch.dispose();
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

  int get _replTotal => _repl.values.fold(0, (a, l) => a + l.price * l.q);

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
          final pm = '${s['payment_method'] ?? 'cash'}';
          _method = (pm == 'card' || pm == 'wallet') ? pm : 'cash';
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
          res = await repo.refund(saleId: _sale!['id'] as String, items: items, reason: _reason.text.trim(), restock: _restock, approvalId: approval, method: _method);
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
      final amt = _money(context, res['amount_minor'] as num);
      final how = switch ('${res['method']}') {
        'card' => _t(context, 'رجّعهم للعميل على الفيزا', 'Return it to the customer\'s card'),
        'wallet' => _t(context, 'حوّلهم للعميل على المحفظة', 'Send it to the customer\'s wallet'),
        _ => _t(context, 'رجّعهم للعميل كاش من الدرج', 'Pay it back in cash from the drawer'),
      };
      showSnack(context, '${res['cancelled'] == true ? _t(context, 'الفاتورة اتلغت ✅ ', 'Invoice cancelled ✅ ') : _t(context, 'تم المرتجع ', 'Refunded ')}$amt — $how${_repl.isEmpty ? '' : _t(context, '. البديل اتضاف للسلة، كمّل البيع.', '. The replacement is in the cart; finish the sale.')}');
      Navigator.pop(context, [for (final l in _repl.values) {'p': l.p, 'q': l.q}]);
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
                decoration: InputDecoration(labelText: _t(context, 'رقم الفاتورة', 'Invoice number'), suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => _find())),
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
                        subtitle: (s['refunded_minor'] as num) >= (s['total_minor'] as num)
                            ? Text(_t(context, 'ملغية', 'Cancelled'), style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700))
                            : ((s['refunded_minor'] as num) > 0 ? Text(_t(context, 'مرتجع جزئي', 'Partly refunded')) : null),
                        trailing: Text(_money(context, s['total_minor'] as num)),
                        onTap: () => _find('${s['number']}'),
                      ),
                  ]);
                },
              ),
            ] else ...[
              Text('${_sale!['number']} · ${_money(context, _sale!['total_minor'] as num)}', style: const TextStyle(fontWeight: FontWeight.w800)),
              if (_sale!['cancelled'] == true)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text(_t(context, 'الفاتورة دي ملغية (اترجّعت بالكامل)', 'This invoice is cancelled (fully refunded)'), style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800))),
              for (final r in (_sale!['refunds'] as List? ?? const []))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('${_t(context, 'مرتجع سابق', 'Earlier refund')}: ${_money(context, (r as Map)['amount_minor'] as num)} · ${switch ('${r['method']}') { 'card' => _t(context, 'فيزا', 'Card'), 'wallet' => _t(context, 'محفظة', 'Wallet'), _ => _t(context, 'كاش', 'Cash') }} · ${r['reason']}',
                      style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                ),
              if (_items.any((it) => (it['quantity'] as num).toInt() - (it['refunded_qty'] as num).toInt() > 0))
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: Text(_t(context, 'إلغاء الفاتورة بالكامل', 'Cancel the whole invoice')),
                    onPressed: () => setState(() {
                      for (final it in _items) {
                        _qty['${it['id']}'] = (it['quantity'] as num).toInt() - (it['refunded_qty'] as num).toInt();
                      }
                    }),
                  ),
                ),
              const SizedBox(height: 6),
              ReceiptButtons(sale: _sale!, text: receiptText(context, _sale!)),
              const SizedBox(height: 6),
              const SizedBox(height: 6),
              Text(_t(context, 'منتجات الفاتورة — اختار اللي هيرجع', 'Invoice products — choose what comes back'), style: const TextStyle(fontWeight: FontWeight.w800)),
              for (final it in _items)
                Builder(builder: (_) {
                  final left = (it['quantity'] as num).toInt() - (it['refunded_qty'] as num).toInt();
                  final q = _qty[it['id']] ?? 0;
                  final id = '${it['id']}';
                  return Container(
                    margin: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(color: q > 0 ? BrandColors.electric.withValues(alpha: .08) : null, borderRadius: BorderRadius.circular(12), border: Border.all(color: q > 0 ? BrandColors.electric : BrandColors.border)),
                    child: ListTile(
                      dense: true,
                      enabled: left > 0,
                      onTap: left == 0 ? null : () => setState(() => _qty[id] = q > 0 ? 0 : left),
                      leading: Checkbox(value: q > 0, onChanged: left == 0 ? null : (v) => setState(() => _qty[id] = v == true ? left : 0)),
                      title: Text('${it['name_ar']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(left == 0
                          ? _t(context, 'اترجّع بالكامل', 'Fully refunded')
                          : '${_t(context, 'اتباع', 'Sold')} ${it['quantity']} × ${_money(context, it['unit_price_minor'] as num)} · ${_t(context, 'متاح للإرجاع', 'Refundable')} $left'),
                      trailing: left == 0
                          ? null
                          : Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove_circle_outline), onPressed: q > 0 ? () => setState(() => _qty[id] = q - 1) : null),
                              SizedBox(
                                width: 64,
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  Text('$q', style: const TextStyle(fontWeight: FontWeight.w800)),
                                  if (q > 0) Text(_money(context, _amountFor(it, q)), style: const TextStyle(fontSize: 11, color: BrandColors.gray)),
                                ]),
                              ),
                              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline), onPressed: q < left ? () => setState(() => _qty[id] = q + 1) : null),
                            ]),
                    ),
                  );
                }),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: _repl.isNotEmpty,
                title: Text(_t(context, 'استبدال بمنتج آخر (اختياري)', 'Exchange for another product (optional)'), style: const TextStyle(fontWeight: FontWeight.w700)),
                children: [
                  TextField(
                    controller: _replSearch,
                    onChanged: (v) => setState(() => _replFound = v.trim().length < 2 ? null : ref.read(posRepoProvider).searchProducts(v)),
                    decoration: InputDecoration(isDense: true, hintText: _t(context, 'ابحث باسم المنتج أو الباركود', 'Search by name or barcode'), prefixIcon: const Icon(Icons.search)),
                  ),
                  if (_replFound != null)
                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: _replFound,
                      builder: (_, snap) {
                        final found = (snap.data ?? const []).take(6).toList();
                        if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
                        return Column(children: [
                          for (final pr in found)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('${pr['name_ar']}'),
                              subtitle: Text('${_t(context, 'متاح', 'In stock')} ${pr['stock_quantity']}'),
                              trailing: Text(_money(context, pr['price_minor'] as num), style: const TextStyle(fontWeight: FontWeight.w800)),
                              onTap: () => setState(() {
                                final pid = '${pr['id']}';
                                final cur = _repl[pid];
                                if (cur == null) {
                                  _repl[pid] = _Line(pr, 1);
                                } else {
                                  cur.q++;
                                }
                                _replSearch.clear();
                                _replFound = null;
                              }),
                            ),
                        ]);
                      },
                    ),
                  for (final l in _repl.values.toList())
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.swap_horiz_rounded),
                      title: Text('${l.p['name_ar']}'),
                      subtitle: Text(_money(context, l.price * l.q)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() { if (l.q > 1) { l.q--; } else { _repl.remove('${l.p['id']}'); } })),
                        Text('${l.q}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline), onPressed: () => setState(() => l.q++)),
                      ]),
                    ),
                  if (_repl.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                          '${_t(context, 'قيمة البديل', 'Replacement value')}: ${_money(context, _replTotal)} · ${_replTotal - _total >= 0 ? _t(context, 'العميل يدفع الفرق', 'Customer pays the difference') : _t(context, 'ليه فرق', 'Difference owed to him')} ${_money(context, (_replTotal - _total).abs())}',
                          style: const TextStyle(color: BrandColors.success, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                ],
              ),
              TextField(controller: _reason, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'سبب الإلغاء / المرتجع (مطلوب)', 'Cancel / refund reason (required)'))),
              const SizedBox(height: 4),
              Text(_t(context, 'رجّعت الفلوس للعميل إزاي؟', 'How is the customer paid back?'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'cash', icon: const Icon(Icons.payments_outlined), label: Text(_t(context, 'كاش', 'Cash'))),
                  ButtonSegment(value: 'card', icon: const Icon(Icons.credit_card), label: Text(_t(context, 'فيزا', 'Card'))),
                  ButtonSegment(value: 'wallet', icon: const Icon(Icons.account_balance_wallet_outlined), label: Text(_t(context, 'محفظة', 'Wallet'))),
                ],
                selected: {_method},
                onSelectionChanged: (v) => setState(() => _method = v.first),
              ),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _restock, onChanged: (v) => setState(() => _restock = v), title: Text(_t(context, 'المنتج سليم؟ رجّعه للمخزون', 'Item is fine? Put it back in stock')),
                  subtitle: Text(_t(context, 'اقفلها لو المنتج تالف', 'Turn off if the item is damaged'), style: const TextStyle(fontSize: 12))),
              Text('${_t(context, 'هتدفع للعميل', 'Pay the customer')}: ${_money(context, _total)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إغلاق', 'Close'))),
        if (_sale != null) FilledButton(onPressed: (_busy || _total <= 0) ? null : _submit, child: Text(_repl.isEmpty ? _t(context, 'تنفيذ المرتجع', 'Refund') : _t(context, 'نفّذ المرتجع والاستبدال', 'Refund and exchange'))),
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
  final _countedCard = TextEditingController();
  final _countedWallet = TextEditingController();
  final _note = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;
  late final Future<Map<String, dynamic>> _summary = ref.read(posRepoProvider).shiftSummary(widget.shiftId);
  bool _busy = false;

  @override
  void dispose() {
    _counted.dispose();
    _countedCard.dispose();
    _countedWallet.dispose();
    _note.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _close(int counted) async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(posRepoProvider).closeShift(widget.shiftId, counted, _note.text.trim().isEmpty ? null : _note.text.trim(), _pass.text,
          countedCard: parseEgpToMinor(_countedCard.text), countedWallet: parseEgpToMinor(_countedWallet.text));
      if (!mounted) return;
      if (r['ok'] != true) {
        showSnack(context, _t(context, 'الباسورد غلط، الوردية لسه مفتوحة', 'Wrong password, the shift is still open'), error: true);
        _pass.clear();
        return;
      }
      _pass.clear();
      // the final closing report: shown at once, and kept for the accountant, the manager and the owner
      await showSmoothDialog<void>(context: context, builder: (_) => ShiftReportDialog(shiftId: widget.shiftId, justClosed: true));
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
            final cardExp = ((s['card_sales_minor'] as num?) ?? 0).toInt() - ((s['card_refunds_minor'] as num?) ?? 0).toInt();
            final walletExp = ((s['wallet_sales_minor'] as num?) ?? 0).toInt() - ((s['wallet_refunds_minor'] as num?) ?? 0).toInt();
            final cardCounted = parseEgpToMinor(_countedCard.text);
            final walletCounted = parseEgpToMinor(_countedWallet.text);
            final cardDiff = cardCounted == null ? null : cardCounted - cardExp;
            final walletDiff = walletCounted == null ? null : walletCounted - walletExp;
            Widget row(String l, String r, {Color? c, bool b = false}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l), Text(r, style: TextStyle(fontWeight: b ? FontWeight.w800 : FontWeight.w600, color: c))]),
                );
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ShiftReviewCard(shiftId: widget.shiftId),
              const SizedBox(height: 8),
              row(_t(context, 'العهدة أول الوردية', 'Opening cash'), _money(context, s['opening_minor'] as num)),
              row('${_t(context, 'المبيعات', 'Sales')} (${s['sales_count']})', _money(context, s['sales_minor'] as num)),
              if ((((s['card_sales_minor'] as num?) ?? 0) + ((s['wallet_sales_minor'] as num?) ?? 0)) > 0) ...[
                row(_t(context, '   كاش', '   Cash'), _money(context, (s['cash_sales_minor'] as num?) ?? 0), c: BrandColors.gray),
                row(_t(context, '   فيزا', '   Visa'), _money(context, (s['card_sales_minor'] as num?) ?? 0), c: BrandColors.gray),
                row(_t(context, '   محافظ إلكترونية', '   E-wallets'), _money(context, (s['wallet_sales_minor'] as num?) ?? 0), c: BrandColors.gray),
              ],
              row(_t(context, 'المرتجعات', 'Refunds'), '- ${_money(context, s['refunds_minor'] as num)}'),
              if (((s['refunds_minor'] as num?) ?? 0) != ((s['cash_refunds_minor'] as num?) ?? 0))
                row(_t(context, '   منها كاش من الدرج', '   of which cash from the drawer'), '- ${_money(context, (s['cash_refunds_minor'] as num?) ?? 0)}', c: BrandColors.gray),
              if (((s['expenses_minor'] as num?) ?? 0) > 0) row(_t(context, 'مصروفات من الدرج', 'Drawer expenses'), '- ${_money(context, s['expenses_minor'] as num)}'),
              if (((s['tips_minor'] as num?) ?? 0) > 0)
                row(_t(context, 'بقشيش (خدته من الدرج)', 'Tips (taken from the drawer)'), _money(context, s['tips_minor'] as num), c: BrandColors.gray),
              if (((s['tips_kept_minor'] as num?) ?? 0) > 0)
                row(_t(context, 'بقشيش (سايبه في الدرج)', 'Tips (left in the drawer)'), _money(context, s['tips_kept_minor'] as num), c: BrandColors.gray),
              const Divider(),
              row(_t(context, 'المفروض كاش في الدرج', 'Expected cash in drawer'), _money(context, expected), b: true),
              row(_t(context, 'المفروض فيزا', 'Expected card'), _money(context, cardExp), c: BrandColors.gray),
              row(_t(context, 'المفروض محافظ', 'Expected e-wallets'), _money(context, walletExp), c: BrandColors.gray),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(_t(context, 'وسيلة دفع غلط؟ صلّحها من «الفواتير» قبل ما تقفل.', 'Wrong payment method? Fix it from "Invoices" before closing.'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _counted,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: _t(context, 'الكاش اللي عدّيته فعلياً في الدرج (ج.م)', 'Cash you actually counted (EGP)')),
              ),
              if (diff != null) ...[
                const SizedBox(height: 8),
                row(diff == 0 ? _t(context, 'الكاش مظبوط ✅', 'Cash matches ✅') : (diff < 0 ? _t(context, 'عجز في الكاش', 'Cash short') : _t(context, 'زيادة في الكاش', 'Cash over')), diff == 0 ? '' : _money(context, diff.abs()),
                    c: diff == 0 ? BrandColors.success : BrandColors.error, b: true),
              ],
              const SizedBox(height: 10),
              Text(_t(context, 'الفيزا والمحافظ (اختياري: اكتب إجمالي ماكينة الفيزا وإجمالي المحافظ)', 'Card and e-wallets (optional: the card machine total and the wallets total)'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 6),
              TextField(
                controller: _countedCard,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(isDense: true, labelText: _t(context, 'إجمالي الفيزا (ج.م)', 'Card total (EGP)'), prefixIcon: const Icon(Icons.credit_card, size: 18)),
              ),
              if (cardDiff != null)
                row(cardDiff == 0 ? _t(context, 'الفيزا مظبوطة ✅', 'Card matches ✅') : (cardDiff < 0 ? _t(context, 'عجز في الفيزا', 'Card short') : _t(context, 'زيادة في الفيزا', 'Card over')), cardDiff == 0 ? '' : _money(context, cardDiff.abs()),
                    c: cardDiff == 0 ? BrandColors.success : BrandColors.error, b: true),
              const SizedBox(height: 8),
              TextField(
                controller: _countedWallet,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(isDense: true, labelText: _t(context, 'إجمالي المحافظ الإلكترونية (ج.م)', 'E-wallets total (EGP)'), prefixIcon: const Icon(Icons.account_balance_wallet_outlined, size: 18)),
              ),
              if (walletDiff != null)
                row(walletDiff == 0 ? _t(context, 'المحافظ مظبوطة ✅', 'Wallets match ✅') : (walletDiff < 0 ? _t(context, 'عجز في المحافظ', 'Wallets short') : _t(context, 'زيادة في المحافظ', 'Wallets over')), walletDiff == 0 ? '' : _money(context, walletDiff.abs()),
                    c: walletDiff == 0 ? BrandColors.success : BrandColors.error, b: true),
              if ((diff ?? 0) != 0 || (cardDiff ?? 0) != 0 || (walletDiff ?? 0) != 0)
                TextField(controller: _note, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'سبب الفرق (مطلوب)', 'Reason for the difference (required)'))),
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
          onPressed: _busy || parseEgpToMinor(_counted.text) == null || _pass.text.isEmpty || (_countedCard.text.trim().isNotEmpty && parseEgpToMinor(_countedCard.text) == null) || (_countedWallet.text.trim().isNotEmpty && parseEgpToMinor(_countedWallet.text) == null) ? null : () => _close(parseEgpToMinor(_counted.text)!),
          child: Text(_t(context, 'قفل الوردية', 'Close shift')),
        ),
      ],
    );
  }
}

/// Second question after "left as a tip": does it stay in the drawer or does the cashier take it? Either answer is fine ("تمام").
class _TipWhereDialog extends StatelessWidget {
  const _TipWhereDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.volunteer_activism_rounded, color: BrandColors.success, size: 44),
        title: Text(_t(context, 'هتعمل إيه في البقشيش؟', 'What will you do with the tip?'), textAlign: TextAlign.center),
        content: Text(_t(context, 'هتسيبه في الدرج ولا هتاخده؟ الاتنين تمام، وهيتسجل في السيستم.', 'Leave it in the drawer or take it? Both are fine; it is recorded.'),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        actionsAlignment: MainAxisAlignment.center,
        actionsOverflowButtonSpacing: 8,
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, 'drawer'), child: Text(_t(context, 'هسيبه في الدرج', 'Leave in the drawer'))),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, 'take'), child: Text(_t(context, 'هاخده', 'I will take it'))),
        ],
      );
}


// =====================================================================================================
// Switch the seller on the same screen: tap the name, pick a cashier of the branch, type his 4-digit PIN.
// The shift and the drawer stay with the account that opened them; every sale records who actually sold.
// =====================================================================================================
class _SellerChip extends ConsumerStatefulWidget {
  const _SellerChip({required this.shiftId, required this.enabled});
  final String shiftId;
  final bool enabled;
  @override
  ConsumerState<_SellerChip> createState() => _SellerChipState();
}

class _SellerChipState extends ConsumerState<_SellerChip> {
  String? _name;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(posRepoProvider).currentSeller(widget.shiftId);
      final me = ref.read(supabaseProvider).auth.currentUser?.id;
      if (!mounted) return;
      ref.read(activeSellerProvider.notifier).state = r['id'] == me ? null : r;
      setState(() => _name = '${r['name'] ?? ''}');
    } catch (_) {}
  }

  Future<void> _open() async {
    final picked = await showSmoothDialog<Map<String, dynamic>>(context: context, builder: (_) => _SellerDialog(shiftId: widget.shiftId));
    if (picked == null || !mounted) return;
    final me = ref.read(supabaseProvider).auth.currentUser?.id;
    ref.read(activeSellerProvider.notifier).state = picked['id'] == me ? null : picked;
    setState(() => _name = '${picked['name'] ?? ''}');
    ref.invalidate(myChallengeProvider);
    showSnack(context, _t(context, 'البائع دلوقتي: ${picked['name']}', 'Seller is now: ${picked['name']}'));
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.enabled ? _t(context, 'تبديل البائع', 'Switch seller') : _t(context, 'فرّغ السلة الأول', 'Empty the cart first'),
      child: ActionChip(
        avatar: const Icon(Icons.badge_outlined, size: 18),
        label: Text('${_t(context, 'البائع', 'Seller')}: ${_name ?? '…'}  ▾', style: const TextStyle(fontWeight: FontWeight.w800)),
        onPressed: widget.enabled ? _open : null,
      ),
    );
  }
}

class _SellerDialog extends ConsumerStatefulWidget {
  const _SellerDialog({required this.shiftId});
  final String shiftId;
  @override
  ConsumerState<_SellerDialog> createState() => _SellerDialogState();
}

class _SellerDialogState extends ConsumerState<_SellerDialog> {
  List<Map<String, dynamic>>? _list;
  Map<String, dynamic>? _target; // the cashier whose PIN is being typed
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();
  String? _msg;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(posRepoProvider).sellerCandidates(widget.shiftId).then((l) {
      if (mounted) setState(() => _list = l);
    }).catchError((Object e) {
      if (mounted) setState(() => _msg = _err(context, e));
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = _target;
    if (t == null || _pin.text.length != 4 || _busy) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final r = await ref.read(posRepoProvider).switchSeller(widget.shiftId, t['id'] as String, _pin.text);
      if (!mounted) return;
      if (r['ok'] == true) {
        Navigator.pop(context, {'id': r['id'], 'name': r['name']});
        return;
      }
      final locked = r['error'] == 'PIN_LOCKED';
      setState(() {
        _busy = false;
        _pin.clear();
        _msg = locked
            ? _t(context, 'محاولات غلط كتير. الموظف ده مقفول ${((r['seconds'] as num?) ?? 300) ~/ 60} دقايق.', 'Too many wrong tries. Locked for a few minutes.')
            : _t(context, 'الـPIN غلط (فاضل ${r['left']} محاولات)', 'Wrong PIN (${r['left']} tries left)');
      });
      _pinFocus.requestFocus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _msg = _err(context, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _target;
    return AlertDialog(
      title: Text(t == null ? _t(context, 'تبديل البائع', 'Switch seller') : '${_t(context, 'PIN', 'PIN')} · ${t['name']}'),
      content: SizedBox(
        width: 360,
        child: t == null
            ? (_list == null
                ? SizedBox(height: 80, child: Center(child: _msg == null ? const CircularProgressIndicator() : Text(_msg!, style: const TextStyle(color: BrandColors.error))))
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final c in _list!)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(c['active'] == true ? Icons.radio_button_checked : Icons.person_outline, color: c['active'] == true ? BrandColors.success : null),
                          title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                          subtitle: c['has_pin'] == true ? null : Text(_t(context, 'مفيش PIN — المالك يحدده', 'No PIN yet — the owner sets it'), style: const TextStyle(color: BrandColors.warning, fontSize: 12)),
                          trailing: c['active'] == true ? Text(_t(context, 'الحالي', 'Current'), style: const TextStyle(color: BrandColors.success)) : const Icon(Icons.chevron_left),
                          enabled: c['has_pin'] == true,
                          onTap: () {
                            setState(() {
                              _target = c;
                              _msg = null;
                            });
                            WidgetsBinding.instance.addPostFrameCallback((_) => _pinFocus.requestFocus());
                          },
                        ),
                      ),
                  ]))
            : Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: _pin,
                  focusNode: _pinFocus,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.w800),
                  decoration: InputDecoration(counterText: '', hintText: '••••', errorText: _msg),
                  onChanged: (v) {
                    if (v.length == 4) _submit();
                  },
                  onSubmitted: (_) => _submit(),
                ),
                if (_busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
              ]),
      ),
      actions: [
        if (t != null) TextButton(onPressed: _busy ? null : () => setState(() { _target = null; _pin.clear(); _msg = null; }), child: Text(_t(context, 'رجوع', 'Back'))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
      ],
    );
  }
}
