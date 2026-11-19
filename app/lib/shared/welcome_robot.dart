import 'dart:math' as math;

import '../core/reduce_motion.dart';
import 'package:flutter/material.dart';

import '../core/appearance.dart';
import '../core/l10n.dart';
import 'brand_logo.dart';

/// "APK welcome logo": the assistant robot comes out from behind the edge of the logo and says hello.
///  - 'peek': slides out at an angle, waves and smiles.
///  - 'call': slides out holding a phone, puts it to its ear, jumps onto the top of the M, sits with its legs crossed and talks.
/// Played once (about 3.4 / 4.2 seconds). The customer app shows it as the opening animation when the owner turns it on.
class WelcomeRobot extends StatefulWidget {
  const WelcomeRobot({super.key, required this.variant, this.scale = 1, this.greeting});
  final String variant;
  final double scale;

  /// Replaces the default "Welcome to ..." line (the team login greets the employee by the name typed).
  final String? greeting;

  static bool isWelcome(String v) => v == 'peek' || v == 'call';
  static Duration durationOf(String v) => Duration(milliseconds: v == 'call' ? 4200 : 3400);

  @override
  State<WelcomeRobot> createState() => _WelcomeRobotState();
}

class _WelcomeRobotState extends State<WelcomeRobot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: WelcomeRobot.durationOf(widget.variant), value: ReduceMotion.on ? 1 : 0)..forward(); // fast mode: final pose at once

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool get _call => widget.variant == 'call';

  String _hello(BuildContext context) {
    final nameAr = AppName.ar == 'My Hatō' ? 'ماي هاتو' : AppName.ar;
    final nameEn = AppName.en.replaceAll(' ', '');
    return context.isAr ? 'أهلاً بيك في $nameAr!' : 'Welcome to $nameEn!';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    final text = widget.greeting ?? _hello(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value * _c.duration!.inMilliseconds / 1000.0;
        final pose = robotPose(widget.variant, t);
        final front = _call && t >= 1.3; // behind the logo until it jumps onto it
        final robot = RobotLook.at(widget.variant, t);
        Widget robotAt() => Positioned(
              left: 65 * s,
              top: 48 * s,
              width: 72 * s,
              height: 72 * s,
              child: CustomPaint(painter: _RobotPainter(look: robot, pose: pose, scale: s)),
            );
        final bubbleIn = _call ? 1.9 : 1.1;
        final bubble = ((t - bubbleIn) / 0.3).clamp(0.0, 1.0);
        final bw = (_call ? 220.0 : 180.0) * s;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 140 * s,
            height: 140 * s,
            child: Stack(clipBehavior: Clip.none, children: [
              if (!front) robotAt(),
              Container(
                width: 140 * s,
                height: 140 * s,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32 * s),
                  gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1E3F7F), Color(0xFF0F2145)]),
                ),
                child: Center(child: BrandMark(size: 104 * s, onDark: true)),
              ),
              if (front) robotAt(),
              Positioned(
                left: (_call ? -7 : 55) * s,
                top: -138 * s,
                width: bw,
                child: Opacity(
                  opacity: bubble,
                  child: Transform.translate(
                    offset: Offset(0, 8 * s * (1 - bubble)),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 10 * s),
                        decoration: BoxDecoration(color: const Color(0xFFEAF3FF), borderRadius: BorderRadius.circular(16 * s)),
                        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: const Color(0xFF152C58), fontSize: 15 * s, fontWeight: FontWeight.w800, decoration: TextDecoration.none)),
                      ),
                      Transform.translate(
                        offset: Offset(_call ? 60 * s : 0, -7 * s),
                        child: Transform.rotate(angle: math.pi / 4, child: Container(width: 14 * s, height: 14 * s, decoration: BoxDecoration(color: const Color(0xFFEAF3FF), borderRadius: BorderRadius.circular(3 * s)))),
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
          SizedBox(height: 20 * s),
          BrandWordmark(size: 30 * s, onDark: true, showSlogan: true),
        ]);
      },
    );
  }
}

/// Where the robot is (offset in px at scale 1 from its hiding place, tilt in degrees, squash) at time t seconds.
class RobotPose {
  const RobotPose(this.x, this.y, this.rot, this.sx, this.sy);
  final double x, y, rot, sx, sy;
}

typedef _Key = (double, double, double, double, double, double);

const _peekKeys = <_Key>[
  (0, 0, 0, 0, 1, 1),
  (0.35, 0, 0, 0, 1, 1),
  (0.75, 44, -94, 28, 0.94, 1.08),
  (0.95, 34, -76, 20, 1.06, 0.94),
  (1.15, 38, -82, 23, 1, 1),
  (99, 38, -82, 23, 1, 1),
];

