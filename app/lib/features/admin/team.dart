// Team (owner only): live board of the team — who is online right now, who is away, who is offline,
// last sign-in, what each member did today — plus creating accounts with any login name + password,
// changing roles, new passwords, instant suspend / resume and removal.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

// ---------------------------------------------------------------- roles
class TeamRole {
  const TeamRole(this.key, this.ar, this.en, this.icon, this.color, this.canAr, this.canEn);
  final String key, ar, en;
  final IconData icon;
  final Color color;
  final List<String> canAr, canEn;
  String label(BuildContext c) => c.isAr ? ar : en;
  List<String> can(BuildContext c) => c.isAr ? canAr : canEn;
}

const teamRoles = <TeamRole>[
  TeamRole('sales', 'فريق المبيعات', 'Sales team', Icons.point_of_sale_rounded, BrandColors.electric,
      ['الطلبات وتحديث حالتها ورسايل العميل', 'المنتجات والأسعار والمخزون واستلام البضاعة', 'العروض وأكواد الخصم', 'تنبيه بكل طلب جديد'],
      ['Orders, status updates and customer messages', 'Products, prices, stock and receiving goods', 'Offers and discount codes', 'Alert for every new order']),
  TeamRole('technician', 'فريق الصيانة', 'Repair team', Icons.build_circle_rounded, BrandColors.warning,
      ['كل طلبات الصيانة وتحديث حالة الجهاز', 'تحديد التكلفة ورسايل العميل', 'تنبيه بكل طلب صيانة جديد'],
      ['All repairs and device status', 'Quotes and customer messages', 'Alert for every new repair']),
  TeamRole('manager', 'مدير', 'Manager', Icons.manage_accounts_rounded, BrandColors.navy,
      ['كل اللي فات (مبيعات + صيانة)', 'تفعيل حسابات العملاء ومراجعة التقييمات', 'ما عدا إدارة الفريق'],
      ['Everything above (sales + repairs)', 'Approve accounts and moderate reviews', 'Except managing the team']),
  TeamRole('support', 'خدمة عملاء', 'Support', Icons.support_agent_rounded, BrandColors.success,
      ['متابعة الطلبات والصيانة (عرض بس)', 'تفعيل حسابات العملاء'], ['View orders and repairs', 'Approve customer accounts']),
  TeamRole('owner', 'مالك', 'Owner', Icons.workspace_premium_rounded, Color(0xFF7A5AF8),
      ['كل الصلاحيات بما فيها الفريق'], ['Every permission, including the team']),
];

TeamRole roleOf(String? key) => teamRoles.firstWhere((r) => r.key == key, orElse: () => teamRoles.first);

// ---------------------------------------------------------------- data
class TeamRepository {
  TeamRepository(this._db);
  final SupabaseClient _db;

  Future<List<Map<String, dynamic>>> team() async => List<Map<String, dynamic>>.from(await _db.rpc('staff_team_live') as List);

  Future<List<Map<String, dynamic>>> activity(String userId) async =>
      List<Map<String, dynamic>>.from(await _db.rpc('staff_member_activity', params: {'p_user_id': userId}) as List);

  Future<bool> loginAvailable(String login) async => await _db.rpc('staff_login_available', params: {'p_login': login}) == true;

  Future<List<Map<String, dynamic>>> findCustomer(String q) async =>
      List<Map<String, dynamic>>.from(await _db.rpc('staff_find_customer', params: {'p_query': q}) as List);

  Future<void> assignRole(String userId, String role) => _db.rpc('staff_assign_role', params: {'p_user_id': userId, 'p_role': role});

  Future<void> remove(String userId) => _db.rpc('staff_remove_member', params: {'p_user_id': userId});

  Future<void> _fn(Map<String, dynamic> body) async {
    try {
      final res = await _db.functions.invoke('admin-staff', body: body);
      final data = res.data;
      if (data is Map && data['ok'] != true) throw Exception(data['error'] ?? 'FAILED');
    } on FunctionException catch (e) {
      final d = e.details;
      throw Exception(d is Map ? (d['error'] ?? 'FAILED') : 'FAILED');
    }
  }

  Future<void> create({required String login, required String password, required String role, String? fullName, String? phone}) =>
      _fn({'action': 'create', 'login': login, 'password': password, 'role': role, 'full_name': fullName, 'phone': phone});

  Future<void> resetPassword(String userId, String password) => _fn({'action': 'reset_password', 'user_id': userId, 'password': password});

  Future<void> setSuspended(String userId, bool suspended) => _fn({'action': 'suspend', 'user_id': userId, 'suspended': suspended});
}

final teamRepoProvider = Provider((ref) => TeamRepository(ref.watch(supabaseProvider)));
final _teamProvider = FutureProvider.autoDispose((ref) => ref.watch(teamRepoProvider).team());

