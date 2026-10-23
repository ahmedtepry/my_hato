import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

/// MYHATO SECRET VAULT. All numbers come from the server (loyalty_dashboard); the app can only ask the
/// server to claim a mission or open the vault. Wording/missions/rewards are tables, editable without a new APK.
final loyaltyProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final db = ref.watch(supabaseProvider);
  return Map<String, dynamic>.from(await db.rpc('loyalty_dashboard') as Map);
});

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
List<Map<String, dynamic>> _list(Object? v) => [for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

String _loyaltyError(BuildContext c, Object e) {
  final m = e is PostgrestException ? e.message : '';
  if (m.startsWith('ALREADY_CLAIMED')) return _t(c, 'خدت المكافأة دي النهاردة', 'Already claimed for this period');
  if (m.startsWith('NOT_ELIGIBLE')) return _t(c, 'لسه ماكملتش المطلوب للمهمة', 'Mission requirement not met yet');
  if (m.startsWith('VAULT_NOT_READY')) return _t(c, 'الخزنة لسه مش جاهزة', 'The vault is not ready yet');
  if (m.startsWith('REWARD_UNAVAILABLE')) return _t(c, 'مفيش مكافآت متاحة دلوقتي، تقدمك محفوظ وحاول بعد شوية', 'No rewards available right now. Your progress is safe, try again later');
  if (m.startsWith('MISSION_NOT_FOUND')) return _t(c, 'المهمة دي مش متاحة', 'Mission unavailable');
  return friendlyError(c, e);
}

IconData _icon(String? n) => switch (n) {
      'event_available' => Icons.event_available_rounded,
      'favorite' => Icons.favorite_rounded,
      'local_fire_department' => Icons.local_fire_department_rounded,
      'smartphone' => Icons.smartphone_rounded,
      'battery_charging_full' => Icons.battery_charging_full_rounded,
      'photo_camera' => Icons.photo_camera_rounded,
      'memory' => Icons.memory_rounded,
      _ => Icons.star_rounded,
    };

const _gold = Color(0xFFF5B83D);

class LoyaltyScreen extends ConsumerStatefulWidget {
  const LoyaltyScreen({super.key});
  @override
  ConsumerState<LoyaltyScreen> createState() => _LoyaltyScreenState();
}

class _LoyaltyScreenState extends ConsumerState<LoyaltyScreen> {
  bool _busy = false; // blocks double taps while the server is working

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) showSnack(context, _loyaltyError(context, e), error: true);
    } finally {
      ref.invalidate(loyaltyProvider); // always reconcile with the server, even after an uncertain failure
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim(Map<String, dynamic> m) => _run(() async {
        final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('loyalty_claim', params: {'p_mission': m['key']}) as Map);
        if (mounted) showSnack(context, _t(context, '+${r['points']} نقطة وشحنت الخزنة 🔋', '+${r['points']} points, vault charged 🔋'));
      });

  Future<void> _openVault() => _run(() async {
        final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('loyalty_open_vault') as Map);
        if (!mounted) return;
        await showDialog<void>(context: context, builder: (_) => _RewardDialog(reward: r));
      });

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(loyaltyProvider);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: BrandColors.navyDeep,
        appBar: AppBar(
          backgroundColor: BrandColors.navyDeep,
          foregroundColor: Colors.white,
          title: const Text('MYHATO SECRET VAULT', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1, fontSize: 16)),
          actions: [IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: () => ref.invalidate(loyaltyProvider), icon: const Icon(Icons.refresh_rounded))],
          bottom: TabBar(
            indicatorColor: BrandColors.electric,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(text: _t(context, 'المهام', 'Missions')),
              Tab(text: _t(context, 'موبايلي', 'My phone')),
              Tab(text: _t(context, 'الخزنة', 'Vault')),
              Tab(text: _t(context, 'مكافآتي', 'Rewards')),
            ],
          ),
        ),
        body: data.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(loyaltyProvider)),
          data: (d) => Column(children: [
            _Header(d: d),
            Expanded(
              child: TabBarView(children: [
                _Missions(d: d, busy: _busy, onClaim: _claim),
                _Phone(d: d),
                _Vault(d: d, busy: _busy, onOpen: _openVault),
                _Wallet(d: d),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

Widget _panel({required Widget child, EdgeInsets? margin, Color? border}) => Container(
      margin: margin ?? const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF10386B), Color(0xFF0B2548)], begin: Alignment.topRight, end: Alignment.bottomLeft),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border ?? BrandColors.electric.withValues(alpha: 0.35)),
      ),
      child: child,
    );

