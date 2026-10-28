// Permissions console (owner only): decide what each role may do, and allow or block a single
// thing for one account. Every change is checked by the database (permissions.manage is held by
// the owner only) and written to the audit log.
// All wording comes from the database (permission_catalog / permission_ui_text, migration 0038):
// edit a row there and pull-to-refresh shows it, no new app build. The text below is only the
// fallback used when the database has no wording yet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'team.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

// ---------------------------------------------------------------- wording from the database
Map<String, dynamic> _serverCatalog = const {};
Map<String, dynamic> _serverText = const {};

/// A sentence of the screen: database text first, built-in fallback second. {name} placeholders are filled from [vars].
String _s(BuildContext c, String key, String ar, String en, [Map<String, String> vars = const {}]) {
  final v = _serverText[key];
  var out = (v is Map ? (c.isAr ? v['ar'] : v['en']) : null)?.toString() ?? (c.isAr ? ar : en);
  vars.forEach((k, val) => out = out.replaceAll('{$k}', val));
  return out;
}

class _PermInfo {
  const _PermInfo(this.group, this.ar, this.en, {this.descAr, this.descEn, this.sensitive = false, this.inert = false});
  final String group, ar, en;
  final String? descAr, descEn;
  final bool sensitive;

  /// Name exists in the catalog but no database function checks it yet.
  final bool inert;
}

const _perms = <String, _PermInfo>{
  'orders.view': _PermInfo('orders', 'يشوف الطلبات', 'View orders', descAr: 'يشوفها بس ومايغيّرش فيها', descEn: 'Can look but not change'),
  'orders.manage': _PermInfo('orders', 'يتحكم في الطلبات', 'Handle orders',
      descAr: 'يغيّر حالة الطلب ويوافق أو يرفض الإلغاء ويعمل أكواد الخصم', descEn: 'Change status, approve cancellations, manage discount codes'),
  'customers.view': _PermInfo('orders', 'يشوف بيانات العملاء', 'View customers'),
  'support.manage': _PermInfo('orders', 'يقبل أو يرفض الحسابات الجديدة', 'Approve new accounts',
      descAr: 'ويرد على طلبات الدعم', descEn: 'And answers support requests'),
  'customers.review': _PermInfo('orders', 'مراجعة العملاء الجداد', 'Review new customers'),
  'cancel_requests.decide': _PermInfo('orders', 'يوافق على إلغاء الطلبات', 'Decide cancellations'),
  'coupons.manage': _PermInfo('orders', 'يعمل أكواد الخصم', 'Manage discount codes'),
  'notifications.broadcast': _PermInfo('orders', 'يبعت إشعارات لكل العملاء', 'Send notifications to all customers'),
  'products.manage': _PermInfo('products', 'يعدّل المنتجات والأسعار والتقييمات', 'Edit products, prices and reviews'),
  'inventory.manage': _PermInfo('products', 'يعدّل المخزون', 'Edit stock'),
  'banners.manage': _PermInfo('products', 'يعدّل الصور الإعلانية', 'Edit banners'),
  'reviews.moderate': _PermInfo('products', 'يراجع تقييمات العملاء', 'Moderate reviews'),
  'repairs.view': _PermInfo('repairs', 'يشوف طلبات الصيانة', 'View repairs'),
  'repairs.manage': _PermInfo('repairs', 'يتحكم في كل طلبات الصيانة', 'Handle all repairs',
      descAr: 'حتى اللي مش مسلّمة له، وقطع الغيار', descEn: 'Even ones not assigned to him, and parts'),
  'repairs.update_assigned': _PermInfo('repairs', 'يحدّث الصيانة اللي اتسلمتله بس', 'Update only his assigned repairs'),
  'audit.view': _PermInfo('system', 'يشوف سجل اللي حصل في النظام', 'View the activity log'),
  'audit.export': _PermInfo('system', 'يحمّل سجل النظام', 'Download the activity log'),
  'settings.manage': _PermInfo('system', 'يغيّر إعدادات المتجر والدفع', 'Change store and payment settings', sensitive: true),
  'staff.manage': _PermInfo('system', 'يدير الفريق', 'Manage the team',
      descAr: 'يضيف ويشيل أعضاء ويغيّر أدوارهم', descEn: 'Add and remove members and change roles', sensitive: true),
  'payments.manage': _PermInfo('system', 'يدير الدفع والاسترداد', 'Manage payments and refunds', sensitive: true),
  'roles.assign': _PermInfo('system', 'يغيّر أدوار الناس', 'Change people roles', sensitive: true),
  'branches.manage': _PermInfo('system', 'يعدّل الفروع ومناطق التوصيل', 'Edit branches and delivery zones'),
  'branches.all': _PermInfo('system', 'يشوف حسابات كل الفروع', 'See the accounts of every branch',
      descAr: 'يشوف الورديات والمبيعات والتقارير لكل الفروع والإدارة، مش فرعه بس', descEn: 'See shifts, sales and reports of every branch and head office'),
};

