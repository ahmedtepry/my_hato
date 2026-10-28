import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const _mPoints = [
  Offset(100, 396), Offset(100, 128), Offset(150, 128), Offset(256, 260), Offset(362, 128), Offset(412, 128),
  Offset(412, 396), Offset(356, 396), Offset(356, 214), Offset(256, 340), Offset(156, 214), Offset(156, 396),
];

Path _poly(List<Offset> pts) {
  final p = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (final o in pts.skip(1)) {
    p.lineTo(o.dx, o.dy);
  }
  return p..close();
}

/// The M logo scaled by [s] around the centre (256, 256), like the icon artwork.
Path _mPath(double s, {double cy = 256}) =>
    _poly(_mPoints).transform((Matrix4.identity()..translate(256.0, cy)..scale(s)..translate(-256.0, -262.0)).storage);

/// A path drawn up to [t] (0..1) of its length.
Path _partial(Path p, double t) {
  final out = Path();
  for (final m in p.computeMetrics()) {
    out.addPath(m.extractPath(0, m.length * t.clamp(0.0, 1.0)), Offset.zero);
  }
  return out;
}

double _iv(double v, double a, double b, [Curve c = Curves.easeOut]) => c.transform(((v - a) / (b - a)).clamp(0.0, 1.0));

/// One of the six picked icon artworks (liquid, orbit, phone, neon, pulse, bird), painted at progress [t] of its opening animation.
/// At t = 1 it is the finished app icon.
class LaunchArt extends StatelessWidget {
  const LaunchArt({super.key, required this.id, required this.t, this.size = 120});
  final String id;
  final double t;
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _ArtPainter(id, t));
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(this.id, this.t);
  final String id;
  final double t;

  static Color _c(int v) => Color(0xFF000000 | v);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 512);
    final tile = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 512, 512), const Radius.circular(112));
    final bg = switch (id) {
      'bird' || 'orbit' => [_c(0x0f4a96), _c(0x061d40)],
      'pulse' => [_c(0x0d3366), _c(0x06172f)],
      'phone' => [_c(0x37c0ff), _c(0x0058c4)],
      'neon' => [_c(0x0a1120), _c(0x03060c)],
      _ => [_c(0x0d3a74), _c(0x051a38)],
    };
    canvas.drawRRect(tile, Paint()..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(512, 512), bg));
    canvas.save();
    canvas.clipRRect(tile);
    switch (id) {
      case 'bird':
        _bird(canvas);
      case 'pulse':
        _pulse(canvas);
      case 'phone':
        _phone(canvas);
      case 'neon':
        _neon(canvas);
      case 'orbit':
        _orbit(canvas);
      default:
        _liquid(canvas);
    }
    canvas.restore();
    canvas.restore();
  }

  Paint _stroke(double w, {Shader? shader, Color? color}) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color ?? Colors.white
    ..shader = shader;

  void _bird(Canvas c) {
    final wing = Path()
      ..moveTo(70, 322)
      ..cubicTo(108, 146, 206, 112, 256, 292)
      ..cubicTo(306, 112, 404, 146, 442, 322);
    final draw = _iv(t, 0, 0.55, Curves.easeOut);
    final flap = t > 0.7 ? 1 - 0.18 * math.sin((t - 0.7) / 0.3 * math.pi) : 1.0;
    c.save();
    c.translate(0, 512 * 0.62);
    c.scale(1, flap);
    c.translate(0, -512 * 0.62);
    c.drawPath(
        _partial(wing, draw),
        _stroke(48,
            shader: ui.Gradient.linear(const Offset(70, 0), const Offset(442, 0), [Colors.white, _c(0xbfe6ff), _c(0x33b5ff)], [0, .5, 1])));
    c.restore();
    final pop = _iv(t, 0.45, 0.7, Curves.easeOutBack);
    c.drawCircle(const Offset(256, 360), 24 * pop, Paint()..color = Colors.white);
  }

  void _pulse(Canvas c) {
    final d = Path()
      ..moveTo(54, 336)
      ..lineTo(146, 336)
      ..lineTo(204, 170)
      ..lineTo(256, 346)
      ..lineTo(308, 170)
      ..lineTo(366, 336)
      ..lineTo(458, 336);
    final draw = _iv(t, 0, 0.9, Curves.easeInOut);
    final part = _partial(d, draw);
    c.drawPath(part, _stroke(44, color: _c(0x33b5ff).withValues(alpha: .55))..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
    c.drawPath(part, _stroke(36, shader: ui.Gradient.linear(const Offset(54, 0), const Offset(458, 0), [_c(0x33b5ff), _c(0x3de0c0)])));
    c.drawCircle(const Offset(458, 336), 16 * _iv(t, 0.82, 1, Curves.easeOutBack), Paint()..color = Colors.white);
  }

  void _phone(Canvas c) {
    final rise = _iv(t, 0, 0.6, Curves.easeOutCubic);
    c.save();
    c.translate(0, 70 * (1 - rise));
    final a = rise.clamp(0.0, 1.0);
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(160, 62, 192, 388), const Radius.circular(42)), Paint()..color = Colors.white.withValues(alpha: a));
    final screenA = _iv(t, 0.4, 0.8);
    c.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(176, 78, 160, 356), const Radius.circular(30)),
        Paint()
          ..shader = ui.Gradient.linear(const Offset(0, 78), const Offset(0, 434), [_c(0x0f3f80).withValues(alpha: screenA), _c(0x071f46).withValues(alpha: screenA)]));
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(226, 90, 60, 14), const Radius.circular(7)), Paint()..color = Colors.white.withValues(alpha: .9 * screenA));
    c.drawPath(_mPath(.36, cy: 264), Paint()..color = Colors.white.withValues(alpha: _iv(t, 0.55, 0.9)));
    c.restore();
  }

  void _neon(Canvas c) {
    final m = _poly(_mPoints);
    final draw = _iv(t, 0, 0.7, Curves.easeOut);
    final flick = t < 0.55 ? 0.0 : const [0.0, .9, .15, 1.0, .3, 1.0][((t - 0.55) / 0.45 * 5).clamp(0, 5).floor()];
    c.drawPath(m, _stroke(22, color: _c(0x2aa6ff).withValues(alpha: .9 * flick))..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    c.drawPath(
        _partial(m, draw),
        _stroke(16, shader: ui.Gradient.linear(const Offset(100, 128), const Offset(412, 396), [_c(0x7ee0ff), _c(0x2aa6ff), _c(0x3de0c0)], [0, .55, 1])));
  }

  void _orbit(Canvas c) {
    final ring = _iv(t, 0, 0.55);
    c.drawArc(Rect.fromCircle(center: const Offset(256, 256), radius: 186), -math.pi / 2, 2 * math.pi * ring, false, _stroke(14, color: _c(0x33b5ff)));
    c.drawPath(_mPath(.52), Paint()..color = Colors.white.withValues(alpha: _iv(t, 0.3, 0.6)));
    final spin = _iv(t, 0.25, 1, Curves.easeOutCubic);
    final ang = (-320 + 360 * spin) * math.pi / 180;
    c.save();
    c.translate(256, 256);
    c.rotate(ang);
    c.translate(-256, -256);
    final a = _iv(t, 0.2, 0.4);
    c.drawCircle(const Offset(256, 70), 40, Paint()..color = _c(0xffb340).withValues(alpha: .25 * a));
    c.drawCircle(const Offset(256, 70), 24, Paint()..color = _c(0xffb340).withValues(alpha: a));
    c.restore();
  }

  void _liquid(Canvas c) {
    final m = _poly(_mPoints);
    c.drawPath(m, Paint()..color = Colors.white.withValues(alpha: .14));
    c.save();
    c.clipPath(m);
    final rise = 1 - _iv(t, 0, 0.95, Curves.easeOutCubic);
    c.translate(0, 300 * rise);
    final shift = -(t * 240 * 1.5) % 240;
    final w = Path()..moveTo(-240 + shift, 170);
    for (var x = -240.0 + shift; x < 800; x += 120) {
      w.relativeQuadraticBezierTo(30, -44, 60, 0);
      w.relativeQuadraticBezierTo(30, 44, 60, 0);
    }
    w
      ..lineTo(800, 600)
      ..lineTo(-240, 600)
      ..close();
    c.drawPath(w, Paint()..shader = ui.Gradient.linear(const Offset(0, 170), const Offset(0, 400), [_c(0x6ff0d4), _c(0x2aa6ff), _c(0x0a5fd0)], [0, .5, 1]));
    c.restore();
    c.drawPath(m, _stroke(6, color: Colors.white.withValues(alpha: .85)));
  }

  @override
  bool shouldRepaint(_ArtPainter old) => old.t != t || old.id != id;
}
