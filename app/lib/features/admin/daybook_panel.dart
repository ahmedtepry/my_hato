// "اليومية والتحصيل": one line per branch per day (like an Odoo POS session). Cash, card and wallet after refunds,
// expenses, drawer difference, what the accountant should collect and what he collected (on any later day).
// Tap a day: its steps in time order (shift opened, refunds, expenses, closed, collected, locked) and the actions.
// Who sees it is decided by permissions (daybook.view / collect / lock) and the owner can switch the page off.
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/motion.dart';
import '../../shared/states.dart';
import 'admin_repository.dart' show staffContextProvider;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _m(BuildContext c, Object? minor) => formatEgp((minor as num?)?.round() ?? 0, c.lang);
int _i(Object? v) => (v as num?)?.round() ?? 0;
String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String daybookError(BuildContext c, Object e) {
  final s = e.toString();
  String? pick(String code, String ar, String en) => s.contains(code) ? _t(c, ar, en) : null;
  return pick('DAYBOOK_OFF', 'المالك قافل صفحة اليومية دلوقتي', 'The owner switched the daily register off') ??
      pick('DAY_LOCKED', 'اليوم ده مقفول، مينفعش يتغيّر فيه حاجة', 'This day is locked') ??
      pick('SHIFT_STILL_OPEN', 'لسه فيه وردية مفتوحة في اليوم ده. اقفلها الأول', 'A shift of this day is still open') ??
      pick('OVER_COLLECT', 'المبلغ أكبر من الباقي على اليوم ده', 'More than what is left to collect') ??
      pick('REASON_REQUIRED', 'اكتب سبب الإلغاء', 'Write the reason') ??
      pick('ALREADY_VOIDED', 'التحصيل ده اتلغى قبل كده', 'Already voided') ??
      pick('FORBIDDEN', 'مالكش صلاحية على ده', 'Not allowed') ??
      friendlyError(c, e);
}

// ------------------------------------------------------------------------------------------------ data
class DaybookRange {
  const DaybookRange(this.preset, this.from, this.to);
  final String preset;
  final DateTime from, to;
  static DaybookRange of(String preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (preset) {
      'month' => DaybookRange(preset, DateTime(now.year, now.month, 1), today),
      'last_month' => DaybookRange(preset, DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0)),
      '7d' => DaybookRange(preset, today.subtract(const Duration(days: 6)), today),
      _ => DaybookRange('14d', today.subtract(const Duration(days: 13)), today),
    };
  }

  @override
  bool operator ==(Object o) => o is DaybookRange && o.preset == preset && o.from == from && o.to == to;
  @override
  int get hashCode => Object.hash(preset, from, to);
}

final _rangeProvider = StateProvider<DaybookRange>((_) => DaybookRange.of('14d'));
final _branchProvider = StateProvider<String?>((_) => null);

final _listProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final r = ref.watch(_rangeProvider);
  final res = await ref.read(supabaseProvider).rpc('daybook_list', params: {'p_branch': null, 'p_from': _iso(r.from), 'p_to': _iso(r.to)});
  return Map<String, dynamic>.from(res as Map);
});

// ------------------------------------------------------------------------------------------------ status
(String, Color, IconData) _status(BuildContext c, String? s) => switch (s) {
      'open' => (_t(c, 'وردية مفتوحة', 'Shift open'), const Color(0xFF2F6BFF), Icons.lock_open_rounded),
      'due' => (_t(c, 'مستني تحصيل', 'To collect'), BrandColors.warning, Icons.hourglass_bottom_rounded),
      'partial' => (_t(c, 'تحصيل جزئي', 'Partly collected'), const Color(0xFFDC6803), Icons.timelapse_rounded),
      'collected' => (_t(c, 'اتحصّلت', 'Collected'), BrandColors.success, Icons.check_circle_rounded),
      'locked' => (_t(c, 'مقفولة', 'Locked'), const Color(0xFF7A5AF8), Icons.lock_rounded),
      _ => (_t(c, 'مفيش كاش', 'No cash'), BrandColors.gray, Icons.remove_circle_outline_rounded),
    };

