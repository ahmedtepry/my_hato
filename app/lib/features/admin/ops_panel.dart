// Live operations room (owner): today's sales per branch, open shifts and who opened them, who is online,
// the latest sales and actions. Every card opens the full detail behind it. Refreshes by itself every 5 seconds.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'pos_repository.dart' show posErrorText;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));
Map<String, dynamic> _m(Object? o) => Map<String, dynamic>.from(o as Map);
List<Map<String, dynamic>> _l(Object? o) => [for (final e in (o as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
DateTime? _dt(Object? o) => o == null ? null : DateTime.tryParse('$o')?.toLocal();

String _ago(BuildContext c, Object? iso) {
  final d = _dt(iso);
  if (d == null) return '—';
  final s = DateTime.now().difference(d);
  if (s.inSeconds < 45) return _t(c, 'دلوقتي', 'now');
  if (s.inMinutes < 60) return _t(c, 'من ${s.inMinutes} د', '${s.inMinutes} min ago');
  if (s.inHours < 24) return _t(c, 'من ${s.inHours} س', '${s.inHours} h ago');
  return _t(c, 'من ${s.inDays} يوم', '${s.inDays} d ago');
}

String _clock(Object? iso) {
  final d = _dt(iso);
  if (d == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}';
}

class OpsRepository {
  OpsRepository(this._db);
  final SupabaseClient _db;
  Future<Map<String, dynamic>> live() async => _m(await _db.rpc('ops_live'));
  Future<List<Map<String, dynamic>>> sales({String? branch, String? shift, bool today = true}) async =>
      _l(await _db.rpc('ops_sales', params: {'p_branch': branch, 'p_shift': shift, 'p_today': today, 'p_limit': 200}));
  Future<List<Map<String, dynamic>>> actions({String? actor}) async => _l(await _db.rpc('ops_actions', params: {'p_actor': actor, 'p_limit': 150}));
  Future<Map<String, dynamic>> shiftSummary(String id) async => _m(await _db.rpc('pos_shift_summary', params: {'p_shift': id}));
}

final opsRepoProvider = Provider((ref) => OpsRepository(ref.watch(supabaseProvider)));

const _actionNames = <String, (String, String)>{
  'pos.sale': ('بيعة كاشير', 'Cashier sale'),
  'pos.refund': ('مرتجع', 'Refund'),
  'shift.open': ('فتح وردية', 'Opened a shift'),
  'shift.close': ('قفل وردية', 'Closed a shift'),
  'shift.correct': ('تصحيح وردية', 'Shift correction'),
  'approval.request': ('طلب موافقة', 'Approval request'),
  'approval.decide': ('قرار موافقة', 'Approval decision'),
  'order.status': ('تغيير حالة طلب', 'Order status change'),
  'order.update': ('تعديل طلب', 'Order edited'),
  'repair.status': ('تغيير حالة صيانة', 'Repair status change'),
  'repair.update': ('تعديل صيانة', 'Repair edited'),
  'customer.approve': ('توثيق حساب', 'Account verified'),
  'customer.reject': ('رفض حساب', 'Account rejected'),
  'customer.password_reset': ('تغيير رقم سري لعميل', 'Customer password reset'),
  'inventory.adjust': ('تعديل مخزون', 'Stock adjustment'),
  'commission.set': ('تحديد عمولة', 'Commission set'),
  'target.branch': ('تحديد تارجت فرع', 'Branch target set'),
  'target.user': ('تحديد تارجت موظف', 'Employee target set'),
  'staff.assign': ('تعيين دور', 'Role assigned'),
  'staff.remove': ('إزالة دور', 'Role removed'),
  'staff.branches': ('تعديل فروع موظف', 'Branches changed'),
  'team_theme.set': ('تغيير ألوان الفريق', 'Team theme changed'),
  'audit.export': ('تصدير سجل', 'Log exported'),
  'coupon.save': ('حفظ كوبون', 'Coupon saved'),
  'offer.broadcast': ('إرسال عرض', 'Offer sent'),
};

String _actionLabel(BuildContext c, String a) {
  final n = _actionNames[a];
  return n == null ? a : _t(c, n.$1, n.$2);
}

class OpsPanel extends ConsumerStatefulWidget {
  const OpsPanel({super.key});
  @override
  ConsumerState<OpsPanel> createState() => _OpsPanelState();
}

class _OpsPanelState extends ConsumerState<OpsPanel> {
  Map<String, dynamic>? _data;
  Object? _error;
  Timer? _timer;
  DateTime? _at;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    try {
      final d = await ref.read(opsRepoProvider).live();
      if (mounted) setState(() {
            _data = d;
            _error = null;
            _at = DateTime.now();
          });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      return _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_err(context, _error!), textAlign: TextAlign.center)))
          : const Center(child: CircularProgressIndicator());
    }
    final branches = _l(d['branches']);
    final shifts = _l(d['open_shifts']);
    final team = _l(d['team']);
    final sales = _l(d['recent_sales']);
    final actions = _l(d['recent_actions']);
    final totalNet = branches.fold<int>(0, (a, b) => a + ((b['net_minor'] as num?) ?? 0).toInt());
    final totalCount = branches.fold<int>(0, (a, b) => a + ((b['sales_count'] as num?) ?? 0).toInt());
    final online = team.where((t) => t['presence'] == 'online').length;
    final pf = d['profit'] is Map ? Map<String, dynamic>.from(d['profit'] as Map) : null; // only when the member has profit.view
    final profitNow = (pf?['profit_minor'] as num?)?.toInt() ?? 0;
    final uncosted = (pf?['sales_uncosted'] as num?)?.toInt() ?? 0;
    final byBranch = pf?['by_branch'] is Map ? Map<String, dynamic>.from(pf!['by_branch'] as Map) : const <String, dynamic>{};

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 56, 20, 32),
        children: [
          Row(children: [
            Expanded(
              child: Text(_t(context, 'غرفة العمليات المباشرة', 'Live operations room'),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: BrandColors.navy)),
            ),
            Container(width: 9, height: 9, decoration: const BoxDecoration(color: BrandColors.success, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(_t(context, 'مباشر · ${_clock(_at?.toIso8601String())}', 'Live · ${_clock(_at?.toIso8601String())}'),
                style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _Stat(Icons.payments_rounded, _t(context, 'صافي مبيعات اليوم (كل الفروع)', 'Net sales today (all branches)'), _money(context, totalNet), BrandColors.success),
            if (pf != null)
              _Stat(profitNow >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded, _t(context, 'صافي الربح الفعلي النهارده', 'Actual net profit today'), '${profitNow >= 0 ? '' : '-'}${_money(context, profitNow.abs())}${uncosted > 0 ? ' *' : ''}',
                  profitNow >= 0 ? BrandColors.success : BrandColors.error),
            _Stat(Icons.receipt_long_rounded, _t(context, 'عدد الفواتير اليوم', 'Invoices today'), '$totalCount', BrandColors.electric),
            _Stat(Icons.lock_open_rounded, _t(context, 'ورديات مفتوحة الآن', 'Open shifts now'), '${shifts.length}', const Color(0xFF7A5AF8)),
            _Stat(Icons.wifi_tethering_rounded, _t(context, 'أونلاين من الفريق', 'Team online'), '$online', const Color(0xFFE8A317)),
          ]),
          if (pf != null && uncosted > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_t(context, '* $uncosted فاتورة النهارده فيها صنف من غير تكلفة ومش داخلة في الربح.', '* $uncosted invoices today have an item with no cost and are left out of the profit.'),
                  style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            ),
          _Title(_t(context, 'مبيعات كل فرع (النهارده)', 'Sales per branch (today)'), Icons.storefront_rounded),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final b in branches)
              _Card(
                width: 280,
                onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _SalesDialog(title: '${_t(context, 'مبيعات', 'Sales of')} ${b['name_ar']}', branch: '${b['id']}')),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${b['name_ar']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                    if ((b['open_shifts'] as num? ?? 0) > 0)
                      _Pill(_t(context, '${b['open_shifts']} وردية مفتوحة', '${b['open_shifts']} open'), BrandColors.success)
                    else
                      _Pill(_t(context, 'مقفول', 'Closed'), BrandColors.gray),
                  ]),
                  const SizedBox(height: 8),
                  Text(_money(context, (b['net_minor'] as num?) ?? 0),
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: BrandColors.navy)),
                  if (pf != null && byBranch['${b['id']}'] != null)
                    Text('${_t(context, 'الربح', 'Profit')}: ${_money(context, byBranch['${b['id']}'] as num)}',
                        style: TextStyle(fontWeight: FontWeight.w800, color: (byBranch['${b['id']}'] as num) >= 0 ? BrandColors.success : BrandColors.error)),
                  const SizedBox(height: 4),
                  Text(
                      '${b['sales_count']} ${_t(context, 'فاتورة', 'invoices')}'
                      '${((b['refunds_minor'] as num?) ?? 0) > 0 ? ' · ${_t(context, 'مرتجع', 'refunds')} ${_money(context, b['refunds_minor'] as num)}' : ''}',
                      style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                  Text('${_t(context, 'آخر بيعة', 'Last sale')}: ${_ago(context, b['last_sale_at'])}', style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                ]),
              ),
          ]),
          _Title(_t(context, 'الورديات المفتوحة ومين فاتحها', 'Open shifts and who opened them'), Icons.lock_open_rounded),
          if (shifts.isEmpty)
            _Empty(_t(context, 'مفيش ورديات مفتوحة دلوقتي', 'No shift is open right now'))
          else
            for (final s in shifts)
              _Row(
                icon: Icons.person_rounded,
                color: const Color(0xFF7A5AF8),
                title: '${s['cashier_name']} · ${s['branch_name_ar']}',
                subtitle:
                    '${_t(context, 'فتح', 'Opened')} ${_clock(s['opened_at'])} (${_ago(context, s['opened_at'])}) · ${s['sales_count']} ${_t(context, 'فاتورة', 'invoices')} · ${_t(context, 'آخر بيعة', 'last sale')} ${_ago(context, s['last_sale_at'])}',
                trailing: _money(context, (s['sales_minor'] as num?) ?? 0),
                onTap: () => showDialog<void>(context: context, builder: (_) => _ShiftDialog(shift: s)),
              ),
          _Title(_t(context, 'الفريق: مين أونلاين ومين فاتح إيه', 'Team: who is online and doing what'), Icons.groups_rounded),
          for (final t in team)
            _Row(
              icon: Icons.circle,
              color: switch (t['presence']) {
                'online' => BrandColors.success,
                'away' => BrandColors.warning,
                'suspended' => BrandColors.error,
                _ => BrandColors.gray,
              },
              iconSize: 14,
              title: '${t['name']} · ${t['role']}',
              subtitle: switch (t['presence']) {
                'online' => '${_t(context, 'أونلاين', 'Online')}${t['area'] != null ? ' · ${t['area']}' : ''}${t['platform'] != null ? ' · ${t['platform']}' : ''}',
                'away' => '${_t(context, 'بعيد', 'Away')} · ${_ago(context, t['last_seen_at'])}',
                'suspended' => _t(context, 'موقوف', 'Suspended'),
                _ => '${_t(context, 'أوفلاين', 'Offline')} · ${_ago(context, t['last_seen_at'])}',
              },
              trailing: '',
              onTap: () => showDialog<void>(context: context, builder: (_) => _ActionsDialog(actor: '${t['user_id']}', name: '${t['name']}')),
            ),
          _Title(_t(context, 'آخر الفواتير', 'Latest invoices'), Icons.receipt_long_rounded),
          if (sales.isEmpty)
            _Empty(_t(context, 'لسه مفيش فواتير', 'No invoices yet'))
          else
            for (final s in sales)
              _Row(
                icon: Icons.receipt_rounded,
                color: BrandColors.success,
                title: '${s['number']} · ${s['branch_name_ar']}',
                subtitle: '${s['cashier_name']} · ${_clock(s['created_at'])} (${_ago(context, s['created_at'])})'
                    '${((s['refunded_minor'] as num?) ?? 0) > 0 ? ' · ${_t(context, 'مرتجع', 'refund')} ${_money(context, s['refunded_minor'] as num)}' : ''}',
                trailing: _money(context, (s['total_minor'] as num?) ?? 0),
                onTap: () => showDialog<void>(context: context, builder: (_) => _SaleDialog(sale: null, id: '${s['id']}', number: '${s['number']}')),
              ),
          _Title(_t(context, 'آخر اللي حصل', 'Latest activity'), Icons.history_rounded),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => showDialog<void>(context: context, builder: (_) => const _ActionsDialog(actor: null, name: '')),
              icon: const Icon(Icons.list_alt_rounded),
              label: Text(_t(context, 'كل السجل', 'Full log')),
            ),
          ),
          for (final a in actions) _ActionRow(a: a),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text, this.icon);
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 26, bottom: 10),
        child: Row(children: [
          Icon(icon, size: 20, color: BrandColors.electric),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: BrandColors.navy)),
        ]),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(12), child: Text(text, style: const TextStyle(color: BrandColors.gray)));
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11.5)),
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.label, this.value, this.color);
  final IconData icon;
  final String label, value;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: 250,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: BrandColors.border)),
        child: Row(children: [
          CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: BrandColors.navy)),
              Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            ]),
          ),
        ]),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.onTap, this.width});
  final Widget child;
  final VoidCallback onTap;
  final double? width;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(14), child: child)),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.color, required this.title, required this.subtitle, required this.trailing, required this.onTap, this.iconSize = 20});
  final IconData icon;
  final Color color;
  final double iconSize;
  final String title, subtitle, trailing;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: BrandColors.border)),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            onTap: onTap,
            leading: Icon(icon, color: color, size: iconSize),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            trailing: trailing.isEmpty
                ? const Icon(Icons.chevron_left_rounded, color: BrandColors.gray)
                : Text(trailing, style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.navy)),
          ),
        ),
      );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.a});
  final Map<String, dynamic> a;
  @override
  Widget build(BuildContext context) => _Row(
        icon: Icons.bolt_rounded,
        color: const Color(0xFFE8A317),
        title: '${a['actor_name']} · ${_actionLabel(context, '${a['action']}')}',
        subtitle: '${a['entity_type']} ${a['entity_id'] ?? ''} · ${_clock(a['created_at'])} (${_ago(context, a['created_at'])})',
        trailing: '',
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(_actionLabel(context, '${a['action']}')),
            content: SingleChildScrollView(
              child: SelectableText(
                '${_t(context, 'بواسطة', 'By')}: ${a['actor_name']}\n'
                '${_t(context, 'الوقت', 'When')}: ${_dt(a['created_at'])}\n'
                '${_t(context, 'النوع', 'Type')}: ${a['entity_type']} ${a['entity_id'] ?? ''}\n\n'
                '${const JsonEncoder.withIndent('  ').convert(a['details'])}',
                textDirection: TextDirection.ltr,
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'OK')))],
          ),
        ),
      );
}

