// "My sales" (Odoo-like): what a member sold under his name for today, yesterday, this week, this month, this year or
// any range, split accessories / brand / repairs, per day (or per month for long ranges), and his top items.
// With "sales.view" (owner / manager) pick any member by code or name, or the whole team. The owner decides which
// category counts as accessories or brand. Server: my_sales_report, staff_codes, category_sales_groups.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/motion.dart';
import '../../shared/states.dart' show showSnack;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

const _accColor = Color(0xFF2E7CF6);
const _brandColor = Color(0xFF8B5CF6);
const _repairColor = Color(0xFFF08C00);

/// Every active team member with his 3-digit code (for pickers and search).
final staffCodesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final r = await ref.watch(supabaseProvider).rpc('staff_codes') as List? ?? const [];
  return [for (final e in r) Map<String, dynamic>.from(e as Map)];
});

/// Does [q] match a member by code ("101", "#101", "1") or by name?
bool staffMatches(Map<String, dynamic> m, String q) {
  final s = q.trim().replaceAll('#', '').toLowerCase();
  if (s.isEmpty) return false;
  final code = '${m['code'] ?? ''}';
  if (RegExp(r'^\d+$').hasMatch(s)) return code == s.padLeft(3, '0') || code.startsWith(s);
  return '${m['name'] ?? ''}'.toLowerCase().contains(s);
}

/// Opens one member's sales in a window (from the search, by code or name).
Future<void> showMemberSales(BuildContext context, String userId) => showSmoothDialog<void>(
      context: context,
      builder: (d) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 980, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
          child: Stack(children: [
            MySalesPanel(initialUser: userId),
            PositionedDirectional(top: 8, end: 8, child: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(d))),
          ]),
        ),
      ),
    );

class MySalesPanel extends ConsumerStatefulWidget {
  const MySalesPanel({super.key, this.initialUser});

  /// open on this member (needs "sales.view"); null = me
  final String? initialUser;
  @override
  ConsumerState<MySalesPanel> createState() => _MySalesPanelState();
}

class _MySalesPanelState extends ConsumerState<MySalesPanel> {
  String _preset = 'month';
  late DateTimeRange _range = _presetRange('month');
  late String? _user = widget.initialUser; // null = me
  bool _all = false;
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static DateTimeRange _presetRange(String p) {
    final d = _today();
    return switch (p) {
      'today' => DateTimeRange(start: d, end: d),
      'yesterday' => DateTimeRange(start: d.subtract(const Duration(days: 1)), end: d.subtract(const Duration(days: 1))),
      'week' => DateTimeRange(start: d.subtract(Duration(days: (d.weekday + 1) % 7)), end: d), // the week starts on Saturday
      'month' => DateTimeRange(start: DateTime(d.year, d.month, 1), end: d),
      'last_month' => DateTimeRange(start: DateTime(d.year, d.month - 1, 1), end: DateTime(d.year, d.month, 0)),
      _ => DateTimeRange(start: DateTime(d.year, 1, 1), end: d),
    };
  }

