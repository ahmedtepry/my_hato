import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

/// MYHATO SECRET VAULT. All numbers come from the server (loyalty_dashboard); the app can only ask the
/// server to claim a mission or open the reward box. Wording/missions/rewards are tables, editable without a new APK.
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
  if (m.startsWith('VAULT_NOT_READY')) return _t(c, 'العلبة لسه مش جاهزة', 'The box is not ready yet');
  if (m.startsWith('REWARD_UNAVAILABLE')) return _t(c, 'مفيش مكافآت متاحة دلوقتي، تقدمك محفوظ وحاول بعد شوية', 'No rewards available right now. Your progress is safe, try again later');
  if (m.startsWith('MISSION_NOT_FOUND')) return _t(c, 'المهمة دي مش متاحة', 'Mission unavailable');
  return friendlyError(c, e);
}

IconData _icon(String? n) => switch (n) {
      'event_available' => Icons.event_available_rounded,
      'favorite' => Icons.favorite_rounded,
      'local_fire_department' => Icons.local_fire_department_rounded,
      'rate_review' => Icons.rate_review_rounded,
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

  bool _awarding = false;

  /// Level prizes the customer has not seen yet: ONE congratulation screen (for the highest new level),
  /// marked as seen before it opens so it can never come back, even if the app is closed while it shows.
  Future<void> _showNewAwards(Map<String, dynamic> d) async {
    if (_awarding) return;
    final fresh = _list(d['awards']).where((a) => a['new'] == true).toList();
    if (fresh.isEmpty) return;
    _awarding = true;
    try {
      try {
        await ref.read(supabaseProvider).rpc('loyalty_ack_awards');
      } catch (_) {
        return; // could not mark as seen: do not show, so it never repeats; the next refresh tries again
      }
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black87,
        transitionDuration: const Duration(milliseconds: 250),
        transitionBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        pageBuilder: (_, __, ___) => _AwardReveal(award: fresh.last, more: fresh.length - 1),
      );
    } finally {
      _awarding = false;
      ref.invalidate(loyaltyProvider);
    }
  }

  Future<void> _claim(Map<String, dynamic> m) => _run(() async {
        final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('loyalty_claim', params: {'p_mission': m['key']}) as Map);
        HapticFeedback.mediumImpact();
        if (mounted) await _showPop(context, '+${r['points']} ${_t(context, 'نقطة', 'points')}', _t(context, 'اتضافت لرصيدك وقرّبتك من العلبة 🎁', 'added to your balance, closer to the box 🎁'));
      });

  Future<void> _openVault() => _run(() async {
        HapticFeedback.mediumImpact();
        final fut = ref.read(supabaseProvider).rpc('loyalty_open_vault').then((v) => Map<String, dynamic>.from(v as Map));
        await showGeneralDialog<void>(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.black87,
          transitionDuration: const Duration(milliseconds: 250),
          transitionBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
          pageBuilder: (_, __, ___) => _VaultOpening(future: fut),
        );
        await fut; // if the opening failed the dialog closed itself; surface the error here
      });

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(loyaltyProvider);
    ref.listen<AsyncValue<Map<String, dynamic>>>(loyaltyProvider, (_, next) {
      final v = next.valueOrNull;
      if (v != null) _showNewAwards(v);
    });
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: BrandColors.navyDeep,
        appBar: AppBar(
          backgroundColor: BrandColors.navyDeep,
          foregroundColor: Colors.white,
          title: Text(_t(context, 'مكافآت My Hatō', 'My Hatō Rewards'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 17)),
          actions: [IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: () => ref.invalidate(loyaltyProvider), icon: const Icon(Icons.refresh_rounded))],
          bottom: TabBar(
            indicatorColor: BrandColors.electric,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(text: _t(context, 'المهام', 'Missions')),
              Tab(text: _t(context, 'العلبة', 'Box')),
              Tab(text: _t(context, 'هدايايا', 'My gifts')),
              Tab(text: _t(context, 'السجل', 'History')),
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
                _Vault(d: d, busy: _busy, onOpen: _openVault),
                _Gifts(d: d),
                _History(d: d),
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
    final pts = d['points'] as int;
    return _panel(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(children: [
        const Icon(Icons.workspace_premium_rounded, color: _gold, size: 30),
        const SizedBox(width: 8),
        Expanded(child: Text(context.pick(lvl, 'name'), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900))),
        TweenAnimationBuilder<int>(
          tween: IntTween(begin: 0, end: pts),
          duration: const Duration(milliseconds: 900),
          builder: (_, v, __) => Text('$v ${_t(context, 'نقطة', 'pts')}', style: const TextStyle(color: _gold, fontWeight: FontWeight.w900, fontSize: 18)),
        ),
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
    final ms0 = ms.where((m) => m['status'] != 'auto').toList();
    final done = ms0.where((m) => m['status'] == 'claimed').length;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(_t(context, 'خلصت $done من ${ms0.length} مهام النهاردة', '$done of ${ms0.length} missions done'), style: const TextStyle(color: Colors.white70)),
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
                Text('+${m['points']} ${_t(context, 'نقطة', 'pts')}',
                    style: const TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
            const SizedBox(width: 8),
            switch (m['status']) {
              'claimed' => const Icon(Icons.check_circle_rounded, color: BrandColors.success, size: 30),
              'auto' => Text(_t(context, 'تلقائي', 'Auto'), style: const TextStyle(color: BrandColors.electric, fontWeight: FontWeight.w800)),
              'ready' => FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(84, 40), padding: const EdgeInsets.symmetric(horizontal: 16)), onPressed: busy ? null : () => onClaim(m), child: Text(_t(context, 'استلم', 'Claim'))),
              _ => Text(_t(context, 'لسه', 'To do'), style: const TextStyle(color: Colors.white54)),
            },
          ]),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(_t(context, 'طلباتك المستلمة وتقييماتك المنشورة بتضيف نقاط لوحدها.', 'Delivered orders and published reviews add points automatically.'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
        ? _t(context, 'العلبة جاهزة تتفتح 🎁', 'Your box is ready 🎁')
        : p == 0
            ? _t(context, 'ابدأ اجمع نقاط', 'Start earning points')
            : p >= req * 0.75
                ? _t(context, 'قربت تجهز', 'Almost ready')
                : _t(context, 'البطارية بتتملي', 'Battery filling up');
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      _panel(
        child: Column(children: [
          _BatteryPhone(progress: (p / req).clamp(0.0, 1.0).toDouble(), ready: ready, style: (d['boxes_opened'] as int? ?? 0).clamp(0, 5).toInt()),
          const SizedBox(height: 14),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          _Bar(p / req, color: ready ? _gold : BrandColors.electric),
          const SizedBox(height: 6),
          Text('${(p / req * 100).clamp(0, 100).floor()}%', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: ready ? _gold : null, foregroundColor: ready ? Colors.black : null, minimumSize: const Size.fromHeight(50)),
              onPressed: ready && !busy ? onOpen : null,
              icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.inventory_2_rounded),
              label: Text(ready ? _t(context, 'افتح العلبة', 'Open the box') : _t(context, 'اجمع نقاط عشان تفتحها', 'Earn points to open it')),
            ),
          ),
          const SizedBox(height: 8),
          Text(_t(context, 'كل نقطة بتكسبها بتملّي بطارية الموبايل. لما تكمل ١٠٠٪ تفتح العلبة، وعدد النقاط اللي جواها بيتحدد من السيرفر لحظة الفتح.', 'Every point you earn charges the phone battery. At 100% you can open the box, and the server picks the points inside when you open it.'),
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ]),
      ),
    ]);
  }
}