/// A scrollable dialog frame used by every drill-down.
class _Frame extends StatelessWidget {
  const _Frame({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
              child: Row(children: [
                Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
              ]),
            ),
            const Divider(height: 1),
            Flexible(child: child),
          ]),
        ),
      );
}

class _SalesDialog extends ConsumerWidget {
  const _SalesDialog({required this.title, this.branch, this.shift, this.today = true});
  final String title;
  final String? branch, shift;
  final bool today;
  @override
  Widget build(BuildContext context, WidgetRef ref) => _Frame(
        title: title,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: ref.read(opsRepoProvider).sales(branch: branch, shift: shift, today: today),
          builder: (ctx, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(20), child: Text(_err(ctx, snap.error!)));
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
            final rows = snap.data!;
            if (rows.isEmpty) return Padding(padding: const EdgeInsets.all(30), child: Text(_t(ctx, 'مفيش فواتير', 'No invoices')));
            final total = rows.fold<int>(0, (a, r) => a + ((r['total_minor'] as num).toInt() - (r['refunded_minor'] as num).toInt()));
            return ListView(shrinkWrap: true, padding: const EdgeInsets.all(14), children: [
              Text('${rows.length} ${_t(ctx, 'فاتورة', 'invoices')} · ${_t(ctx, 'الصافي', 'net')} ${_money(ctx, total)}',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.navy)),
              const SizedBox(height: 8),
              for (final r in rows) _SaleTile(r: r),
            ]);
          },
        ),
      );
}