  String _iso(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(supabaseProvider).rpc('my_sales_report', params: {
        'p_from': _iso(_range.start),
        'p_to': _iso(_range.end),
        'p_user': _all ? null : _user,
        'p_all': _all,
      });
      if (mounted && seq == _seq) setState(() => _data = Map<String, dynamic>.from(r as Map));
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = friendlyError(context, e));
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  void _pick(String p) async {
    if (p == 'custom') {
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2024),
        lastDate: _today(),
        initialDateRange: _range,
        helpText: _t(context, 'اختار الفترة', 'Pick the period'),
      );
      if (r == null) return;
      setState(() {
        _preset = 'custom';
        _range = r;
      });
    } else {
      setState(() {
        _preset = p;
        _range = _presetRange(p);
      });
    }
    _load();
  }

  int _i(Object? v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final lang = context.lang;
    final canOthers = d?['can_others'] == true;
    final total = _i(d?['total']);
    final groups = (d?['groups'] as Map?) ?? const {};
    int amt(String g) => _i((groups[g] as Map?)?['amount']);
    int qty(String g) => _i((groups[g] as Map?)?['qty']);
    final invoices = _i(d?['invoices']);
    final presets = [
      ('today', _t(context, 'النهارده', 'Today')),
      ('yesterday', _t(context, 'امبارح', 'Yesterday')),
      ('week', _t(context, 'الأسبوع ده', 'This week')),
      ('month', _t(context, 'الشهر ده', 'This month')),
      ('last_month', _t(context, 'الشهر اللي فات', 'Last month')),
      ('year', _t(context, 'السنة دي', 'This year')),
      ('custom', _t(context, 'فترة تانية…', 'Other period…')),
    ];
    final fmt = DateFormat.yMMMd(lang);
    final who = _all
        ? _t(context, 'كل الفريق', 'The whole team')
        : d == null
            ? ''
            : '${d['name'] ?? ''}${d['code'] == null ? '' : ' · #${d['code']}'}';

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 18, 20, 32), children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 10, children: [
          Text(widget.initialUser == null && !_all && _user == null ? _t(context, 'مبيعاتي', 'My sales') : _t(context, 'مبيعات', 'Sales of'),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          if (who.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(who, style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.electric)),
            ),
          if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2)),
        ]),
        const SizedBox(height: 4),
        Text('${fmt.format(_range.start)} ← ${fmt.format(_range.end)}', style: const TextStyle(color: BrandColors.gray)),
        const SizedBox(height: 14),
        if (canOthers) ...[
          _MemberPicker(
            user: _user,
            all: _all,
            onChanged: (u, all) {
              setState(() {
                _user = u;
                _all = all;
              });
              _load();
            },
          ),
          const SizedBox(height: 12),
        ],
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (k, label) in presets) ChoiceChip(label: Text(label), selected: _preset == k, onSelected: (_) => _pick(k)),
        ]),
        const SizedBox(height: 18),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: const TextStyle(color: BrandColors.error)))
        else if (d != null) ...[
          // the headline: the total, then the three groups
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(20), border: Border.all(color: panelLine(context))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t(context, 'إجمالي المبيعات', 'Total sales'), style: const TextStyle(color: BrandColors.gray, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(formatEgp(total, lang), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(
                  '${_t(context, 'فواتير', 'Invoices')}: $invoices'
                  '${invoices == 0 ? '' : ' · ${_t(context, 'متوسط الفاتورة', 'Average invoice')}: ${formatEgp(((amt('acc') + amt('brand')) / invoices).round(), lang)}'}',
                  style: const TextStyle(color: BrandColors.gray)),
              const SizedBox(height: 14),
              if (total > 0)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 12,
                    child: Row(children: [
                      for (final (g, c) in [('acc', _accColor), ('brand', _brandColor), ('repair', _repairColor)])
                        if (amt(g) > 0) Expanded(flex: (amt(g) * 1000 ~/ total).clamp(1, 1000), child: Container(color: c)),
                    ]),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            final cards = [
              _GroupCard(color: _accColor, icon: Icons.headphones_rounded, title: _t(context, 'إكسسوارات', 'Accessories'), amount: amt('acc'), qty: qty('acc'), total: total, unit: _t(context, 'قطعة', 'items')),
              _GroupCard(color: _brandColor, icon: Icons.phone_iphone_rounded, title: _t(context, 'براند', 'Brand'), amount: amt('brand'), qty: qty('brand'), total: total, unit: _t(context, 'قطعة', 'items')),
              _GroupCard(color: _repairColor, icon: Icons.build_rounded, title: _t(context, 'صيانة', 'Repairs'), amount: amt('repair'), qty: qty('repair'), total: total, unit: _t(context, 'جهاز', 'devices')),
            ];
            if (c.maxWidth < 640) return Column(children: [for (final w in cards) Padding(padding: const EdgeInsets.only(bottom: 10), child: w)]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < cards.length; i++) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: cards[i])],
            ]);
          }),
          const SizedBox(height: 18),
          _Bars(series: [for (final e in (d['series'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)], monthly: d['monthly'] == true),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: Text(_t(context, 'أكتر حاجات اتباعت', 'Top items'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900))),
            if (d['can_edit_groups'] == true)
              TextButton.icon(
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(_t(context, 'أقسام المبيعات', 'Sales groups')),
                onPressed: () async {
                  await showSmoothDialog<void>(context: context, builder: (_) => const _GroupsDialog());
                  _load();
                },
              ),
          ]),
          const SizedBox(height: 6),
          if ((d['top'] as List? ?? const []).isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text(_t(context, 'مفيش مبيعات في الفترة دي', 'No sales in this period'), style: const TextStyle(color: BrandColors.gray))),
            )
          else
            for (final t in (d['top'] as List))
              Builder(builder: (context) {
                final m = Map<String, dynamic>.from(t as Map);
                final c = switch (m['group']) { 'brand' => _brandColor, 'repair' => _repairColor, _ => _accColor };
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 6, backgroundColor: c),
                  minLeadingWidth: 14,
                  title: Text(_t(context, '${m['name_ar']}', '${m['name_en']}'), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('× ${_i(m['qty'])}'),
                  trailing: Text(formatEgp(_i(m['amount']), lang), style: const TextStyle(fontWeight: FontWeight.w800)),
                );
              }),
        ],
      ]),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.color, required this.icon, required this.title, required this.amount, required this.qty, required this.total, required this.unit});
  final Color color;
  final IconData icon;
  final String title, unit;
  final int amount, qty, total;

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0 : (amount * 100 / total).round();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
          Text('$pct%', style: TextStyle(color: color, fontWeight: FontWeight.w900)),
        ]),
        const SizedBox(height: 10),
        Text(formatEgp(amount, context.lang), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        Text('$qty $unit', style: const TextStyle(color: BrandColors.gray)),
      ]),
    );
  }
}