String _date(BuildContext c, Object? iso) => iso == null ? '' : DateFormat.yMMMd(c.lang).add_Hm().format(DateTime.parse(iso as String).toLocal());

/// Small "+points" card that pops in, then closes by itself.
Future<void> _showPop(BuildContext context, String big, String small) {
  final nav = Navigator.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 450),
    transitionBuilder: (_, a, __, child) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.elasticOut), child: FadeTransition(opacity: a, child: child)),
    pageBuilder: (ctx, __, ___) {
      Future.delayed(const Duration(milliseconds: 1700), () {
        if (ctx.mounted && nav.canPop()) Navigator.of(ctx).pop();
      });
      return Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
            decoration: BoxDecoration(
              color: BrandColors.navy,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: _gold),
              boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.45), blurRadius: 30)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.stars_rounded, color: _gold, size: 54),
              const SizedBox(height: 6),
              Text(big, style: const TextStyle(color: _gold, fontSize: 30, fontWeight: FontWeight.w900)),
              Text(small, style: const TextStyle(color: Colors.white70)),
            ]),
          ),
        ),
      );
    },
  );
}

/// A phone whose battery fills with points. After each opened box the phone itself changes look
/// (thick bezels -> notch -> punch hole -> edge-to-edge -> gold finish); the new box starts again at 0%.
class _BatteryPhone extends StatefulWidget {
  const _BatteryPhone({required this.progress, required this.ready, required this.style});
  final double progress;
  final bool ready;
  final int style; // 0..5
  @override
  State<_BatteryPhone> createState() => _BatteryPhoneState();
}

