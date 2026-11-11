import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../shared/motion.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'pos_repository.dart' show posErrorText, commissionTodayProvider;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));

Map<String, dynamic> _m(Object? o) => Map<String, dynamic>.from(o as Map);
List<Map<String, dynamic>> _l(Object? o) => [for (final e in (o as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

class TargetsRepository {
  TargetsRepository(this._db);
  final SupabaseClient _db;

  Future<Map<String, dynamic>> overview(DateTime? month) async =>
      _m(await _db.rpc('targets_overview', params: {'p_month': month == null ? null : DateFormat('yyyy-MM-01').format(month)}));
  Future<Map<String, dynamic>> mine() async => _m(await _db.rpc('my_target_status'));
  Future<void> setBranch(String id, int minor) => _db.rpc('targets_set_branch', params: {'p_branch': id, 'p_monthly_minor': minor});
  /// Daily target bonus in tiers: [minor] at 100% of the daily target, [b120] at 120%, [b150] at 150% (0 = tier not used).
  Future<void> setDailyBonus(String id, int minor, {int? b120, int? b150}) =>
      _db.rpc('targets_set_daily_bonus', params: {'p_user': id, 'p_bonus_minor': minor, 'p_bonus_120': b120, 'p_bonus_150': b150});
  Future<void> setUser(String id, int minor) => _db.rpc('targets_set_user', params: {'p_user': id, 'p_monthly_minor': minor});
  Future<List<Map<String, dynamic>>> commissions(String? q) async => _l(await _db.rpc('commission_list', params: {'p_search': q, 'p_limit': 100}));
  Future<void> setCommission(String productId, int minor) => _db.rpc('commission_set', params: {'p_product': productId, 'p_amount_minor': minor});
}

final targetsRepoProvider = Provider((ref) => TargetsRepository(ref.watch(supabaseProvider)));
final _monthProvider = StateProvider.autoDispose<DateTime>((ref) => DateTime(DateTime.now().year, DateTime.now().month));
final _overviewProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(targetsRepoProvider).overview(ref.watch(_monthProvider)));

Color _tone(num pct) => pct >= 100 ? BrandColors.success : (pct >= 70 ? BrandColors.warning : BrandColors.error);

Future<int?> _askMoney(BuildContext context, String title, String hint, {int? current}) {
  final c = TextEditingController(text: current == null || current == 0 ? '' : (current / 100).toStringAsFixed(current % 100 == 0 ? 0 : 2));
  return showSmoothDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: hint, suffixText: _t(ctx, 'ج.م', 'EGP')),
        onSubmitted: (_) => Navigator.pop(ctx, parseEgpToMinor(c.text) ?? 0),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t(ctx, 'رجوع', 'Back'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, parseEgpToMinor(c.text) ?? 0), child: Text(_t(ctx, 'حفظ', 'Save'))),
      ],
    ),
  );
}

// =====================================================================================
// Branch targets: who hit this month's target and who did not
// =====================================================================================
class TargetsPanel extends ConsumerStatefulWidget {
  const TargetsPanel({super.key});
  @override
  ConsumerState<TargetsPanel> createState() => _TargetsPanelState();
}

