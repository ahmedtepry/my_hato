import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/save_file.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'pos_repository.dart';
import 'shift_reports.dart';
import 'books_export.dart';
import 'books_period.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));
String _when(String? iso) => iso == null ? '—' : DateFormat('d/M  HH:mm').format(DateTime.parse(iso).toLocal());

final _approvalsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) => ref.watch(posRepoProvider).pendingApprovals());
final _shiftsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) => ref.watch(posRepoProvider).shifts());
final _branchReportProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, int>((ref, days) => ref.watch(posRepoProvider).branchReport(days));

/// Shifts and approvals: another person approves big discounts and refunds, the cash difference of every shift is
/// visible, branches are compared side by side, and the owner sets the limits and checks the log has not been tampered with.
class ShiftsPanel extends ConsumerStatefulWidget {
  const ShiftsPanel({super.key});
  @override
  ConsumerState<ShiftsPanel> createState() => _ShiftsPanelState();
}

class _ShiftsPanelState extends ConsumerState<ShiftsPanel> {
  Timer? _timer;
  int _days = 7;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    // new approval requests show up on their own
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted && (ref.read(staffContextProvider).valueOrNull?.permissions.contains('pos.approve') ?? false)) ref.invalidate(_approvalsProvider);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _decide(Map<String, dynamic> a, bool approve) async {
    String? note;
    if (!approve) {
      note = await showDialog<String>(context: context, builder: (_) => const _NoteDialog());
      if (note == null || !mounted) return;
    }
    setState(() => _busy.add('${a['id']}'));
    try {
      await ref.read(posRepoProvider).decideApproval('${a['id']}', approve, note);
      ref.invalidate(_approvalsProvider);
      if (mounted) showSnack(context, approve ? _t(context, 'تمت الموافقة ✅', 'Approved ✅') : _t(context, 'اترفض', 'Rejected'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove('${a['id']}'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = ref.watch(staffContextProvider).valueOrNull;
    final perms = ctx?.permissions ?? const <String>{};
    final isOwner = ctx?.roles.contains('owner') ?? false;
    final canApprove = perms.contains('pos.approve');
    final canReview = perms.contains('shifts.review');
    final canReport = perms.contains('sales.view') || canReview;

    Widget title(String ar, String en, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Row(children: [Text(_t(context, ar, en), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)), const Spacer(), if (trailing != null) trailing]),
        );

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_approvalsProvider);
        ref.invalidate(_shiftsProvider);
        ref.invalidate(_branchReportProvider);
        ref.invalidate(shiftReportsProvider);
      },
      child: ListView(padding: const EdgeInsets.all(14), children: [
        if (canApprove) ...[
          title('طلبات موافقة مستنية', 'Approvals waiting'),
          ref.watch(_approvalsProvider).when(
                loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
                error: (e, _) => Text(_err(context, e)),
                data: (list) => list.isEmpty
                    ? Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_t(context, 'مفيش طلبات مستنية ✅', 'Nothing waiting ✅'), style: const TextStyle(color: BrandColors.gray))))
                    : Column(children: [
                        for (final a in list)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Icon(a['kind'] == 'discount' ? Icons.percent_rounded : Icons.assignment_return_outlined, color: BrandColors.warning),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${a['kind'] == 'discount' ? _t(context, 'خصم', 'Discount') : _t(context, 'مرتجع', 'Refund')}  ${_money(context, a['amount_minor'] as num)}',
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                                  ),
                                  const Spacer(),
                                  Text(_when(a['created_at'] as String?), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                                ]),
                                const SizedBox(height: 4),
                                Text('${_t(context, 'من', 'From')}: ${a['requester_name']}', style: const TextStyle(color: BrandColors.gray)),
                                Text('${_t(context, 'السبب', 'Reason')}: ${a['reason']}'),
                                const SizedBox(height: 8),
                                Row(children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      icon: const Icon(Icons.check_rounded),
                                      label: Text(_t(context, 'موافقة', 'Approve')),
                                      onPressed: _busy.contains('${a['id']}') ? null : () => _decide(a, true),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(foregroundColor: BrandColors.error),
                                      icon: const Icon(Icons.close_rounded),
                                      label: Text(_t(context, 'رفض', 'Reject')),
                                      onPressed: _busy.contains('${a['id']}') ? null : () => _decide(a, false),
                                    ),
                                  ),
                                ]),
                              ]),
                            ),
                          ),
                      ]),
              ),
        ],
        if (canReview || perms.contains('pos.shift')) ...[
        title('الورديات', 'Shifts', trailing: IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: () => ref.invalidate(_shiftsProvider))),
        ref.watch(_shiftsProvider).when(
              loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => Text(_err(context, e)),
              data: (list) => list.isEmpty
                  ? Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_t(context, 'مفيش ورديات في آخر ٧ أيام', 'No shifts in the last 7 days'), style: const TextStyle(color: BrandColors.gray))))
                  : Column(children: [for (final s in list) _ShiftTile(s: s)]),
            ),
        ],
        if (perms.contains('shifts.reports')) ...[
          title('تقارير إقفال الورديات', 'Shift closing reports'),
          ShiftReportsList(days: _days),
        ],
        if (canReport) ...[
          title('مقارنة الفروع', 'Branches side by side',
              trailing: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 1, label: Text(_t(context, 'النهارده', 'Today'))),
                  ButtonSegment(value: 7, label: Text(_t(context, '٧ أيام', '7d'))),
                  ButtonSegment(value: 30, label: Text(_t(context, '٣٠ يوم', '30d'))),
                ],
                selected: {_days},
                onSelectionChanged: (v) => setState(() => _days = v.first),
              )),
          ref.watch(_branchReportProvider(_days)).when(
                loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
                error: (e, _) => Text(_err(context, e)),
                data: (list) => Column(children: [
                  for (final b in list)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${b['branch_name_ar']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                          const SizedBox(height: 6),
                          Wrap(spacing: 18, runSpacing: 6, children: [
                            _stat(context, _t(context, 'صافي المبيعات', 'Net sales'), _money(context, b['net_minor'] as num), BrandColors.navy),
                            _stat(context, _t(context, 'المبيعات', 'Sales'), '${_money(context, b['sales_minor'] as num)} (${b['sales_count']})', null),
                            if (b['card_minor'] != null) ...[
                              _stat(context, _t(context, 'كاش', 'Cash'), _money(context, b['cash_minor'] as num), null),
                              _stat(context, _t(context, 'فيزا', 'Visa'), '${_money(context, b['card_minor'] as num)} (${b['card_count']})', null),
                              _stat(context, _t(context, 'محافظ إلكترونية', 'E-wallets'), _money(context, (b['wallet_minor'] as num?) ?? 0), null),
                            ],
                            _stat(context, _t(context, 'المرتجعات', 'Refunds'), _money(context, b['refunds_minor'] as num), null),
                            _stat(context, _t(context, 'ورديات مقفولة', 'Closed shifts'), '${b['shifts_closed']}', null),
                            _stat(context, _t(context, 'فرق الدرج', 'Drawer difference'), _money(context, b['variance_minor'] as num),
                                (b['variance_minor'] as num) == 0 ? BrandColors.success : BrandColors.error),
                          ]),
                        ]),
                      ),
                    ),
                ]),
              ),
        ],
        if (isOwner) ...[
          title('الحدود والحماية', 'Limits and protection'),
          const _OwnerTools(),
        ],
        const SizedBox(height: 30),
      ]),
    );
  }

  Widget _stat(BuildContext c, String l, String v, Color? color) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
        Text(v, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: color)),
      ]);
}