const _callKeys = <_Key>[
  (0, 0, 0, 0, 1, 1),
  (0.3, 0, 0, 0, 1, 1),
  (0.65, 44, -94, 28, 0.94, 1.08),
  (0.8, 34, -76, 20, 1.06, 0.94),
  (0.9, 38, -82, 23, 1, 1),
  (1.3, 38, -82, 23, 1, 1),
  (1.5, 14, -130, 8, 0.94, 1.08),
  (1.7, -6, -76, -3, 1.1, 0.9),
  (1.8, -6, -76, -3, 1, 1),
  (99, -6, -76, -3, 1, 1),
];

RobotPose robotPose(String variant, double t) {
  final keys = variant == 'call' ? _callKeys : _peekKeys;
  for (var i = 1; i < keys.length; i++) {
    if (t <= keys[i].$1) {
      final a = keys[i - 1], b = keys[i];
      final u = Curves.easeInOut.transform(((t - a.$1) / (b.$1 - a.$1)).clamp(0.0, 1.0));
      double m(double p, double q) => p + (q - p) * u;
      return RobotPose(m(a.$2, b.$2), m(a.$3, b.$3), m(a.$4, b.$4), m(a.$5, b.$5), m(a.$6, b.$6));
    }
  }
  final l = keys.last;
  return RobotPose(l.$2, l.$3, l.$4, l.$5, l.$6);
}

/// Everything about the robot's face, arm and legs at one moment.
class RobotLook {
  const RobotLook({required this.armDeg, required this.phone, required this.sit, required this.mouthOpen, required this.happy, required this.blink, required this.shinDeg, required this.waves});
  final double armDeg; // 0 = arm straight up, 180 = hanging down
  final bool phone;
  final bool sit;
  final double mouthOpen; // < 0: smiling with a closed mouth
  final double happy; // 0..1, closed smiling eyes + cheeks
  final double blink; // eye height 0.1..1
  final double shinDeg;
  final double waves; // phone sound waves 0..1

  static double _lerp(double a, double b, double u) => a + (b - a) * Curves.easeInOut.transform(u.clamp(0.0, 1.0));

  factory RobotLook.at(String variant, double t) {
    final m = t % 3.0;
    final blink = (m > 2.8 && m < 2.92) ? 0.1 : 1.0;
    if (variant == 'call') {
      final arm = t < 0.3 ? 172.0 : (t < 1.0 ? _lerp(172, -8, (t - 0.3) / 0.7) : -8.0);
      final ring = (t > 1.0 && t < 1.3) ? math.sin((t - 1.0) * 60) * 2 : 0.0;
      final talking = t > 1.85;
      return RobotLook(
        armDeg: arm + ring,
        phone: true,
        sit: t >= 1.7,
        mouthOpen: talking ? 0.25 + 0.75 * (0.5 + 0.5 * math.sin(t * 2 * math.pi / 0.56)) : -1,
        happy: 0,
        blink: blink,
        shinDeg: math.sin(t * 2 * math.pi / 1.8) * 9,
        waves: t > 1.0 ? 0.25 + 0.75 * (0.5 + 0.5 * math.sin(t * 2 * math.pi / 0.7)) : 0,
      );
    }
    final waving = t > 1.2 && t < 2.5;
    return RobotLook(
      armDeg: -12 + (waving ? math.sin((t - 1.2) / 1.3 * 3 * 2 * math.pi) * 24 : 0),
      phone: false,
      sit: false,
      mouthOpen: -1,
      happy: ((t - 0.95) / 0.2).clamp(0.0, 1.0),
      blink: blink,
      shinDeg: 0,
      waves: 0,
    );
  }
}

class _RobotPainter extends CustomPainter {
  _RobotPainter({required this.look, required this.pose, required this.scale});
  final RobotLook look;
  final RobotPose pose;
  final double scale;

  static const _white = Color(0xFFEAF3FF);
  static const _navy = Color(0xFF152C58);
  static const _cyan = Color(0xFF6FD3FF);
  static const _light = Color(0xFF7FC4FF);
  static const _body = Color(0xFFBFE0FF);
  static const _legs = Color(0xFF9ED3FF);

  @override
  void paint(Canvas c, Size size) {
    final s = scale;
    c.save();
    // squash and tilt around the feet, then into the 72 x 72 design box (svg viewBox -8 -4 72 72)
    c.translate((36 + pose.x) * s, (72 + pose.y) * s);
    c.rotate(pose.rot * math.pi / 180);
    c.scale(pose.sx, pose.sy);
    c.translate(-36 * s, -72 * s);
    c.scale(s);
    c.translate(8, 4);
    _robot(c);
    c.restore();
  }