class _SaleTile extends StatelessWidget {
  const _SaleTile({required this.r});
  final Map<String, dynamic> r;
  @override
  Widget build(BuildContext context) {
    final items = _l(r['items']);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: BrandColors.border)),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text('${r['number']} · ${_money(context, r['total_minor'] as num)}', style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${r['cashier_name']} · ${r['branch_name_ar']} · ${_clock(r['created_at'])}', style: const TextStyle(fontSize: 12.5)),
        children: [
          for (final i in items)
            ListTile(
              dense: true,
              title: Text('${i['name_ar']} × ${i['quantity']}'),
              trailing: Text(_money(context, i['line_total_minor'] as num)),
              subtitle: ((i['refunded_qty'] as num?) ?? 0) > 0 ? Text('${_t(context, 'مرتجع', 'refunded')}: ${i['refunded_qty']}') : null,
            ),
          if (((r['discount_minor'] as num?) ?? 0) > 0)
            ListTile(dense: true, title: Text(_t(context, 'خصم', 'Discount')), trailing: Text('-${_money(context, r['discount_minor'] as num)}')),
          if (((r['refunded_minor'] as num?) ?? 0) > 0)
            ListTile(dense: true, title: Text(_t(context, 'مرتجع', 'Refunded')), trailing: Text(_money(context, r['refunded_minor'] as num))),
        ],
      ),
    );
  }
}