String _teamError(BuildContext context, Object e) {
  final m = e.toString();
  String? pick(String code, String ar, String en) => m.contains(code) ? _t(context, ar, en) : null;
  return pick('USERNAME_TAKEN', 'اسم الدخول ده مستخدم قبل كده', 'This login name is taken') ??
      pick('PHONE_TAKEN', 'رقم الموبايل ده على حساب تاني', 'Phone already used') ??
      pick('INVALID_USERNAME', 'اسم الدخول من ٢ لـ ٤٠ حرف ومن غير @', 'Login name: 2–40 characters, no @') ??
      pick('INVALID_PHONE', 'رقم موبايل مصري مش صحيح', 'Invalid Egyptian mobile') ??
      pick('WEAK_PASSWORD', 'كلمة السر ٦ حروف أو أرقام على الأقل', 'Password needs at least 6 characters') ??
      pick('CANNOT_CHANGE_OWN_ROLE', 'مينفعش تغيّر حسابك إنت', 'You cannot change your own account') ??
      pick('LAST_OWNER', 'لازم يفضل مالك واحد على الأقل', 'At least one owner must remain') ??
      friendlyError(context, e);
}

class _UserMsg implements Exception {
  _UserMsg(this.text);
  final String text;
}

String _genPassword() {
  const letters = 'abcdefghjkmnpqrstuvwxyz';
  const digits = '23456789';
  final r = Random.secure();
  return List.generate(4, (_) => letters[r.nextInt(letters.length)]).join() + List.generate(4, (_) => digits[r.nextInt(digits.length)]).join();
}

String _ago(BuildContext context, DateTime t) {
  final d = DateTime.now().difference(t);
  final ar = context.isAr;
  if (d.inSeconds < 60) return ar ? 'من ثواني' : 'seconds ago';
  if (d.inMinutes < 60) return ar ? 'من ${d.inMinutes} دقيقة' : '${d.inMinutes} min ago';
  if (d.inHours < 24) return ar ? 'من ${d.inHours} ساعة' : '${d.inHours} h ago';
  if (d.inDays == 1) return ar ? 'امبارح ${TimeOfDay.fromDateTime(t).format(context)}' : 'yesterday ${TimeOfDay.fromDateTime(t).format(context)}';
  if (d.inDays < 7) return ar ? 'من ${d.inDays} أيام' : '${d.inDays} days ago';
  return MaterialLocalizations.of(context).formatShortDate(t);
}

String _when(BuildContext context, DateTime t) =>
    '${MaterialLocalizations.of(context).formatShortDate(t)} • ${TimeOfDay.fromDateTime(t).format(context)}';

String areaLabel(BuildContext context, String? area) => switch (area) {
      'orders' => _t(context, 'في الطلبات', 'in Orders'),
      'repairs' => _t(context, 'في الصيانة', 'in Repairs'),
      'products' => _t(context, 'في المنتجات', 'in Products'),
      'reviews' => _t(context, 'في التقييمات', 'in Reviews'),
      'accounts' => _t(context, 'في الحسابات', 'in Accounts'),
      'overview' => _t(context, 'في النظرة العامة', 'on Overview'),
      'team' => _t(context, 'في الفريق', 'in Team'),
      'offers' => _t(context, 'في العروض', 'in Offers'),
      'store' => _t(context, 'في المتجر', 'in the store'),
      _ => '',
    };

String actionLabel(BuildContext context, String? a) {
  final ar = context.isAr;
  const m = {
    'order.status': ['غيّر حالة طلب', 'Changed an order status'],
    'order.update': ['عدّل طلب', 'Edited an order'],
    'order.closed': ['قفل عملية طلب', 'Closed an order'],
    'repair.status': ['غيّر حالة صيانة', 'Changed a repair status'],
    'repair.update': ['عدّل صيانة', 'Edited a repair'],
    'repair.details': ['كتب تشخيص صيانة', 'Wrote a diagnosis'],
    'repair.quote': ['حدّد تكلفة صيانة', 'Set a repair quote'],
    'repair.quote_decision': ['سجّل رد على تكلفة', 'Recorded a quote decision'],
    'repair.assign': ['سلّم صيانة لفني', 'Assigned a repair'],
    'repair.closed': ['قفل عملية صيانة', 'Closed a repair'],
    'cancel.approved': ['وافق على إلغاء', 'Approved a cancellation'],
    'cancel.rejected': ['رفض إلغاء', 'Rejected a cancellation'],
    'inventory.adjust': ['عدّل مخزون', 'Adjusted stock'],
    'coupon.save': ['حفظ كود خصم', 'Saved a discount code'],
    'offer.broadcast': ['بعت عرض للعملاء', 'Sent an offer'],
    'customer.approve': ['فعّل حساب عميل', 'Approved an account'],
    'customer.reject': ['رفض حساب عميل', 'Rejected an account'],
    'customer.password_reset': ['غيّر باسورد عميل', 'Reset a customer password'],
    'review.approve': ['وافق على تقييم', 'Approved a review'],
    'review.remove': ['شال تقييم', 'Removed a review'],
    'staff.assign': ['غيّر صلاحية عضو', 'Changed a member role'],
    'staff.grant': ['أضاف صلاحية', 'Granted a role'],
    'staff.revoke': ['شال صلاحية', 'Revoked a role'],
    'staff.remove': ['شال عضو من الفريق', 'Removed a member'],
    'staff.suspend': ['أوقف عضو', 'Suspended a member'],
    'staff.resume': ['رجّع عضو', 'Resumed a member'],
    'staff.password_reset': ['غيّر باسورد عضو', 'Reset a member password'],
  };
  final v = m[a];
  if (v != null) return ar ? v[0] : v[1];
  return a ?? '';
}

