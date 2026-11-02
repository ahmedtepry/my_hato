// The daily lucky wheel (customer side). The server picks the winning slice and pays it; this screen only shows the wheel, spins it to the answer
// and lists the gifts won. Look: light "gifts" style (pastel slices, white borders, pink rim, 🎁 hub, confetti on a win).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../shared/states.dart';
import '../admin/feature_switches.dart';
import '../orders/orders_repository.dart' show pendingCouponProvider;

final wheelStateProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  ref.watch(currentUserProvider);
  final flags = await ref.watch(featureFlagsProvider.future);
  if (flags['wheel'] != true) throw 'FEATURE_OFF';
  return Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('wheel_state') as Map);
});

String _wheelError(BuildContext c, Object e) {
  final t = '$e';
  final ar = c.isAr;
  if (t.contains('NOT_VERIFIED')) return ar ? 'وثّق حسابك (الإيميل أو الموبايل) عشان تلف العجلة.' : 'Verify your account (email or phone) to spin.';
  if (t.contains('NOT_APPROVED')) return ar ? 'حسابك لسه قيد المراجعة. هتقدر تلف أول ما يتفعّل.' : 'Your account is still being reviewed.';
  if (t.contains('NEEDS_ORDER')) return ar ? 'اشتري أي حاجة من المحل، وهتكون ليك فرصة تكسب أي حاجة من الموجودة في العجلة 🎁' : 'Buy anything from the shop and you get a chance to win anything on the wheel 🎁';
  if (t.contains('NO_SPINS_LEFT')) return ar ? 'خلّصت لفّات النهارده. ارجع بكرة!' : 'No spins left today. Come back tomorrow!';
  if (t.contains('FEATURE_OFF')) return ar ? 'العجلة مش متاحة دلوقتي.' : 'The wheel is not available right now.';
  return ar ? 'حصلت مشكلة، جرّب تاني.' : 'Something went wrong, try again.';
}

const _pastel = [Color(0xFFFDA4AF), Color(0xFFFCD34D), Color(0xFF86EFAC), Color(0xFF93C5FD), Color(0xFFC4B5FD), Color(0xFFFDBA74), Color(0xFFF9A8D4), Color(0xFF5EEAD4)];
const _ink = Color(0xFF4C0519);

class WheelScreen extends ConsumerStatefulWidget {
  const WheelScreen({super.key});
  @override
  ConsumerState<WheelScreen> createState() => _WheelScreenState();
}