class _TargetsPanelState extends ConsumerState<TargetsPanel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) ref.invalidate(_overviewProvider);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
      ref.invalidate(_overviewProvider);
      if (mounted) showSnack(context, _t(context, 'اتحفظ ✅', 'Saved ✅'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(_monthProvider);
    final data = ref.watch(_overviewProvider);
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>{};
    final canCommission = perms.contains('commission.set');
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(_overviewProvider),
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Row(children: [
          IconButton(
            tooltip: _t(context, 'الشهر اللي فات', 'Previous month'),
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: () => ref.read(_monthProvider.notifier).state = DateTime(month.year, month.month - 1),
          ),
          Expanded(
            child: Text(DateFormat('MMMM yyyy', context.isAr ? 'ar' : 'en').format(month),
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ),
          IconButton(
            tooltip: _t(context, 'الشهر الجاي', 'Next month'),
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: month.isBefore(DateTime(DateTime.now().year, DateTime.now().month))
                ? () => ref.read(_monthProvider.notifier).state = DateTime(month.year, month.month + 1)
                : null,
          ),
        ]),
        data.when(
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Padding(padding: const EdgeInsets.all(20), child: Text(_err(context, e))),
          data: (d) {
            final branches = _l(d['branches']);
            final employees = _l(d['employees']);
            final canManage = d['can_manage'] == true;
            final hit = branches.where((b) => b['hit'] == true).length;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                color: (hit == branches.length && branches.isNotEmpty ? BrandColors.success : BrandColors.electric).withValues(alpha: 0.10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Icon(hit == branches.length && branches.isNotEmpty ? Icons.emoji_events_rounded : Icons.flag_rounded, size: 30, color: BrandColors.electric),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        branches.isEmpty
                            ? _t(context, 'مفيش فروع تتعرض', 'No branches to show')
                            : _t(context, '$hit من ${branches.length} فروع حققوا التارجت', '$hit of ${branches.length} branches hit the target'),
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              if (branches.isNotEmpty) Card(child: Padding(padding: const EdgeInsets.fromLTRB(8, 16, 8, 8), child: _BranchChart(branches: branches))),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                child: Text(_t(context, 'الفروع', 'Branches'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              for (final b in branches)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon((b['hit'] == true) ? Icons.check_circle_rounded : Icons.timelapse_rounded, color: _tone((b['pct'] as num?) ?? 0)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_t(context, '${b['name_ar']}', '${b['name_en']}'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                        Text('${b['pct']}%', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: _tone((b['pct'] as num?) ?? 0))),
                        if (canManage)
                          IconButton(
                            tooltip: _t(context, 'غيّر التارجت', 'Change target'),
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () async {
                              final v = await _askMoney(context, _t(context, 'تارجت ${b['name_ar']} الشهري', 'Monthly target'), _t(context, 'المبلغ', 'Amount'), current: (b['target_minor'] as num).toInt());
                              if (v != null) _run(() => ref.read(targetsRepoProvider).setBranch(b['branch_id'] as String, v));
                            },
                          ),
                      ]),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          minHeight: 10,
                          value: math.min(1, ((b['pct'] as num?) ?? 0) / 100),
                          color: _tone((b['pct'] as num?) ?? 0),
                          backgroundColor: BrandColors.border,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('${_t(context, 'المبيعات الصافية', 'Net sales')}: ${_money(context, b['net_minor'] as num)}   ·   ${_t(context, 'التارجت', 'Target')}: ${_money(context, b['target_minor'] as num)}',
                          style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
                    ]),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                child: Row(children: [
                  Expanded(child: Text(_t(context, 'الموظفين', 'Employees'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                  if (canCommission)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.payments_outlined, size: 18),
                      label: Text(_t(context, 'عمولات المنتجات', 'Product commissions')),
                      onPressed: () => showSmoothDialog<void>(context: context, builder: (_) => const _CommissionsDialog()),
                    ),
                ]),
              ),
              if (employees.isEmpty)
                Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_t(context, 'مفيش مبيعات للموظفين في الشهر ده', 'No employee sales this month'), style: const TextStyle(color: BrandColors.gray)))),
              for (final e in employees)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${e['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                        if (e['pct'] != null) Text('${e['pct']}%', style: TextStyle(fontWeight: FontWeight.w900, color: _tone(e['pct'] as num))),
                        if (canManage)
                          IconButton(
                            tooltip: _t(context, 'حدد تارجت للموظف', 'Set a target for him'),
                            icon: const Icon(Icons.flag_outlined, size: 20),
                            onPressed: () async {
                              final v = await _askMoney(context, _t(context, 'تارجت ${e['name']} الشهري', 'Monthly target'), _t(context, 'المبلغ (فاضي = من غير تارجت)', 'Amount (empty = none)'),
                                  current: (e['target_minor'] as num?)?.toInt());
                              if (v != null) _run(() => ref.read(targetsRepoProvider).setUser(e['user_id'] as String, v));
                            },
                          ),
                        if (canManage)
                          IconButton(
                            tooltip: _t(context, 'مكافأة التارجت اليومي', 'Daily target bonus'),
                            icon: const Icon(Icons.card_giftcard_rounded, size: 20),
                            onPressed: () async {
                              if (e['target_minor'] == null) {
                                showSnack(context, _t(context, 'حدد التارجت الشهري للموظف الأول (علامة الفلاج)', 'Set his monthly target first (flag icon)'), error: true);
                                return;
                              }
                              final v = await showSmoothDialog<List<int>>(
                                  context: context,
                                  builder: (_) => _TierBonusDialog(
                                        name: '${e['name']}',
                                        current: [for (final k in const ['daily_bonus_minor', 'bonus_120_minor', 'bonus_150_minor']) ((e[k] as num?) ?? 0).toInt()],
                                      ));
                              if (v != null) _run(() => ref.read(targetsRepoProvider).setDailyBonus(e['user_id'] as String, v[0], b120: v[1], b150: v[2]));
                            },
                          ),
                      ]),
                      if (e['pct'] != null) ...[
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(minHeight: 8, value: math.min(1, (e['pct'] as num) / 100), color: _tone(e['pct'] as num), backgroundColor: BrandColors.border),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Wrap(spacing: 16, runSpacing: 4, children: [
                        Text('${_t(context, 'مبيعات', 'Sales')}: ${_money(context, e['net_minor'] as num)}', style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
                        if (e['target_minor'] != null) Text('${_t(context, 'التارجت', 'Target')}: ${_money(context, e['target_minor'] as num)}', style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
                        if (_tiersText(context, e) != null)
                          Text('${_t(context, 'مكافأة اليوم', 'Daily bonus')}: ${_tiersText(context, e)}', style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
                        if (e['commission_minor'] != null)
                          Text('${_t(context, 'العمولة', 'Commission')}: ${_money(context, e['commission_minor'] as num)}',
                              style: const TextStyle(color: BrandColors.success, fontSize: 13, fontWeight: FontWeight.w800)),
                      ]),
                    ]),
                  ),
                ),
              const SizedBox(height: 30),
            ]);
          },
        ),
      ]),
    );
  }
}