class _BatteryPhoneState extends State<_BatteryPhone> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const _radius = [12.0, 16.0, 20.0, 24.0, 26.0, 28.0];
  static const _bezel = [12.0, 9.0, 7.0, 6.0, 4.0, 3.0];
  static const _frame = [Color(0xFF8A94A6), Color(0xFFB8C4D6), Color(0xFFD5DDEA), Color(0xFF7FD3FF), Color(0xFFF1D58A), _gold];

  Widget _top(int s) => switch (s) {
        0 => Container(width: 26, height: 4, decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3))), // speaker slit
        1 => Container(width: 44, height: 12, decoration: const BoxDecoration(color: Colors.black, borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)))), // wide notch
        2 => Container(width: 22, height: 10, decoration: const BoxDecoration(color: Colors.black, borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)))), // small notch
        _ => Container(margin: const EdgeInsets.only(top: 5), width: 8, height: 8, decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle)), // punch hole
      };

  Widget _phone(double k) {
    final s = widget.style;
    final color = widget.ready ? _gold : BrandColors.electric;
    return Container(
      key: ValueKey(s),
      width: 104,
      height: 178,
      padding: EdgeInsets.all(_bezel[s]),
      decoration: BoxDecoration(
        color: const Color(0xFF05080F),
        borderRadius: BorderRadius.circular(_radius[s]),
        border: Border.all(color: _frame[s], width: s >= 4 ? 3.5 : 3),
        boxShadow: [
          if (s >= 3) BoxShadow(color: _frame[s].withValues(alpha: 0.25), blurRadius: 14),
          if (widget.ready) BoxShadow(color: _gold.withValues(alpha: 0.35 + 0.35 * k), blurRadius: 22 + 20 * k, spreadRadius: 1 + 4 * k),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius[s] - _bezel[s] / 2 - 2),
        child: Stack(alignment: Alignment.center, children: [
          Container(color: Colors.white10),
          Align(
            alignment: Alignment.bottomCenter,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: widget.progress),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (_, v, __) => FractionallySizedBox(
                heightFactor: v,
                widthFactor: 1,
                child: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withValues(alpha: 0.35), color], begin: Alignment.bottomCenter, end: Alignment.topCenter))),
              ),
            ),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.bolt_rounded, color: Colors.white, size: 40 + 6 * k),
            Text('${(widget.progress * 100).floor()}%', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
          ]),
          Align(alignment: Alignment.topCenter, child: _top(s)),
          if (s >= 2) Align(alignment: Alignment.bottomCenter, child: Container(margin: const EdgeInsets.only(bottom: 4), width: 30, height: 3, decoration: BoxDecoration(color: Colors.white54, borderRadius: BorderRadius.circular(3)))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final k = widget.ready ? Curves.easeInOut.transform(_c.value) : 0.0;
          return Transform.scale(
            scale: 1 + 0.04 * k,
            // a new box opened -> the phone flips to its next look
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              transitionBuilder: (child, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)), child: child)),
              child: _phone(k),
            ),
          );
        },
      );
}

/// Phone box: the lid flies off and the phone rises out with its screen showing the points.
class _BoxArt extends StatelessWidget {
  const _BoxArt({this.lid = 0, this.phone = 0, this.glow = 0, this.text});
  final double lid, phone, glow;
  final String? text;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 230,
        height: 340,
        child: Stack(alignment: Alignment.bottomCenter, children: [
          Positioned(
            bottom: -50 + phone * 175,
            child: Container(
              width: 92,
              height: 154,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(color: const Color(0xFF0B0F18), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white70, width: 2.5)),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  gradient: LinearGradient(colors: [Color.lerp(const Color(0xFF0B0F18), BrandColors.navy, glow)!, Color.lerp(const Color(0xFF0B0F18), BrandColors.electric, glow)!], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                  boxShadow: [BoxShadow(color: BrandColors.electric.withValues(alpha: 0.7 * glow), blurRadius: 30 * glow)],
                ),
                alignment: Alignment.center,
                child: Opacity(opacity: glow, child: Text(text ?? '', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, shadows: [Shadow(color: Colors.white54, blurRadius: 12)]))),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            child: Container(
              width: 190,
              height: 100,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
                gradient: const LinearGradient(colors: [Color(0xFF123F7A), BrandColors.navyDeep], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                border: Border.all(color: BrandColors.electric.withValues(alpha: 0.7)),
              ),
              child: const Text('My Hatō', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1)),
            ),
          ),
          Positioned(
            bottom: 100 + lid * 110,
            left: 20 + lid * 70,
            child: Opacity(
              opacity: (1 - lid * 0.7).clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: lid * 0.7,
                child: Container(
                  width: 200,
                  height: 28,
                  decoration: BoxDecoration(color: BrandColors.electric, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white54)),
                ),
              ),
            ),
          ),
        ]),
      );
}

