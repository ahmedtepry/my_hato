// Permissions console (owner only): decide what each role may do, and add or take away a single
// permission for one account. Every change is checked by the database (permissions.manage is held
// by the owner only) and written to the audit log.
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

// ---------------------------------------------------------------- catalog
class _PermInfo {
  const _PermInfo(this.group, this.ar, this.en, {this.descAr, this.descEn, this.sensitive = false, this.inert = false});
  final String group, ar, en;
  final String? descAr, descEn;
  final bool sensitive;

  /// Name exists in the catalog but no database function checks it yet.
  final bool inert;
}

const _perms = <String, _PermInfo>{
  'orders.view': _PermInfo('orders', 'عرض الطلبات', 'View orders'),
  'orders.manage': _PermInfo('orders', 'إدارة الطلبات', 'Manage orders',
      descAr: 'تغيير الحالة، الكوبونات، طلبات الإلغاء، الاسترداد', descEn: 'Status, coupons, cancel requests, refunds'),
  'customers.view': _PermInfo('orders', 'عرض العملاء', 'View customers'),
  'support.manage': _PermInfo('orders', 'الدعم وقبول الحسابات', 'Support & account approval',
      descAr: 'قبول ورفض الحسابات الجديدة وطلبات الدعم', descEn: 'Approve or reject new accounts and support requests'),
  'customers.review': _PermInfo('orders', 'مراجعة العملاء', 'Review customers', inert: true),
  'cancel_requests.decide': _PermInfo('orders', 'قرارات الإلغاء', 'Cancel decisions', inert: true),
  'notifications.broadcast': _PermInfo('orders', 'إشعارات للعملاء', 'Customer notifications', inert: true),
  'coupons.manage': _PermInfo('orders', 'الكوبونات', 'Coupons', inert: true),
  'products.manage': _PermInfo('products', 'المنتجات والتقييمات', 'Products & reviews'),
  'inventory.manage': _PermInfo('products', 'المخزون', 'Inventory'),
  'banners.manage': _PermInfo('products', 'البانرات', 'Banners'),
  'reviews.moderate': _PermInfo('products', 'مراجعة التقييمات', 'Moderate reviews', inert: true),
  'repairs.view': _PermInfo('repairs', 'عرض الصيانة', 'View repairs'),
  'repairs.manage': _PermInfo('repairs', 'إدارة كل الصيانة', 'Manage all repairs',
      descAr: 'كل الطلبات مش المسندة له بس، وقطع الغيار', descEn: 'Every repair, not only assigned ones, and parts'),
  'repairs.update_assigned': _PermInfo('repairs', 'تحديث الصيانة المسندة له', 'Update assigned repairs'),
  'audit.view': _PermInfo('system', 'سجل العمليات', 'Activity log'),
  'audit.export': _PermInfo('system', 'تصدير سجل العمليات', 'Export activity log', inert: true),
  'settings.manage': _PermInfo('system', 'الإعدادات والدفع', 'Settings & payments', sensitive: true),
  'staff.manage': _PermInfo('system', 'إدارة الفريق', 'Manage the team', sensitive: true),
  'payments.manage': _PermInfo('system', 'الدفع والاستردادات', 'Payments & refunds', sensitive: true, inert: true),
  'roles.assign': _PermInfo('system', 'تعيين الأدوار', 'Assign roles', sensitive: true, inert: true),
  'branches.manage': _PermInfo('system', 'الفروع والتوصيل', 'Branches & delivery', inert: true),
};

const _groupOrder = ['orders', 'products', 'repairs', 'system', 'other'];

String _groupLabel(BuildContext c, String g) => switch (g) {
      'orders' => _t(c, 'الطلبات والعملاء', 'Orders & customers'),
      'products' => _t(c, 'المنتجات', 'Products'),
      'repairs' => _t(c, 'الصيانة', 'Repairs'),
      'system' => _t(c, 'النظام', 'System'),
      _ => _t(c, 'أخرى', 'Other'),
    };

_PermInfo _infoOf(String key) => _perms[key] ?? _PermInfo('other', key, key);