/// Bars per branch with a line at 100% of the target; green = hit, amber = close, red = far.
class _BranchChart extends StatelessWidget {
  const _BranchChart({required this.branches});
  final List<Map<String, dynamic>> branches;

  @override
  Widget build(BuildContext context) {
    final maxPct = math.max<double>(110, branches.fold<double>(0, (a, b) => math.max(a, ((b['pct'] as num?) ?? 0).toDouble()))) * 1.08;
    const h = 190.0;
    return SizedBox(
      height: h + 56,
      child: Stack(children: [
        // the 100% line
        Positioned(
          left: 0,
          right: 0,
          bottom: 40 + h * (100 / maxPct),
          child: Row(children: [
            Expanded(child: Container(height: 1.5, color: BrandColors.gray.withValues(alpha: 0.55))),
            const SizedBox(width: 6),
            Text(_t(context, 'التارجت ١٠٠٪', 'Target 100%'), style: const TextStyle(fontSize: 11, color: BrandColors.gray, fontWeight: FontWeight.w700)),
          ]),
        ),
        Positioned.fill(
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final b in branches)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text('${b['pct']}%', style: TextStyle(fontWeight: FontWeight.w900, color: _tone((b['pct'] as num?) ?? 0))),
                    const SizedBox(height: 3),
                    Container(
                      height: math.max(4, h * (((b['pct'] as num?) ?? 0) / maxPct)),
                      decoration: BoxDecoration(
                        color: _tone((b['pct'] as num?) ?? 0),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(height: 34, child: Text(_t(context, '${b['name_ar']}', '${b['name_en']}'), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  ]),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

// =====================================================================================
// Product commissions (who may: "commission.set")
// =====================================================================================
class _CommissionsDialog extends ConsumerStatefulWidget {
  const _CommissionsDialog();
  @override
  ConsumerState<_CommissionsDialog> createState() => _CommissionsDialogState();
}

class _CommissionsDialogState extends ConsumerState<_CommissionsDialog> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await ref.read(targetsRepoProvider).commissions(_q.text.trim().isEmpty ? null : _q.text.trim());
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit(Map<String, dynamic> r) async {
    final v = await _askMoney(context, '${r['name_ar']}', _t(context, 'عمولة البيع للقطعة (فاضي = من غير)', 'Commission per unit (empty = none)'), current: (r['commission_minor'] as num?)?.toInt());
    if (v == null) return;
    try {
      await ref.read(targetsRepoProvider).setCommission(r['product_id'] as String, v);
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t(context, 'عمولات المنتجات', 'Product commissions')),
        content: SizedBox(
          width: 520,
          height: 460,
          child: Column(children: [
            Text(_t(context, 'المبلغ ده بيتحسب للبياع على كل قطعة بتتباع. تغييره بعد كده مبيغيّرش الفواتير القديمة.', 'This amount is earned by the seller on each unit sold. Changing it later does not touch old invoices.'),
                style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
            const SizedBox(height: 8),
            TextField(
              controller: _q,
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: _t(context, 'ابحث باسم المنتج أو الكود', 'Search by name or SKU')),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(children: [
                      for (final r in _rows)
                        ListTile(
                          dense: true,
                          title: Text('${r['name_ar']}'),
                          subtitle: Text('${r['sku'] ?? ''}  ·  ${_money(context, r['price_minor'] as num)}'),
                          trailing: Text(
                            r['commission_minor'] == null ? _t(context, 'من غير', 'None') : _money(context, r['commission_minor'] as num),
                            style: TextStyle(fontWeight: FontWeight.w800, color: r['commission_minor'] == null ? BrandColors.gray : BrandColors.success),
                          ),
                          onTap: () => _edit(r),
                        ),
                    ]),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'Done')))],
      );
}

// =====================================================================================
// The seller's own page: progress to his target and his commission, live
// =====================================================================================
final _mineProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(targetsRepoProvider).mine());

class MyTargetPanel extends ConsumerStatefulWidget {
  const MyTargetPanel({super.key});
  @override
  ConsumerState<MyTargetPanel> createState() => _MyTargetPanelState();
}

class _MyTargetPanelState extends ConsumerState<MyTargetPanel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // live: re-read every few seconds, so a new sale shows up in his commission right away
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) ref.invalidate(_mineProvider);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_mineProvider);
    final d = async.valueOrNull;
    if (d == null) {
      return async.hasError ? Center(child: Text(_err(context, async.error!))) : const Center(child: CircularProgressIndicator());
    }
    final pct = (d['pct'] as num?)?.toDouble();
    final target = (d['target_minor'] as num?)?.toInt();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Text(_t(context, 'تارجت الشهر', 'This month\'s target'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            if (pct == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(_t(context, 'لسه مفيش تارجت متحدد ليك. اسأل المالك.', 'No target set for you yet. Ask the owner.'), style: const TextStyle(color: BrandColors.gray)),
              )
            else
              SizedBox(
                width: 190,
                height: 190,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox.expand(child: CircularProgressIndicator(value: math.min(1, pct / 100), strokeWidth: 16, color: _tone(pct), backgroundColor: BrandColors.border)),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${pct.toStringAsFixed(pct == pct.roundToDouble() ? 0 : 1)}%', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: _tone(pct))),
                    Text(pct >= 100 ? _t(context, 'حققت التارجت 🎉', 'Target reached 🎉') : _t(context, 'من التارجت', 'of the target'), style: const TextStyle(color: BrandColors.gray)),
                  ]),
                ]),
              ),
            const SizedBox(height: 14),
            Text('${_t(context, 'مبيعاتك الصافية', 'Your net sales')}: ${_money(context, d['net_minor'] as num)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (target != null) Text('${_t(context, 'التارجت', 'Target')}: ${_money(context, target)}', style: const TextStyle(color: BrandColors.gray)),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _CommissionTile(label: _t(context, 'عمولتك النهارده', 'Your commission today'), minor: d['commission_today_minor'] as num, icon: Icons.bolt_rounded)),
        const SizedBox(width: 10),
        Expanded(child: _CommissionTile(label: _t(context, 'عمولتك الشهر ده', 'Your commission this month'), minor: d['commission_month_minor'] as num, icon: Icons.savings_outlined)),
      ]),
      if (_tiersText(context, d) != null) ...[
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            leading: const Icon(Icons.card_giftcard_rounded, color: BrandColors.success),
            title: Text(_t(context, 'مكافأة التارجت اليومي', 'Daily target bonus'), style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(_t(context, '${_tiersText(context, d)} في اليوم. كل ما تبيع أكتر من التارجت تاخد مرحلة أعلى (متضافة للعمولة).', '${_tiersText(context, d)} per day. Sell past the target to reach a higher tier (included in commission).')),
            trailing: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('${_t(context, 'النهارده', 'Today')} ${_money(context, (d['bonus_today_minor'] as num?) ?? 0)}', style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.success)),
              Text('${_t(context, 'الشهر', 'Month')} ${_money(context, (d['bonus_month_minor'] as num?) ?? 0)} · ${(d['bonus_days'] as num?) ?? 0} ${_t(context, 'يوم', 'days')}', style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            ]),
          ),
        ),
      ],
      if (ref.watch(staffContextProvider).valueOrNull?.permissions.contains('commission.today') ?? false) ...[
        const SizedBox(height: 10),
        const _TodayCommissionProducts(),
      ],
      const SizedBox(height: 10),
      Text(_t(context, 'الأرقام بتتحدّث لوحدها كل لحظة. أي مرتجع بيتخصم من العمولة.', 'Numbers refresh on their own. A refund reduces the commission.'),
          textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
    ]);
  }
}

