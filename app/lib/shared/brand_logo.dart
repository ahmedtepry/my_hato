import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Reusable brand mark: stylised "M" with an electric-blue diagonal stroke,
/// following the brand board. Replace the painter with the final vector asset
/// (e.g. flutter_svg) when the official file is supplied — callers stay the same.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 48, this.onDark = false, this.progress = 1});
  final double size;
  final bool onDark;
  /// 0..1 — used by the animated order-confirmation sequence.
  final double progress;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size * 0.82,
        child: CustomPaint(painter: _MPainter(onDark: onDark, progress: progress)),
      );
}

class _MPainter extends CustomPainter {
  _MPainter({required this.onDark, required this.progress});
  final bool onDark;
  final double progress;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final stroke = w * 0.2;
    final base = Paint()
      ..color = onDark ? BrandColors.white : BrandColors.navy
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // left leg + first diagonal
    final p1 = Path()
      ..moveTo(stroke / 2, h - stroke / 2)
      ..lineTo(stroke / 2, stroke / 2)
      ..lineTo(w * 0.5, h * 0.62);
    _drawPartial(canvas, p1, base, (progress * 2).clamp(0.0, 1.0));
    // electric diagonal + right leg
    final accent = Paint()
      ..shader = const LinearGradient(colors: [BrandColors.electric, Color(0xFF1E6BFF)])
          .createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p2 = Path()
      ..moveTo(w * 0.5, h * 0.62)
      ..lineTo(w - stroke / 2, stroke / 2)
      ..lineTo(w - stroke / 2, h - stroke / 2);
    _drawPartial(canvas, p2, accent, ((progress - 0.5) * 2).clamp(0.0, 1.0));
  }

  void _drawPartial(Canvas canvas, Path path, Paint paint, double t) {
    if (t <= 0) return;
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * t), paint);
    }
  }

  @override
  bool shouldRepaint(_MPainter old) => old.progress != progress || old.onDark != onDark;
}

class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.size = 28, this.onDark = false, this.showSlogan = false});
  final double size;
  final bool onDark;
  final bool showSlogan;

  @override
  Widget build(BuildContext context) {
    final color = onDark ? BrandColors.white : BrandColors.navy;
    return Directionality(
      textDirection: TextDirection.ltr, // the logo always reads left-to-right
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            BrandMark(size: size * 1.25, onDark: onDark),
            SizedBox(width: size * 0.3),
            Text.rich(TextSpan(children: [
              TextSpan(text: 'My', style: TextStyle(color: color)),
              const TextSpan(text: 'Hatō', style: TextStyle(color: BrandColors.electric)),
            ]), style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          ]),
          if (showSlogan) ...[
            SizedBox(height: size * 0.25),
            Text('YOUR PHONE. OUR PRIORITY.',
                style: TextStyle(fontSize: size * 0.32, letterSpacing: size * 0.12, color: color, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}


/// Tappable logo for the top of the app: a quick flip-and-pulse of the M mark with a light
/// haptic, then it takes the customer to the home screen (or scrolls home back to the top).
class HomeLogoButton extends StatefulWidget {
  const HomeLogoButton({super.key, this.size = 22, this.onAlreadyHome, this.onTripleTap});
  final double size;

  /// Three quick taps (within ~1.2 s).
  final VoidCallback? onTripleTap;

  /// Called instead of navigating when the home screen is already showing.
  final VoidCallback? onAlreadyHome;

  @override
  State<HomeLogoButton> createState() => _HomeLogoButtonState();
}

class _HomeLogoButtonState extends State<HomeLogoButton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final _flip = CurvedAnimation(parent: _c, curve: const Interval(0, 0.75, curve: Curves.easeInOutCubic));
  late final _pulse = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.88).chain(CurveTween(curve: Curves.easeOut)), weight: 20),
    TweenSequenceItem(tween: Tween(begin: 0.88, end: 1.08).chain(CurveTween(curve: Curves.easeOut)), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)), weight: 40),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  final _taps = <DateTime>[];

  Future<void> _tap() async {
    final now = DateTime.now();
    _taps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(milliseconds: 1200));
    if (_taps.length >= 3 && widget.onTripleTap != null) {
      _taps.clear();
      HapticFeedback.mediumImpact();
      _c.forward(from: 0);
      widget.onTripleTap!();
      return;
    }
    HapticFeedback.lightImpact();
    _c.forward(from: 0);
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;
    final router = GoRouter.of(context);
    final atHome = router.routerDelegate.currentConfiguration.uri.path == '/';
    if (atHome) {
      widget.onAlreadyHome?.call();
    } else {
      router.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Semantics(
      button: true,
      label: 'My Hatō',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Transform.scale(
              scale: _pulse.value,
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0015)
                      ..rotateY(_flip.value * 2 * math.pi),
                    child: BrandMark(size: size * 1.25),
                  ),
                  SizedBox(width: size * 0.3),
                  ShaderMask(
                    // a soft light sweep across the name while animating
                    shaderCallback: (r) => LinearGradient(
                      colors: const [Colors.transparent, Colors.white54, Colors.transparent],
                      stops: [(_c.value * 1.4 - 0.3).clamp(0.0, 1.0), (_c.value * 1.4 - 0.15).clamp(0.0, 1.0), (_c.value * 1.4).clamp(0.0, 1.0)],
                    ).createShader(r),
                    blendMode: _c.isAnimating ? BlendMode.srcATop : BlendMode.dst,
                    child: Text.rich(
                      const TextSpan(children: [
                        TextSpan(text: 'My', style: TextStyle(color: BrandColors.navy)),
                        TextSpan(text: 'Hatō', style: TextStyle(color: BrandColors.electric)),
                      ]),
                      style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