/// The day's status. With [onTap] (accountant / owner, day waiting for collection) it is a button: tap it to mark
/// the day collected.
Widget _pill(BuildContext c, String? s, {VoidCallback? onTap}) {
  final (label, color, icon) = _status(c, s);
  final body = Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
        color: color.withValues(alpha: onTap != null ? 0.22 : 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: onTap != null ? 0.9 : 0.5), width: onTap != null ? 1.6 : 1)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 15, color: color),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5)),
      if (onTap != null) ...[
        const SizedBox(width: 6),
        Icon(Icons.touch_app_rounded, size: 15, color: color),
      ],
    ]),
  );
  if (onTap == null) return body;
  return Tooltip(
    message: _t(c, 'اضغط علشان تسجّل إنه اتحصّل', 'Tap to mark it collected'),
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(type: MaterialType.transparency, child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: body)),
    ),
  );
}

String _dayLabel(BuildContext c, String iso) {
  final d = DateTime.parse(iso);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  final name = DateFormat('EEEE d/M', c.isAr ? 'ar' : 'en').format(d);
  if (diff == 0) return '${_t(c, 'النهارده', 'Today')} · $name';
  if (diff == 1) return '${_t(c, 'امبارح', 'Yesterday')} · $name';
  return name;
}

// ------------------------------------------------------------------------------------------------ the page
class DaybookPanel extends ConsumerWidget {
  const DaybookPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_listProvider);
    final range = ref.watch(_rangeProvider);
    final branch = ref.watch(_branchProvider);
    final owner = ref.watch(staffContextProvider).valueOrNull?.roles.contains('owner') ?? false;
    final d = data.valueOrNull;
    final rows = [for (final e in (d?['rows'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    final older = [for (final e in (d?['older_due'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    final branches = <String, String>{for (final r in [...rows, ...older]) '${r['branch_id']}': '${r['branch_name'] ?? ''}'};
    final shown = branch == null ? rows : rows.where((r) => r['branch_id'] == branch).toList();
    final shownOlder = branch == null ? older : older.where((r) => r['branch_id'] == branch).toList();
    int sum(String k) => shown.fold(0, (s, r) => s + _i(r[k]));
    final canCollect = d?['can_collect'] == true;
    final ink = inkColor(context);

    Widget chip(String label, bool on, VoidCallback onTap) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8, bottom: 8),
          child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => onTap()),
        );

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(_listProvider),
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 18, 20, 40), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t(context, 'اليومية والتحصيل', 'Daily register & collection'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(_t(context, 'سطر لكل يوم في كل فرع: الكاش والفيزا والمحفظة بعد المرتجع، فرق الدرج، واللي المحاسب حصّله. اضغط على أي يوم تشوف خطواته.',
                      'One line per day per branch: cash, card and wallet after refunds, the drawer difference, and what the accountant collected. Tap a day to see its steps.'),
                  style: TextStyle(color: ink.withValues(alpha: 0.65))),
            ]),
          ),
          IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: () => ref.invalidate(_listProvider), icon: const Icon(Icons.refresh_rounded)),
        ]),
        if (owner && d != null) _OwnerSwitch(enabled: d['enabled'] != false),
        const SizedBox(height: 12),
        Wrap(children: [
          chip(_t(context, 'آخر 7 أيام', 'Last 7 days'), range.preset == '7d', () => ref.read(_rangeProvider.notifier).state = DaybookRange.of('7d')),
          chip(_t(context, 'آخر 14 يوم', 'Last 14 days'), range.preset == '14d', () => ref.read(_rangeProvider.notifier).state = DaybookRange.of('14d')),
          chip(_t(context, 'الشهر ده', 'This month'), range.preset == 'month', () => ref.read(_rangeProvider.notifier).state = DaybookRange.of('month')),
          chip(_t(context, 'الشهر اللي فات', 'Last month'), range.preset == 'last_month', () => ref.read(_rangeProvider.notifier).state = DaybookRange.of('last_month')),
        ]),
        if (branches.length > 1)
          Wrap(children: [
            chip(_t(context, 'كل الفروع', 'All branches'), branch == null, () => ref.read(_branchProvider.notifier).state = null),
            for (final e in branches.entries) chip(e.value, branch == e.key, () => ref.read(_branchProvider.notifier).state = e.key),
          ]),
        const SizedBox(height: 6),
        if (data.isLoading && d == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (data.hasError && d == null) ErrorView(error: daybookError(context, data.error!), onRetry: () => ref.invalidate(_listProvider)),
        if (d != null) ...[
          _Totals(items: [
            (_t(context, 'صافي المبيعات', 'Net sales'), sum('total_minor'), null),
            (_t(context, 'كاش', 'Cash'), sum('cash_minor'), null),
            (_t(context, 'فيزا', 'Card'), sum('card_minor'), null),
            (_t(context, 'محفظة', 'Wallet'), sum('wallet_minor'), null),
            (_t(context, 'للتحصيل', 'To collect'), sum('to_collect_minor'), null),
            (_t(context, 'اتحصّل', 'Collected'), sum('collected_minor'), BrandColors.success),
            (_t(context, 'باقي', 'Left'), sum('remaining_minor'), sum('remaining_minor') > 0 ? BrandColors.warning : BrandColors.success),
          ]),
          if (shownOlder.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(children: [
              const Icon(Icons.history_rounded, color: BrandColors.warning),
              const SizedBox(width: 8),
              Text(_t(context, 'أيام قديمة لسه مستنية تحصيل', 'Older days still waiting for collection'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            ]),
            const SizedBox(height: 8),
            for (final r in shownOlder) _DayLine(row: r, canCollect: canCollect),
          ],
          const SizedBox(height: 16),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(30),
              child: Center(child: Text(_t(context, 'مفيش ورديات في الفترة دي', 'No shifts in this period'), style: TextStyle(color: ink.withValues(alpha: 0.6)))),
            ),
          for (final r in shown) _DayLine(row: r, canCollect: canCollect),
        ],
      ]),
    );
  }
}