class _Bar extends StatelessWidget {
  const _Bar(this.value, {this.color = BrandColors.electric});
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value.clamp(0, 1).toDouble()),
          duration: const Duration(milliseconds: 600),
          builder: (_, v, __) => LinearProgressIndicator(value: v, minHeight: 9, backgroundColor: Colors.white12, valueColor: AlwaysStoppedAnimation(color)),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final lvl = Map<String, dynamic>.from(d['level'] as Map);
    final next = d['next_level'] == null ? null : Map<String, dynamic>.from(d['next_level'] as Map);
    final pts = d['points'] as int;
    final from = lvl['min_points'] as int;
    final to = next?['min_points'] as int?;
    return _panel(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.workspace_premium_rounded, color: _gold, size: 30),
          const SizedBox(width: 8),
          Expanded(child: Text(context.pick(lvl, 'name'), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900))),
          Text('$pts ${_t(context, 'نقطة', 'pts')}', style: const TextStyle(color: _gold, fontWeight: FontWeight.w900, fontSize: 18)),
        ]),
        const SizedBox(height: 10),
        _Bar(to == null ? 1 : (pts - from) / (to - from), color: _gold),
        const SizedBox(height: 6),
        Text(
          next == null
              ? _t(context, 'وصلت لأعلى مستوى 👑', 'You reached the top level 👑')
              : _t(context, 'باقي ${to! - pts} نقطة على ${context.pick(next, 'name')}', '${to! - pts} points to ${context.pick(next, 'name')}'),
          style: const TextStyle(color: Colors.white70, fontSize: 12.5),
        ),
        if (lvl['perk_ar'] != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(context.pick(lvl, 'perk'), style: const TextStyle(color: Colors.white54, fontSize: 12))),
      ]),
    );
  }
}