class _ShiftTile extends StatelessWidget {
  const _ShiftTile({required this.s});
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final open = s['status'] == 'open';
    final v = s['variance_minor'] as num?;
    return Card(
      child: ListTile(
        leading: Icon(open ? Icons.lock_open_rounded : Icons.lock_outline_rounded, color: open ? BrandColors.success : BrandColors.gray),
        title: Text('${s['cashier_name']} · ${s['branch_name_ar']}', style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${_when(s['opened_at'] as String?)}${open ? '' : ' → ${_when(s['closed_at'] as String?)}'}\n'
          '${_t(context, 'مبيعات', 'Sales')} ${_money(context, s['sales_minor'] as num)} (${s['sales_count']})'
          '${(s['refunds_minor'] as num) > 0 ? ' · ${_t(context, 'مرتجع', 'refunds')} ${_money(context, s['refunds_minor'] as num)}' : ''}'
          '${(s['note'] as String?) == null ? '' : '\n${s['note']}'}',
        ),
        isThreeLine: true,
        trailing: open
            ? Chip(label: Text(_t(context, 'مفتوحة', 'Open')))
            : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(v == null || v == 0 ? _t(context, 'مظبوطة ✅', 'Matches ✅') : '${v < 0 ? _t(context, 'عجز', 'Short') : _t(context, 'زيادة', 'Over')} ${_money(context, v.abs())}',
                    style: TextStyle(fontWeight: FontWeight.w800, color: v == null || v == 0 ? BrandColors.success : BrandColors.error)),
                Text('${_t(context, 'متوقع', 'Expected')} ${_money(context, s['expected_minor'] as num)}', style: const TextStyle(fontSize: 11, color: BrandColors.gray)),
              ]),
      ),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog();
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t(context, 'سبب الرفض', 'Reason for rejecting')),
        content: TextField(controller: _c, autofocus: true, maxLength: 200, decoration: InputDecoration(hintText: _t(context, 'اختياري', 'Optional'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'رجوع', 'Back'))),
          FilledButton(onPressed: () => Navigator.pop(context, _c.text.trim()), child: Text(_t(context, 'رفض', 'Reject'))),
        ],
      );
}