const _groupOrder = ['orders', 'products', 'repairs', 'pos', 'system', 'other'];

_PermInfo _infoOf(String key) {
  final c = _serverCatalog[key];
  if (c is Map) {
    return _PermInfo(
      (c['grp'] ?? 'other').toString(),
      (c['name_ar'] ?? key).toString(),
      (c['name_en'] ?? key).toString(),
      descAr: c['desc_ar']?.toString(),
      descEn: c['desc_en']?.toString(),
      sensitive: c['sensitive'] == true,
      inert: c['inert'] == true,
    );
  }
  return _perms[key] ?? _PermInfo('other', key, key);
}

int _sortOf(String key) {
  final c = _serverCatalog[key];
  if (c is Map && c['sort'] is num) return (c['sort'] as num).toInt();
  final i = _perms.keys.toList().indexOf(key);
  return i < 0 ? 999 : i;
}

String _groupLabel(BuildContext c, String g) => switch (g) {
      'orders' => _s(c, 'grp_orders', 'الطلبات والعملاء', 'Orders and customers'),
      'products' => _s(c, 'grp_products', 'المنتجات', 'Products'),
      'repairs' => _s(c, 'grp_repairs', 'الصيانة', 'Repairs'),
      'pos' => _s(c, 'grp_pos', 'الكاشير والورديات', 'Cashier and shifts'),
      'system' => _s(c, 'grp_system', 'النظام', 'System'),
      _ => _s(c, 'grp_other', 'أخرى', 'Other'),
    };

/// Permissions grouped for display. [inert] = true returns only the ones that are not active yet.
List<MapEntry<String, List<String>>> _grouped(Iterable<String> keys, {bool inert = false}) {
  final byGroup = <String, List<String>>{};
  for (final k in keys) {
    if (k == 'permissions.manage') continue; // never delegable, never shown
    if (_infoOf(k).inert != inert) continue;
    byGroup.putIfAbsent(_infoOf(k).group, () => <String>[]).add(k);
  }
  for (final list in byGroup.values) {
    list.sort((a, b) => _sortOf(a).compareTo(_sortOf(b)));
  }
  return [
    for (final g in _groupOrder)
      if (byGroup.containsKey(g)) MapEntry(g, byGroup[g]!),
  ];
}

List<String> _stringList(Object? v) => v is List ? v.map((e) => e.toString()).toList() : <String>[];

Set<String> _rolePerms(Map<String, dynamic> ov, String role) {
  final roles = ov['roles'];
  return roles is Map ? _stringList(roles[role]).toSet() : <String>{};
}

Map<String, String> _overridesOf(Map<String, dynamic> ov, String userId) {
  final out = <String, String>{};
  final list = ov['overrides'];
  if (list is List) {
    for (final o in list) {
      if (o is Map && o['user_id'].toString() == userId) out[o['permission'].toString()] = o['effect'].toString();
    }
  }
  return out;
}

String _permError(BuildContext context, Object e) {
  final m = e.toString();
  String? pick(String code, String ar, String en) => m.contains(code) ? _t(context, ar, en) : null;
  return pick('OWNER_FIXED', 'صلاحيات المالك ثابتة ومينفعش تتعدل', 'Owner permissions are fixed') ??
      pick('NOT_DELEGABLE', 'الصلاحية دي للمالك بس ومينفعش تتسلم', 'This permission stays with the owner') ??
      pick('NOT_STAFF', 'الحساب ده مش في الفريق', 'This account is not on the team') ??
      pick('UNKNOWN_PERMISSION', 'صلاحية مش معروفة', 'Unknown permission') ??
      pick('CANNOT_CHANGE_OWN_ROLE', 'مينفعش تغيّر حسابك إنت', 'You cannot change your own account') ??
      friendlyError(context, e);
}