/// Stacked bars, one per day (or per month): accessories, brand, repairs. Hover a bar for its numbers.
class _Bars extends StatelessWidget {
  const _Bars({required this.series, required this.monthly});
  final List<Map<String, dynamic>> series;
  final bool monthly;

  @override
  Widget build(BuildContext context) {
    if (series.length < 2) return const SizedBox.shrink();
    int v(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;
    final max = series.map((m) => v(m, 'acc') + v(m, 'brand') + v(m, 'repair')).fold<int>(1, (a, b) => b > a ? b : a);
    final lang = context.lang;
    const h = 150.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(18), border: Border.all(color: panelLine(context))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(monthly ? _t(context, 'كل شهر', 'By month') : _t(context, 'كل يوم', 'By day'), style: const TextStyle(fontWeight: FontWeight.w900))),
          for (final (c, l) in [(_accColor, _t(context, 'إكسسوارات', 'Accessories')), (_brandColor, _t(context, 'براند', 'Brand')), (_repairColor, _t(context, 'صيانة', 'Repairs'))]) ...[
            CircleAvatar(radius: 5, backgroundColor: c),
            const SizedBox(width: 4),
            Text(l, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 10),
          ],
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: h + 22,
          child: LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth / series.length).clamp(10.0, 44.0);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final m in series)
                  Builder(builder: (context) {
                    final day = DateTime.parse('${m['b']}');
                    final sum = v(m, 'acc') + v(m, 'brand') + v(m, 'repair');
                    double px(int x) => x * h / max;
                    final label = monthly ? DateFormat.MMM(lang).format(day) : '${day.day}';
                    return Tooltip(
                      message: '${monthly ? DateFormat.yMMM(lang).format(day) : DateFormat.MMMEd(lang).format(day)}\n'
                          '${_t(context, 'الإجمالي', 'Total')}: ${formatEgp(sum, lang)}\n'
                          '${_t(context, 'إكسسوارات', 'Accessories')}: ${formatEgp(v(m, 'acc'), lang)}\n'
                          '${_t(context, 'براند', 'Brand')}: ${formatEgp(v(m, 'brand'), lang)}\n'
                          '${_t(context, 'صيانة', 'Repairs')}: ${formatEgp(v(m, 'repair'), lang)}',
                      child: SizedBox(
                        width: w,
                        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                          Container(
                            width: w * 0.62,
                            clipBehavior: Clip.antiAlias,
                            decoration: const BoxDecoration(borderRadius: BorderRadius.vertical(top: Radius.circular(4))),
                            child: Column(children: [
                              if (v(m, 'repair') > 0) Container(height: px(v(m, 'repair')), color: _repairColor),
                              if (v(m, 'brand') > 0) Container(height: px(v(m, 'brand')), color: _brandColor),
                              if (v(m, 'acc') > 0) Container(height: px(v(m, 'acc')), color: _accColor),
                              if (sum == 0) Container(height: 2, color: BrandColors.border),
                            ]),
                          ),
                          const SizedBox(height: 4),
                          Text(label, style: const TextStyle(fontSize: 10.5, color: BrandColors.gray)),
                        ]),
                      ),
                    );
                  }),
              ]),
            );
          }),
        ),
      ]),
    );
  }
}