/// One invoice (opened from the latest-invoices list).
class _SaleDialog extends ConsumerWidget {
  const _SaleDialog({required this.sale, required this.id, required this.number});
  final Map<String, dynamic>? sale;
  final String id, number;
  @override
  Widget build(BuildContext context, WidgetRef ref) => _Frame(
        title: '${_t(context, 'فاتورة', 'Invoice')} $number',
        child: FutureBuilder<Map<String, dynamic>>(
          future: () async {
            final db = ref.read(supabaseProvider);
            final s = _m(await db.rpc('pos_sale_get', params: {'p_sale': id}));
            return s;
          }(),
          builder: (ctx, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(20), child: Text(_err(ctx, snap.error!)));
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
            final s = snap.data!;
            return ListView(shrinkWrap: true, padding: const EdgeInsets.all(14), children: [
              _kv(ctx, _t(ctx, 'الفرع', 'Branch'), '${s['branch_name_ar']}'),
              _kv(ctx, _t(ctx, 'الكاشير', 'Cashier'), '${s['cashier_name']}'),
              _kv(ctx, _t(ctx, 'الوقت', 'Time'), '${_dt(s['created_at'])}'.split('.').first),
              const Divider(),
              for (final i in _l(s['items']))
                ListTile(
                  dense: true,
                  title: Text('${i['name_ar']} × ${i['quantity']}'),
                  subtitle: Text('${_money(ctx, i['unit_price_minor'] as num)} ${_t(ctx, 'للقطعة', 'each')}'
                      '${((i['refunded_qty'] as num?) ?? 0) > 0 ? ' · ${_t(ctx, 'مرتجع', 'refunded')} ${i['refunded_qty']}' : ''}'),
                  trailing: Text(_money(ctx, i['line_total_minor'] as num)),
                ),
              const Divider(),
              _kv(ctx, _t(ctx, 'الإجمالي قبل الخصم', 'Subtotal'), _money(ctx, s['subtotal_minor'] as num)),
              if (((s['discount_minor'] as num?) ?? 0) > 0) _kv(ctx, _t(ctx, 'الخصم', 'Discount'), _money(ctx, s['discount_minor'] as num)),
              _kv(ctx, _t(ctx, 'الإجمالي', 'Total'), _money(ctx, s['total_minor'] as num), bold: true),
              _kv(ctx, _t(ctx, 'المدفوع', 'Paid'), _money(ctx, s['cash_received_minor'] as num)),
              _kv(ctx, _t(ctx, 'الباقي', 'Change'), _money(ctx, s['change_minor'] as num)),
              if (((s['refunded_minor'] as num?) ?? 0) > 0) _kv(ctx, _t(ctx, 'المرتجع', 'Refunded'), _money(ctx, s['refunded_minor'] as num)),
            ]);
          },
        ),
      );
}

