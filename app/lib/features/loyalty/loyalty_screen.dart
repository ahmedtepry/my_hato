import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
        if (mounted) await _showPop(context, '+${r['points']} ${_t(context, 'نقطة', 'points')}', _t(context, 'اتضافت لرصيدك ✨', 'added to your balance ✨'));
      });

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(loyaltyProvider);
    ref.listen<AsyncValue<Map<String, dynamic>>>(loyaltyProvider, (_, next) {
      final v = next.valueOrNull;
      if (v != null) _showNewAwards(v);
    });
    return DefaultTabController(
      length: 3,
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
              Tab(text: _t(context, 'مستواك', 'Your level')),
              Tab(text: _t(context, 'هدايايا', 'My gifts')),
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
                _LevelsTab(d: d),
                _Gifts(d: d),
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

// ---------------------------------------------------------------------------------------------
// "Your level": the badge changes shape with every level; levels you passed are crossed out and ticked,
// the next ones stay hidden (name and points are secret).
// ---------------------------------------------------------------------------------------------
const _badgeColors = <List<int>>[
  [0xFFAAB4C8, 0xFF6B7488],
  [0xFFE8AE78, 0xFF9C5B2E],
  [0xFFEEF2F8, 0xFF8D99AE],
  [0xFFFFD66B, 0xFFD99A00],
  [0xFFA6ECFF, 0xFF3FA7D6],
  [0xFFC2AEFF, 0xFF6A4CE0],
  [0xFFFFADD2, 0xFFE0338A],
  [0xFFFFB07A, 0xFFEA5A14],
  [0xFF8CF5C4, 0xFF14A671],
  [0xFFFFE98A, 0xFFE23D52],
];

class _LevelsTab extends StatelessWidget {
  const _LevelsTab({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final levels = _list(d['levels']);
    final cur = Map<String, dynamic>.from(d['level'] as Map);
    final curSort = (cur['sort'] as num).toInt();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      const SizedBox(height: 8),
      Center(child: _LevelBadge(sort: curSort, size: 132, glow: true)),
      const SizedBox(height: 12),
      Center(child: Text(_t(context, 'أنت دلوقتي في مستوى', 'You are at level'), style: const TextStyle(color: Colors.white70))),
      Center(child: Text(context.pick(cur, 'name'), style: const TextStyle(color: _gold, fontSize: 30, fontWeight: FontWeight.w900))),
      const SizedBox(height: 18),
      Text(_t(context, 'رحلتك', 'Your journey'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: 8),
      for (final l in levels) _LevelRow(level: l),
    ]);
  }
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({required this.level});
  final Map<String, dynamic> level;
  @override
  Widget build(BuildContext context) {
    final sort = (level['sort'] as num).toInt();
    final state = level['state'] as String;
    final passed = state == 'passed', current = state == 'current';
    final name = state == 'locked' ? '؟؟؟' : context.pick(level, 'name');
    return _panel(
      margin: const EdgeInsets.only(bottom: 8),
      border: current ? _gold : null,
      child: Row(children: [
        _LevelBadge(sort: sort, size: 46, locked: state == 'locked', dim: passed),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            name,
            style: TextStyle(
              color: current ? _gold : (passed ? Colors.white54 : Colors.white38),
              fontWeight: FontWeight.w800,
              fontSize: 17,
              decoration: passed ? TextDecoration.lineThrough : null,
              decorationColor: Colors.white70,
              decorationThickness: 2.5,
            ),
          ),
        ),
        if (passed)
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle_rounded, color: Color(0xFF3DDC97), size: 20),
            const SizedBox(width: 4),
            Text(_t(context, 'عدّيته', 'Passed'), style: const TextStyle(color: Color(0xFF3DDC97), fontWeight: FontWeight.w700)),
          ])
        else if (current)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(20)),
            child: Text(_t(context, 'أنت هنا', 'You are here'), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 12.5)),
          )
        else
          const Icon(Icons.lock_rounded, color: Colors.white30, size: 20),
      ]),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.sort, required this.size, this.locked = false, this.dim = false, this.glow = false});
  final int sort;
  final double size;
  final bool locked, dim, glow;
  @override
  Widget build(BuildContext context) {
    final c = _badgeColors[(sort - 1).clamp(0, _badgeColors.length - 1)];
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: glow ? BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(c[0]).withValues(alpha: 0.55), blurRadius: 36, spreadRadius: 2)]) : const BoxDecoration(),
        child: CustomPaint(
          painter: _BadgePainter(sort: sort, top: Color(c[0]), bottom: Color(c[1]), locked: locked, dim: dim),
          child: Center(
            child: locked
                ? Icon(Icons.lock_rounded, color: Colors.white38, size: size * 0.38)
                : Text('$sort', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.36, shadows: const [Shadow(color: Colors.black45, blurRadius: 4)])),
          ),
        ),
      ),
    );
  }
}

/// Each level has its own outline: circle, triangle, diamond, pentagon, hexagon, then stars with more and more points.
class _BadgePainter extends CustomPainter {
  _BadgePainter({required this.sort, required this.top, required this.bottom, required this.locked, required this.dim});
  final int sort;
  final Color top, bottom;
  final bool locked, dim;

  Path _poly(Offset c, double r, int n) {
    final p = Path();
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + 2 * math.pi * i / n;
      final o = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
      if (i == 0) {
        p.moveTo(o.dx, o.dy);
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    return p..close();
  }

  Path _star(Offset c, double r, int n, double inner) {
    final p = Path();
    for (var i = 0; i < n * 2; i++) {
      final rr = i.isEven ? r : r * inner;
      final a = -math.pi / 2 + math.pi * i / n;
      final o = Offset(c.dx + rr * math.cos(a), c.dy + rr * math.sin(a));
      if (i == 0) {
        p.moveTo(o.dx, o.dy);
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 * 0.94;
    final path = switch (sort) {
      1 => (Path()..addOval(Rect.fromCircle(center: c, radius: r * 0.92))),
      2 => _poly(c, r, 3),
      3 => _poly(c, r, 4),
      4 => _poly(c, r, 5),
      5 => _poly(c, r, 6),
      6 => _star(c, r, 5, 0.52),
      7 => _star(c, r, 6, 0.58),
      8 => _star(c, r, 8, 0.66),
      9 => _star(c, r, 12, 0.76),
      _ => _star(c, r, 16, 0.84),
    };
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: locked ? const [Color(0xFF2A3350), Color(0xFF1B2238)] : [top.withValues(alpha: dim ? 0.55 : 1), bottom.withValues(alpha: dim ? 0.55 : 1)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, fill);
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = size.width * 0.03..color = Colors.white.withValues(alpha: locked ? 0.12 : 0.5));
    if (sort >= 10 && !locked) {
      canvas.drawCircle(c, r * 0.5, Paint()..style = PaintingStyle.stroke..strokeWidth = size.width * 0.025..color = Colors.white.withValues(alpha: 0.55));
    }
  }

  @override
  bool shouldRepaint(covariant _BadgePainter o) => o.sort != sort || o.locked != locked || o.dim != dim;
}