List<MapEntry<String, List<String>>> _grouped(Iterable<String> keys) {
  final byGroup = <String, List<String>>{};
  for (final k in keys) {
    if (k == 'permissions.manage') continue; // never delegable, never shown
    byGroup.putIfAbsent(_infoOf(k).group, () => <String>[]).add(k);
  }
  final order = _perms.keys.toList();
  for (final list in byGroup.values) {
    list.sort((a, b) {
      final ia = order.indexOf(a), ib = order.indexOf(b);
      return (ia < 0 ? 999 : ia).compareTo(ib < 0 ? 999 : ib);
    });
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

  Future<Map<String, dynamic>> overview() async => Map<String, dynamic>.from(await _db.rpc('staff_permissions_overview') as Map);

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
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'إلغاء', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'تأكيد', 'Confirm'))),
      ],
    ),
  );
  return ok == true;
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
          title: Text(_t(context, 'صلاحيات الفريق', 'Team permissions')),
          bottom: TabBar(tabs: [
            Tab(text: _t(context, 'الأدوار', 'Roles')),
            Tab(text: _t(context, 'حسابات معينة', 'Single accounts')),
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
    var body = _t(context, 'التغيير ده بيأثر على $n حساب دلوقتي.', 'This affects $n account(s) right now.');
    if (info.sensitive) {
      body += '\n${_t(context, 'صلاحية حساسة، اتأكد قبل ما تكمل.', 'Sensitive permission, please double-check.')}';
    }
    final ok = await _confirm(
      context,
      grant
          ? _t(context, 'تدي «$name» لـ ${role.ar}؟', 'Give "$name" to ${role.en}?')
          : _t(context, 'تسحب «$name» من ${role.ar}؟', 'Take "$name" from ${role.en}?'),
      body,
    );
    if (!ok || !mounted) return;
    setState(() => _busy.add(perm));
    try {
      await ref.read(permissionsRepoProvider).setRole(_role, perm, grant);
      ref.invalidate(_overviewProvider);
      if (mounted) showSnack(context, _t(context, 'اتحفظ', 'Saved'));
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
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final key in const ['owner', 'manager', 'sales', 'technician', 'support'])
          ChoiceChip(
            label: Text(roleOf(key).label(context)),
            selected: _role == key,
            onSelected: (_) => setState(() => _role = key),
          ),
      ]),
      const SizedBox(height: 10),
      if (locked)
        Text(
          _t(context, 'المالك عنده كل الصلاحيات وثابت، ده بيمنع إنك تقفل على نفسك بالغلط.',
              'The owner always has everything. This stops you from locking yourself out.'),
          style: const TextStyle(color: BrandColors.gray, fontSize: 13),
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
    ]);
  }
}

class _PermSubtitle extends StatelessWidget {
  const _PermSubtitle({required this.permKey});
  final String permKey;
  @override
  Widget build(BuildContext context) {
    final info = _infoOf(permKey);
    final desc = context.isAr ? info.descAr : info.descEn;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (desc != null) Text(desc),
      if (info.sensitive)
        Text(_t(context, 'حساسة', 'Sensitive'), style: const TextStyle(color: BrandColors.warning, fontWeight: FontWeight.w700, fontSize: 12)),
      if (info.inert)
        Text(_t(context, 'مش مفعّلة في النظام لسه', 'Not enforced yet'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
      Directionality(
        textDirection: TextDirection.ltr,
        child: Text(permKey, style: const TextStyle(color: BrandColors.gray, fontSize: 11)),
      ),
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
          child: Text(_t(context, 'مفيش حسابات في الفريق غير المالك', 'No team accounts besides the owner'), textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
      Text(
        _t(context, 'الاستثناء بيغيّر صلاحية واحدة لحساب واحد من غير ما يلمس الدور كله.',
            'An exception changes one permission for one account without touching the whole role.'),
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
              trailing: count > 0 ? Chip(label: Text(_t(context, '$count استثناء', '$count exceptions'))) : const Icon(Icons.chevron_right_rounded),
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
    ]);
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

  Future<void> _set(String perm, String value) async {
    final info = _infoOf(perm);
    if (info.sensitive && value == 'grant') {
      final ok = await _confirm(
        context,
        _t(context, 'تدي «${info.ar}» للحساب ده؟', 'Give "${info.en}" to this account?'),
        _t(context, 'صلاحية حساسة، اتأكد قبل ما تكمل.', 'Sensitive permission, please double-check.'),
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy.add(perm));
    try {
      await ref.read(permissionsRepoProvider).setUser(widget.member['user_id'].toString(), perm, value == 'role' ? 'clear' : value);
      ref.invalidate(_overviewProvider);
      if (mounted) showSnack(context, _t(context, 'اتحفظ', 'Saved'));
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
      for (final g in _grouped(_stringList(ov['permissions']))) ...[
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Text(_groupLabel(context, g.key), style: const TextStyle(color: BrandColors.gray, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        for (final k in g.value)
          Builder(builder: (context) {
            final cur = mine[k] ?? 'role';
            final base = rolePerms.contains(k);
            final effective = cur == 'grant' ? true : (cur == 'deny' ? false : base);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_t(context, _infoOf(k).ar, _infoOf(k).en), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  _t(context, 'النتيجة: ${effective ? 'معاه' : 'مش معاه'}  ·  الدور: ${base ? 'معاه' : 'مش معاه'}',
                      'Result: ${effective ? 'allowed' : 'not allowed'}  ·  Role: ${base ? 'allowed' : 'not allowed'}'),
                  style: const TextStyle(color: BrandColors.gray, fontSize: 12.5),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: 'deny', label: Text(_t(context, 'سحب', 'Deny'))),
                      ButtonSegment(value: 'role', label: Text(_t(context, 'الدور', 'Role'))),
                      ButtonSegment(value: 'grant', label: Text(_t(context, 'زيادة', 'Grant'))),
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
