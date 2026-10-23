import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

/// Built-in cartoon avatars (drawn in code, no image files): 8 men (m1–m4 young, m5–m8 older) and
/// 8 women (f1–f8, incl. hijab and niqab). Customers pick one instead of uploading a photo.
const avatarIds = ['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8'];

bool isAvatarId(String? id) => id != null && avatarIds.contains(id);

enum _Hair { cap, curly, sidePart, spiky, long, bun, bob, hijab, bald, kufi, receding, niqab, ponytail, curlyLong }

class _Look {
  const _Look({
    required this.bg,
    required this.skin,
    required this.hair,
    required this.hairColor,
    required this.shirt,
    required this.accent,
    this.female = false,
    this.glasses = false,
    this.beard = false,
    this.headphones = false,
    this.mustache = false,
    this.tie = false,
    this.older = false,
  });
  final List<Color> bg;
  final Color skin, hairColor, shirt, accent;
  final _Hair hair;
  final bool female, glasses, beard, headphones, mustache, tie, older;
}

const _looks = <String, _Look>{
  // boys
  'm1': _Look(bg: [Color(0xFF0B1F4D), Color(0xFF00A3FF)], skin: Color(0xFFF2C29B), hair: _Hair.cap, hairColor: Color(0xFF3B2A20), shirt: Color(0xFFFFFFFF), accent: Color(0xFF00A3FF)),
  'm2': _Look(bg: [Color(0xFFFF8A3D), Color(0xFFFFC75F)], skin: Color(0xFF8D5A3B), hair: _Hair.curly, hairColor: Color(0xFF1E1410), shirt: Color(0xFF0B1F4D), accent: Color(0xFFFF5E5E), headphones: true),
  'm3': _Look(bg: [Color(0xFF1B9C85), Color(0xFF7BE0C3)], skin: Color(0xFFE0A77E), hair: _Hair.sidePart, hairColor: Color(0xFF2B2B2B), shirt: Color(0xFFFFD166), accent: Color(0xFF2B2B2B), glasses: true, beard: true),
  'm4': _Look(bg: [Color(0xFF6C4BEF), Color(0xFFB79CFF)], skin: Color(0xFFF7D2B5), hair: _Hair.spiky, hairColor: Color(0xFFFF7A1A), shirt: Color(0xFF00C2A8), accent: Color(0xFFFFFFFF)),
  // girls
  'f1': _Look(bg: [Color(0xFFFF6FA5), Color(0xFFFFB3C7)], skin: Color(0xFFF5C7A6), hair: _Hair.long, hairColor: Color(0xFF6B3E26), shirt: Color(0xFFFFFFFF), accent: Color(0xFFFFD23F), female: true),
  'f2': _Look(bg: [Color(0xFF00A3FF), Color(0xFF8FD8FF)], skin: Color(0xFF9C6644), hair: _Hair.bun, hairColor: Color(0xFF1A1110), shirt: Color(0xFFFF6F61), accent: Color(0xFFFFC94A), female: true),
  'f3': _Look(bg: [Color(0xFF0B1F4D), Color(0xFF5B6CFF)], skin: Color(0xFFF3CDB0), hair: _Hair.bob, hairColor: Color(0xFF111111), shirt: Color(0xFFFFD166), accent: Color(0xFFFF4D8D), female: true, glasses: true),
  'f4': _Look(bg: [Color(0xFF14B8A6), Color(0xFF99F6E4)], skin: Color(0xFFE8B48F), hair: _Hair.hijab, hairColor: Color(0xFF7C3AED), shirt: Color(0xFF7C3AED), accent: Color(0xFFFFFFFF), female: true),
  // older men
  'm5': _Look(bg: [Color(0xFF3A6073), Color(0xFF9CC9DC)], skin: Color(0xFFEDC3A0), hair: _Hair.bald, hairColor: Color(0xFFD9D9D9), shirt: Color(0xFFB5523B), accent: Color(0xFF6B4226), glasses: true, mustache: true, older: true),
  'm6': _Look(bg: [Color(0xFF0F5132), Color(0xFF6FCF97)], skin: Color(0xFFC98E62), hair: _Hair.kufi, hairColor: Color(0xFFF2F2F2), shirt: Color(0xFFFFFFFF), accent: Color(0xFF0F5132), beard: true, older: true),
  'm7': _Look(bg: [Color(0xFF1F2A44), Color(0xFF6E7FA8)], skin: Color(0xFFF1CBA8), hair: _Hair.sidePart, hairColor: Color(0xFF9AA0A6), shirt: Color(0xFF1F2A44), accent: Color(0xFFC62828), mustache: true, tie: true, older: true),
  'm8': _Look(bg: [Color(0xFFB7791F), Color(0xFFF6D365)], skin: Color(0xFF9C6A48), hair: _Hair.receding, hairColor: Color(0xFF8E8E8E), shirt: Color(0xFF2E5E4E), accent: Color(0xFF1B1B2F), glasses: true, beard: true, older: true),
  // more women
  'f5': _Look(bg: [Color(0xFF3D2C5E), Color(0xFF9F86C0)], skin: Color(0xFFE9BE98), hair: _Hair.niqab, hairColor: Color(0xFF1C1C24), shirt: Color(0xFF1C1C24), accent: Color(0xFFE0B354), female: true),
  'f6': _Look(bg: [Color(0xFFFF8FAB), Color(0xFFFFD6E0)], skin: Color(0xFFF2C7A5), hair: _Hair.hijab, hairColor: Color(0xFFE5486F), shirt: Color(0xFFE5486F), accent: Color(0xFFFFD166), female: true, glasses: true),
  'f7': _Look(bg: [Color(0xFF0EA5E9), Color(0xFFBAE6FD)], skin: Color(0xFFF6D0B1), hair: _Hair.ponytail, hairColor: Color(0xFFB5651D), shirt: Color(0xFF22C55E), accent: Color(0xFFFF5D8F), female: true),
  'f8': _Look(bg: [Color(0xFFF97316), Color(0xFFFED7AA)], skin: Color(0xFF7B4B2A), hair: _Hair.curlyLong, hairColor: Color(0xFF1F130C), shirt: Color(0xFFFFFFFF), accent: Color(0xFF8B5CF6), female: true),
};