void openTeam(BuildContext context) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TeamScreen()));

// ---------------------------------------------------------------- presence look
(Color, String) _presence(BuildContext context, String p) => switch (p) {
      'online' => (BrandColors.success, _t(context, 'أونلاين', 'Online')),
      'away' => (BrandColors.warning, _t(context, 'بعيد', 'Away')),
      'suspended' => (BrandColors.error, _t(context, 'موقوف', 'Suspended')),
      _ => (const Color(0xFF98A2B3), _t(context, 'أوفلاين', 'Offline')),
    };

class _PresenceDot extends StatefulWidget {
  const _PresenceDot({required this.presence, this.size = 14});
  final String presence;
  final double size;
  @override
  State<_PresenceDot> createState() => _PresenceDotState();
}

class _PresenceDotState extends State<_PresenceDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _PresenceDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.presence == 'online') {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, _) = _presence(context, widget.presence);
    final s = widget.size;
    return SizedBox(
      width: s * 2,
      height: s * 2,
      child: Stack(alignment: Alignment.center, children: [
        if (widget.presence == 'online')
          AnimatedBuilder(
            animation: _c,
            builder: (_, __) => Container(
              width: s + s * _c.value,
              height: s + s * _c.value,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.35 * (1 - _c.value))),
            ),
          ),
        Container(
          width: s,
          height: s,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color, border: Border.all(color: Colors.white, width: 2.5)),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- screen
class TeamScreen extends ConsumerStatefulWidget {
  const TeamScreen({super.key});
  @override
  ConsumerState<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends ConsumerState<TeamScreen> {
  Timer? _timer;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    // live board: refresh every 20 seconds while open
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => ref.invalidate(_teamProvider));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_teamProvider);
    final list = data.valueOrNull ?? const <Map<String, dynamic>>[];
    int count(String p) => list.where((m) => m['presence'] == p).length;
    final shown = _filter == 'all' ? list : list.where((m) => m['presence'] == _filter || (_filter == 'offline' && m['presence'] == 'suspended')).toList();

    return Scaffold(
      appBar: AppBar(title: Text(_t(context, 'فريق العمل', 'Team'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addMember(context, ref),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(_t(context, 'حساب جديد للفريق', 'New team account')),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(_teamProvider),
        child: data.isLoading && list.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : data.hasError && list.isEmpty
                ? ErrorView(error: data.error!, onRetry: () => ref.invalidate(_teamProvider))
                : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
                    // live header
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: const LinearGradient(colors: [BrandColors.navyDeep, BrandColors.navy], begin: Alignment.topRight, end: Alignment.bottomLeft),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const _PresenceDot(presence: 'online', size: 10),
                          const SizedBox(width: 4),
                          Text(_t(context, 'مباشر', 'Live'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                          const Spacer(),
                          Text(_t(context, '${list.length} عضو', '${list.length} members'), style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12.5)),
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          for (final p in ['online', 'away', 'offline'])
                            Expanded(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => setState(() => _filter = _filter == p ? 'all' : p),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  margin: const EdgeInsetsDirectional.only(end: 8),
                                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: _filter == p ? 0.22 : 0.08),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text('${p == 'offline' ? count('offline') + count('suspended') : count(p)}',
                                        style: TextStyle(color: _presence(context, p).$1, fontSize: 24, fontWeight: FontWeight.w900)),
                                    Text(_presence(context, p).$2, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                                  ]),
                                ),
                              ),
                            ),
                        ]),
                      ]),
                    ),
                    const SizedBox(height: 14),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(30),
                        child: Center(child: Text(_t(context, 'مفيش حد هنا دلوقتي', 'Nobody here right now'))),
                      ),
                    for (final m in shown) _MemberCard(key: ValueKey(m['user_id']), member: m),
                  ]),
      ),
    );
  }
}

class _MemberCard extends ConsumerWidget {
  const _MemberCard({super.key, required this.member});
  final Map<String, dynamic> member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = member;
    final role = roleOf(m['role'] as String?);
    final me = m['is_me'] == true;
    final presence = m['presence'] as String? ?? 'offline';
    final (pColor, _) = _presence(context, presence);
    final name = ((m['full_name'] as String?) ?? '').trim();
    final login = m['username'] as String?;
    final lastSeen = m['last_seen_at'] == null ? null : DateTime.parse(m['last_seen_at'] as String).toLocal();
    final lastIn = m['last_sign_in_at'] == null ? null : DateTime.parse(m['last_sign_in_at'] as String).toLocal();
    final today = (m['actions_today'] as num?)?.toInt() ?? 0;
    final area = areaLabel(context, m['area'] as String?);