class _OwnerSwitch extends ConsumerStatefulWidget {
  const _OwnerSwitch({required this.enabled});
  final bool enabled;
  @override
  ConsumerState<_OwnerSwitch> createState() => _OwnerSwitchState();
}

class _OwnerSwitchState extends ConsumerState<_OwnerSwitch> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(16), border: Border.all(color: panelLine(context))),
        child: SwitchListTile(
          value: widget.enabled,
          onChanged: _busy
              ? null
              : (v) async {
                  setState(() => _busy = true);
                  try {
                    await ref.read(supabaseProvider).rpc('daybook_enable', params: {'p_on': v});
                    ref.invalidate(_listProvider);
                    if (context.mounted) showSnack(context, v ? _t(context, 'اليومية رجعت تظهر للفريق ✅', 'The team can see it again ✅') : _t(context, 'اليومية اتقفلت على الفريق (إنت بس اللي شايفها)', 'Hidden from the team (only you see it)'));
                  } catch (e) {
                    if (context.mounted) showSnack(context, daybookError(context, e), error: true);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          secondary: Icon(widget.enabled ? Icons.visibility_rounded : Icons.visibility_off_rounded),
          title: Text(_t(context, 'ظاهرة للفريق', 'Visible to the team'), style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(_t(context, 'مين يشوفها ومين يحصّل ومين يقفل بيتحدد من «الصلاحيات» (اليومية والتحصيل). القفل هنا بيخفيها عن الكل ماعداك.',
              'Who sees, collects and locks is set in Permissions (daily register). Switching off here hides it from everyone but you.')),
        ),
      );
}

class _Totals extends StatelessWidget {
  const _Totals({required this.items});
  final List<(String, int, Color?)> items;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(18), border: Border.all(color: BrandColors.electric.withValues(alpha: 0.3))),
        child: Wrap(spacing: 26, runSpacing: 12, children: [
          for (final (label, v, color) in items)
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: TextStyle(fontSize: 12.5, color: inkColor(context).withValues(alpha: 0.65))),
              Text(_m(context, v), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
        ]),
      );
}