class _WheelScreenState extends ConsumerState<WheelScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 4800));
  double _from = 0, _to = 0, _theta = 0;
  bool _busy = false;
  bool _confetti = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(() => setState(() => _theta = _from + (_to - _from) * Curves.easeOutCubic.transform(_ctl.value)));
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _spin(List<Map<String, dynamic>> segs) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('wheel_spin') as Map);
      final i = segs.indexWhere((s) => s['id'] == r['segment_id']);
      final a = 2 * math.pi / segs.length;
      final jitter = (math.Random().nextDouble() - .5) * a * .6;
      final target = -(i < 0 ? 0 : i + .5) * a + jitter;
      final cur = _theta % (2 * math.pi);
      _from = _theta;
      _to = _theta + ((target - cur) % (2 * math.pi)) + 2 * math.pi * 6;
      await _ctl.forward(from: 0);
      if (!mounted) return;
      final kind = '${r['kind']}';
      if (kind == 'points' || kind == 'gift' || kind == 'again' || kind == 'discount') {
        setState(() => _confetti = true);
        Future.delayed(const Duration(milliseconds: 2200), () {
          if (mounted) setState(() => _confetti = false);
        });
      }
      await _showResult(r);
      ref.invalidate(wheelStateProvider);
    } catch (e) {
      if (mounted) setState(() => _error = _wheelError(context, e));
      ref.invalidate(wheelStateProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _useVoucher(String code) {
    ref.read(pendingCouponProvider.notifier).state = code.toUpperCase();
    context.go('/cart');
  }

  Future<void> _showResult(Map<String, dynamic> r) {
    final ar = context.isAr;
    final label = ar ? '${r['label_ar']}' : '${r['label_en']}';
    final (emoji, title, body) = switch ('${r['kind']}') {
      'points' => ('⭐', ar ? 'مبروك! كسبت $label' : 'You won $label', ar ? 'النقاط اتضافت لحسابك.' : 'The points were added to your account.'),
      'gift' => ('🎁', ar ? 'مبروك! كسبت $label' : 'You won $label', ar ? 'هنكلّمك لتسليمها، أو تعالى استلمها من المحل.' : 'We will contact you, or pick it up from the shop.'),
      'discount' => ('🏷️', ar ? 'مبروك! كسبت $label' : 'You won $label', ar ? 'الخصم محفوظ في حسابك لمدة ${r['valid_hours']} ساعة، ويُستخدم مرة واحدة بس. استخدمه في طلبك.' : 'Saved in your account for ${r['valid_hours']} hours, one-time use. Use it on your order.'),
      'again' => ('🔁', ar ? 'لفّة تانية!' : 'Spin again!', ar ? 'لف تاني من غير ما تتحسب.' : 'One more spin for free.'),
      _ => ('🍀', ar ? 'حظ أوفر المرة دي' : 'Better luck next time', ar ? 'ارجع بكرة والعجلة مستنياك.' : 'Come back tomorrow, the wheel is waiting.'),
    };
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Column(children: [Text(emoji, style: const TextStyle(fontSize: 44)), const SizedBox(height: 4), Text(title, textAlign: TextAlign.center)]),
        content: Text(body, textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ar ? 'تمام' : 'OK')),
          if (r['voucher'] is Map)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _useVoucher('${(r['voucher'] as Map)['code']}');
              },
              child: Text(ar ? 'استخدمه دلوقتي' : 'Use it now'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final st = ref.watch(wheelStateProvider);
    return Scaffold(
      backgroundColor: const Color(0xFFFFF1F2),
      appBar: AppBar(
        title: Text(ar ? 'عجلة الحظ 🎡' : 'Lucky wheel 🎡'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.canPop() ? context.pop() : context.go('/')),
      ),
      body: st.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_wheelError(context, e), textAlign: TextAlign.center))),
        data: (d) {
          final segs = (d['segments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final block = d['block'] as String?;
          final left = (d['spins_left'] as num?)?.toInt() ?? 0;
          final preview = d['preview'] == true;
          final gifts = (d['gifts'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final vouchers = (d['vouchers'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final canSpin = block == null && left > 0 && segs.length >= 3;
          return Stack(children: [
            ListView(padding: const EdgeInsets.all(16), children: [
              if (preview)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                  child: Text(ar ? 'معاينة للفريق: اللفّ هنا مش بيتسجل ومش بيدّي جوايز.' : 'Team preview: spins here are not recorded or paid.', style: const TextStyle(color: _ink)),
                ),
              Text(ar ? 'لفّة كل يوم، وممكن تكسب نقاط أو هدية!' : 'One spin a day. Win points or a gift!', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: _ink)),
              const SizedBox(height: 14),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Stack(alignment: Alignment.topCenter, children: [
                      Padding(padding: const EdgeInsets.only(top: 10), child: CustomPaint(size: Size.infinite, painter: _WheelPainter(segs, _theta, ar))),
                      const Icon(Icons.arrow_drop_down_rounded, size: 54, color: Color(0xFF881337)),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE11D48), padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 14), shape: const StadiumBorder()),
                  onPressed: canSpin && !_busy ? () => _spin(segs) : null,
                  child: Text(canSpin ? (ar ? 'لُفّ العجلة' : 'Spin') : block == 'NEEDS_ORDER' ? (ar ? 'اشتري الأول' : 'Buy first') : (ar ? 'ارجع بكرة' : 'Come back tomorrow'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
              ),
              if (block == 'NEEDS_ORDER')
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFECDD3))),
                    child: Column(children: [
                      Text(_wheelError(context, block!), textAlign: TextAlign.center, style: const TextStyle(color: _ink, fontWeight: FontWeight.w700, height: 1.5)),
                      const SizedBox(height: 10),
                      FilledButton.icon(onPressed: () => context.go('/'), icon: const Icon(Icons.shopping_bag_outlined), label: Text(ar ? 'تسوّق دلوقتي' : 'Shop now')),
                    ]),
                  ),
                )
              else if (block != null || _error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error ?? _wheelError(context, block!), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF9F1239))),
                ),
              if (vouchers.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text(ar ? 'خصوماتي' : 'My discounts', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: _ink)),
                const SizedBox(height: 6),
                for (final v in vouchers)
                  _VoucherCard(
                    key: ValueKey('${v['code']}-${v['seconds_left']}'),
                    voucher: v,
                    onUse: () => _useVoucher('${v['code']}'),
                    onExpired: () => ref.invalidate(wheelStateProvider),
                  ),
              ],
              if (gifts.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text(ar ? 'هداياي' : 'My gifts', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: _ink)),
                const SizedBox(height: 6),
                for (final g in gifts)
                  Card(
                    child: ListTile(
                      leading: const Text('🎁', style: TextStyle(fontSize: 26)),
                      title: Text(ar ? '${g['label_ar']}' : '${g['label_en']}'),
                      subtitle: Text('${g['created_at']}'.split('T').first),
                      trailing: Chip(label: Text(g['status'] == 'delivered' ? (ar ? 'اتسلّمت' : 'Delivered') : (ar ? 'في الانتظار' : 'Waiting'))),
                    ),
                  ),
              ],
            ]),
            if (_confetti) const IgnorePointer(child: _Confetti()),
          ]);
        },
      ),
    );
  }
}