// ---------------------------------------------------------------- data
class PermissionsRepository {
  PermissionsRepository(this._db);
  final SupabaseClient _db;

  Future<Map<String, dynamic>> overview() async {
    final m = Map<String, dynamic>.from(await _db.rpc('staff_permissions_overview') as Map);
    final c = m['catalog'], s = m['strings'];
    _serverCatalog = c is Map ? Map<String, dynamic>.from(c) : const {};
    _serverText = s is Map ? Map<String, dynamic>.from(s) : const {};
    return m;
  }

  Future<void> setRole(String role, String permission, bool grant) =>
      _db.rpc('staff_set_role_permission', params: {'p_role': role, 'p_permission': permission, 'p_grant': grant});

  /// effect: 'grant' | 'deny' | 'clear'
  Future<void> setUser(String userId, String permission, String effect) =>
      _db.rpc('staff_set_user_permission', params: {'p_user_id': userId, 'p_permission': permission, 'p_effect': effect});
}

final permissionsRepoProvider = Provider((ref) => PermissionsRepository(ref.watch(supabaseProvider)));
final _overviewProvider = FutureProvider.autoDispose((ref) => ref.watch(permissionsRepoProvider).overview());
final _staffProvider = FutureProvider.autoDispose((ref) => ref.watch(teamRepoProvider).team());

void openPermissions(BuildContext context) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PermissionsScreen()));

Future<bool> _confirm(BuildContext context, String title, String body) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_s(ctx, 'cancel', 'إلغاء', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_s(ctx, 'confirm', 'تأكيد', 'Confirm'))),
      ],
    ),
  );
  return ok == true;
}

Future<void> _refresh(WidgetRef ref) async {
  ref.invalidate(_overviewProvider);
  ref.invalidate(_staffProvider);
  try {
    await ref.read(_overviewProvider.future);
  } catch (_) {}
}

// ---------------------------------------------------------------- screen
class PermissionsScreen extends ConsumerWidget {
  const PermissionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_overviewProvider);
    final ov = data.valueOrNull;
    Widget body;
    if (ov != null) {
      body = TabBarView(children: [_RolesTab(overview: ov), _AccountsTab(overview: ov)]);
    } else if (data.hasError) {
      final err = data.error!;
      body = err.toString().contains('PGRST202') || err.toString().contains('staff_permissions_overview')
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _t(context, 'شغّل migration رقم 0037 على قاعدة البيانات الأول.', 'Apply database migration 0037 first.'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ErrorView(error: err, onRetry: () => ref.invalidate(_overviewProvider));
    } else {
      body = const Center(child: CircularProgressIndicator());
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_s(context, 'title', 'صلاحيات الفريق', 'Team permissions')),
          actions: [
            IconButton(
              tooltip: _s(context, 'refresh', 'تحديث', 'Refresh'),
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => _refresh(ref),
            ),
          ],
          bottom: TabBar(tabs: [
            Tab(text: _s(context, 'tab_roles', 'كل دور', 'By role')),
            Tab(text: _s(context, 'tab_accounts', 'حساب بعينه', 'One account')),
          ]),
        ),
        body: body,
      ),
    );
  }
}

// ---------------------------------------------------------------- roles tab
class _RolesTab extends ConsumerStatefulWidget {
  const _RolesTab({required this.overview});
  final Map<String, dynamic> overview;
  @override
  ConsumerState<_RolesTab> createState() => _RolesTabState();
}

class _RolesTabState extends ConsumerState<_RolesTab> {
  String _role = 'technician';
  final Set<String> _busy = <String>{};