// ---------------------------------------------------------------- owner: limits, log check, backup check
class _OwnerTools extends ConsumerStatefulWidget {
  const _OwnerTools();
  @override
  ConsumerState<_OwnerTools> createState() => _OwnerToolsState();
}

class _OwnerToolsState extends ConsumerState<_OwnerTools> {
  final _pct = TextEditingController();
  final _refund = TextEditingController();
  final _free = TextEditingController();
  bool _neg = false;
  bool _loaded = false;
  bool _busy = false;
  Map<String, dynamic>? _verify;
  Map<String, dynamic>? _snap;

  @override
  void dispose() {
    _pct.dispose();
    _refund.dispose();
    _free.dispose();
    super.dispose();
  }

  Future<void> _saveLimits() async {
    final pct = num.tryParse(_pct.text.trim());
    final refund = parseEgpToMinor(_refund.text);
    final free = parseEgpToMinor(_free.text);
    if (pct == null || pct < 0 || pct > 100 || refund == null || free == null) {
      showSnack(context, _t(context, 'اكتب نسبة من ٠ لـ ١٠٠ ومبلغ صحيح', 'Type a % from 0 to 100 and a valid amount'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(posRepoProvider).setLimits(discountPct: pct, refundMinor: refund, allowNegative: _neg, freeMinor: free);
      ref.invalidate(posLimitsProvider);
      if (mounted) showSnack(context, _t(context, 'اتحفظت الحدود ✅', 'Limits saved ✅'));
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runVerify() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(posRepoProvider).auditVerify();
      if (mounted) setState(() => _verify = r);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportLog() async {
    setState(() => _busy = true);
    try {
      final csv = await ref.read(posRepoProvider).auditExport(30);
      final bytes = utf8.encode('\uFEFF$csv'); // BOM so Excel reads Arabic correctly
      await deliverFile(context, Uint8List.fromList(bytes), 'activity-log.csv', 'text/csv');
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runSnapshot() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(posRepoProvider).snapshot();
      if (mounted) setState(() => _snap = r);
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _snapText() {
    final s = _snap!;
    final c = Map<String, dynamic>.from(s['counts'] as Map);
    return [
      'My Hatō data snapshot — ${s['taken_at']}',
      for (final e in c.entries) '${e.key}: ${e.value}',
      'stock units: ${s['stock_units']}',
      'audit head: ${s['audit_head']}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final limits = ref.watch(posLimitsProvider);
    if (!_loaded && limits.hasValue) {
      final l = limits.value!;
      _pct.text = '${l['discount_approval_pct']}';
      final fm = ((l['discount_free_minor'] as num?) ?? 1000).toInt();
      _free.text = (fm / 100).toStringAsFixed(fm % 100 == 0 ? 0 : 2);
      final rm = ((l['refund_approval_minor'] as num).toInt());
      _refund.text = (rm / 100).toStringAsFixed(rm % 100 == 0 ? 0 : 2);
      _neg = l['allow_negative_stock'] == true;
      _loaded = true;
    }
    final v = _verify;
    return Column(children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_t(context, 'حدود الموافقة', 'Approval limits'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(_t(context, 'فوق الحدود دي لازم شخص تاني يوافق (المالك مش محتاج).', 'Above these limits another person must approve (the owner does not need it).'), style: const TextStyle(color: BrandColors.gray)),
            const SizedBox(height: 10),
            TextField(controller: _pct, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: _t(context, 'خصم أكبر من (٪ من الفاتورة)', 'Discount above (% of the invoice)'))),
            const SizedBox(height: 10),
            TextField(controller: _free, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: _t(context, 'خصم صغير من غير موافقة لحد (ج.م)', 'Small discount without approval up to (EGP)'))),
            const SizedBox(height: 10),
            TextField(controller: _refund, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: _t(context, 'مرتجع أكبر من (ج.م)', 'Refund above (EGP)'))),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: _neg, onChanged: (x) => setState(() => _neg = x), title: Text(_t(context, 'السماح بالبيع من غير مخزون', 'Allow selling without stock'))),
            FilledButton(onPressed: _busy ? null : _saveLimits, child: Text(_t(context, 'حفظ الحدود', 'Save limits'))),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_t(context, 'سلامة سجل النشاط', 'Activity log integrity'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(_t(context, 'كل عملية في السجل متربطة بالقبلها. أي تعديل أو مسح بيتكشف.', 'Every log entry is chained to the one before it. Any edit or removal is detected.'), style: const TextStyle(color: BrandColors.gray)),
            const SizedBox(height: 10),
            OutlinedButton.icon(icon: const Icon(Icons.verified_user_outlined), label: Text(_t(context, 'افحص السجل', 'Check the log')), onPressed: _busy ? null : _runVerify),
            if (ref.watch(staffContextProvider).valueOrNull?.permissions.contains('audit.export') ?? false) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(icon: const Icon(Icons.download_rounded), label: Text(_t(context, 'نزّل سجل آخر ٣٠ يوم (Excel)', 'Download the last 30 days (CSV)')), onPressed: _busy ? null : _exportLog),
            ],
            if (v != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  v['ok'] == true
                      ? _t(context, '✅ السجل سليم — اتفحص ${v['checked']} سطر. (سجلات قديمة قبل التفعيل: ${v['unchained_old_rows']})', '✅ Log is intact — ${v['checked']} rows checked. (Older rows before this feature: ${v['unchained_old_rows']})')
                      : _t(context, '⚠️ فيه تلاعب! أول سطر متغيّر رقم ${v['first_bad_id']}', '⚠️ Tampering detected! First changed row: ${v['first_bad_id']}'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: v['ok'] == true ? BrandColors.success : BrandColors.error),
                ),
              ),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_t(context, 'النسخ الاحتياطي واختبار الاستعادة', 'Backup and restore test'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(_t(context, 'خد لقطة بالأعداد قبل أي استعادة، وبعد الاستعادة قارنها. لازم تتطابق.', 'Take a snapshot of the counts before a restore, and compare it afterwards. They must match.'), style: const TextStyle(color: BrandColors.gray)),
            const SizedBox(height: 10),
            OutlinedButton.icon(icon: const Icon(Icons.fact_check_outlined), label: Text(_t(context, 'خد لقطة دلوقتي', 'Take a snapshot now')), onPressed: _busy ? null : _runSnapshot),
            if (_snap != null) ...[
              const SizedBox(height: 8),
              SelectableText(_snapText(), style: const TextStyle(height: 1.6)),
              TextButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(_t(context, 'نسخ', 'Copy')),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _snapText()));
                  if (context.mounted) showSnack(context, _t(context, 'اتنسخت', 'Copied'));
                },
              ),
            ],
          ]),
        ),
      ),
    ]);
  }
}

