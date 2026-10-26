import 'dart:math' as math;

import 'package:flutter/material.dart';

const occasionStampKinds = {
  'ramadan': ['crescent', 'lantern', 'both'],
  'fitr': ['crescent_star', 'lantern', 'stars'],
  'adha': ['crescent_star', 'crescent', 'stars'],
  'oct6': ['flag', 'bunting', 'star'],
};

const _gold = Color(0xFFE8B44F);
const _red = Color(0xFFCE1126);

/// Small seasonal drawing (crescent, lantern, stars, flag colours) that sits on the logo while an occasion is running.
class OccasionStamp extends StatelessWidget {
  const OccasionStamp({super.key, required this.kind, required this.size});
  final String kind;
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(size, size), painter: _StampPainter(kind));
}

class _StampPainter extends CustomPainter {
  _StampPainter(this.kind);
  final String kind;

  Path _crescent(double cx, double cy, double r) {
    final outer = Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    final inner = Path()..addOval(Rect.fromCircle(center: Offset(cx + r * 0.42, cy - r * 0.08), radius: r * 0.82));
    return Path.combine(PathOperation.difference, outer, inner);
  }

  Path _star(double cx, double cy, double r) {
    final p = Path();
    for (var i = 0; i < 10; i++) {
      final a = -math.pi / 2 + i * math.pi / 5;
      final rr = i.isOdd ? r * 0.42 : r;
      final pt = Offset(cx + rr * math.cos(a), cy + rr * math.sin(a));
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    return p..close();
  }

  void _lantern(Canvas c, double x, double y, double w, Paint gold) {
    final h = w * 1.7;
    final line = Paint()
      ..color = _gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09
      ..strokeCap = StrokeCap.round;
    c.drawLine(Offset(x + w / 2, y), Offset(x + w / 2, y + h * 0.14), line);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + w * 0.2, y + h * 0.14, w * 0.6, h * 0.1), Radius.circular(w * 0.04)), gold);
    final body = Path()
      ..moveTo(x + w * 0.28, y + h * 0.26)
      ..lineTo(x + w * 0.72, y + h * 0.26)
      ..lineTo(x + w * 0.9, y + h * 0.55)
      ..lineTo(x + w * 0.72, y + h * 0.84)
      ..lineTo(x + w * 0.28, y + h * 0.84)
      ..lineTo(x + w * 0.1, y + h * 0.55)
      ..close();
    c.drawPath(body, line);
    c.drawLine(Offset(x + w / 2, y + h * 0.26), Offset(x + w / 2, y + h * 0.84), line);
    c.drawLine(Offset(x + w * 0.1, y + h * 0.55), Offset(x + w * 0.9, y + h * 0.55), line);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + w * 0.24, y + h * 0.86, w * 0.52, h * 0.1), Radius.circular(w * 0.04)), gold);
  }

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final gold = Paint()..color = _gold;
    switch (kind) {
      case 'crescent':
        canvas.drawPath(_crescent(w * 0.5, w * 0.5, w * 0.42), gold);
      case 'crescent_star':
        canvas.drawPath(_crescent(w * 0.4, w * 0.5, w * 0.36), gold);
        canvas.drawPath(_star(w * 0.8, w * 0.32, w * 0.14), gold);
      case 'lantern':
        _lantern(canvas, w * 0.2, 0, w * 0.6, gold);
      case 'both':
        canvas.drawPath(_crescent(w * 0.3, w * 0.45, w * 0.28), gold);
        _lantern(canvas, w * 0.58, 0, w * 0.38, gold);
      case 'stars':
        canvas.drawPath(_star(w * 0.5, w * 0.38, w * 0.3), gold);
        canvas.drawPath(_star(w * 0.84, w * 0.72, w * 0.16), gold);
        canvas.drawPath(_star(w * 0.2, w * 0.7, w * 0.13), gold);
      case 'star':
        canvas.drawPath(_star(w * 0.5, w * 0.52, w * 0.42), gold);
      case 'flag':
        canvas.save();
        canvas.translate(w * 0.5, w * 0.5);
        canvas.rotate(-math.pi / 9);
        final bw = w * 0.9, bh = w * 0.2;
        final edge = Paint()
          ..color = const Color(0x55000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        for (var i = 0; i < 3; i++) {
          final r = Rect.fromLTWH(-bw / 2, -bh * 1.5 + i * bh, bw, bh);
          canvas.drawRect(r, Paint()..color = [_red, Colors.white, const Color(0xFF111111)][i]);
          canvas.drawRect(r, edge);
        }
        canvas.restore();
      case 'bunting':
        final string = Paint()
          ..color = _gold
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.04;
        final curve = Path()
          ..moveTo(0, w * 0.2)
          ..quadraticBezierTo(w * 0.5, w * 0.5, w, w * 0.2);
        canvas.drawPath(curve, string);
        final colors = [_red, Colors.white, const Color(0xFF111111), _red];
        for (var i = 0; i < 4; i++) {
          final t = (i + 0.7) / 4.4;
          final x = w * t;
          final y = w * 0.2 + math.sin(t * math.pi) * w * 0.15;
          final tri = Path()
            ..moveTo(x - w * 0.1, y)
            ..lineTo(x + w * 0.1, y)
            ..lineTo(x, y + w * 0.24)
            ..close();
          canvas.drawPath(tri, Paint()..color = colors[i]);
          canvas.drawPath(tri, Paint()
            ..color = const Color(0x55000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _StampPainter old) => old.kind != kind;
}