  Future<void> _toggle(String perm, bool grant) async {
    final info = _infoOf(perm);
    final role = roleOf(_role);
    final staff = ref.read(_staffProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    final n = staff.where((m) => m['role'] == _role).length;
    final name = _t(context, info.ar, info.en);
    var body = _s(context, 'affects', 'ده هيأثر على {n} حساب دلوقتي.', 'This affects {n} account(s) right now.', {'n': '$n'});
    if (info.sensitive) {
      body += '\n${_s(context, 'sensitive_warn', 'صلاحية حساسة، اتأكد قبل ما تكمل.', 'This is a sensitive permission, please double-check.')}';
    }
    final vars = {'perm': name, 'role': role.label(context)};
    final ok = await _confirm(
      context,
      grant
          ? _s(context, 'confirm_give_role', 'تسمح بـ «{perm}» لـ {role}؟', 'Allow "{perm}" for {role}?', vars)
          : _s(context, 'confirm_take_role', 'تمنع «{perm}» عن {role}؟', 'Block "{perm}" for {role}?', vars),
      body,
    );
    if (!ok || !mounted) return;
    setState(() => _busy.add(perm));
    try {
      await ref.read(permissionsRepoProvider).setRole(_role, perm, grant);
      ref.invalidate(_overviewProvider);
      if (mounted) showSnack(context, _s(context, 'saved', 'اتحفظ', 'Saved'));
    } catch (e) {
      if (mounted) showSnack(context, _permError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(perm));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ov = widget.overview;
    final locked = _role == 'owner';
    final mine = _rolePerms(ov, _role);
    final all = _stringList(ov['permissions']);
    final soon = _grouped(all);
    return RefreshIndicator(
      onRefresh: () => _refresh(ref),
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Text(
          _s(context, 'hint_roles', 'اختار الدور وشغّل أو اقفل أي حاجة. التغيير بيتطبق على كل اللي في الدور ده.',
              'Pick a role and switch things on or off. It applies to everyone in that role.'),
          style: const TextStyle(color: BrandColors.gray, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final key in const ['owner', 'manager', 'accountant', 'cashier', 'sales', 'technician', 'support'])
            ChoiceChip(
              label: Text(roleOf(key).label(context)),
              selected: _role == key,
              onSelected: (_) => setState(() => _role = key),
            ),
        ]),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _s(context, 'owner_note', 'المالك عنده كل حاجة وثابت، عشان متقفلش على نفسك بالغلط.', 'The owner always has everything, so you cannot lock yourself out.'),
              style: const TextStyle(color: BrandColors.gray, fontSize: 13),
            ),
          ),
        for (final g in _grouped(all)) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 6),
            child: Text(_groupLabel(context, g.key), style: const TextStyle(color: BrandColors.gray, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final k in g.value)
                SwitchListTile(
                  value: locked ? true : mine.contains(k),
                  onChanged: (locked || _busy.contains(k)) ? null : (v) => _toggle(k, v),
                  title: Text(_t(context, _infoOf(k).ar, _infoOf(k).en)),
                  subtitle: _PermSubtitle(permKey: k),
                ),
            ]),
          ),
        ],
        if (soon.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(
                title: Text(_s(context, 'soon_title', 'حاجات جاية قريب', 'Coming soon')),
                subtitle: Text(_s(context, 'soon_sub', 'لسه مش شغالة، تشغيلها دلوقتي مالوش تأثير', 'Not active yet, switching them on has no effect')),
                children: [
                  for (final g in soon)
                    for (final k in g.value)
                      SwitchListTile(
                        value: locked ? true : mine.contains(k),
                        onChanged: null,
                        title: Text(_t(context, _infoOf(k).ar, _infoOf(k).en)),
                      ),
                ],
              ),
            ),
          ),
      ]),
    );
  }
}

class _PermSubtitle extends StatelessWidget {
  const _PermSubtitle({required this.permKey});
  final String permKey;
  @override
  Widget build(BuildContext context) {
    final info = _infoOf(permKey);
    final desc = context.isAr ? info.descAr : info.descEn;
    if (desc == null && !info.sensitive) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (desc != null) Text(desc),
      if (info.sensitive)
        Text(_s(context, 'sensitive', 'حساسة', 'Sensitive'),
            style: const TextStyle(color: BrandColors.warning, fontWeight: FontWeight.w700, fontSize: 12)),
    ]);
  }
}