class _Missions extends StatelessWidget {
  const _Missions({required this.d, required this.busy, required this.onClaim});
  final Map<String, dynamic> d;
  final bool busy;
  final Future<void> Function(Map<String, dynamic>) onClaim;
  @override
  Widget build(BuildContext context) {
    final ms = _list(d['missions']);
    final done = ms.where((m) => m['status'] == 'claimed').length;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(_t(context, 'خلصت $done من ${ms.length} مهام', '$done of ${ms.length} missions done'), style: const TextStyle(color: Colors.white70)),
      ),
      for (final m in ms)
        _panel(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(children: [
            CircleAvatar(backgroundColor: Colors.white12, child: Icon(_icon(m['icon'] as String?), color: BrandColors.electric)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.pick(m, 'title'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                Text(context.pick(m, 'desc'), style: const TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 4),
                Text('+${m['points']} ${_t(context, 'نقطة', 'pts')}  •  +${m['vault']} ${_t(context, 'شحن', 'charge')}${m['component'] != null ? '  •  ${_t(context, 'جزء موبايل', 'phone part')}' : ''}',
                    style: const TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
            const SizedBox(width: 8),
            switch (m['status']) {
              'claimed' => const Icon(Icons.check_circle_rounded, color: BrandColors.success, size: 30),
              'ready' => FilledButton(onPressed: busy ? null : () => onClaim(m), child: Text(_t(context, 'استلم', 'Claim'))),
              _ => Text(_t(context, 'لسه', 'To do'), style: const TextStyle(color: Colors.white54)),
            },
          ]),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(_t(context, 'طلباتك المدفوعة والمستلمة بتحسب نقاط وشحن لوحدها.', 'Paid, delivered orders add points and charge automatically.'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ),
    ]);
  }
}

class _Phone extends StatelessWidget {
  const _Phone({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final comps = _list(d['components']);
    final tier = Map<String, dynamic>.from(d['tier'] as Map);
    final next = d['next_tier'] == null ? null : Map<String, dynamic>.from(d['next_tier'] as Map);
    final owned = d['parts_owned'] as int;
    final total = comps.length;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      _panel(
        child: Column(children: [
          // the phone gets more complete as parts are collected
          SizedBox(
            height: 150,
            child: Stack(alignment: Alignment.center, children: [
              Icon(Icons.smartphone_rounded, size: 150, color: Color.lerp(Colors.white24, BrandColors.electric, total == 0 ? 0 : owned / total)),
              Positioned(
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(20)),
                    child: Text(context.pick(tier, 'name'), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900)),
                  )),
            ]),
          ),
          const SizedBox(height: 8),
          Text(
            next == null
                ? _t(context, 'موبايلك وصل لأعلى مستوى 🔥', 'Your phone is fully upgraded 🔥')
                : _t(context, 'اجمع ${next['min_parts'] - owned} جزء كمان عشان يبقى «${context.pick(next, 'name')}»', 'Collect ${next['min_parts'] - owned} more part(s) to reach ${context.pick(next, 'name')}'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ]),
      ),
      for (final c in comps)
        _panel(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          border: (c['qty'] as int) > 0 ? BrandColors.success : null,
          child: Row(children: [
            Icon(_icon(c['icon'] as String?), color: (c['qty'] as int) > 0 ? BrandColors.success : Colors.white38, size: 28),
            const SizedBox(width: 12),
            Expanded(child: Text(context.pick(c, 'name'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
            Text((c['qty'] as int) > 0 ? '×${c['qty']}' : _t(context, 'لسه', 'Missing'), style: TextStyle(color: (c['qty'] as int) > 0 ? BrandColors.success : Colors.white54, fontWeight: FontWeight.w800)),
          ]),
        ),
    ]);
  }
}

class _Vault extends StatelessWidget {
  const _Vault({required this.d, required this.busy, required this.onOpen});
  final Map<String, dynamic> d;
  final bool busy;
  final Future<void> Function() onOpen;
  @override
  Widget build(BuildContext context) {
    final p = d['vault_progress'] as int, req = d['vault_required'] as int;
    final ready = p >= req;
    final label = ready
        ? _t(context, 'جاهزة للفتح', 'Ready to open')
        : p == 0
            ? _t(context, 'مقفولة', 'Locked')
            : p >= req * 0.75
                ? _t(context, 'قربت تجهز', 'Almost ready')
                : _t(context, 'بتتشحن', 'Charging');
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      _panel(
        child: Column(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            padding: const EdgeInsets.all(26),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white10,
              boxShadow: [if (ready) BoxShadow(color: _gold.withValues(alpha: 0.6), blurRadius: 36, spreadRadius: 4)],
            ),
            child: Icon(ready ? Icons.lock_open_rounded : Icons.lock_rounded, size: 84, color: ready ? _gold : BrandColors.electric),
          ),
          const SizedBox(height: 14),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          _Bar(p / req, color: ready ? _gold : BrandColors.electric),
          const SizedBox(height: 6),
          Text('${p.clamp(0, req)} / $req', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: ready ? _gold : null, foregroundColor: ready ? Colors.black : null, minimumSize: const Size.fromHeight(50)),
              onPressed: ready && !busy ? onOpen : null,
              icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.vpn_key_rounded),
              label: Text(ready ? _t(context, 'افتح الخزنة', 'Open the vault') : _t(context, 'كمّل المهام عشان تشحنها', 'Finish missions to charge it')),
            ),
          ),
          const SizedBox(height: 8),
          Text(_t(context, 'المكافأة بتتحدد من السيرفر لحظة الفتح، ومفيش حاجة مضمونة قبلها.', 'The reward is picked by the server when you open it; nothing is promised before.'),
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ]),
      ),
    ]);
  }
}