    final statusLine = switch (presence) {
      'online' => me ? _t(context, 'إنت • أونلاين دلوقتي', 'You • online now') : '${_t(context, 'أونلاين دلوقتي', 'Online now')}${area.isEmpty ? '' : ' • $area'}',
      'away' => '${_t(context, 'بعيد', 'Away')} • ${_t(context, 'آخر ظهور', 'last seen')} ${_ago(context, lastSeen!)}',
      'suspended' => _t(context, 'الحساب موقوف', 'Account suspended'),
      _ => lastSeen == null ? _t(context, 'لسه مفتحش التطبيق', 'Has not opened the app yet') : '${_t(context, 'آخر ظهور', 'Last seen')} ${_ago(context, lastSeen)}',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: presence == 'online' ? BrandColors.success.withValues(alpha: 0.45) : BrandColors.border),
        ),
        child: InkWell(
          onTap: () => _openMember(context, ref, m),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Stack(clipBehavior: Clip.none, children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: role.color.withValues(alpha: 0.12),
                    child: Text(name.isEmpty ? '?' : name.characters.first,
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 19, color: role.color)),
                  ),
                  PositionedDirectional(end: -8, bottom: -8, child: _PresenceDot(presence: presence, size: 13)),
                ]),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name.isEmpty ? (login ?? '—') : name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                    const SizedBox(height: 2),
                    Text(statusLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: pColor, fontWeight: FontWeight.w700)),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(color: role.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(role.icon, size: 14, color: role.color),
                    const SizedBox(width: 4),
                    Text(role.label(context), style: TextStyle(color: role.color, fontWeight: FontWeight.w800, fontSize: 11.5)),
                  ]),
                ),
              ]),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: BrandColors.offWhite, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(
                    child: _MiniStat(
                      icon: Icons.login_rounded,
                      label: _t(context, 'آخر تسجيل دخول', 'Last sign-in'),
                      value: lastIn == null ? '—' : _ago(context, lastIn),
                    ),
                  ),
                  Container(width: 1, height: 28, color: BrandColors.border),
                  Expanded(
                    child: _MiniStat(
                      icon: Icons.bolt_rounded,
                      label: _t(context, 'شغل النهارده', 'Today'),
                      value: today == 0 ? _t(context, 'لسه', 'none yet') : _t(context, '$today عملية', '$today actions'),
                    ),
                  ),
                ]),
              ),
              if ((m['last_action'] as String?) != null && m['last_action_at'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    const Icon(Icons.history_rounded, size: 15, color: BrandColors.gray),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${actionLabel(context, m['last_action'] as String?)} • ${_ago(context, DateTime.parse(m['last_action_at'] as String).toLocal())}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: BrandColors.gray),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          Icon(icon, size: 16, color: BrandColors.navy),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 10.5, color: BrandColors.gray)),
              Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
      );
}

// ---------------------------------------------------------------- member details
Future<void> _openMember(BuildContext context, WidgetRef ref, Map<String, dynamic> m) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _MemberSheet(member: m),
  );
  ref.invalidate(_teamProvider);
}