// ---------------------------------------------------------------- accounts tab
class _AccountsTab extends ConsumerWidget {
  const _AccountsTab({required this.overview});
  final Map<String, dynamic> overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_staffProvider);
    final staff = data.valueOrNull;
    if (staff == null) {
      return data.hasError
          ? ErrorView(error: data.error!, onRetry: () => ref.invalidate(_staffProvider))
          : const Center(child: CircularProgressIndicator());
    }
    final people = staff.where((m) => m['role'] != null && m['role'] != 'owner').toList();
    if (people.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_s(context, 'no_staff', 'مفيش حد في الفريق غير المالك', 'No team members besides the owner'), textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _refresh(ref),
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Text(
          _s(context, 'hint_accounts', 'اختار شخص، وتقدر تسمح له بحاجة زيادة أو تمنعه من حاجة، من غير ما تغيّر دوره كله.',
              'Pick a person to allow or block single things without changing the whole role.'),
          style: const TextStyle(color: BrandColors.gray, fontSize: 13),
        ),
        const SizedBox(height: 10),
        for (final m in people)
          Builder(builder: (context) {
            final role = roleOf(m['role']?.toString());
            final name = (m['full_name'] ?? m['username'] ?? '').toString();
            final count = _overridesOf(overview, m['user_id'].toString()).length;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(backgroundColor: role.color.withValues(alpha: 0.14), child: Icon(role.icon, color: role.color)),
                title: Text(name.isEmpty ? '—' : name),
                subtitle: Text(role.label(context)),
                trailing: count > 0
                    ? Chip(label: Text(_s(context, 'exceptions', '{n} استثناء', '{n} exceptions', {'n': '$count'})))
                    : const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  await showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    useSafeArea: true,
                    builder: (_) => _AccountSheet(member: m),
                  );
                  ref.invalidate(_overviewProvider);
                },
              ),
            );
          }),
      ]),
    );
  }
}

