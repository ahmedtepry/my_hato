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
        HapticFeedback.mediumImpact();
        if (mounted) await _showPop(context, '+${r['points']} ${_t(context, 'نقطة', 'points')}', _t(context, 'والخزنة اتشحنت +${r['vault']} 🔋', 'and the vault charged +${r['vault']} 🔋'));
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
    return DefaultTabController(
      length: 3,
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
              Tab(text: _t(context, 'الخزنة', 'Vault')),
              Tab(text: _t(context, 'سجل المكافآت', 'Rewards')),
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
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: pts),
            duration: const Duration(milliseconds: 900),
            builder: (_, v, __) => Text('$v ${_t(context, 'نقطة', 'pts')}', style: const TextStyle(color: _gold, fontWeight: FontWeight.w900, fontSize: 18)),
          ),
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
                Text('+${m['points']} ${_t(context, 'نقطة', 'pts')}  •  +${m['vault']} ${_t(context, 'شحن', 'charge')}',
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
          _VaultIcon(ready: ready),
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
          Text(_t(context, 'عدد النقاط بيتحدد من السيرفر لحظة الفتح، ومفيش حاجة مضمونة قبلها.', 'The server picks your points when you open it; nothing is promised before.'),
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

class _VaultIcon extends StatefulWidget {
  const _VaultIcon({required this.ready});
  final bool ready;
  @override
  State<_VaultIcon> createState() => _VaultIconState();
}

class _VaultIconState extends State<_VaultIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final k = widget.ready ? Curves.easeInOut.transform(_c.value) : 0.0;
          return Transform.scale(
            scale: 1 + 0.05 * k,
            child: Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white10,
                boxShadow: [if (widget.ready) BoxShadow(color: _gold.withValues(alpha: 0.35 + 0.35 * k), blurRadius: 24 + 22 * k, spreadRadius: 2 + 4 * k)],
              ),
              child: Icon(widget.ready ? Icons.lock_open_rounded : Icons.lock_rounded, size: 84, color: widget.ready ? _gold : BrandColors.electric),
            ),
          );
        },
      );
}

/// Full-screen opening: the vault shakes while the server decides, then rays + confetti + counting points.
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
                builder: (_, child) => Transform.rotate(angle: (_shake.value - 0.5) * 0.28, child: child),
                child: Container(
                  padding: const EdgeInsets.all(30),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white10, boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.5), blurRadius: 40, spreadRadius: 4)]),
                  child: const Icon(Icons.lock_rounded, size: 100, color: _gold),
                ),
              ),
              const SizedBox(height: 28),
              Text(_t(context, 'بنفتح الخزنة...', 'Opening the vault...'), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            ] else ...[
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 900),
                curve: Curves.elasticOut,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: const Icon(Icons.card_giftcard_rounded, color: _gold, size: 120),
              ),
              const SizedBox(height: 8),
              AnimatedBuilder(
                animation: _burst,
                builder: (_, __) {
                  final t = Curves.easeOutCubic.transform((_burst.value * 2.2).clamp(0.0, 1.0));
                  return Text('+${((r['points'] as int) * t).round()}', style: const TextStyle(color: _gold, fontSize: 64, fontWeight: FontWeight.w900, shadows: [Shadow(color: Color(0xAAF5B83D), blurRadius: 24)]));
                },
              ),
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

class _History extends StatelessWidget {
  const _History({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final rows = _list(d['history']);
    if (rows.isEmpty) {
      return Center(child: Text(_t(context, 'لسه ماافتحتش الخزنة', 'You have not opened the vault yet'), style: const TextStyle(color: Colors.white60)));
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