/// Full-screen opening: the phone box shakes while the server decides, then the lid flies off and the phone shows the points.
class _VaultOpening extends StatefulWidget {
  const _VaultOpening({required this.future});
  final Future<Map<String, dynamic>> future;
  @override
  State<_VaultOpening> createState() => _VaultOpeningState();
}

class _VaultOpeningState extends State<_VaultOpening> with TickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 90))..repeat(reverse: true);
  late final AnimationController _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
  Map<String, dynamic>? _r;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Future.wait<Object?>([widget.future, Future<void>.delayed(const Duration(milliseconds: 1700))]);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      _shake.stop();
      setState(() => _r = res[0] as Map<String, dynamic>);
      _burst.forward();
    } catch (_) {
      if (mounted) Navigator.of(context).pop(); // caller shows the error
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return PopScope(
      canPop: r != null,
      child: Material(
        color: Colors.transparent,
        child: Stack(alignment: Alignment.center, children: [
          if (r != null) Positioned.fill(child: AnimatedBuilder(animation: _burst, builder: (_, __) => CustomPaint(painter: _BurstPainter(_burst.value)))),
          Column(mainAxisSize: MainAxisSize.min, children: [
            if (r == null) ...[
              AnimatedBuilder(
                animation: _shake,
                builder: (_, child) => Transform.rotate(angle: (_shake.value - 0.5) * 0.2, child: child),
                child: const _BoxArt(),
              ),
              const SizedBox(height: 16),
              Text(_t(context, 'بنفتح العلبة...', 'Opening your box...'), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            ] else ...[
              AnimatedBuilder(
                animation: _burst,
                builder: (_, __) {
                  final v = _burst.value;
                  double seg(double a, double b, Curve c) => c.transform(((v - a) / (b - a)).clamp(0.0, 1.0));
                  final count = (r['points'] as int) * seg(0.3, 0.6, Curves.easeOutCubic);
                  return _BoxArt(lid: seg(0, 0.15, Curves.easeOut), phone: seg(0.08, 0.38, Curves.easeOutBack), glow: seg(0.25, 0.4, Curves.easeIn), text: '+${count.round()}');
                },
              ),
              const SizedBox(height: 12),
              Text(_t(context, 'نقطة اتضافت لرصيدك 🎉', 'points added to your balance 🎉'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 28),
              FadeTransition(
                opacity: CurvedAnimation(parent: _burst, curve: const Interval(0.3, 0.5)),
                child: FilledButton(style: FilledButton.styleFrom(backgroundColor: _gold, foregroundColor: Colors.black, minimumSize: const Size(180, 50)), onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'Awesome'))),
              ),
            ],
          ]),
        ]),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  _BurstPainter(this.t);
  final double t;
  static final _rnd = math.Random(7);
  static final _p = List.generate(70, (i) => (angle: _rnd.nextDouble() * math.pi * 2, speed: 160 + _rnd.nextDouble() * 320, size: 5 + _rnd.nextDouble() * 7, spin: _rnd.nextDouble() * 8, hue: i % 4));
  static const _colors = [_gold, BrandColors.electric, Colors.white, Color(0xFF12B76A)];

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2 - 40);
    // slow rotating light rays
    final ray = Paint()..color = _gold.withValues(alpha: 0.10 * (1 - t));
    for (var i = 0; i < 12; i++) {
      final a = t * 1.2 + i * math.pi / 6;
      canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy)
          ..lineTo(c.dx + math.cos(a - 0.1) * size.height, c.dy + math.sin(a - 0.1) * size.height)
          ..lineTo(c.dx + math.cos(a + 0.1) * size.height, c.dy + math.sin(a + 0.1) * size.height)
          ..close(),
        ray,
      );
    }
    // confetti: flies out, then gravity pulls it down while it fades
    final life = (t * 1.4).clamp(0.0, 1.0);
    for (final p in _p) {
      final x = c.dx + math.cos(p.angle) * p.speed * life;
      final y = c.dy + math.sin(p.angle) * p.speed * life + 420 * life * life;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * life * 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 1.6), const Radius.circular(2)),
        Paint()..color = _colors[p.hue].withValues(alpha: (1 - life * life).clamp(0.0, 1.0)),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.t != t;
}