class _AccountSheet extends ConsumerStatefulWidget {
  const _AccountSheet({required this.member});
  final Map<String, dynamic> member;
  @override
  ConsumerState<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<_AccountSheet> {
  final Set<String> _busy = <String>{};
  List<Map<String, dynamic>>? _branches; // every branch + head office
  Set<String> _mine = <String>{}; // the ones this person works in
  bool _savingBranches = false;

  @override
  void initState() {
    super.initState();
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    try {
      final repo = ref.read(teamRepoProvider);
      final all = await repo.branches();
      final mine = (await repo.memberBranches(widget.member['user_id'].toString())).toSet();
      if (mounted) setState(() {
        _branches = all;
        _mine = mine;
      });
    } catch (_) {
      if (mounted) setState(() => _branches = const []);
    }
  }

  /// Ticking a branch saves at once; the person's app picks it up within seconds.
  Future<void> _toggleBranch(String id) async {
    final next = {..._mine};
    next.contains(id) ? next.remove(id) : next.add(id);
    setState(() {
      _mine = next;
      _savingBranches = true;
    });
    try {
      await ref.read(teamRepoProvider).setMemberBranches(widget.member['user_id'].toString(), next.toList());
      if (mounted) showSnack(context, _s(context, 'saved', 'اتحفظ', 'Saved'));
    } catch (e) {
      if (mounted) {
        showSnack(context, _permError(context, e), error: true);
        _loadBranches();
      }
    } finally {
      if (mounted) setState(() => _savingBranches = false);
    }
  }

  Widget _branchBar(BuildContext context, bool seesAll) {
    final all = _branches;
    if (all == null) return const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator());
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.store_mall_directory_outlined, size: 20),
          const SizedBox(width: 6),
          Text(_s(context, 'branch_title', 'الفرع اللي بيشتغل فيه', 'Branch he works in'), style: const TextStyle(fontWeight: FontWeight.w800)),
          if (_savingBranches) const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
        ]),
        const SizedBox(height: 8),
        if (all.isEmpty)
          Text(_s(context, 'branch_none', 'مفيش فروع متاحة', 'No branches'), style: const TextStyle(color: BrandColors.gray))
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in all)
              FilterChip(
                selected: _mine.contains(b['id']),
                avatar: b['is_hq'] == true ? const Icon(Icons.apartment_rounded, size: 18) : null,
                label: Text(_t(context, '${b['name_ar']}', '${b['name_en']}')),
                onSelected: _savingBranches ? null : (_) => _toggleBranch(b['id'] as String),
              ),
          ]),
        const SizedBox(height: 6),
        Text(
          seesAll
              ? _s(context, 'branch_all_hint', 'بيشوف حسابات كل الفروع من صلاحية «يشوف حسابات كل الفروع»، والفرع هنا للشغل الفعلي (بيع ووردية).', 'He sees the accounts of every branch through the "every branch" permission; the branch here is where he actually works.')
              : _s(context, 'branch_hint', 'مش هيشوف غير بيانات الفروع اللي معلّم عليها. لو مفيش، مش هيقدر يفتح وردية.', 'He only sees the branches ticked. With none, he cannot open a shift.'),
          style: const TextStyle(color: BrandColors.gray, fontSize: 12.5),
        ),
      ]),
    );
  }

  Future<void> _set(String perm, String value) async {
    final info = _infoOf(perm);
    if (info.sensitive && value == 'grant') {
      final ok = await _confirm(
        context,
        _s(context, 'confirm_give_user', 'تسمح بـ «{perm}» للحساب ده؟', 'Allow "{perm}" for this account?', {'perm': _t(context, info.ar, info.en)}),
        _s(context, 'sensitive_warn', 'صلاحية حساسة، اتأكد قبل ما تكمل.', 'This is a sensitive permission, please double-check.'),
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy.add(perm));
    try {
      await ref.read(permissionsRepoProvider).setUser(widget.member['user_id'].toString(), perm, value == 'role' ? 'clear' : value);
      ref.invalidate(_overviewProvider);
      if (mounted) showSnack(context, _s(context, 'saved', 'اتحفظ', 'Saved'));
    } catch (e) {
      if (mounted) showSnack(context, _permError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(perm));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ov = ref.watch(_overviewProvider).valueOrNull;
    if (ov == null) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    final m = widget.member;
    final roleKey = (m['role'] ?? '').toString();
    final role = roleOf(roleKey);
    final name = (m['full_name'] ?? m['username'] ?? '').toString();
    final rolePerms = _rolePerms(ov, roleKey);
    final mine = _overridesOf(ov, m['user_id'].toString());
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
      Text(name.isEmpty ? '—' : name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      Text(role.label(context), style: const TextStyle(color: BrandColors.gray)),
      _branchBar(context, mine['branches.all'] == 'grant' || (mine['branches.all'] == null && rolePerms.contains('branches.all'))),
      for (final g in _grouped(_stringList(ov['permissions']))) ...[
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 4),
          child: Text(_groupLabel(context, g.key), style: const TextStyle(color: BrandColors.gray, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        for (final k in g.value)
          Builder(builder: (context) {
            final cur = mine[k] ?? 'role';
            final base = rolePerms.contains(k);
            final effective = cur == 'grant' ? true : (cur == 'deny' ? false : base);
            final info = _infoOf(k);
            final desc = context.isAr ? info.descAr : info.descEn;
            final note = switch (cur) {
              'deny' => _s(context, 'note_deny', 'ممنوع منه حتى لو دوره بيسمح', 'Blocked even if the role allows it'),
              'grant' => _s(context, 'note_grant', 'مسموح له بيه حتى لو دوره مبيسمحش', 'Allowed even if the role does not'),
              _ => base
                  ? _s(context, 'note_role_yes', 'زي دوره، ودوره بيسمح بيه', 'Follows the role, which allows it')
                  : _s(context, 'note_role_no', 'زي دوره، ودوره مبيسمحش بيه', 'Follows the role, which does not allow it'),
            };
            final tone = effective ? BrandColors.success : BrandColors.error;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_t(context, info.ar, info.en), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (desc != null) Text(desc, style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(effective ? Icons.check_circle_rounded : Icons.block_rounded, size: 18, color: tone),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      effective ? _s(context, 'can_yes', 'يقدر يعمل ده', 'Can do this') : _s(context, 'can_no', 'مايقدرش يعمل ده', 'Cannot do this'),
                      style: TextStyle(fontWeight: FontWeight.w700, color: tone, fontSize: 13),
                    ),
                  ),
                ]),
                Text(note, style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: 'deny', label: Text(_s(context, 'opt_deny', 'ممنوع', 'Blocked'))),
                      ButtonSegment(value: 'role', label: Text(_s(context, 'opt_role', 'زي دوره', 'Same as role'))),
                      ButtonSegment(value: 'grant', label: Text(_s(context, 'opt_grant', 'مسموح', 'Allowed'))),
                    ],
                    selected: {cur},
                    onSelectionChanged: _busy.contains(k) ? null : (s) => _set(k, s.first),
                  ),
                ),
              ]),
            );
          }),
      ],
    ]);
  }
}