/// Owner / manager: whose sales — me, the whole team, or any member by code or name.
class _MemberPicker extends ConsumerWidget {
  const _MemberPicker({required this.user, required this.all, required this.onChanged});
  final String? user;
  final bool all;
  final void Function(String? user, bool all) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(staffCodesProvider).valueOrNull ?? const [];
    final value = all ? '__all' : (user ?? '__me');
    return DropdownMenu<String>(
      key: ValueKey(value),
      initialSelection: value,
      width: 340,
      enableFilter: true,
      requestFocusOnTap: true,
      leadingIcon: const Icon(Icons.badge_outlined),
      label: Text(_t(context, 'الموظف (اكتب الكود أو الاسم)', 'Member (type the code or name)')),
      filterCallback: (entries, q) => q.trim().isEmpty
          ? entries
          : [
              for (final e in entries)
                if (e.value.startsWith('__') || list.any((m) => m['user_id'] == e.value && staffMatches(m, q))) e,
            ],
      dropdownMenuEntries: [
        DropdownMenuEntry(value: '__me', label: _t(context, 'أنا', 'Me'), leadingIcon: const Icon(Icons.person_rounded)),
        DropdownMenuEntry(value: '__all', label: _t(context, 'كل الفريق', 'Whole team'), leadingIcon: const Icon(Icons.groups_rounded)),
        for (final m in list) DropdownMenuEntry(value: '${m['user_id']}', label: '#${m['code'] ?? '—'}  ${m['name'] ?? ''}'),
      ],
      onSelected: (v) {
        if (v == null) return;
        if (v == '__all') {
          onChanged(null, true);
        } else if (v == '__me') {
          onChanged(null, false);
        } else {
          onChanged(v, false);
        }
      },
    );
  }
}

/// Owner: which categories count as accessories and which as brand (repairs are their own group).
class _GroupsDialog extends ConsumerStatefulWidget {
  const _GroupsDialog();
  @override
  ConsumerState<_GroupsDialog> createState() => _GroupsDialogState();
}

class _GroupsDialogState extends ConsumerState<_GroupsDialog> {
  List<Map<String, dynamic>>? _cats;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(supabaseProvider).rpc('category_sales_groups').then((r) {
      if (mounted) setState(() => _cats = [for (final e in (r as List)) Map<String, dynamic>.from(e as Map)]);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = friendlyError(context, e));
    });
  }

  Future<void> _set(Map<String, dynamic> c, String g) async {
    final old = c['sales_group'];
    setState(() => c['sales_group'] = g);
    try {
      await ref.read(supabaseProvider).rpc('category_sales_group_set', params: {'p_category': c['id'], 'p_group': g});
    } catch (e) {
      if (mounted) {
        setState(() => c['sales_group'] = old);
        showSnack(context, friendlyError(context, e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t(context, 'أقسام المبيعات', 'Sales groups')),
        content: SizedBox(
          width: 520,
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: _error != null
              ? Text(_error!, style: const TextStyle(color: BrandColors.error))
              : _cats == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(children: [
                      Text(_t(context, 'كل فئة منتجات بتتحسب إكسسوارات أو براند. الصيانة بتتحسب لوحدها.', 'Each product category counts as accessories or brand. Repairs count on their own.'),
                          style: const TextStyle(color: BrandColors.gray)),
                      const SizedBox(height: 10),
                      for (final c in _cats!)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            Expanded(child: Text(_t(context, '${c['name_ar']}', '${c['name_en']}'), style: const TextStyle(fontWeight: FontWeight.w700))),
                            SegmentedButton<String>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(value: 'acc', label: Text(_t(context, 'إكسسوارات', 'Accessories'))),
                                ButtonSegment(value: 'brand', label: Text(_t(context, 'براند', 'Brand'))),
                              ],
                              selected: {'${c['sales_group'] ?? 'acc'}'},
                              onSelectionChanged: (s) => _set(c, s.first),
                            ),
                          ]),
                        ),
                    ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'Done')))],
      );
}