/// One day of one branch.
class _DayLine extends ConsumerWidget {
  const _DayLine({required this.row, required this.canCollect});
  final Map<String, dynamic> row;
  final bool canCollect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = row;
    final ink = inkColor(context);
    final status = r['status'] as String?;
    final variance = _i(r['variance_minor']);
    Widget cell(String label, Object? v, {Color? color, bool strong = false}) => SizedBox(
          width: 118,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 11.5, color: ink.withValues(alpha: 0.6))),
            Text(_m(context, v), style: TextStyle(fontWeight: strong ? FontWeight.w900 : FontWeight.w700, fontSize: 14, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showDaybookDay(context, '${r['branch_id']}', '${r['day']}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(_dayLabel(context, '${r['day']}'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(8), border: Border.all(color: panelLine(context))),
                    child: Text('${r['branch_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ),
                  _pill(context, status, onTap: canCollect && (status == 'due' || status == 'partial') ? () => collectDay(context, ref, r) : null),
                  Text('${_i(r['shifts'])} ${_t(context, 'وردية', 'shifts')} · ${_i(r['sales_count'])} ${_t(context, 'فاتورة', 'invoices')}',
                      style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.6))),
                ]),
              ),
              if (canCollect && (status == 'due' || status == 'partial'))
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
                  onPressed: () => collectDay(context, ref, r),
                  icon: const Icon(Icons.payments_rounded, size: 18),
                  label: Text(_t(context, 'تحصيل', 'Collect')),
                ),
              const Icon(Icons.chevron_left_rounded),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 10, children: [
              cell(_t(context, 'كاش', 'Cash'), r['cash_minor']),
              cell(_t(context, 'فيزا', 'Card'), r['card_minor']),
              cell(_t(context, 'محفظة', 'Wallet'), r['wallet_minor']),
              cell(_t(context, 'مرتجع', 'Refunds'), r['refunds_minor']),
              cell(_t(context, 'مصروفات', 'Expenses'), r['expenses_minor']),
              cell(_t(context, 'فرق الدرج', 'Drawer diff.'), variance, color: variance == 0 ? null : (variance < 0 ? BrandColors.error : BrandColors.warning)),
              cell(_t(context, 'للتحصيل', 'To collect'), r['to_collect_minor'], strong: true),
              cell(_t(context, 'اتحصّل', 'Collected'), r['collected_minor'], color: BrandColors.success, strong: true),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ collect
Future<bool> collectDay(BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
  final res = await showSmoothDialog<Map<String, dynamic>>(context: context, builder: (_) => _CollectDialog(row: row));
  if (res == null || !context.mounted) return false;
  try {
    await ref.read(supabaseProvider).rpc('daybook_collect', params: {
      'p_branch': row['branch_id'],
      'p_day': row['day'],
      'p_amount_minor': res['amount'],
      'p_method': res['method'],
      'p_note': res['note'],
    });
    ref.invalidate(_listProvider);
    if (context.mounted) showSnack(context, _t(context, 'اتسجّل التحصيل ✅', 'Collection recorded ✅'));
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, daybookError(context, e), error: true);
    return false;
  }
}

class _CollectDialog extends StatefulWidget {
  const _CollectDialog({required this.row});
  final Map<String, dynamic> row;
  @override
  State<_CollectDialog> createState() => _CollectDialogState();
}

class _CollectDialogState extends State<_CollectDialog> {
  late final _amount = TextEditingController(text: (_i(widget.row['remaining_minor']) / 100).toStringAsFixed(_i(widget.row['remaining_minor']) % 100 == 0 ? 0 : 2));
  final _note = TextEditingController();
  String _method = 'cash';

  @override
  void dispose() {
    disposeLater(_amount);
    disposeLater(_note);
    super.dispose();
  }

  int? get _minor => parseEgpToMinor(_amount.text);