class _Gifts extends StatelessWidget {
  const _Gifts({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final gifts = _list(d['awards']);
    if (gifts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(_t(context, 'كمّل تجمع نقاط، ولو كسبت هدية هتظهر هنا 🎁', 'Keep earning points. If you win a gift it will show up here 🎁'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      for (final g in gifts)
        _panel(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          border: _gold,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.card_giftcard_rounded, color: _gold, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text(_t(context, 'هدية مستوى ${context.pick(g, 'name')}', '${context.pick(g, 'name')} level gift'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))),
              if (g['status'] == 'delivered') Text('✅ ${_t(context, 'اتسلمت', 'Delivered')}', style: const TextStyle(color: BrandColors.success, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 8),
            if (context.pick(g, 'prize').isNotEmpty)
              Text('🎁 ${context.pick(g, 'prize')}', style: const TextStyle(color: _gold, fontSize: 16, fontWeight: FontWeight.w800)),
            Text(context.pick(g, 'status'), style: const TextStyle(color: Colors.white70)),
            if (g['status'] != 'delivered') ...[
              const SizedBox(height: 8),
              _CodeChip(code: g['code'] as String),
            ],
          ]),
        ),
    ]);
  }
}

class _CodeChip extends StatelessWidget {
  const _CodeChip({required this.code});
  final String code;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Clipboard.setData(ClipboardData(text: code));
          HapticFeedback.selectionClick();
          showSnack(context, _t(context, 'اتنسخ الكود', 'Code copied'));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(border: Border.all(color: _gold), borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(code, style: const TextStyle(color: _gold, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2)),
            const SizedBox(width: 10),
            const Icon(Icons.copy_rounded, color: _gold, size: 20),
          ]),
        ),
      );
}

/// Shown once when a gift is won. It never names the gift: the customer copies the code and asks the store.
class _AwardReveal extends StatefulWidget {
  const _AwardReveal({required this.award, this.more = 0});
  final Map<String, dynamic> award;
  final int more; // other new gifts that are listed in the Gifts tab
  @override
  State<_AwardReveal> createState() => _AwardRevealState();
}

class _AwardRevealState extends State<_AwardReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..forward();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.award;
    return PopScope(
      canPop: false,
      child: Material(
        color: Colors.transparent,
        child: Stack(alignment: Alignment.center, children: [
          Positioned.fill(child: AnimatedBuilder(animation: _c, builder: (_, __) => CustomPaint(painter: _BurstPainter(_c.value)))),
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 900),
                curve: Curves.elasticOut,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: const Icon(Icons.card_giftcard_rounded, color: _gold, size: 120),
              ),
              Text(_t(context, 'مبروك! وصلت لمستوى', 'Congratulations! You reached'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
              Text(context.pick(a, 'name'), style: const TextStyle(color: _gold, fontSize: 36, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Text(_t(context, 'وعندك هدية من My Hatō 🎁', 'and you have a gift from My Hatō 🎁'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 16),
              _CodeChip(code: a['code'] as String),
              const SizedBox(height: 12),
              Text(_t(context, 'انسخ الكود وابعتهولنا واكتب: «اسأل عن هديتي»', 'Copy the code, send it to us and write: "asking about my gift"'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
              if (widget.more > 0) ...[
                const SizedBox(height: 10),
                Text(_t(context, 'وعندك كمان ${widget.more} ${widget.more == 1 ? 'هدية' : 'هدايا'} تانية، هتلاقيها في «هدايايا»', 'plus ${widget.more} more gift${widget.more == 1 ? '' : 's'} in "My gifts"'),
                    textAlign: TextAlign.center, style: const TextStyle(color: _gold, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 22),
              FadeTransition(
                opacity: CurvedAnimation(parent: _c, curve: const Interval(0.3, 0.5)),
                child: FilledButton(style: FilledButton.styleFrom(backgroundColor: _gold, foregroundColor: Colors.black, minimumSize: const Size(180, 50)), onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'Awesome'))),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final rows = _list(d['history']);
    if (rows.isEmpty) {
      return Center(child: Text(_t(context, 'لسه ماافتحتش أي علبة مكافآت', 'You have not opened any reward box yet'), style: const TextStyle(color: Colors.white60)));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      for (final r in rows)
        _panel(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(children: [
            const Icon(Icons.card_giftcard_rounded, color: _gold, size: 28),
            const SizedBox(width: 12),
            Expanded(child: Text(_date(context, r['at']), style: const TextStyle(color: Colors.white70))),
            Text('+${r['points']} ${_t(context, 'نقطة', 'pts')}', style: const TextStyle(color: _gold, fontWeight: FontWeight.w900, fontSize: 16)),
          ]),
        ),
    ]);
  }
}