class _TodayCommissionProducts extends ConsumerWidget {
  const _TodayCommissionProducts();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(commissionTodayProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.local_fire_department_rounded, color: Color(0xFFE8A317)),
            const SizedBox(width: 6),
            Expanded(child: Text(_t(context, 'منتجات عليها كوميشن النهارده', 'Products with a commission today'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          ]),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_t(context, 'مفيش منتجات عليها كوميشن النهارده', 'No product has a commission today'), style: const TextStyle(color: BrandColors.gray)))
          else
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${context.isAr ? r['name_ar'] : (r['name_en'] ?? r['name_ar'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${r['sku'] ?? ''}${r['ends_on'] == null ? '' : '  ·  ${_t(context, 'لحد', 'until')} ${r['ends_on']}'}', style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: BrandColors.success.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)),
                    child: Text('+${_money(context, r['amount_minor'] as num)}', style: const TextStyle(color: BrandColors.success, fontWeight: FontWeight.w900)),
                  ),
                ]),
              ),
        ]),
      ),
    );
  }
}

class _CommissionTile extends StatelessWidget {
  const _CommissionTile({required this.label, required this.minor, required this.icon});
  final String label;
  final num minor;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(icon, size: 20, color: BrandColors.success), const SizedBox(width: 6), Expanded(child: Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 13)))]),
            const SizedBox(height: 8),
            Text(_money(context, minor), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: BrandColors.success)),
          ]),
        ),
      );
}


