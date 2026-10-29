// The smart assistant at the till ("المساعد الذكي") and the shift guard. READ ONLY: it looks things up, explains and warns.
// It never changes a price, a stock quantity, an invoice or a refund: those stay with the cashier and the people who may approve them.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, Object? minor) => formatEgp(((minor as num?) ?? 0).round(), c.lang);
List<Map<String, dynamic>> _maps(Object? v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

/// Which assistant features this member sees. 'available' = he may use the automatic mode; 'mine' = he switched it ON for himself.
const _flagKeys = ['available', 'mine', 'cashier', 'guard', 'find', 'robot_close', 'robot_open', 'fingerprint', 'reel', 'challenge'];
final assistantFlagsProvider = FutureProvider.autoDispose<Map<String, bool>>((ref) async {
  try {
    final r = Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('assistant_flags') as Map);
    return {for (final k in _flagKeys) k: r[k] == true};
  } catch (_) {
    return {for (final k in _flagKeys) k: false};
  }
});

/// The member's own ON/OFF switch for the automatic mode. ON opens every assistant feature he was given; OFF closes them all.
class AssistantModeSwitch extends ConsumerStatefulWidget {
  const AssistantModeSwitch({super.key});
  @override
  ConsumerState<AssistantModeSwitch> createState() => _AssistantModeSwitchState();
}

class _AssistantModeSwitchState extends ConsumerState<AssistantModeSwitch> {
  bool _busy = false;
  Future<void> _set(bool on) async {
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('assistant_my_mode_set', params: {'p_enabled': on});
      ref.invalidate(assistantFlagsProvider);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(assistantFlagsProvider).valueOrNull ?? const {};
    if (f['available'] != true) return const SizedBox.shrink();
    final on = f['mine'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: on ? const Color(0xFF0E9384) : BrandColors.border), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.smart_toy_rounded, size: 18, color: on ? const Color(0xFF0E9384) : BrandColors.gray),
        const SizedBox(width: 6),
        Text(_t(context, on ? 'المساعد الآلي: شغّال' : 'المساعد الآلي: مقفول', on ? 'Assistant: ON' : 'Assistant: OFF'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        Switch(value: on, onChanged: _busy ? null : _set),
      ]),
    );
  }
}

final _reviewProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async =>
    Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('assistant_shift_review', params: {'p_shift': id}) as Map));

Future<void> showCashierAssistant(BuildContext context, {String? shiftId, required bool guard}) => showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 580, maxHeight: MediaQuery.of(context).size.height * .86),
          child: _AssistantDialog(shiftId: shiftId, guard: guard),
        ),
      ),
    );

/// The button shown in the till's top bar.
class AssistantButton extends ConsumerWidget {
  const AssistantButton({super.key, required this.shiftId});
  final String? shiftId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(assistantFlagsProvider).valueOrNull ?? const {};
    if (f['find'] != true) return const SizedBox.shrink();
    return FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0E9384)),
      icon: const Icon(Icons.smart_toy_rounded, size: 18),
      label: Text(_t(context, 'المساعد الذكي', 'Smart assistant')),
      onPressed: () => showCashierAssistant(context, shiftId: shiftId, guard: f['guard'] == true),
    );
  }
}