  void _rr(Canvas c, double x, double y, double w, double h, double r, Color col, {Paint? paint}) =>
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)), paint ?? (Paint()..color = col));

  void _robot(Canvas c) {
    final l = look;
    if (l.sit) _rr(c, 17, 55, 8, 12, 4, _light);
    // antenna
    c.drawLine(const Offset(28, 9), const Offset(28, 12), Paint()..color = _light..strokeWidth = 2.5..strokeCap = StrokeCap.round);
    c.drawCircle(const Offset(28, 5), 3.5, Paint()..color = _light);
    _rr(c, 1, 21, 5, 10, 2.5, _light);
    _rr(c, 50, 21, 5, 10, 2.5, _light);
    _rr(c, 6, 11, 44, 31, 12, _white);
    _rr(c, 11, 17, 34, 19, 8, _navy);
    // eyes
    final eye = Paint()..color = _cyan.withValues(alpha: 1 - l.happy);
    for (final x in const [21.0, 35.0]) {
      c.save();
      c.translate(x, 25);
      c.scale(1, l.blink);
      c.drawCircle(Offset.zero, 3.8, eye);
      c.restore();
    }
    if (l.happy > 0) {
      final arc = Paint()..color = _cyan.withValues(alpha: l.happy)..style = PaintingStyle.stroke..strokeWidth = 2.4..strokeCap = StrokeCap.round;
      c.drawPath(Path()..moveTo(17, 26.5)..quadraticBezierTo(21, 20.5, 25, 26.5), arc);
      c.drawPath(Path()..moveTo(31, 26.5)..quadraticBezierTo(35, 20.5, 39, 26.5), arc);
      final cheek = Paint()..color = const Color(0xFFFF8FB1).withValues(alpha: 0.7 * l.happy);
      c.drawCircle(const Offset(15, 31), 2.4, cheek);
      c.drawCircle(const Offset(41, 31), 2.4, cheek);
    }
    // mouth
    if (l.mouthOpen >= 0) {
      c.drawOval(Rect.fromCenter(center: const Offset(28, 32), width: 7.2, height: 5.6 * l.mouthOpen), Paint()..color = _cyan);
    } else {
      c.drawPath(Path()..moveTo(22, 30.5)..quadraticBezierTo(28, 37, 34, 30.5), Paint()..color = _cyan..style = PaintingStyle.stroke..strokeWidth = 2..strokeCap = StrokeCap.round);
    }
    // body and resting arm
    _rr(c, 15, 43, 26, 14, 7, _body);
    c.drawCircle(const Offset(28, 50), 2.6, Paint()..color = _navy);
    _rr(c, 8, 45, 6, 13, 3, _body);
    if (!l.sit) {
      _rr(c, 16, 57, 9, 5, 2.5, _light);
      _rr(c, 31, 57, 9, 5, 2.5, _light);
    } else {
      _rr(c, 14, 52, 26, 8, 4, _legs);
      c.save();
      c.translate(14, 55);
      c.rotate(l.shinDeg * math.pi / 180);
      c.translate(-14, -55);
      _rr(c, 8, 55, 8, 12, 4, _legs);
      c.restore();
    }
    // the raised arm (with the phone)
    c.save();
    c.translate(47, 48);
    c.rotate(l.armDeg * math.pi / 180);
    c.translate(-47, -48);
    _rr(c, 43.5, 27, 7, 22, 3.5, _body);
    c.drawCircle(const Offset(47, 27), 5.2, Paint()..color = _white);
    if (l.phone) {
      _rr(c, 49.5, 14, 8, 16, 2.6, const Color(0xFF20324F));
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(49.5, 14, 8, 16), const Radius.circular(2.6)), Paint()..color = _light..style = PaintingStyle.stroke..strokeWidth = 1.2);
      _rr(c, 51, 16, 5, 9, 1.2, _cyan.withValues(alpha: 0.8));
    }
    c.restore();
    if (l.waves > 0 && l.armDeg < 20) {
      final w = Paint()..color = _light.withValues(alpha: l.waves)..style = PaintingStyle.stroke..strokeWidth = 2..strokeCap = StrokeCap.round;
      c.drawPath(Path()..moveTo(61, 17)..quadraticBezierTo(65, 22, 61, 27), w);
      c.drawPath(Path()..moveTo(65, 13)..quadraticBezierTo(72, 22, 65, 31), w);
    }
  }

  @override
  bool shouldRepaint(covariant _RobotPainter old) => true;
}