/// One avatar. [animate] adds an occasional blink (off in tiny places).
class HatoAvatar extends StatefulWidget {
  const HatoAvatar({super.key, required this.id, this.size = 64, this.animate = true});
  final String id;
  final double size;
  final bool animate;

  @override
  State<HatoAvatar> createState() => _HatoAvatarState();
}

class _HatoAvatarState extends State<HatoAvatar> with SingleTickerProviderStateMixin {
  // A 0.22 s blink fired by a timer every few seconds: the avatar is a still picture in between,
  // so it costs nothing while idle (no per-frame repaint).
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Timer? _timer;

  void _sync() {
    if (widget.animate && _timer == null) {
      final every = Duration(milliseconds: 3800 + 230 * avatarIds.indexOf(widget.id).clamp(0, 15));
      _timer = Timer.periodic(every, (_) {
        if (mounted) _c.forward(from: 0);
      });
    } else if (!widget.animate && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant HatoAvatar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final look = _looks[widget.id] ?? _looks['m1']!;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final t = _c.value;
            final b = (_c.isAnimating ? 1 - math.sin(t * math.pi) : 1.0).clamp(0.08, 1.0).toDouble();
            return CustomPaint(painter: _AvatarPainter(look, blink: b, bob: 0));
          },
        ),
      ),
    );
  }
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter(this.l, {required this.blink, required this.bob});
  final _Look l;
  final double blink;
  final double bob;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100;
    Offset p(double x, double y) => Offset(x * u, y * u);
    Rect oval(double cx, double cy, double rx, double ry) => Rect.fromCenter(center: p(cx, cy), width: rx * 2 * u, height: ry * 2 * u);
    Paint fill(Color c) => Paint()..color = c..isAntiAlias = true;
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final circle = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    canvas.drawRect(
        circle, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: l.bg).createShader(circle));
    // soft light blob
    canvas.drawCircle(p(26, 22), 30 * u, fill(Colors.white.withValues(alpha: 0.12)));

    canvas.save();
    canvas.translate(0, bob * 0.9 * u);

    final skinShade = Color.lerp(l.skin, Colors.black, 0.12)!;
    final niqab = l.hair == _Hair.niqab;
    final hijab = l.hair == _Hair.hijab || niqab;

    // ---------- back hair / hijab drape
    switch (l.hair) {
      case _Hair.long:
        final back = Path()
          ..moveTo(26 * u, 50 * u)
          ..cubicTo(22 * u, 18 * u, 78 * u, 18 * u, 74 * u, 50 * u)
          ..lineTo(79 * u, 86 * u)
          ..quadraticBezierTo(50 * u, 96 * u, 21 * u, 86 * u)
          ..close();
        canvas.drawPath(back, fill(l.hairColor));
      case _Hair.bob:
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(24 * u, 22 * u, 76 * u, 68 * u), Radius.circular(20 * u)), fill(l.hairColor));
      case _Hair.bun:
        canvas.drawCircle(p(50, 18), 10.5 * u, fill(l.hairColor));
      case _Hair.curly:
        for (var i = 0; i <= 10; i++) {
          final a = math.pi + i * math.pi / 10;
          canvas.drawCircle(p(50 + 24 * math.cos(a), 45 + 22 * math.sin(a)), 7.5 * u, fill(l.hairColor));
        }
        canvas.drawCircle(p(50, 24), 9 * u, fill(l.hairColor));
      case _Hair.hijab:
      case _Hair.niqab:
        final drape = Path()
          ..addOval(oval(50, 50, 30, 32))
          ..addRect(Rect.fromLTRB(20 * u, 50 * u, 80 * u, 92 * u));
        canvas.drawPath(drape, fill(l.hairColor));
      case _Hair.ponytail:
        final tail = Path()
          ..moveTo(66 * u, 30 * u)
          ..cubicTo(90 * u, 30 * u, 92 * u, 62 * u, 80 * u, 76 * u)
          ..cubicTo(84 * u, 58 * u, 78 * u, 44 * u, 68 * u, 42 * u)
          ..close();
        canvas.drawPath(tail, fill(l.hairColor));
      case _Hair.curlyLong:
        for (var i = 0; i <= 12; i++) {
          final a = math.pi * 0.85 + i * math.pi * 1.3 / 12;
          canvas.drawCircle(p(50 + 29 * math.cos(a), 50 + 30 * math.sin(a)), 9 * u, fill(l.hairColor));
        }
        for (final x in [22.0, 30.0, 70.0, 78.0]) {
          canvas.drawCircle(p(x, 72), 8.5 * u, fill(l.hairColor));
        }
      default:
        break;
    }

    // ---------- body
    final shirtRect = oval(50, 102, hijab ? 40 : 37, 28);
    canvas.drawOval(shirtRect, fill(l.shirt));
    if (!hijab) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(43 * u, 64 * u, 57 * u, 80 * u), Radius.circular(5 * u)), fill(skinShade));
      // collar V
      final collar = Path()
        ..moveTo(42 * u, 76.5 * u)
        ..lineTo(50 * u, 84 * u)
        ..lineTo(58 * u, 76.5 * u);
      canvas.drawPath(collar, stroke(Color.lerp(l.shirt, Colors.black, 0.18)!, 1.6));
      if (l.tie) {
        canvas.drawPath(Path()..moveTo(41 * u, 75 * u)..lineTo(50 * u, 92 * u)..lineTo(59 * u, 75 * u)..close(), fill(Colors.white));
        canvas.drawPath(
            Path()
              ..moveTo(47.5 * u, 79 * u)
              ..lineTo(52.5 * u, 79 * u)
              ..lineTo(53.5 * u, 92 * u)
              ..lineTo(50 * u, 96 * u)
              ..lineTo(46.5 * u, 92 * u)
              ..close(),
            fill(l.accent));
        canvas.drawPath(Path()..moveTo(47 * u, 75.5 * u)..lineTo(53 * u, 75.5 * u)..lineTo(52 * u, 80 * u)..lineTo(48 * u, 80 * u)..close(),
            fill(Color.lerp(l.accent, Colors.black, 0.2)!));
      }
    } else {
      // hijab falls over the shoulders
      canvas.drawOval(oval(50, 96, 34, 22), fill(l.hairColor));
    }
    if (l.headphones) {
      canvas.drawArc(oval(50, 74, 13, 7), 0.1, math.pi - 0.2, false, stroke(l.accent, 3));
    }

    // ---------- head
    if (!hijab) {
      canvas.drawCircle(p(28, 51), 5 * u, fill(l.skin));
      canvas.drawCircle(p(72, 51), 5 * u, fill(l.skin));
      canvas.drawCircle(p(28.5, 51), 2.2 * u, fill(skinShade));
      canvas.drawCircle(p(71.5, 51), 2.2 * u, fill(skinShade));
    }
    if (hijab) {
      canvas.drawOval(oval(50, 51, 22.5, 24.5), fill(Color.lerp(l.hairColor, Colors.white, niqab ? 0.1 : 0.25)!)); // inner band
    }
    if (niqab) {
      // veil over the face: only an eye band of skin shows
      final face = oval(50, 50, 19.5, 22);
      canvas.drawOval(face, fill(Color.lerp(l.hairColor, Colors.white, 0.06)!));
      canvas.save();
      canvas.clipPath(Path()..addOval(face));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(28 * u, 40.5 * u, 72 * u, 56 * u), Radius.circular(6 * u)), fill(l.skin));
      canvas.restore();
      canvas.drawLine(p(33, 56.5), p(67, 56.5), stroke(l.accent.withValues(alpha: 0.85), 1.2)); // veil edge
      canvas.drawCircle(p(50, 70), 1.6 * u, fill(l.accent));
    } else {
      canvas.drawOval(oval(50, 50, hijab ? 19.5 : 22, hijab ? 22 : 25), fill(l.skin));
    }
    // older faces: soft forehead and smile lines
    if (l.older) {
      final line = stroke(skinShade, 1.1);
      if (l.hair == _Hair.bald || l.hair == _Hair.receding) {
        canvas.drawArc(oval(50, 39, 9, 3), math.pi + 0.4, math.pi - 0.8, false, line);
        canvas.drawArc(oval(50, 35.5, 7, 2.5), math.pi + 0.4, math.pi - 0.8, false, line);
      }
      if (!l.beard) {
        canvas.drawArc(oval(38.5, 59, 4, 5), math.pi * 0.55, math.pi * 0.5, false, line);
        canvas.drawArc(oval(61.5, 59, 4, 5), -math.pi * 0.05, math.pi * 0.5, false, line);
      }
    }

    // beard
    if (l.beard) {
      final beard = Path()
        ..moveTo(28.5 * u, 50 * u)
        ..quadraticBezierTo(30 * u, 77 * u, 50 * u, 76.5 * u)
        ..quadraticBezierTo(70 * u, 77 * u, 71.5 * u, 50 * u)
        ..quadraticBezierTo(66 * u, 62 * u, 50 * u, 61 * u)
        ..quadraticBezierTo(34 * u, 62 * u, 28.5 * u, 50 * u)
        ..close();
      canvas.drawPath(beard, fill(l.hairColor));
    }

    // ---------- front hair / headwear
    switch (l.hair) {
      case _Hair.cap:
        // sideburns
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(27.5 * u, 38 * u, 31 * u, 49 * u), Radius.circular(2 * u)), fill(l.hairColor));
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(69 * u, 38 * u, 72.5 * u, 49 * u), Radius.circular(2 * u)), fill(l.hairColor));
        final dome = Path()
          ..moveTo(26.5 * u, 40 * u)
          ..cubicTo(26 * u, 14 * u, 74 * u, 14 * u, 73.5 * u, 40 * u)
          ..close();
        canvas.drawPath(dome, fill(l.accent));
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(40 * u, 35.5 * u, 86 * u, 41.5 * u), Radius.circular(3 * u)),
            fill(Color.lerp(l.accent, Colors.black, 0.25)!));
        canvas.drawCircle(p(50, 20.5), 2 * u, fill(Colors.white));
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(44 * u, 26 * u, 56 * u, 31 * u), Radius.circular(1.5 * u)), fill(Colors.white));
      case _Hair.curly:
        for (var i = 0; i < 5; i++) {
          canvas.drawCircle(p(34 + i * 8, 30 + (i.isEven ? 0 : -1.5)), 6.5 * u, fill(l.hairColor));
        }
      case _Hair.sidePart:
        final top = Path()
          ..moveTo(27.5 * u, 47 * u)
          ..cubicTo(24 * u, 18 * u, 76 * u, 16 * u, 72.5 * u, 46 * u)
          ..quadraticBezierTo(70 * u, 36 * u, 62 * u, 33 * u)
          ..quadraticBezierTo(46 * u, 30 * u, 38 * u, 36 * u)
          ..quadraticBezierTo(31 * u, 40 * u, 27.5 * u, 47 * u)
          ..close();
        canvas.drawPath(top, fill(l.hairColor));
      case _Hair.spiky:
        final spikes = Path()..moveTo(26.5 * u, 46 * u);
        const pts = [
          [24.0, 30.0], [32.0, 33.0], [30.0, 16.0], [40.0, 27.0], [44.0, 10.0], [51.0, 25.0],
          [60.0, 9.0], [62.0, 26.0], [72.0, 15.0], [69.0, 31.0], [78.0, 29.0], [73.5, 46.0],
        ];
        for (final q in pts) {
          spikes.lineTo(q[0] * u, q[1] * u);
        }
        spikes
          ..quadraticBezierTo(60 * u, 34 * u, 50 * u, 35 * u)
          ..quadraticBezierTo(36 * u, 35 * u, 26.5 * u, 46 * u)
          ..close();
        canvas.drawPath(spikes, fill(l.hairColor));
      case _Hair.long:
        final bangs = Path()
          ..moveTo(27 * u, 50 * u)
          ..cubicTo(23 * u, 15 * u, 77 * u, 15 * u, 73 * u, 50 * u)
          ..quadraticBezierTo(66 * u, 34 * u, 46 * u, 33 * u)
          ..quadraticBezierTo(34 * u, 36 * u, 27 * u, 50 * u)
          ..close();
        canvas.drawPath(bangs, fill(l.hairColor));
        // flower clip
        for (var i = 0; i < 5; i++) {
          final a = i * 2 * math.pi / 5;
          canvas.drawCircle(p(67 + 3.2 * math.cos(a), 31 + 3.2 * math.sin(a)), 2.6 * u, fill(l.accent));
        }
        canvas.drawCircle(p(67, 31), 1.8 * u, fill(Colors.white));
      case _Hair.bun:
        final top = Path()
          ..moveTo(27.5 * u, 46 * u)
          ..cubicTo(25 * u, 20 * u, 75 * u, 20 * u, 72.5 * u, 46 * u)
          ..quadraticBezierTo(62 * u, 31 * u, 50 * u, 31 * u)
          ..quadraticBezierTo(38 * u, 31 * u, 27.5 * u, 46 * u)
          ..close();
        canvas.drawPath(top, fill(l.hairColor));
        canvas.drawLine(p(40, 26), p(60, 26), stroke(l.accent, 2.4)); // hair tie
      case _Hair.bob:
        final bangs = Path()
          ..moveTo(27 * u, 46 * u)
          ..cubicTo(24 * u, 14 * u, 76 * u, 14 * u, 73 * u, 46 * u)
          ..lineTo(73 * u, 39 * u)
          ..lineTo(27 * u, 39 * u)
          ..close();
        canvas.drawPath(bangs, fill(l.hairColor));
      case _Hair.hijab:
        canvas.drawCircle(p(69, 64), 2 * u, fill(l.accent)); // pin
      case _Hair.niqab:
        break;
      case _Hair.bald:
        // grey hair left only around the sides + a little shine on top
        canvas.drawPath(
            Path()
              ..moveTo(27.5 * u, 52 * u)
              ..quadraticBezierTo(25 * u, 38 * u, 32 * u, 33 * u)
              ..quadraticBezierTo(30 * u, 42 * u, 31.5 * u, 52 * u)
              ..close(),
            fill(l.hairColor));
        canvas.drawPath(
            Path()
              ..moveTo(72.5 * u, 52 * u)
              ..quadraticBezierTo(75 * u, 38 * u, 68 * u, 33 * u)
              ..quadraticBezierTo(70 * u, 42 * u, 68.5 * u, 52 * u)
              ..close(),
            fill(l.hairColor));
        canvas.drawOval(oval(42, 31, 6, 3), fill(Colors.white.withValues(alpha: 0.35)));
      case _Hair.kufi:
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(27.5 * u, 38 * u, 31 * u, 50 * u), Radius.circular(2 * u)), fill(l.hairColor));
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(69 * u, 38 * u, 72.5 * u, 50 * u), Radius.circular(2 * u)), fill(l.hairColor));
        final cap = Path()
          ..moveTo(27 * u, 38 * u)
          ..cubicTo(27 * u, 17 * u, 73 * u, 17 * u, 73 * u, 38 * u)
          ..close();
        canvas.drawPath(cap, fill(Colors.white));
        canvas.drawLine(p(27.5, 37.5), p(72.5, 37.5), stroke(const Color(0xFFDADADA), 2));
        for (var i = 0; i < 7; i++) {
          canvas.drawCircle(p(33 + i * 5.7, 31), 0.9 * u, fill(l.accent.withValues(alpha: 0.6)));
        }
        for (var i = 0; i < 5; i++) {
          canvas.drawCircle(p(38.5 + i * 5.7, 25.5), 0.9 * u, fill(l.accent.withValues(alpha: 0.6)));
        }
      case _Hair.receding:
        final top = Path()
          ..moveTo(27.5 * u, 48 * u)
          ..cubicTo(24 * u, 22 * u, 76 * u, 22 * u, 72.5 * u, 48 * u)
          ..quadraticBezierTo(71 * u, 33 * u, 63 * u, 28 * u)
          ..quadraticBezierTo(50 * u, 31 * u, 37 * u, 28 * u)
          ..quadraticBezierTo(29 * u, 33 * u, 27.5 * u, 48 * u)
          ..close();
        canvas.drawPath(top, fill(l.hairColor));
      case _Hair.ponytail:
        final top = Path()
          ..moveTo(27.5 * u, 47 * u)
          ..cubicTo(24 * u, 17 * u, 76 * u, 17 * u, 72.5 * u, 47 * u)
          ..quadraticBezierTo(64 * u, 31 * u, 44 * u, 32 * u)
          ..quadraticBezierTo(33 * u, 36 * u, 27.5 * u, 47 * u)
          ..close();
        canvas.drawPath(top, fill(l.hairColor));
        canvas.drawCircle(p(69, 33), 3.2 * u, fill(l.accent)); // scrunchie
      case _Hair.curlyLong:
        for (var i = 0; i < 6; i++) {
          canvas.drawCircle(p(31 + i * 7.6, 30 + (i.isEven ? 0 : -2)), 6.8 * u, fill(l.hairColor));
        }
        canvas.drawCircle(p(27, 40), 6 * u, fill(l.hairColor));
        canvas.drawCircle(p(73, 40), 6 * u, fill(l.hairColor));
    }

    // ---------- face
    final ink = const Color(0xFF1B1B2F);
    // brows
    final browY = l.glasses ? 41.0 : 42.5;
    final browColor = hijab ? const Color(0xFF3B2A20) : (l.hair == _Hair.bald || l.hair == _Hair.kufi ? Color.lerp(l.hairColor, Colors.black, 0.35)! : l.hairColor);
    canvas.drawLine(p(37, browY), p(44, browY - 1.2), stroke(browColor, l.older ? 2.3 : 1.8));
    canvas.drawLine(p(56, browY - 1.2), p(63, browY), stroke(browColor, l.older ? 2.3 : 1.8));
    // eyes
    for (final x in [41.0, 59.0]) {
      canvas.drawOval(oval(x, 50, 3.1, 3.8 * blink), fill(ink));
      if (blink > 0.5) canvas.drawCircle(p(x + 1, 48.8), 1.1 * u, fill(Colors.white));
      if (l.female && blink > 0.5) {
        final dir = x < 50 ? -1 : 1;
        canvas.drawLine(p(x + dir * 2.6, 47.6), p(x + dir * 4.6, 46), stroke(ink, 1.1));
      }
    }
    // glasses
    if (l.glasses) {
      final frame = stroke(l.female ? l.accent : const Color(0xFF1B1B2F), 1.7);
      if (l.female) {
        canvas.drawRRect(RRect.fromRectAndRadius(oval(41, 50, 7, 5.6), Radius.circular(4 * u)), frame);
        canvas.drawRRect(RRect.fromRectAndRadius(oval(59, 50, 7, 5.6), Radius.circular(4 * u)), frame);
      } else {
        canvas.drawCircle(p(41, 50), 6.6 * u, frame);
        canvas.drawCircle(p(59, 50), 6.6 * u, frame);
      }
      canvas.drawLine(p(47.4, 49.5), p(52.6, 49.5), frame);
    }
    if (niqab) {
      canvas.restore();
      canvas.restore();
      return;
    }
    // cheeks
    canvas.drawCircle(p(35, 58), 3.4 * u, fill(const Color(0xFFFF7A90).withValues(alpha: 0.35)));
    canvas.drawCircle(p(65, 58), 3.4 * u, fill(const Color(0xFFFF7A90).withValues(alpha: 0.35)));
    // mustache
    if (l.mustache) {
      final m = Path()
        ..moveTo(50 * u, 56 * u)
        ..quadraticBezierTo(43 * u, 53.5 * u, 39 * u, 59.5 * u)
        ..quadraticBezierTo(44 * u, 57.5 * u, 50 * u, 59 * u)
        ..quadraticBezierTo(56 * u, 57.5 * u, 61 * u, 59.5 * u)
        ..quadraticBezierTo(57 * u, 53.5 * u, 50 * u, 56 * u)
        ..close();
      canvas.drawPath(m, fill(l.hairColor));
    }
    // smile
    final smile = Path()
      ..moveTo(44 * u, 60 * u)
      ..quadraticBezierTo(50 * u, 66.5 * u, 56 * u, 60 * u);
    if (l.beard) {
      canvas.drawPath(smile..close(), fill(Colors.white));
      canvas.drawPath(Path()..moveTo(44 * u, 60 * u)..quadraticBezierTo(50 * u, 66.5 * u, 56 * u, 60 * u), stroke(ink, 1.6));
    } else {
      canvas.drawPath(smile, stroke(ink, 1.8));
    }
    // earrings
    if (l.hair == _Hair.bun) {
      canvas.drawCircle(p(28, 60), 3 * u, stroke(l.accent, 1.5));
      canvas.drawCircle(p(72, 60), 3 * u, stroke(l.accent, 1.5));
    }
    // headphones on top
    if (l.headphones) {
      canvas.drawArc(oval(50, 48, 27, 27), math.pi + 0.15, math.pi - 0.3, false, stroke(l.accent, 3.4));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(21 * u, 44 * u, 30 * u, 59 * u), Radius.circular(4 * u)), fill(l.accent));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(70 * u, 44 * u, 79 * u, 59 * u), Radius.circular(4 * u)), fill(l.accent));
    }

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AvatarPainter old) => old.blink != blink || old.bob != bob || old.l != l;
}