/// "100%: 10 · 120%: 25 · 150%: 50" for the tiers that are set, or null when none is.
String? _tiersText(BuildContext context, Map d) {
  final parts = <String>[
    for (final (k, p) in const [('daily_bonus_minor', 100), ('bonus_120_minor', 120), ('bonus_150_minor', 150)])
      if (((d[k] as num?) ?? 0) > 0) '$p%: ${_money(context, d[k] as num)}',
  ];
  return parts.isEmpty ? null : parts.join('  ·  ');
}

/// The owner sets the daily bonus tiers of one employee: at 100%, 120% and 150% of his daily target.
class _TierBonusDialog extends StatefulWidget {
  const _TierBonusDialog({required this.name, required this.current});
  final String name;
  final List<int> current;
  @override
  State<_TierBonusDialog> createState() => _TierBonusDialogState();
}

class _TierBonusDialogState extends State<_TierBonusDialog> {
  late final _c = [
    for (final v in widget.current) TextEditingController(text: v == 0 ? '' : (v / 100).toStringAsFixed(v % 100 == 0 ? 0 : 2)),
  ];
  String? _err;

  @override
  void dispose() {
    for (final c in _c) {
      c.dispose();
    }
    super.dispose();
  }

  int? _v(TextEditingController c) => c.text.trim().isEmpty ? 0 : parseEgpToMinor(c.text);

  void _save() {
    final v = [for (final c in _c) _v(c)];
    if (v.any((x) => x == null || x < 0)) {
      setState(() => _err = _t(context, 'مبلغ مش مظبوط', 'Invalid amount'));
      return;
    }
    final a = v[0]!, b = v[1]!, c = v[2]!;
    if ((b > 0 && b < a) || (c > 0 && c < (b > a ? b : a))) {
      setState(() => _err = _t(context, 'المرحلة الأعلى لازم مكافأتها أكبر من اللي قبلها', 'A higher tier must pay more than the one before'));
      return;
    }
    Navigator.pop(context, [a, b, c]);
  }

  @override
  Widget build(BuildContext context) {
    Widget field(int i, String label, String hint) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: _c[i],
            autofocus: i == 0,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() => _err = null),
            decoration: InputDecoration(labelText: label, helperText: hint, suffixText: _t(context, 'ج.م', 'EGP')),
          ),
        );
    return AlertDialog(
      title: Text(_t(context, 'مكافأة ${widget.name} على مراحل', 'Bonus tiers for ${widget.name}')),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_t(context, 'في اليوم بيتحسب أعلى مرحلة وصلها بس (مش مجموعهم). سيب الخانة فاضية لو مش عايز المرحلة دي.',
                  'Each day pays only the highest tier reached (not the sum). Leave a box empty to skip that tier.'),
              style: const TextStyle(color: BrandColors.gray, fontSize: 12.5, height: 1.5)),
          const SizedBox(height: 12),
          field(0, _t(context, 'لما يحقق 100% من تارجت اليوم', 'At 100% of the daily target'), _t(context, 'المكافأة الأساسية', 'The base bonus')),
          field(1, _t(context, 'لما يوصل 120%', 'At 120%'), _t(context, 'أكبر من الأساسية', 'More than the base')),
          field(2, _t(context, 'لما يوصل 150%', 'At 150%'), _t(context, 'أكبر مكافأة', 'The top bonus')),
          if (_err != null) Text(_err!, style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w700)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
        FilledButton(onPressed: _save, child: Text(_t(context, 'حفظ', 'Save'))),
      ],
    );
  }
}