class _MemberSheet extends ConsumerStatefulWidget {
  const _MemberSheet({required this.member});
  final Map<String, dynamic> member;
  @override
  ConsumerState<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends ConsumerState<_MemberSheet> {
  late Future<List<Map<String, dynamic>>> _activity = ref.read(teamRepoProvider).activity(widget.member['user_id'] as String);
  bool _busy = false;
  late bool _suspended = widget.member['suspended'] == true;
  late String _role = widget.member['role'] as String? ?? 'sales';

  Map<String, dynamic> get m => widget.member;
  String get _id => m['user_id'] as String;

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) {
        showSnack(context, done);
        setState(() => _activity = ref.read(teamRepoProvider).activity(_id));
      }
    } catch (e) {
      if (mounted) showSnack(context, _teamError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeRole() async {
    final role = await _pickRole(context, current: _role);
    if (role == null || role == _role || !mounted) return;
    await _run(() async {
      await ref.read(teamRepoProvider).assignRole(_id, role);
      _role = role;
    }, _t(context, 'اتغيّرت الصلاحية لـ ${roleOf(role).ar} ✅', 'Role changed to ${roleOf(role).en} ✅'));
  }

  Future<void> _newPassword() async {
    final pw = await showDialog<String>(context: context, builder: (_) => const _PasswordDialog());
    if (pw == null || !mounted) return;
    await _run(() async {
      await ref.read(teamRepoProvider).resetPassword(_id, pw);
      await Clipboard.setData(ClipboardData(text: pw));
    }, _t(context, 'اتغيّرت كلمة السر واتنسخت ✅', 'Password changed and copied ✅'));
  }

  Future<void> _toggleSuspend() async {
    final to = !_suspended;
    final ok = !to ||
        await showDialog<bool>(
              context: context,
              builder: (d) => AlertDialog(
                icon: const Icon(Icons.pause_circle_rounded, color: BrandColors.error, size: 36),
                title: Text(_t(context, 'إيقاف الحساب؟', 'Suspend account?')),
                content: Text(_t(context, 'هيتمنع فورًا من كل الصلاحيات ومن تسجيل الدخول، لحد ما ترجّعه.', 'They lose every permission and cannot sign in until you resume them.')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(context, 'رجوع', 'Back'))),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
                    onPressed: () => Navigator.pop(d, true),
                    child: Text(_t(context, 'إيقاف', 'Suspend')),
                  ),
                ],
              ),
            ) ==
            true;
    if (!ok || !mounted) return;
    await _run(() async {
      await ref.read(teamRepoProvider).setSuspended(_id, to);
      _suspended = to;
    }, to ? _t(context, 'اتوقف الحساب ⏸️', 'Suspended ⏸️') : _t(context, 'رجع الحساب يشتغل ▶️', 'Resumed ▶️'));
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(context, 'إزالة من الفريق؟', 'Remove from team?')),
        content: Text(_t(context, 'هيتشال من الفريق ومش هيقدر يدخل لوحة الفريق تاني.', 'They will no longer have console access.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(context, 'رجوع', 'Back'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            onPressed: () => Navigator.pop(d, true),
            child: Text(_t(context, 'إزالة', 'Remove')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(teamRepoProvider).remove(_id);
      if (mounted) {
        Navigator.pop(context);
        showSnack(context, _t(context, 'اتشال من الفريق', 'Removed from the team'));
      }
    } catch (e) {
      if (mounted) showSnack(context, _teamError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = m['is_me'] == true;
    final role = roleOf(_role);
    final presence = _suspended ? 'suspended' : (m['presence'] as String? ?? 'offline');
    final (pColor, pLabel) = _presence(context, presence);
    final name = ((m['full_name'] as String?) ?? '').trim();
    final login = m['username'] as String?;
    final phone = m['phone'] as String?;
    DateTime? dt(String k) => m[k] == null ? null : DateTime.parse(m[k] as String).toLocal();
    final lastSeen = dt('last_seen_at'), lastIn = dt('last_sign_in_at'), since = dt('granted_at');
    final device = [m['platform'], m['app_version']].whereType<String>().join(' • ');

    Widget fact(IconData i, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(i, size: 18, color: BrandColors.gray),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
            const Spacer(),
            Flexible(child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
          ]),
        );

    Widget action(IconData i, String label, VoidCallback onTap, {Color? color}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                foregroundColor: color ?? BrandColors.navy,
                side: BorderSide(color: (color ?? BrandColors.navy).withValues(alpha: 0.35)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _busy ? null : onTap,
              child: Column(children: [Icon(i), const SizedBox(height: 4), Text(label, style: const TextStyle(fontSize: 11.5))]),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: ListView(shrinkWrap: true, children: [
        Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: role.color.withValues(alpha: 0.12),
              child: Text(name.isEmpty ? '?' : name.characters.first, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 28, color: role.color)),
            ),
            PositionedDirectional(end: -6, bottom: -6, child: _PresenceDot(presence: presence, size: 16)),
          ]),
          const SizedBox(height: 10),
          Text(name.isEmpty ? (login ?? '—') : name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: role.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(role.label(context), style: TextStyle(color: role.color, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: pColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(pLabel, style: TextStyle(color: pColor, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          ]),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: BrandColors.offWhite, borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            if (login != null) fact(Icons.alternate_email_rounded, _t(context, 'اسم الدخول', 'Login name'), login),
            if (phone != null) fact(Icons.phone_iphone_rounded, _t(context, 'الموبايل', 'Mobile'), phone),
            fact(Icons.login_rounded, _t(context, 'آخر تسجيل دخول', 'Last sign-in'), lastIn == null ? '—' : _when(context, lastIn)),
            fact(Icons.visibility_rounded, _t(context, 'آخر ظهور', 'Last seen'),
                presence == 'online' ? '${_t(context, 'دلوقتي', 'now')} ${areaLabel(context, m['area'] as String?)}' : (lastSeen == null ? '—' : _when(context, lastSeen))),
            if (device.isNotEmpty) fact(Icons.smartphone_rounded, _t(context, 'الجهاز / النسخة', 'Device / version'), device),
            fact(Icons.bolt_rounded, _t(context, 'عمليات النهارده', 'Actions today'), '${m['actions_today'] ?? 0}'),
            if (since != null) fact(Icons.event_available_rounded, _t(context, 'في الفريق من', 'On the team since'), MaterialLocalizations.of(context).formatShortDate(since)),
          ]),
        ),
        if (!me) ...[
          const SizedBox(height: 14),
          Row(children: [
            action(Icons.swap_horiz_rounded, _t(context, 'الصلاحية', 'Role'), _changeRole),
            action(Icons.key_rounded, _t(context, 'باسورد', 'Password'), _newPassword),
            action(_suspended ? Icons.play_circle_rounded : Icons.pause_circle_rounded, _suspended ? _t(context, 'تشغيل', 'Resume') : _t(context, 'إيقاف', 'Suspend'),
                _toggleSuspend,
                color: _suspended ? BrandColors.success : BrandColors.warning),
            action(Icons.person_remove_rounded, _t(context, 'إزالة', 'Remove'), _remove, color: BrandColors.error),
          ]),
          if (phone != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.call_rounded, size: 18),
                    label: Text(_t(context, 'اتصال', 'Call')),
                    onPressed: () => launchUrl(Uri.parse('tel:${phone.replaceAll(' ', '')}')),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF1DA851)),
                    icon: const Icon(Icons.chat_rounded, size: 18),
                    label: Text(_t(context, 'واتساب', 'WhatsApp')),
                    onPressed: () => launchUrl(Uri.parse('https://wa.me/${phone.replaceAll(RegExp(r'\D'), '')}'), mode: LaunchMode.externalApplication),
                  ),
                ),
              ]),
            ),
        ],
        if (_busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
        const SizedBox(height: 18),
        Text(_t(context, 'سجل النشاط', 'Activity log'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _activity,
          builder: (context, snap) {
            if (!snap.hasData) {
              return snap.hasError
                  ? Text(friendlyError(context, snap.error!))
                  : const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
            }
            final items = snap.data!;
            if (items.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_t(context, 'لسه مفيش نشاط مسجّل', 'No activity yet'), style: const TextStyle(color: BrandColors.gray)),
              );
            }
            return Column(children: [
              for (var i = 0; i < items.length; i++)
                IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SizedBox(
                      width: 22,
                      child: Column(children: [
                        Container(
                          width: 10,
                          height: 10,
                          margin: const EdgeInsets.only(top: 5),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: i == 0 ? role.color : BrandColors.border),
                        ),
                        if (i < items.length - 1) Expanded(child: Container(width: 2, color: BrandColors.border)),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(
                            [actionLabel(context, items[i]['action'] as String?), if ((items[i]['entity_id'] as String?) != null && (items[i]['entity_id'] as String).length < 20) items[i]['entity_id']]
                                .join(' — '),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                          ),
                          Text(_when(context, DateTime.parse(items[i]['created_at'] as String).toLocal()),
                              style: const TextStyle(fontSize: 11.5, color: BrandColors.gray)),
                        ]),
                      ),
                    ),
                  ]),
                ),
            ]);
          },
        ),
      ]),
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  late final _c = TextEditingController(text: _genPassword());
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t(context, 'كلمة سر جديدة', 'New password')),
        content: TextField(
          controller: _c,
          autofocus: true,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            helperText: _t(context, 'اكتب اللي إنت عايزه (٦ على الأقل)', 'Type anything (6+ characters)'),
            suffixIcon: IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: () => setState(() => _c.text = _genPassword())),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
          FilledButton(
            onPressed: () {
              if (_c.text.length < 6) return;
              Navigator.pop(context, _c.text);
            },
            child: Text(_t(context, 'حفظ ونسخ', 'Save & copy')),
          ),
        ],
      );
}