/// Bottom sheet with the 16 avatars (men rows, women rows). Returns the chosen id.
Future<String?> showAvatarPicker(BuildContext context, {String? current}) => showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _AvatarPicker(current: current),
    );

class _AvatarPicker extends StatefulWidget {
  const _AvatarPicker({this.current});
  final String? current;
  @override
  State<_AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<_AvatarPicker> {
  late String? _sel = widget.current;

  Widget _row(List<String> ids) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final id in ids)
            GestureDetector(
              onTap: () => setState(() => _sel = id),
              child: AnimatedScale(
                scale: _sel == id ? 1.08 : 0.94,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _sel == id ? BrandColors.electric : Colors.transparent, width: 3),
                    boxShadow: _sel == id ? [BoxShadow(color: BrandColors.electric.withValues(alpha: 0.35), blurRadius: 14)] : const [],
                  ),
                  child: HatoAvatar(id: id, size: 66),
                ),
              ),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(ar ? 'اختار الأفاتار بتاعك' : 'Choose your avatar',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
            child: _sel == null
                ? const SizedBox(key: ValueKey('none'), height: 120, child: Icon(Icons.face_retouching_natural_rounded, size: 72, color: BrandColors.border))
                : SizedBox(key: ValueKey(_sel), height: 120, child: Center(child: HatoAvatar(id: _sel!, size: 116))),
          ),
          const SizedBox(height: 18),
          Flexible(
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(ar ? 'رجالة' : 'Men', style: const TextStyle(fontWeight: FontWeight.w700, color: BrandColors.gray)),
                const SizedBox(height: 8),
                _row(const ['m1', 'm2', 'm3', 'm4']),
                const SizedBox(height: 10),
                _row(const ['m5', 'm6', 'm7', 'm8']),
                const SizedBox(height: 16),
                Text(ar ? 'بنات وستات' : 'Women', style: const TextStyle(fontWeight: FontWeight.w700, color: BrandColors.gray)),
                const SizedBox(height: 8),
                _row(const ['f1', 'f2', 'f3', 'f4']),
                const SizedBox(height: 10),
                _row(const ['f5', 'f6', 'f7', 'f8']),
              ]),
            ),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _sel == null || _sel == widget.current ? null : () => Navigator.pop(context, _sel),
            child: Text(ar ? 'حفظ' : 'Save'),
          ),
        ]),
      ),
    );
  }
}