String _rewardText(BuildContext c, Map<String, dynamic> r) {
  final off = r['percent_off'] != null ? '${r['percent_off']}%' : formatEgp(r['amount_off_minor'] as int?, c.lang);
  final min = (r['min_order_minor'] as int? ?? 0);
  return _t(c, 'خصم $off${min > 0 ? ' على طلب من ${formatEgp(min, c.lang)}' : ''}', '$off off${min > 0 ? ' on orders from ${formatEgp(min, c.lang)}' : ''}');
}

String _date(BuildContext c, Object? iso) => iso == null ? '' : DateFormat.yMMMd(c.lang).format(DateTime.parse(iso as String).toLocal());

class _RewardDialog extends StatelessWidget {
  const _RewardDialog({required this.reward});
  final Map<String, dynamic> reward;
  @override
  Widget build(BuildContext context) {
    final code = reward['code'] as String;
    return AlertDialog(
      backgroundColor: BrandColors.navy,
      icon: const Icon(Icons.card_giftcard_rounded, color: _gold, size: 56),
      title: Text(context.pick(reward, 'name'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900), textAlign: TextAlign.center),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_rewardText(context, reward), style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: code));
            showSnack(context, _t(context, 'اتنسخ الكود', 'Code copied'));
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(border: Border.all(color: _gold), borderRadius: BorderRadius.circular(12)),
            child: Text(code, style: const TextStyle(color: _gold, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2)),
          ),
        ),
        const SizedBox(height: 8),
        Text(_t(context, 'صالح لحد ${_date(context, reward['expires_at'])} • استخدام واحد', 'Valid until ${_date(context, reward['expires_at'])} • single use'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'OK'))),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            context.go('/cart?coupon=$code');
          },
          child: Text(_t(context, 'استخدمه في السلة', 'Use in cart')),
        ),
      ],
    );
  }
}

class _Wallet extends StatefulWidget {
  const _Wallet({required this.d});
  final Map<String, dynamic> d;
  @override
  State<_Wallet> createState() => _WalletState();
}

class _WalletState extends State<_Wallet> {
  String _f = 'all';
  @override
  Widget build(BuildContext context) {
    final all = _list(widget.d['wallet']);
    final rows = [for (final w in all) if (_f == 'all' || w['status'] == _f) w];
    final filters = {
      'all': _t(context, 'الكل', 'All'),
      'available': _t(context, 'متاح', 'Available'),
      'used': _t(context, 'اتستخدم', 'Used'),
      'expired': _t(context, 'انتهى', 'Expired'),
    };
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Wrap(spacing: 8, children: [
          for (final e in filters.entries)
            ChoiceChip(label: Text(e.value), selected: _f == e.key, onSelected: (_) => setState(() => _f = e.key)),
        ]),
      ),
      if (rows.isEmpty)
        Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(_t(context, 'مفيش مكافآت هنا لسه', 'No rewards here yet'), style: const TextStyle(color: Colors.white60)))),
      for (final w in rows)
        _panel(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          border: w['status'] == 'available' ? _gold : Colors.white24,
          child: Row(children: [
            Icon(Icons.local_activity_rounded, color: w['status'] == 'available' ? _gold : Colors.white38, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_rewardText(context, w), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                Text(w['status'] == 'available' ? _t(context, 'لحد ${_date(context, w['expires_at'])}', 'Until ${_date(context, w['expires_at'])}') : filters[w['status']]!,
                    style: const TextStyle(color: Colors.white60, fontSize: 12)),
                if (w['status'] == 'available')
                  SelectableText(w['code'] as String, style: const TextStyle(color: _gold, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              ]),
            ),
            if (w['status'] == 'available')
              FilledButton(onPressed: () => context.go('/cart?coupon=${w['code']}'), child: Text(_t(context, 'استخدم', 'Use'))),
          ]),
        ),
    ]);
  }
}