final _acctReportProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, Period>((ref, p) => ref.watch(posRepoProvider).branchReportRange(p.from, p.to));
final _acctShiftsProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, Period>((ref, p) => ref.watch(posRepoProvider).booksShifts(null, p.from, p.to));

/// The accountant's own screen: the money of the period at a glance, branch by branch, and every shift with its cash difference.
/// View only: nothing here sells, refunds or changes a price or stock.
class AccountantPanel extends ConsumerStatefulWidget {
  const AccountantPanel({super.key});
  @override
  ConsumerState<AccountantPanel> createState() => _AccountantPanelState();
}

final _viewBranchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) => ref.watch(posRepoProvider).viewBranches());

class _AccountantPanelState extends ConsumerState<AccountantPanel> {
  Period _period = Period.lastDays(7);
  bool _onlyDiff = false;
  String? _branch; // null = every branch
  bool _exporting = false;

  String _periodLabel() => _period.label(context);

  String _branchLabel(List<Map<String, dynamic>> all) {
    if (_branch == null) return _t(context, 'كل الفروع', 'All branches');
    for (final b in all) {
      if (b['id'] == _branch) return '${b['name_ar']}';
    }
    return '';
  }

  /// Excel or PDF of exactly what is on screen: the chosen branch (or all) for the chosen period.
  Future<void> _export(bool pdf) async {
    setState(() => _exporting = true);
    try {
      final repo = ref.read(posRepoProvider);
      final branches = (await repo.branchReportRange(_period.from, _period.to)).where((b) => _branch == null || b['branch_id'] == _branch).toList();
      final shifts = await repo.booksShifts(_branch, _period.from, _period.to);
      final sales = await repo.booksSales(_branch, _period.from, _period.to);
      final canReports = ref.read(staffContextProvider).valueOrNull?.permissions.contains('shifts.reports') ?? false;
      final reports = canReports ? await repo.booksReports(_branch, _period.from, _period.to) : <Map<String, dynamic>>[];
      final all = ref.read(_viewBranchesProvider).valueOrNull ?? const <Map<String, dynamic>>[];
      if (!mounted) return;
      final data = BooksData(
        ar: context.isAr, periodLabel: _periodLabel(), branchLabel: _branchLabel(all),
        branches: branches, shifts: shifts, sales: sales, reports: reports,
      );
      final stamp = DateFormat('yyyyMMdd').format(DateTime.now());
      if (pdf) {
        final bytes = await booksPdf(data);
        await deliverFile(context, bytes, 'myhato-accounts-$stamp.pdf', 'application/pdf');
      } else {
        final bytes = booksXlsx(data);
        final name = 'myhato-accounts-$stamp.xlsx';
        await deliverFile(context, bytes, name, xlsxMime);
      }
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  num _sum(List<Map<String, dynamic>> l, String k) => l.fold<num>(0, (a, b) => a + ((b[k] as num?) ?? 0));

  String _text(List<Map<String, dynamic>> branches, List<Map<String, dynamic>> shifts) {
    final b = StringBuffer()
      ..writeln('${_t(context, 'تقرير المحاسبة', 'Accounting report')} — ${_period.label(context)}')
      ..writeln(
          '${_t(context, 'صافي المبيعات', 'Net sales')}: ${_money(context, _sum(branches, 'net_minor'))}  |  ${_t(context, 'المرتجعات', 'Refunds')}: ${_money(context, _sum(branches, 'refunds_minor'))}  |  ${_t(context, 'فرق الدرج', 'Drawer difference')}: ${_money(context, _sum(branches, 'variance_minor'))}')
      ..writeln();
    for (final x in branches) {
      b.writeln('${x['branch_name_ar']}: ${_t(context, 'صافي', 'net')} ${_money(context, x['net_minor'] as num)} · ${_t(context, 'مبيعات', 'sales')} ${_money(context, x['sales_minor'] as num)} (${x['sales_count']}) · ${_t(context, 'مرتجع', 'refunds')} ${_money(context, x['refunds_minor'] as num)} · ${_t(context, 'فرق', 'diff')} ${_money(context, x['variance_minor'] as num)}');
    }
    final diff = shifts.where((s) => s['status'] == 'closed' && ((s['variance_minor'] as num?) ?? 0) != 0);
    if (diff.isNotEmpty) {
      b
        ..writeln()
        ..writeln(_t(context, 'ورديات فيها فرق:', 'Shifts with a difference:'));
      for (final s in diff) {
        b.writeln('${_when(s['opened_at'] as String?)} · ${s['cashier_name']} · ${s['branch_name_ar']} · ${_money(context, s['variance_minor'] as num)}');
      }
    }
    return b.toString();
  }

  Widget _kpi(String label, String value, IconData icon, Color color) => SizedBox(
        width: 172,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 12.5))),
              ]),
              const SizedBox(height: 6),
              Text(value, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: color)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(_acctReportProvider(_period));
    final shifts = ref.watch(_acctShiftsProvider(_period));
    final canPick = ref.watch(staffContextProvider).valueOrNull?.permissions.contains('books.period') ?? false;
    final branches = report.valueOrNull;
    final shiftList = shifts.valueOrNull ?? const <Map<String, dynamic>>[];

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_acctReportProvider);
        ref.invalidate(_acctShiftsProvider);
        ref.invalidate(shiftReportsPeriodProvider);
      },
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: PeriodBar(period: _period, canPick: canPick, onChanged: (p) => setState(() => _period = p))),
          const SizedBox(width: 8),
          if (_exporting)
            const Padding(padding: EdgeInsets.all(10), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)))
          else
            PopupMenuButton<bool>(
              tooltip: _t(context, 'تصدير', 'Export'),
              icon: const Icon(Icons.file_download_outlined),
              onSelected: _export,
              itemBuilder: (_) => [
                PopupMenuItem(value: false, child: Text(_t(context, 'ملف Excel', 'Excel file'))),
                PopupMenuItem(value: true, child: Text(_t(context, 'ملف PDF', 'PDF file'))),
              ],
            ),
          IconButton.filledTonal(
            tooltip: _t(context, 'انسخ التقرير', 'Copy the report'),
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: branches == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _text(branches, shiftList)));
                    if (context.mounted) showSnack(context, _t(context, 'اتنسخ التقرير', 'Report copied'));
                  },
          ),
        ]),
        const SizedBox(height: 10),
        ref.watch(_viewBranchesProvider).maybeWhen(
              data: (all) => all.length <= 1
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Wrap(spacing: 8, runSpacing: 8, children: [
                        ChoiceChip(label: Text(_t(context, 'كل الفروع', 'All branches')), selected: _branch == null, onSelected: (_) => setState(() => _branch = null)),
                        for (final b in all)
                          ChoiceChip(
                            avatar: b['is_hq'] == true ? const Icon(Icons.apartment_rounded, size: 18) : null,
                            label: Text(_t(context, '${b['name_ar']}', '${b['name_en']}')),
                            selected: _branch == b['id'],
                            onSelected: (_) => setState(() => _branch = b['id'] as String),
                          ),
                      ]),
                    ),
              orElse: () => const SizedBox.shrink(),
            ),
        report.when(
          loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(_err(context, e)),
          data: (allRows) {
            final list = allRows.where((b) => _branch == null || b['branch_id'] == _branch).toList();
            final variance = _sum(list, 'variance_minor');
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                _kpi(_t(context, 'صافي المبيعات', 'Net sales'), _money(context, _sum(list, 'net_minor')), Icons.account_balance_wallet_rounded, BrandColors.navy),
                _kpi(_t(context, 'إجمالي المبيعات', 'Total sales'), _money(context, _sum(list, 'sales_minor')), Icons.trending_up_rounded, BrandColors.success),
                _kpi(_t(context, 'عدد الفواتير', 'Invoices'), '${_sum(list, 'sales_count')}', Icons.receipt_long_rounded, BrandColors.electric),
                _kpi(_t(context, 'المرتجعات', 'Refunds'), _money(context, _sum(list, 'refunds_minor')), Icons.assignment_return_outlined, BrandColors.warning),
                _kpi(_t(context, 'ورديات مقفولة', 'Closed shifts'), '${_sum(list, 'shifts_closed')}', Icons.lock_outline_rounded, BrandColors.gray),
                _kpi(_t(context, 'فرق الدرج', 'Drawer difference'), variance == 0 ? _t(context, 'مظبوط ✅', 'Matches ✅') : _money(context, variance), Icons.balance_rounded,
                    variance == 0 ? BrandColors.success : BrandColors.error),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                child: Text(_t(context, 'الفروع', 'Branches'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              for (final b in list)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${b['branch_name_ar']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 18, runSpacing: 6, children: [
                        _mini(_t(context, 'صافي', 'Net'), _money(context, b['net_minor'] as num), BrandColors.navy),
                        _mini(_t(context, 'مبيعات', 'Sales'), '${_money(context, b['sales_minor'] as num)} (${b['sales_count']})', null),
                        _mini(_t(context, 'مرتجعات', 'Refunds'), _money(context, b['refunds_minor'] as num), null),
                        _mini(_t(context, 'فرق الدرج', 'Drawer difference'), _money(context, b['variance_minor'] as num),
                            (b['variance_minor'] as num) == 0 ? BrandColors.success : BrandColors.error),
                      ]),
                    ]),
                  ),
                ),
            ]);
          },
        ),
        if (ref.watch(staffContextProvider).valueOrNull?.permissions.contains('shifts.reports') ?? false) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Text(_t(context, 'تقارير إقفال الورديات', 'Shift closing reports'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          ShiftReportsList(days: 0, period: _period, branchId: _branch),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Row(children: [
            Text(_t(context, 'الورديات', 'Shifts'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Spacer(),
            FilterChip(
              label: Text(_t(context, 'اللي فيها فرق بس', 'Only with a difference')),
              selected: _onlyDiff,
              onSelected: (v) => setState(() => _onlyDiff = v),
            ),
          ]),
        ),
        shifts.when(
          loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(_err(context, e)),
          data: (all) {
            final inBranch = all.where((s) => _branch == null || s['branch_id'] == _branch).toList();
            final list = _onlyDiff ? inBranch.where((s) => s['status'] == 'closed' && ((s['variance_minor'] as num?) ?? 0) != 0).toList() : inBranch;
            return list.isEmpty
                ? Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_t(context, 'مفيش ورديات في الفترة دي', 'No shifts in this period'), style: const TextStyle(color: BrandColors.gray))))
                : Column(children: [for (final s in list) _ShiftTile(s: s)]);
          },
        ),
        const SizedBox(height: 30),
      ]),
    );
  }

  Widget _mini(String l, String v, Color? color) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
        Text(v, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: color)),
      ]);
}