Future<String?> _pickRole(BuildContext context, {String? current}) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _RolePicker(current: current),
    );

class _RolePicker extends StatefulWidget {
  const _RolePicker({this.current});
  final String? current;
  @override
  State<_RolePicker> createState() => _RolePickerState();
}

class _RolePickerState extends State<_RolePicker> {
  late String _sel = widget.current ?? 'sales';
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ListView(shrinkWrap: true, children: [
          Text(_t(context, 'اختار الصلاحية', 'Choose a role'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          for (final r in teamRoles) _RoleOption(role: r, selected: _sel == r.key, onTap: () => setState(() => _sel = r.key)),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: () => Navigator.pop(context, _sel),
            child: Text(_t(context, 'تأكيد', 'Confirm')),
          ),
        ]),
      );
}

class _RoleOption extends StatelessWidget {
  const _RoleOption({required this.role, required this.selected, required this.onTap});
  final TeamRole role;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: selected ? role.color.withValues(alpha: 0.07) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? role.color : BrandColors.border, width: selected ? 2 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(role.icon, color: role.color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(role.label(context), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 4),
                    for (final c in role.can(context))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Icon(Icons.check_rounded, size: 14, color: role.color),
                          const SizedBox(width: 4),
                          Expanded(child: Text(c, style: const TextStyle(fontSize: 12.5))),
                        ]),
                      ),
                  ]),
                ),
                Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: selected ? role.color : BrandColors.gray),
              ]),
            ),
          ),
        ),
      );
}