/// A won discount: live "time remaining" countdown, one-time use, tap to use it on the next order.
class _VoucherCard extends StatefulWidget {
  const _VoucherCard({super.key, required this.voucher, required this.onUse, required this.onExpired});
  final Map<String, dynamic> voucher;
  final VoidCallback onUse, onExpired;
  @override
  State<_VoucherCard> createState() => _VoucherCardState();
}

class _VoucherCardState extends State<_VoucherCard> {
  late final DateTime _end = DateTime.now().add(Duration(seconds: (widget.voucher['seconds_left'] as num?)?.toInt() ?? 0));
  Timer? _t;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= Duration.zero && !_fired && widget.voucher['in_order'] != true) {
        _fired = true;
        widget.onExpired();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Duration get _left => _end.difference(DateTime.now());

  String _fmt(Duration d) {
    if (d.isNegative) d = Duration.zero;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final v = widget.voucher;
    final inOrder = v['in_order'] == true;
    final expired = !inOrder && _left <= Duration.zero;
    return Card(
      child: ListTile(
        leading: const Text('🏷️', style: TextStyle(fontSize: 26)),
        title: Text(ar ? 'خصم ${v['percent']}%' : '${v['percent']}% off', style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(inOrder
            ? (ar ? 'مستخدم في طلبك وبانتظار تأكيده' : 'Used on your order, waiting for confirmation')
            : expired
                ? (ar ? 'انتهت المدة' : 'Expired')
                : (ar ? 'الوقت المتبقي ${_fmt(_left)} · استعمال مرة واحدة' : 'Time remaining ${_fmt(_left)} · one-time use')),
        trailing: inOrder || expired ? null : FilledButton(onPressed: widget.onUse, child: Text(ar ? 'استخدمه' : 'Use it')),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.segs, this.theta, this.ar);
  final List<Map<String, dynamic>> segs;
  final double theta;
  final bool ar;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2;
    final c = Offset(size.width / 2, size.height / 2);
    final n = segs.length;
    if (n == 0) return;
    final a = 2 * math.pi / n;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(theta);
    final rect = Rect.fromCircle(center: Offset.zero, radius: r - 8);
    for (var i = 0; i < n; i++) {
      final lose = segs[i]['kind'] == 'lose';
      canvas.drawArc(rect, -math.pi / 2 + i * a, a, true, Paint()..color = lose ? const Color(0xFFE5E7EB) : _pastel[i % _pastel.length]);
      canvas.drawArc(rect, -math.pi / 2 + i * a, a, true, Paint()..style = PaintingStyle.stroke..strokeWidth = 4..color = Colors.white);
      canvas.save();
      canvas.rotate(i * a + a / 2 - math.pi / 2);   // x axis now points outwards through the middle of this slice
      final label = (ar ? segs[i]['label_ar'] : segs[i]['label_en']) as String? ?? '';
      final emoji = switch (segs[i]['kind']) { 'gift' => '🎁', 'points' => '⭐', 'again' => '🔁', 'discount' => '🏷️', _ => '🍀' };
      final tp = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(color: _ink, fontWeight: FontWeight.w800, fontSize: 13)),
        textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: r * .52);
      tp.paint(canvas, Offset(r * .34, -tp.height / 2));
      final ep = TextPainter(text: TextSpan(text: emoji, style: const TextStyle(fontSize: 20)), textDirection: TextDirection.ltr)..layout();
      ep.paint(canvas, Offset(r * .34 + r * .52 + 2 > r - 30 ? r - 42 : r * .34 + r * .52 + 2, -ep.height / 2));
      canvas.restore();
    }
    canvas.drawCircle(Offset.zero, r - 8, Paint()..style = PaintingStyle.stroke..strokeWidth = 8..color = const Color(0xFFFB7185));
    canvas.restore();
    canvas.drawCircle(c, 30, Paint()..color = Colors.white);
    final hub = TextPainter(text: const TextSpan(text: '🎁', style: TextStyle(fontSize: 28)), textDirection: TextDirection.ltr)..layout();
    hub.paint(canvas, c - Offset(hub.width / 2, hub.height / 2));
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.theta != theta || old.segs != segs;
}

class _Confetti extends StatefulWidget {
  const _Confetti();
  @override
  State<_Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<_Confetti> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..forward();
  final _rnd = math.Random();
  late final List<(double, double, String)> _p = List.generate(26, (i) => (_rnd.nextDouble(), _rnd.nextDouble() * 200 - 100, const ['🎉', '✨', '🎊', '⭐', '🎈'][i % 5]));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final w = MediaQuery.of(context).size.width;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Stack(children: [
        for (final p in _p)
          Positioned(
            left: p.$1 * w + p.$2 * _c.value,
            top: -30 + (h * .8) * Curves.easeIn.transform(_c.value),
            child: Opacity(opacity: 1 - _c.value * .6, child: Text(p.$3, style: const TextStyle(fontSize: 26))),
          ),
      ]),
    );
  }
}

/// Home card: shown only when the wheel is on for this user and a spin is waiting today.
class WheelBanner extends ConsumerWidget {
  const WheelBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!featureVisible(ref, 'wheel')) return const SizedBox.shrink();
    final d = ref.watch(wheelStateProvider).valueOrNull;
    if (d == null || d['preview'] == true) return const SizedBox.shrink();
    final teaser = d['block'] == 'NEEDS_ORDER';
    if (!teaser && (d['block'] != null || ((d['spins_left'] as num?)?.toInt() ?? 0) <= 0)) return const SizedBox.shrink();
    final ar = context.isAr;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: const Color(0xFFFFE4E6),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push('/wheel'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Text('🎡', style: TextStyle(fontSize: 30)),
              const SizedBox(width: 10),
              Expanded(child: Text(teaser ? (ar ? 'اشتري أي حاجة واكسب هدايا من عجلة الحظ 🎁' : 'Buy anything and win gifts on the lucky wheel 🎁') : (ar ? 'لفّتك النهارده مستنياك! لف العجلة واكسب' : 'Your daily spin is waiting! Spin and win'), style: const TextStyle(fontWeight: FontWeight.w800, color: _ink))),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
      ),
    );
  }
}