Widget _kv(BuildContext c, String k, String v, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(k, style: const TextStyle(color: BrandColors.gray))),
        Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w700)),
      ]),
    );

class _ShiftDialog extends ConsumerWidget {
  const _ShiftDialog({required this.shift});
  final Map<String, dynamic> shift;
  @override
  Widget build(BuildContext context, WidgetRef ref) => _Frame(
        title: '${_t(context, 'وردية', 'Shift')} ${shift['cashier_name']} · ${shift['branch_name_ar']}',
        child: FutureBuilder<Map<String, dynamic>>(
          future: ref.read(opsRepoProvider).shiftSummary('${shift['shift_id']}'),
          builder: (ctx, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(20), child: Text(_err(ctx, snap.error!)));
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
            final s = snap.data!;
            return ListView(shrinkWrap: true, padding: const EdgeInsets.all(14), children: [
              _kv(ctx, _t(ctx, 'فتحها', 'Opened by'), '${shift['cashier_name']}'),
              _kv(ctx, _t(ctx, 'وقت الفتح', 'Opened at'), '${_dt(s['opened_at'])}'.split('.').first),
              _kv(ctx, _t(ctx, 'عهدة الفتح', 'Opening cash'), _money(ctx, (s['opening_minor'] as num?) ?? 0)),
              _kv(ctx, _t(ctx, 'عدد الفواتير', 'Invoices'), '${s['sales_count']}'),
              _kv(ctx, _t(ctx, 'المبيعات', 'Sales'), _money(ctx, (s['sales_minor'] as num?) ?? 0)),
              _kv(ctx, _t(ctx, 'المرتجعات', 'Refunds'), _money(ctx, (s['refunds_minor'] as num?) ?? 0)),
              _kv(ctx, _t(ctx, 'المفروض في الدرج', 'Expected in drawer'), _money(ctx, (s['expected_minor'] as num?) ?? 0), bold: true),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (_) => _SalesDialog(title: '${_t(ctx, 'فواتير الوردية', 'Shift invoices')}', shift: '${shift['shift_id']}', today: false)),
                icon: const Icon(Icons.receipt_long_rounded),
                label: Text(_t(ctx, 'فواتير الوردية', 'Shift invoices')),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                    context: ctx, builder: (_) => _ActionsDialog(actor: '${shift['cashier_id']}', name: '${shift['cashier_name']}')),
                icon: const Icon(Icons.history_rounded),
                label: Text(_t(ctx, 'اللي عمله الكاشير', 'What this cashier did')),
              ),
            ]);
          },
        ),
      );
}

class _ActionsDialog extends ConsumerWidget {
  const _ActionsDialog({required this.actor, required this.name});
  final String? actor;
  final String name;
  @override
  Widget build(BuildContext context, WidgetRef ref) => _Frame(
        title: actor == null ? _t(context, 'سجل كل اللي حصل', 'Full activity log') : '${_t(context, 'نشاط', 'Activity of')} $name',
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: ref.read(opsRepoProvider).actions(actor: actor),
          builder: (ctx, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(20), child: Text(_err(ctx, snap.error!)));
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
            final rows = snap.data!;
            if (rows.isEmpty) return Padding(padding: const EdgeInsets.all(30), child: Text(_t(ctx, 'مفيش نشاط', 'No activity')));
            return ListView(shrinkWrap: true, padding: const EdgeInsets.all(14), children: [for (final a in rows) _ActionRow(a: a)]);
          },
        ),
      );
}