  @override
  Widget build(BuildContext context) {
    final rem = _i(widget.row['remaining_minor']);
    final v = _minor;
    final ok = v != null && v > 0 && v <= rem;
    return AlertDialog(
      title: Text('${_t(context, 'تحصيل', 'Collect')} · ${widget.row['branch_name']} · ${_dayLabel(context, '${widget.row['day']}')}'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${_t(context, 'الباقي على اليوم ده', 'Left on this day')}: ${_m(context, rem)}', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: _t(context, 'المبلغ اللي استلمته (ج.م)', 'Amount received (EGP)'), errorText: v != null && v > rem ? _t(context, 'أكبر من الباقي', 'More than what is left') : null),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Text(_t(context, 'استلمته إزاي؟', 'How?'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (k, ar, en) in const [('cash', 'كاش في إيدي', 'Cash in hand'), ('bank', 'إيداع بنك', 'Bank deposit'), ('wallet', 'تحويل محفظة', 'Wallet transfer'), ('other', 'تاني', 'Other')])
              ChoiceChip(label: Text(_t(context, ar, en)), selected: _method == k, onSelected: (_) => setState(() => _method = k)),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _note, maxLength: 300, decoration: InputDecoration(labelText: _t(context, 'ملاحظة (اختياري)', 'Note (optional)'), counterText: '')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
        FilledButton(
          onPressed: ok ? () => Navigator.pop(context, {'amount': v, 'method': _method, 'note': _note.text.trim().isEmpty ? null : _note.text.trim()}) : null,
          child: Text(_t(context, 'سجّل التحصيل', 'Record collection')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ one day: the steps
Future<void> showDaybookDay(BuildContext context, String branchId, String day) =>
    showSmoothDialog<void>(context: context, builder: (_) => _DayDialog(branchId: branchId, day: day));

class _DayDialog extends ConsumerStatefulWidget {
  const _DayDialog({required this.branchId, required this.day});
  final String branchId, day;
  @override
  ConsumerState<_DayDialog> createState() => _DayDialogState();
}

class _DayDialogState extends ConsumerState<_DayDialog> {
  late Future<Map<String, dynamic>> _f = _load();
  bool _busy = false;

  Future<Map<String, dynamic>> _load() async =>
      Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('daybook_day', params: {'p_branch': widget.branchId, 'p_day': widget.day}) as Map);

  void _reload() {
    ref.invalidate(_listProvider);
    setState(() => _f = _load());
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) showSnack(context, done);
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, daybookError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _void(Map<String, dynamic> step) async {
    final c = TextEditingController();
    final reason = await showSmoothDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(context, 'إلغاء التحصيل ده؟', 'Void this collection?')),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: _t(context, 'السبب (لازم)', 'Reason (required)'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(_t(context, 'رجوع', 'Back'))),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: BrandColors.error), onPressed: () => Navigator.pop(d, c.text.trim()), child: Text(_t(context, 'إلغاء التحصيل', 'Void'))),
        ],
      ),
    );
    disposeLater(c);
    if (reason == null || reason.isEmpty || !mounted) return;
    await _run(() => ref.read(supabaseProvider).rpc('daybook_collection_void', params: {'p_id': step['id'], 'p_reason': reason}), _t(context, 'التحصيل اتلغى', 'Collection voided'));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760, maxHeight: size.height * 0.88),
        child: FutureBuilder<Map<String, dynamic>>(
          future: _f,
          builder: (context, snap) {
            if (!snap.hasData) {
              return SizedBox(
                height: 220,
                child: Center(child: snap.hasError ? Padding(padding: const EdgeInsets.all(20), child: Text(daybookError(context, snap.error!))) : const CircularProgressIndicator()),
              );
            }
            final d = snap.data!;
            final s = Map<String, dynamic>.from(d['summary'] as Map);
            final steps = [for (final e in (d['steps'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
            final canCollect = d['can_collect'] == true, canLock = d['can_lock'] == true;
            final status = s['status'] as String?;
            final locked = s['locked'] == true;
            final ink = inkColor(context);
            Widget kv(String k, Object? v, {Color? color, bool strong = false}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Expanded(child: Text(k, style: TextStyle(color: ink.withValues(alpha: 0.7)))),
                    Text(_m(context, v), style: TextStyle(fontWeight: strong ? FontWeight.w900 : FontWeight.w700, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
                  ]),
                );
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(children: [
                  Expanded(
                    child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text('${s['branch_name']} · ${_dayLabel(context, widget.day)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                      _pill(context, status,
                          onTap: canCollect && (status == 'due' || status == 'partial') && !_busy
                              ? () async {
                                  if (await collectDay(context, ref, s)) _reload();
                                }
                              : null),
                    ]),
                  ),
                  IconButton(tooltip: _t(context, 'إغلاق', 'Close'), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                ]),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 14, 20, 14), children: [
                  // the numbers of the day
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(16), border: Border.all(color: panelLine(context))),
                    child: Column(children: [
                      kv(_t(context, 'كاش (بعد المرتجع)', 'Cash (after refunds)'), s['cash_minor']),
                      kv(_t(context, 'فيزا', 'Card'), s['card_minor']),
                      kv(_t(context, 'محفظة', 'Wallet'), s['wallet_minor']),
                      kv(_t(context, 'المرتجع', 'Refunds'), s['refunds_minor']),
                      kv(_t(context, 'المصروفات من الدرج', 'Expenses from the drawer'), s['expenses_minor']),
                      kv(_t(context, 'العهدة أول اليوم', 'Opening float'), s['float_minor']),
                      kv(_t(context, 'المفروض في الدرج', 'Expected in the drawer'), s['expected_minor']),
                      kv(_t(context, 'اتعدّ في الدرج', 'Counted in the drawer'), s['counted_minor']),
                      kv(_t(context, 'فرق الدرج', 'Drawer difference'), s['variance_minor'], color: _i(s['variance_minor']) == 0 ? null : BrandColors.warning),
                      const Divider(),
                      kv(_t(context, 'المطلوب تحصيله (المعدود ناقص العهدة)', 'To collect (counted minus float)'), s['to_collect_minor'], strong: true),
                      kv(_t(context, 'اتحصّل', 'Collected'), s['collected_minor'], color: BrandColors.success, strong: true),
                      kv(_t(context, 'باقي', 'Left'), s['remaining_minor'], color: _i(s['remaining_minor']) > 0 ? BrandColors.warning : BrandColors.success, strong: true),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Text(_t(context, 'خطوات اليوم', 'The day step by step'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  for (var i = 0; i < steps.length; i++)
                    _Step(step: steps[i], last: i == steps.length - 1, onVoid: canCollect && !locked && steps[i]['kind'] == 'collect' && !_busy ? () => _void(steps[i]) : null),
                  if (steps.isEmpty) Text(_t(context, 'مفيش خطوات', 'No steps'), style: TextStyle(color: ink.withValues(alpha: 0.6))),
                ]),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 8, children: [
                  if (canLock && status != 'open')
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(140, 48)),
                      onPressed: _busy
                          ? null
                          : () => _run(() => ref.read(supabaseProvider).rpc('daybook_lock', params: {'p_branch': widget.branchId, 'p_day': widget.day, 'p_lock': !locked}),
                              locked ? _t(context, 'اليوم اتفتح تاني', 'Day unlocked') : _t(context, 'اليوم اتقفل 🔒', 'Day locked 🔒')),
                      icon: Icon(locked ? Icons.lock_open_rounded : Icons.lock_rounded),
                      label: Text(locked ? _t(context, 'افتح اليوم', 'Unlock day') : _t(context, 'اقفل اليوم', 'Lock day')),
                    ),
                  if (canCollect && (status == 'due' || status == 'partial'))
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(150, 48)),
                      onPressed: _busy
                          ? null
                          : () async {
                              if (await collectDay(context, ref, s)) _reload();
                            },
                      icon: const Icon(Icons.payments_rounded),
                      label: Text(_t(context, 'سجّل تحصيل', 'Record collection')),
                    ),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.step, required this.last, this.onVoid});
  final Map<String, dynamic> step;
  final bool last;
  final VoidCallback? onVoid;

  @override
  Widget build(BuildContext context) {
    final s = step;
    final ink = inkColor(context);
    final kind = s['kind'] as String?;
    final at = DateTime.tryParse('${s['at']}')?.toLocal();
    final time = at == null ? '' : DateFormat(context.isAr ? 'd/M  h:mm a' : 'd/M  h:mm a', context.isAr ? 'ar' : 'en').format(at);
    String method(Object? m) => switch (m) {
          'card' => _t(context, 'فيزا', 'card'),
          'wallet' => _t(context, 'محفظة', 'wallet'),
          'bank' => _t(context, 'إيداع بنك', 'bank deposit'),
          'other' => _t(context, 'طريقة تانية', 'other'),
          _ => _t(context, 'كاش', 'cash'),
        };
    final (IconData icon, Color color, String title, String sub) = switch (kind) {
      'open' => (Icons.play_circle_rounded, const Color(0xFF2F6BFF), _t(context, 'فتح وردية', 'Shift opened'), '${s['who']} · ${_t(context, 'العهدة', 'float')} ${_m(context, s['amount_minor'])}'),
      'close' => (
          Icons.stop_circle_rounded,
          const Color(0xFF0E9384),
          '${_t(context, 'قفل وردية', 'Shift closed')}${s['report_no'] != null ? ' · ${s['report_no']}' : ''}',
          '${s['who']} · ${_i(s['sales_count'])} ${_t(context, 'فاتورة', 'invoices')} · ${_t(context, 'اتعدّ', 'counted')} ${_m(context, s['counted_minor'])} · ${_t(context, 'الفرق', 'diff.')} ${_m(context, s['variance_minor'])}'
        ),
      'refund' => (Icons.undo_rounded, BrandColors.warning, '${_t(context, 'مرتجع', 'Refund')} ${_m(context, s['amount_minor'])} (${method(s['method'])})', '${s['who'] ?? ''}${(s['reason'] ?? '').toString().isEmpty ? '' : ' · ${s['reason']}'}'),
      'expense' => (Icons.receipt_rounded, const Color(0xFFDC6803), '${_t(context, 'مصروف', 'Expense')} ${_m(context, s['amount_minor'])}', '${s['who'] ?? ''}${(s['reason'] ?? '').toString().isEmpty ? '' : ' · ${s['reason']}'}'),
      'correction' => (Icons.build_circle_outlined, const Color(0xFF7A5AF8), '${_t(context, 'تصحيح', 'Correction')} ${_m(context, s['amount_minor'])}', '${s['who'] ?? ''} · ${s['reason'] ?? ''}'),
      'collect' => (Icons.payments_rounded, BrandColors.success, '${_t(context, 'تحصيل', 'Collected')} ${_m(context, s['amount_minor'])} (${method(s['method'])})', '${s['who'] ?? ''}${(s['note'] ?? '').toString().isEmpty ? '' : ' · ${s['note']}'}'),
      'collect_void' => (Icons.cancel_rounded, BrandColors.error, '${_t(context, 'تحصيل اتلغى', 'Voided collection')} ${_m(context, s['amount_minor'])}', '${s['who'] ?? ''} · ${_t(context, 'السبب', 'reason')}: ${s['void_reason'] ?? ''}'),
      'lock' => (Icons.lock_rounded, const Color(0xFF7A5AF8), _t(context, 'اليوم اتقفل', 'Day locked'), '${s['who'] ?? ''}'),
      _ => (Icons.circle, BrandColors.gray, '$kind', ''),
    };
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 34,
          child: Column(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle, border: Border.all(color: color)),
              child: Icon(icon, size: 17, color: color),
            ),
            if (!last) Expanded(child: Container(width: 2, color: panelLine(context))),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14, top: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w800, decoration: kind == 'collect_void' ? TextDecoration.lineThrough : null)),
                  if (sub.trim().isNotEmpty) Text(sub, style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.65))),
                  Text(time, style: TextStyle(fontSize: 11.5, color: ink.withValues(alpha: 0.5))),
                ]),
              ),
              if (onVoid != null) TextButton(onPressed: onVoid, child: Text(_t(context, 'إلغاء', 'Void'))),
            ]),
          ),
        ),
      ]),
    );
  }
}
