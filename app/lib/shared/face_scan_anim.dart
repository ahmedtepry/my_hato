import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/supabase_providers.dart';

/// The five face-recognition looks. The Hatō wave is the default; the owner can switch everyone to another one.
const faceScanStyles = ['wave', 'ring', 'mesh', 'fog', 'laser'];

String faceScanStyleName(String id, bool ar) => switch (id) {
      'ring' => ar ? 'حلقة الضوء' : 'Ring of light',
      'mesh' => ar ? 'شبكة الملامح' : 'Feature mesh',
      'fog' => ar ? 'الضباب' : 'Fog',
      'laser' => ar ? 'الليزر' : 'Laser',
      _ => ar ? 'موجة هاتو' : 'Hatō wave',
    };

/// What the owner picked for everyone (application_settings.face_scan_style). Wave when nothing was set.
final faceScanStyleProvider = FutureProvider<String>((ref) async {
  try {
    final rows = await ref.read(supabaseProvider).from('application_settings').select('value').eq('key', 'face_scan_style').limit(1);
    final v = rows.isEmpty ? null : rows.first['value'];
    if (v is Map && faceScanStyles.contains(v['style'])) return v['style'] as String;
  } catch (_) {}
  return 'wave';
});

const _blue = Color(0xFF4FA8F5), _ice = Color(0xFFBFE6FF), _ok = Color(0xFF5EEAD4);

/// The scanner overlay. While [recognized] is false it scans in a loop; when it turns true it plays the
/// "recognized" moment once. Put the camera picture behind it in a Stack.
class FaceScanView extends StatefulWidget {
  const FaceScanView({super.key, required this.style, this.recognized = false, this.failed = false});
  final String style;
  final bool recognized;
  final bool failed;
  @override
  State<FaceScanView> createState() => _FaceScanViewState();
}

class _FaceScanViewState extends State<FaceScanView> with TickerProviderStateMixin {
  late final AnimationController _scan = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200))..repeat();
  late final AnimationController _done = AnimationController(vsync: this, duration: const Duration(milliseconds: 1900));
  bool _reduce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduce) _scan.stop();
  }

  @override
  void didUpdateWidget(FaceScanView old) {
    super.didUpdateWidget(old);
    if (widget.recognized && !old.recognized) {
      _scan.stop();
      _done.forward(from: 0);
    } else if (!widget.recognized && old.recognized) {
      _done.reset();
      if (!_reduce) _scan.repeat();
    }
  }

  @override
  void dispose() {
    _scan.dispose();
    _done.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_scan, _done]),
          builder: (_, __) => CustomPaint(
            painter: _FacePainter(
              widget.style,
              widget.recognized ? 1 : (_reduce ? 0.6 : _scan.value),
              widget.recognized,
              widget.recognized ? (_reduce ? 1 : _done.value) : 0,
              widget.failed,
              _scan.lastElapsedDuration?.inMilliseconds ?? 0,
            ),
            size: Size.infinite,
          ),
        ),
      );
}

// ------------------------------------------------------------------------------------------- drawn face (280x320 box)
const double _w = 280, _h = 320, _cx = 140, _cy = 150, _rx = 72, _ry = 94;

Offset _contour(double t) {
  final y = _cy - _ry * math.cos(t);
  final k = math.max(0.0, (y - _cy) / _ry);
  final w = 1 - 0.30 * math.pow(k, 1.6);
  return Offset(_cx + _rx * math.sin(t) * w, y);
}