class _AssistantDialog extends StatelessWidget {
  const _AssistantDialog({required this.shiftId, required this.guard});
  final String? shiftId;
  final bool guard;
  @override
  Widget build(BuildContext context) {
    final showShift = guard && shiftId != null;
    return DefaultTabController(
      length: showShift ? 3 : 2,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
          child: Row(children: [
            const Icon(Icons.smart_toy_rounded, color: Color(0xFF0E9384)),
            const SizedBox(width: 8),
            Expanded(child: Text(_t(context, 'المساعد الذكي', 'Smart assistant'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
          ]),
        ),
        TabBar(tabs: [
          Tab(text: _t(context, 'دوّر على منتج', 'Find a product')),
          Tab(text: _t(context, 'إزاي أعمل؟', 'How do I?')),
          if (showShift) Tab(text: _t(context, 'ورديتي', 'My shift')),
        ]),
        Flexible(
          child: SizedBox(
            height: 520,
            child: TabBarView(children: [
              const _FindTab(),
              const _GuideTab(),
              if (showShift) SingleChildScrollView(padding: const EdgeInsets.all(14), child: ShiftReviewCard(shiftId: shiftId!, expanded: true)),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(_t(context, 'المساعد بيقترح ويشرح بس. السعر والمخزون والفواتير والمرتجعات بتفضل بإيدك وبموافقة المدير.',
              'The assistant only suggests and explains. Prices, stock, invoices and refunds stay in your hands and with your manager\'s approval.'),
              style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- find a product
class _FindTab extends ConsumerStatefulWidget {
  const _FindTab();
  @override
  ConsumerState<_FindTab> createState() => _FindTabState();
}

class _FindTabState extends ConsumerState<_FindTab> {
  Timer? _debounce;
  List<Map<String, dynamic>> _rows = const [];
  String? _error;
  bool _loading = false;
  bool _searched = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v.trim()));
  }

  Future<void> _search(String q) async {
    if (q.length < 2) {
      setState(() {
        _rows = const [];
        _searched = false;
        _error = null;
      });
      return;
    }
    final my = ++_seq;
    setState(() => _loading = true);
    try {
      final r = _maps(await ref.read(supabaseProvider).rpc('assistant_find_product', params: {'p_q': q}));
      if (!mounted || my != _seq) return;
      setState(() {
        _rows = r;
        _searched = true;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || my != _seq) return;
      setState(() {
        _error = '$e'.contains('MODE_OFF') ? _t(context, 'المساعد مقفول دلوقتي.', 'The assistant is off.') : friendlyError(context, e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(14), children: [
      TextField(
        autofocus: true,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: _t(context, 'اسم المنتج أو الكود: سعره، موجود فين، وبدايله', 'Product name or SKU: price, where it is, alternatives'),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: _onChanged,
      ),
      if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
      if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: BrandColors.error))),
      if (_searched && _rows.isEmpty && _error == null) Padding(padding: const EdgeInsets.all(20), child: Text(_t(context, 'مفيش منتج بالاسم ده.', 'No product found.'))),
      for (final p in _rows) _ProductCard(p: p),
    ]);
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.p});
  final Map<String, dynamic> p;
  @override
  Widget build(BuildContext context) {
    final here = (p['here_qty'] as num?)?.toInt() ?? 0;
    final branches = p['branches'] is List ? _maps(p['branches']) : null;
    final warehouse = (p['warehouse'] as num?)?.toInt();
    final alts = _maps(p['alternatives']);
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${p['name_ar']}', style: const TextStyle(fontWeight: FontWeight.w800))),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_money(context, p['price_minor']), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              if (p['compare_minor'] != null)
                Text(_money(context, p['compare_minor']), style: const TextStyle(decoration: TextDecoration.lineThrough, color: BrandColors.gray, fontSize: 12)),
            ]),
          ]),
          Text('${p['sku'] ?? ''}', style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
          const SizedBox(height: 8),
          Row(children: [
            Icon(here > 0 ? Icons.check_circle : Icons.cancel, size: 18, color: here > 0 ? BrandColors.success : BrandColors.error),
            const SizedBox(width: 6),
            Text(here > 0 ? _t(context, 'متوفر في فرعك: $here', 'In your branch: $here') : _t(context, 'مش متوفر في فرعك', 'Not in your branch'), style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          if (branches != null) ...[
            for (final b in branches) Padding(padding: const EdgeInsets.only(top: 3), child: Text('• ${b['branch']}: ${b['qty']}', style: const TextStyle(fontSize: 13))),
            if ((warehouse ?? 0) > 0) Padding(padding: const EdgeInsets.only(top: 3), child: Text('• ${_t(context, 'الوير هاوس', 'Warehouse')}: $warehouse', style: const TextStyle(fontSize: 13))),
          ] else if (p['elsewhere'] == true && here == 0)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(_t(context, 'متوفر في مكان تاني. اطلب من المدير يحوّله لفرعك.', 'Available elsewhere. Ask your manager to transfer it.'), style: const TextStyle(fontSize: 13)),
            ),
          if (alts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(here > 0 ? _t(context, 'بدائل قريبة', 'Similar products') : _t(context, 'بدائل متوفرة في فرعك', 'Alternatives in your branch'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            for (final a in alts)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(children: [
                  Expanded(child: Text('• ${a['name_ar']}', style: const TextStyle(fontSize: 13))),
                  Text('${_money(context, a['price_minor'])} · ${a['here_qty']}', style: const TextStyle(fontSize: 13, color: BrandColors.gray)),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- how do I
/// The common questions (also answered by the docked robot).
final assistantGuides = <(String, String, List<String>, List<String>)>[
  (
    'إزاي أعمل فاتورة صح؟',
    'How do I make an invoice?',
    [
      'اختار المنتجات من القائمة أو امسح الباركود، وراجع الاسم والكمية والسعر في السلة.',
      'لو في خصم، اكتبه في حدود المسموح لك. لو أكبر من حدّك هيطلب موافقة المدير.',
      'اكتب المبلغ اللي استلمته من العميل وراجع الباقي قبل ما ترجّعه.',
      'أكّد البيع وسلّم الفاتورة. الفاتورة بعد التأكيد مبتتعدّلش، التصحيح بيكون بمرتجع.',
    ],
    [
      'Pick the products or scan the barcode and check name, quantity and price in the cart.',
      'If there is a discount, keep it within your limit. Above your limit it asks your manager to approve.',
      'Type the cash you received and check the change before you hand it back.',
      'Confirm the sale. A confirmed invoice cannot be edited; corrections are made by a refund.',
    ],
  ),
  (
    'إزاي أعمل مرتجع صح؟',
    'How do I make a refund?',
    [
      'اضغط «مرتجع» في أعلى الشاشة وابحث عن الفاتورة برقمها.',
      'اختار القطع والكمية اللي هترجع، واكتب السبب بوضوح (مطلوب).',
      'لو المبلغ فوق حدّك هتطلب موافقة المدير، استنى موافقته.',
      'بعد التأكيد رجّع الفلوس للعميل من الدرج. كل مرتجع بيتسجل باسمك.',
    ],
    [
      'Press "Refund" at the top and find the invoice by its number.',
      'Pick the items and quantity to return and write the reason clearly (required).',
      'Above your limit you need your manager\'s approval; wait for it.',
      'After confirming, pay the customer from the drawer. Every refund is logged under your name.',
    ],
  ),
  (
    'لو المنتج خلص في فرعي؟',
    'The product is out in my branch?',
    [
      'دوّر عليه في تبويب «دوّر على منتج»: هيقولك لو متوفر في مكان تاني، وهيعرض لك بدايل في فرعك.',
      'لو في بديل مناسب اعرضه على العميل. لو عايز المنتج نفسه، اطلب من المدير يحوّله لفرعك.',
    ],
    [
      'Look it up in "Find a product": it tells you if it is available elsewhere and shows alternatives in your branch.',
      'Offer a suitable alternative, or ask your manager to transfer the product to your branch.',
    ],
  ),
  (
    'قبل ما أقفل الوردية',
    'Before I close the shift',
    [
      'عدّ الدرج فعلًا واكتب الرقم في خانة العد، ولو في فرق اكتب السببه.',
      'راجع تبويب «ورديتي»: هيعرض لك الفرق والخصومات والمرتجعات اللي هتتراجع.',
      'اكتب الباسورد وأقفل. بعدها بيتعمل تقرير نهائي مبيتعدّلش.',
    ],
    [
      'Count the drawer and type the number; if it differs write why.',
      'Check the "My shift" tab: it shows the difference, discounts and refunds that will be reviewed.',
      'Type your password and close. A final report is made that cannot be changed.',
    ],
  ),
];
class _GuideTab extends StatelessWidget {
  const _GuideTab();
  @override
  Widget build(BuildContext context) {

    return ListView(padding: const EdgeInsets.all(8), children: [
      for (final g in assistantGuides)
        ExpansionTile(
          title: Text(_t(context, g.$1, g.$2), style: const TextStyle(fontWeight: FontWeight.w700)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < g.$3.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('${i + 1}. ${_t(context, g.$3[i], g.$4[i])}')),
          ],
        ),
    ]);
  }
}

// ---------------------------------------------------------------- the shift guard
/// What will be looked at when this shift closes: cash difference, unusual discounts, refunds, voided invoices.
class ShiftReviewCard extends ConsumerWidget {
  const ShiftReviewCard({super.key, required this.shiftId, this.expanded = false});
  final String shiftId;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ref.watch(assistantFlagsProvider).valueOrNull ?? const {};
    if (flags['guard'] != true) return const SizedBox.shrink();
    final async = ref.watch(_reviewProvider(shiftId));
    return async.when(
      loading: () => const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator(minHeight: 2)),
      error: (e, _) => const SizedBox.shrink(),
      data: (r) {
        final alerts = _maps(r['alerts']);
        final refunds = r['refunds'] is Map ? Map<String, dynamic>.from(r['refunds'] as Map) : const <String, dynamic>{};
        final sales = r['sales'] is Map ? Map<String, dynamic>.from(r['sales'] as Map) : const <String, dynamic>{};
        final flagged = _maps(r['flagged_discounts']);
        final voided = _maps(r['voided']);
        final items = _maps(refunds['items']);
        return Card(
          color: alerts.isEmpty ? BrandColors.success.withValues(alpha: .08) : BrandColors.warning.withValues(alpha: .12),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.shield_rounded, size: 18),
                const SizedBox(width: 6),
                Text(_t(context, 'حارس الوردية', 'Shift guard'), style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 6),
              if (alerts.isEmpty) Text(_t(context, 'لحد دلوقتي كل حاجة سليمة ✅', 'Everything looks fine so far ✅')),
              for (final a in alerts) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('⚠️ ${a['text_ar']}')),
              if (expanded) ...[
                const Divider(),
                Text(_t(context, 'ملخص الوردية', 'Shift summary'), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${_t(context, 'فواتير', 'Invoices')}: ${sales['count'] ?? 0} · ${_t(context, 'مبيعات', 'Sales')}: ${_money(context, sales['total_minor'])}'),
                Text('${_t(context, 'الخصومات', 'Discounts')}: ${_money(context, sales['discount_minor'])} (${sales['discount_percent'] ?? 0}٪ — ${_t(context, 'المعتاد', 'usual')} ${sales['usual_percent'] ?? 0}٪)'),
                Text('${_t(context, 'المرتجعات', 'Refunds')}: ${refunds['count'] ?? 0} · ${_money(context, refunds['total_minor'])}'),
                if (flagged.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_t(context, 'خصومات أعلى من المعتاد', 'Higher-than-usual discounts'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  for (final f in flagged) Text('• ${f['number']}: ${f['percent']}٪ (${_money(context, f['discount_minor'])})'),
                ],
                if (items.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_t(context, 'المرتجعات', 'Refunds'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  for (final f in items) Text('• ${f['sale']}: ${_money(context, f['amount_minor'])} — ${f['reason']}'),
                ],
                if (voided.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_t(context, 'فواتير اترجعت بالكامل', 'Fully refunded invoices'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  for (final f in voided) Text('• ${f['number']}: ${_money(context, f['total_minor'])}'),
                ],
              ],
            ]),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- the managers' overview
class GuardOverviewDialog extends ConsumerWidget {
  const GuardOverviewDialog({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.of(context).size.height * .88),
        child: FutureBuilder<dynamic>(
          future: ref.read(supabaseProvider).rpc('assistant_guard_overview', params: {'p_days': 7}),
          builder: (c, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text(friendlyError(c, snap.error!)));
            if (!snap.hasData) return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
            final o = Map<String, dynamic>.from(snap.data as Map);
            Widget section(String ar, String en, List<Widget> rows, {String? emptyAr, String? emptyEn}) => Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_t(c, ar, en), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    if (rows.isEmpty) Text(_t(c, emptyAr ?? 'مفيش حاجة', emptyEn ?? 'Nothing'), style: const TextStyle(color: BrandColors.gray)),
                    ...rows,
                  ]),
                );
            final cashiers = _maps(o['cashiers']);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.shield_rounded, color: Color(0xFF0E9384)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_t(c, 'مراجعة العمليات — آخر ${o['days']} أيام', 'Operations review — last ${o['days']} days'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                  IconButton(onPressed: () => Navigator.pop(c), icon: const Icon(Icons.close_rounded)),
                ]),
                section('الموظفين: خصومات ومرتجعات', 'Staff: discounts and refunds', [
                  for (final x in cashiers)
                    Text('${x['flag'] == true ? '⚠️' : '•'} ${x['name']}: ${x['sales']} ${_t(c, 'فاتورة', 'invoices')} · ${_t(c, 'خصم', 'discount')} ${x['discount_percent']}٪ · ${_t(c, 'مرتجعات', 'refunds')} ${x['refund_count']} (${_money(c, x['refund_minor'])})'),
                ]),
                section('فروق النقدية', 'Cash differences', [
                  for (final x in _maps(o['cash_differences'])) Text('• ${x['branch']} · ${x['cashier']}: ${_money(c, x['variance_minor'])}'),
                ], emptyAr: 'مفيش فروق ✅', emptyEn: 'No differences ✅'),
                section('شاشات وبطاريات وإكسسوارات قربت تخلص', 'Screens, batteries and accessories running low', [
                  for (final x in _maps(o['low_key'])) Text('• ${x['name']}: ${x['total']}'),
                ]),
                section('فرع فاضي ومنتج كتير في فرع تاني', 'A branch is empty while another holds plenty', [
                  for (final x in _maps(o['imbalance'])) Text('• ${x['name']}: ${x['empty_branch']} ${_t(c, 'فاضي', 'empty')} · ${x['rich_branch']} ${x['rich_qty']}'),
                ]),
                section('اقتراح الشراء (حسب معدل البيع)', 'Suggested purchases (by sales rate)', [
                  for (final x in _maps(o['reorder']))
                    Text('• ${x['name']}: ${_t(c, 'فاضل', 'left')} ${x['stock']} (${x['days_left']} ${_t(c, 'يوم', 'days')}) → ${_t(c, 'اشترِ', 'buy')} ${x['suggest']}'),
                ]),
                section('منتجات راكدة (ما اتباعتش من 60 يوم)', 'Stagnant products (no sale for 60 days)', [
                  for (final x in _maps(o['stagnant'])) Text('• ${x['name']}: ${x['stock']}'),
                ]),
                const SizedBox(height: 12),
                Text(_t(c, 'ده اقتراح بس. الروبوت مابيغيّرش سعر ولا مخزون ولا فاتورة.', 'Suggestions only. The robot never changes a price, stock or invoice.'),
                    style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
              ]),
            );
          },
        ),
      ),
    );
  }
}