// ---------------------------------------------------------------- new team account
Future<void> _addMember(BuildContext context, WidgetRef ref) async {
  final creds = await showModalBottomSheet<({String login, String password, String role})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const _AddMemberSheet(),
  );
  if (creds == null || !context.mounted) return;
  ref.invalidate(_teamProvider);
  final text = 'أهلاً 👋 ده حسابك في فريق My Hatō (${roleOf(creds.role).ar})\n'
      'اسم الدخول: ${creds.login}\nكلمة السر: ${creds.password}\n'
      'ادخل من صفحة تسجيل الدخول في التطبيق، وبعدها هتلاقي "لوحة الفريق" في حسابك.';
  await showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      icon: const Icon(Icons.verified_rounded, color: BrandColors.success, size: 44),
      title: Text(_t(context, 'الحساب جاهز 🎉', 'Account ready 🎉')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: BrandColors.offWhite, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_t(context, 'اسم الدخول', 'Login name'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            SelectableText(creds.login, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text(_t(context, 'كلمة السر', 'Password'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            SelectableText(creds.password, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 1)),
          ]),
        ),
        const SizedBox(height: 10),
        Text(_t(context, 'يدخل بيهم من صفحة تسجيل الدخول العادية.', 'They sign in from the normal sign-in page.'),
            style: const TextStyle(fontSize: 12.5, color: BrandColors.gray)),
      ]),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(_t(context, 'نسخ', 'Copy')),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            Navigator.pop(d);
            showSnack(context, _t(context, 'اتنسخت بيانات الدخول', 'Sign-in details copied'));
          },
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366)),
          icon: const Icon(Icons.chat_rounded, size: 18),
          label: Text(_t(context, 'ابعتها واتساب', 'Send on WhatsApp')),
          onPressed: () {
            Navigator.pop(d);
            launchUrl(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);
          },
        ),
      ],
    ),
  );
}

