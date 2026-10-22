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