final List<Offset> _out = [for (var i = 0; i < 36; i++) _contour(i / 36 * math.pi * 2)];
final List<Offset> _pts = () {
  final f = <Offset>[..._out];
  for (final s in [-1, 1]) {
    for (var i = 0; i < 8; i++) {
      final a = i / 8 * math.pi * 2;
      f.add(Offset(_cx + s * 28 + math.cos(a) * 11, _cy - 14 + math.sin(a) * 5));
    }
    for (var i = 0; i < 5; i++) {
      f.add(Offset(_cx + s * (14 + i * 7), _cy - 32 - math.sin(i / 4 * math.pi) * 5));
    }
  }
  for (var i = 0; i < 5; i++) {
    f.add(Offset(_cx, _cy - 6 + i * 8));
  }
  f.addAll(const [Offset(_cx - 8, _cy + 26), Offset(_cx + 8, _cy + 26)]);
  for (var i = 0; i < 10; i++) {
    final a = i / 10 * math.pi * 2;
    f.add(Offset(_cx + math.cos(a) * 20, _cy + 48 + math.sin(a) * (a < math.pi ? 6 : 3)));
  }
  return f;
}();
final List<(int, int)> _edges = () {
  final e = <(int, int)>[];
  for (var i = 0; i < _pts.length; i++) {
    final d = [
      for (var j = 0; j < _pts.length; j++)
        if (j != i) (j, (_pts[i] - _pts[j]).distance)
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    for (final (j, dd) in d.take(3)) {
      if (dd < 60 && i < j) e.add((i, j));
    }
  }
  return e;
}();

double _rnd(num i) {
  final s = math.sin(i * 127.1 + 311.7) * 43758.5453;
  return s - s.floorToDouble();
}

double _ease(double t) => t < .5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2;

class _Dust {
  _Dust(int i)
      : sx = _rnd(i) * _w,
        sy = _rnd(i + 999) * _h,
        tg = _pts[i % _pts.length],
        jx = (_rnd(i + 5) - .5) * 6,
        jy = (_rnd(i + 7) - .5) * 6,
        s = .6 + _rnd(i + 3) * 1.4;
  final double sx, sy, jx, jy, s;
  final Offset tg;
}

final List<_Dust> _fog = [for (var i = 0; i < 420; i++) _Dust(i)];

class _FacePainter extends CustomPainter {
  _FacePainter(this.style, this.t, this.ok, this.o, this.failed, this.ms);
  final String style;
  final double t, o;
  final bool ok, failed;
  final int ms;

  /// seconds since the scan started: keeps continuous motion (waves, fog drift) smooth across loops
  double get _clock => ms / 1000;

  @override
  void paint(Canvas c, Size size) {
    final k = math.min(size.width / _w, size.height / _h);
    c.save();
    c.translate((size.width - _w * k) / 2, (size.height - _h * k) / 2);
    c.scale(k);
    switch (style) {
      case 'ring':
        _ring(c);
      case 'mesh':
        _mesh(c);
      case 'fog':
        _fogDraw(c);
      case 'laser':
        _laser(c);
      default:
        _wave(c);
    }
    c.restore();
  }

  Color get _scanColor => failed ? const Color(0xFFF0A453) : _blue;

  Paint _stroke(Color col, double w, {double glow = 0}) {
    final p = Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    if (glow > 0) p.maskFilter = MaskFilter.blur(BlurStyle.solid, glow);
    return p;
  }

  void _faceOutline(Canvas c, double a, Color col) {
    final path = Path()..addPolygon(_out, true);
    c.drawPath(path, _stroke(col.withValues(alpha: a), 1.2));
  }

  // ------------------------------------------------------------------ C: Hatō wave (default)
  void _wave(Canvas c) {
    const lines = 26;
    final k = ok ? _ease(math.min(1, o * 1.4)) : 0.0;
    final band = (t * 1.3) % 1;
    for (var l = 0; l < lines; l++) {
      final base = 40 + l * (240 / lines);
      final path = Path();
      for (double x = 0; x <= _w; x += 4) {
        var y = base + math.sin(x / _w * math.pi * 2 + _clock * 1.7 + l * .25) * 6;
        final dy = (y - _cy) / _ry, dx = (x - _cx) / _rx, r = dx * dx + dy * dy;
        if (r < 1) y -= math.sqrt(1 - r) * 26 * math.min(1.0, ok ? 1.0 : t * 2.2);
        final target = (l < lines / 2 ? _cy - 18 : _cy + 22) - math.sin((x - 40) / 200 * math.pi * 1.1) * 34;
        y = y + (target - y) * k;
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      final lit = (l - lines * band).abs() < 2;
      final a = ok ? (.45 + .4 * k) : (lit ? .8 : .3);
      c.drawPath(path, _stroke((ok ? _ice : _scanColor).withValues(alpha: math.min(1.0, a)), ok ? 1.6 : 1.1, glow: ok || lit ? 3 : 0));
    }
  }

  // ------------------------------------------------------------------ A: ring of ticks
  void _ring(Canvas c) {
    const r = 90.0, n = 60;
    _faceOutline(c, .18, _blue);
    final order = List.generate(n, (i) => i)..sort((a, b) => _rnd(a).compareTo(_rnd(b)));
    final lit = order.take(((ok ? 1 : t) * n).floor()).toSet();
    final sweep = (t * math.pi * 6) % (math.pi * 2);
    for (var i = 0; i < n; i++) {
      final a = i / n * math.pi * 2 - math.pi / 2;
      final near = math.cos(a - sweep + math.pi / 2) > 0.96;
      final on = ok || lit.contains(i);
      final col = ok ? _ok : on ? _ice : near ? _scanColor : const Color(0xFF1B3A64);
      final r2 = r + (on ? 12 : 8) + (ok ? math.sin(o * math.pi) * 4 : 0);
      c.drawLine(Offset(_cx + math.cos(a) * r, _cy + math.sin(a) * r), Offset(_cx + math.cos(a) * r2, _cy + math.sin(a) * r2), _stroke(col, on ? 3.2 : 2, glow: on || near ? 3 : 0));
    }
    if (ok) {
      final k = _ease(math.min(1, o * 2));
      const p0 = Offset(_cx - 30, _cy + 2), p1 = Offset(_cx - 8, _cy + 24), p2 = Offset(_cx + 34, _cy - 22);
      final path = Path()..moveTo(p0.dx, p0.dy);
      if (k < .4) {
        final q = Offset.lerp(p0, p1, k / .4)!;
        path.lineTo(q.dx, q.dy);
      } else {
        final q = Offset.lerp(p1, p2, (k - .4) / .6)!;
        path
          ..lineTo(p1.dx, p1.dy)
          ..lineTo(q.dx, q.dy);
      }
      c.drawPath(path, _stroke(_ok, 6, glow: 4));
    }
  }

  // ------------------------------------------------------------------ B: landmark mesh
  void _mesh(Canvas c) {
    final n = ok ? _pts.length : math.min(_pts.length, (t * 1.25 * _pts.length).floor());
    final pulse = ok ? math.sin(math.min(1, o * 1.6) * math.pi) : 0.0;
    for (final (i, j) in _edges) {
      if (i >= n || j >= n) continue;
      final fl = ok ? 1.0 : .35 + .65 * _rnd(i * 3 + j + (t * 30).floor());
      c.drawLine(_pts[i], _pts[j], _stroke(ok ? _ok.withValues(alpha: .35 + pulse * .5) : _scanColor.withValues(alpha: .3 * fl), .8));
    }
    final dot = Paint();
    for (var i = 0; i < n; i++) {
      final fresh = !ok && i > n - 6;
      dot.color = ok ? _ok : fresh ? Colors.white : _ice;
      c.drawCircle(_pts[i], fresh ? 2.6 : 1.7 + pulse * 1.2, dot);
    }
  }

  // ------------------------------------------------------------------ D: fog of light dust
  void _fogDraw(Canvas c) {
    final k = ok ? 1.0 : _ease(math.min(1, t * 1.1));
    final flash = ok ? math.max(0.0, 1 - o * 1.5) : 0.0;
    final p = Paint();
    for (var i = 0; i < _fog.length; i++) {
      final d = _fog[i];
      final x = d.sx + (d.tg.dx + d.jx - d.sx) * k + math.sin(_clock * .7 + i) * 10 * (1 - k);
      final y = d.sy + (d.tg.dy + d.jy - d.sy) * k + math.cos(_clock * .6 + i) * 10 * (1 - k);
      p.color = ok ? _ok.withValues(alpha: .55 + flash * .45) : _ice.withValues(alpha: .18 + .55 * k * _rnd(i + (t * 20).floor()));
      c.drawCircle(Offset(x, y), d.s + flash * 1.2, p);
    }
    if (ok) _faceOutline(c, .5 * math.min(1, o * 2), _ok);
  }

  // ------------------------------------------------------------------ E: laser sweep
  void _laser(Canvas c) {
    const top = _cy - _ry - 14, bot = _cy + _ry + 14;
    final p = ok ? 1.0 : (t * 2) % 1;
    final down = (t * 2).floor() % 2 == 0;
    final ly = top + (down ? p : 1 - p) * (bot - top);
    for (double y = top; y <= bot; y += 5) {
      final seen = ok || t > .5 || (down ? y <= ly : y >= ly);
      if (!seen) continue;
      final ty = (_cy - y) / _ry;
      if (ty.abs() > 1) continue;
      final x2 = _contour(math.acos(ty.clamp(-1.0, 1.0))).dx, x1 = 2 * _cx - x2;
      c.drawLine(Offset(x1, y), Offset(x2, y), _stroke(ok ? _ok.withValues(alpha: .55) : _scanColor.withValues(alpha: .25 + .35 * _rnd(y + (t * 14).floor())), 1));
    }
    if (!ok) {
      c.drawRect(Rect.fromLTWH(_cx - _rx - 26, ly - 1, (_rx + 26) * 2, 2), Paint()
        ..color = _ice
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 5));
    }
    final k = ok ? _ease(math.min(1, o * 2.2)) : 0.0;
    final pad = 34 - 14 * k, x0 = _cx - _rx - pad, x1 = _cx + _rx + pad, y0 = top - pad + 14, y1 = bot + pad - 14;
    const cl = 22.0;
    final st = _stroke(ok ? _ok : _ice.withValues(alpha: .45), ok ? 3 : 1.5, glow: ok ? 3 : 0);
    for (final (x, y, sx, sy) in [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)]) {
      c.drawPath(
          Path()
            ..moveTo(x, y + sy * cl)
            ..lineTo(x, y)
            ..lineTo(x + sx * cl, y),
          st);
    }
  }

  @override
  bool shouldRepaint(_FacePainter old) => true;
}