class _AddMemberSheet extends ConsumerStatefulWidget {
  const _AddMemberSheet();
  @override
  ConsumerState<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends ConsumerState<_AddMemberSheet> {
  bool _newAccount = true;
  String _role = 'sales';
  final _login = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _search = TextEditingController();
  bool _showPw = true;
  bool? _available;
  Timer? _debounce;
  List<Map<String, dynamic>>? _found;
  Map<String, dynamic>? _picked;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_login, _name, _phone, _password, _search]) {
      c.dispose();
    }
    super.dispose();
  }

  void _checkLogin(String v) {
    _debounce?.cancel();
    setState(() => _available = null);
    if (v.trim().length < 2) return;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final ok = await ref.read(teamRepoProvider).loginAvailable(v);
        if (mounted && _login.text == v) setState(() => _available = ok);
      } catch (_) {}
    });
  }

  Future<void> _find() async {
    setState(() {
      _busy = true;
      _error = null;
      _picked = null;
    });
    try {
      final r = await ref.read(teamRepoProvider).findCustomer(_search.text);
      setState(() => _found = r);
    } catch (e) {
      setState(() => _error = _teamError(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(teamRepoProvider);
    try {
      if (_newAccount) {
        final login = _login.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        if (login.length < 2) throw _UserMsg(_t(context, 'اكتب اسم الدخول', 'Enter a login name'));
        if (login.contains('@')) throw _UserMsg(_t(context, 'اسم الدخول من غير @', 'No @ in the login name'));
        if (_password.text.length < 6) throw _UserMsg(_t(context, 'كلمة السر ٦ حروف أو أرقام على الأقل', 'Password: at least 6 characters'));
        if (_available == false) throw _UserMsg(_t(context, 'اسم الدخول ده مستخدم قبل كده', 'This login name is taken'));
        await repo.create(
          login: login,
          password: _password.text,
          role: _role,
          fullName: _name.text.trim().isEmpty ? null : _name.text.trim(),
          phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        );
        if (mounted) Navigator.pop(context, (login: login, password: _password.text, role: _role));
      } else {
        if (_picked == null) throw _UserMsg(_t(context, 'اختار الحساب الأول', 'Pick an account first'));
        await repo.assignRole(_picked!['user_id'] as String, _role);
        if (mounted) {
          Navigator.pop(context);
          showSnack(context, _t(context, 'اتضاف للفريق ✅ يدخل بحسابه العادي', 'Added ✅ they sign in with their usual account'));
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is _UserMsg ? e.text : _teamError(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget? availability() {
      if (_login.text.trim().length < 2) return null;
      if (_available == null) return const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)));
      return Icon(_available! ? Icons.check_circle_rounded : Icons.cancel_rounded, color: _available! ? BrandColors.success : BrandColors.error);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: ListView(shrinkWrap: true, children: [
        Text(_t(context, 'حساب جديد للفريق', 'New team account'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(_t(context, 'اختار أي اسم دخول وأي كلمة سر، والحساب يشتغل على طول.', 'Pick any login name and password; the account works right away.'),
            style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
        const SizedBox(height: 14),
        // role first: the two main teams as big cards
        Row(children: [
          for (final r in teamRoles.take(2))
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _role = r.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _role == r.key ? r.color.withValues(alpha: 0.10) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _role == r.key ? r.color : BrandColors.border, width: _role == r.key ? 2 : 1),
                    ),
                    child: Column(children: [
                      Icon(r.icon, color: r.color, size: 30),
                      const SizedBox(height: 6),
                      Text(r.label(context), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final r in teamRoles.skip(2))
            ChoiceChip(
              avatar: Icon(r.icon, size: 16, color: r.color),
              label: Text(r.label(context)),
              selected: _role == r.key,
              onSelected: (_) => setState(() => _role = r.key),
            ),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: roleOf(_role).color.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final c in roleOf(_role).can(context))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [
                  Icon(Icons.check_rounded, size: 15, color: roleOf(_role).color),
                  const SizedBox(width: 4),
                  Expanded(child: Text(c, style: const TextStyle(fontSize: 12.5))),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, icon: const Icon(Icons.person_add_rounded), label: Text(_t(context, 'اسم وكلمة سر', 'Login + password'))),
            ButtonSegment(value: false, icon: const Icon(Icons.person_search_rounded), label: Text(_t(context, 'حساب موجود', 'Existing account'))),
          ],
          selected: {_newAccount},
          onSelectionChanged: (s) => setState(() {
            _newAccount = s.first;
            _error = null;
          }),
        ),
        const SizedBox(height: 14),
        if (_newAccount) ...[
          TextField(
            controller: _login,
            onChanged: _checkLogin,
            decoration: InputDecoration(
              labelText: _t(context, 'اسم الدخول', 'Login name'),
              hintText: _t(context, 'مثلاً: محمد مبيعات', 'e.g. Mohamed Sales'),
              prefixIcon: const Icon(Icons.person_rounded),
              suffixIcon: availability(),
              helperText: _available == false ? _t(context, 'الاسم ده مستخدم', 'Taken') : _t(context, 'أي اسم بالعربي أو الإنجليزي', 'Any name, Arabic or English'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            obscureText: !_showPw,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: _t(context, 'كلمة السر', 'Password'),
              prefixIcon: const Icon(Icons.key_rounded),
              helperText: _t(context, 'أي حاجة تختارها (٦ على الأقل)', 'Anything you like (6+)'),
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: Icon(_showPw ? Icons.visibility_off_rounded : Icons.visibility_rounded), onPressed: () => setState(() => _showPw = !_showPw)),
                IconButton(
                  tooltip: _t(context, 'اقترح كلمة سر', 'Suggest'),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  onPressed: () => setState(() {
                    _password.text = _genPassword();
                    _showPw = true;
                  }),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(_t(context, 'بيانات إضافية (اختياري)', 'More details (optional)'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            children: [
              TextField(controller: _name, decoration: InputDecoration(labelText: _t(context, 'الاسم الكامل', 'Full name'), prefixIcon: const Icon(Icons.badge_outlined))),
              const SizedBox(height: 10),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: _t(context, 'الموبايل', 'Mobile'), prefixIcon: const Icon(Icons.phone_iphone_rounded)),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ] else ...[
          Row(children: [
            Expanded(
              child: TextField(
                controller: _search,
                textDirection: TextDirection.ltr,
                onSubmitted: (_) => _find(),
                decoration: InputDecoration(
                  labelText: _t(context, 'موبايل / اسم مستخدم / إيميل / MHC', 'Phone / username / email / MHC'),
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(64, 52)), onPressed: _busy ? null : _find, child: Text(_t(context, 'بحث', 'Find'))),
          ]),
          if (_found != null && _found!.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(_t(context, 'مفيش حساب بالبيانات دي (أو هو أصلاً في الفريق)', 'No matching account (or already on the team)'))),
          for (final c in _found ?? const <Map<String, dynamic>>[])
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Material(
                color: _picked == c ? BrandColors.navy.withValues(alpha: 0.06) : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: _picked == c ? BrandColors.navy : BrandColors.border, width: _picked == c ? 2 : 1),
                ),
                child: ListTile(
                  onTap: () => setState(() => _picked = c),
                  leading: const Icon(Icons.person_rounded),
                  title: Text((c['full_name'] as String?) ?? (c['username'] as String?) ?? '—'),
                  subtitle: Text([c['customer_code'], c['phone'], c['username']].whereType<String>().join(' • '), textDirection: TextDirection.ltr),
                  trailing: _picked == c ? const Icon(Icons.check_circle_rounded, color: BrandColors.navy) : null,
                ),
              ),
            ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w700))),
        const SizedBox(height: 14),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
              : Text(_newAccount ? _t(context, 'إنشاء الحساب', 'Create account') : _t(context, 'إضافة للفريق', 'Add to team')),
        ),
      ]),
    );
  }
}
