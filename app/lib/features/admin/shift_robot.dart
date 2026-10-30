// The shift robot: a drawn robot with moods, a typing console whose lines fly into its head, and the fingerprint helper.
// It only shows and asks. It never changes a shift by itself: closing and opening stay with the cashier.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

// ---------------------------------------------------------------- fingerprint
/// The fingerprint never leaves the device. After the cashier proves his password once, the password is kept in the
/// device's encrypted storage and released only after the system fingerprint / Windows Hello prompt. The server still checks it every time.
class ShiftBio {
  static final LocalAuthentication _auth = LocalAuthentication();
  static const FlutterSecureStorage _store = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static String _key(String uid) => 'bio_pw_$uid';

  static Future<bool> available() async {
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> enabled(String uid) async {
    try {
      return (await _store.read(key: _key(uid))) != null;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> prompt(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, options: const AuthenticationOptions(stickyAuth: true));
    } catch (_) {
      return false;
    }
  }

  /// The saved password after a successful fingerprint, or null.
  static Future<String?> secret(String uid, String reason) async {
    if (!await prompt(reason)) return null;
    try {
      return await _store.read(key: _key(uid));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> save(String uid, String password, String reason) async {
    if (!await prompt(reason)) return false;
    try {
      await _store.write(key: _key(uid), value: password);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clear(String uid) async {
    try {
      await _store.delete(key: _key(uid));
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- verses and sayings about trust
class TrustWords {
  static const List<(String, String, String)> all = [
    ('إِنَّ اللَّهَ يَأْمُرُكُمْ أَن تُؤَدُّوا الْأَمَانَاتِ إِلَىٰ أَهْلِهَا', 'سورة النساء · الآية 58', 'الأمانة تبدأ من أول جنيه تعدّه.'),
    ('وَالَّذِينَ هُمْ لِأَمَانَاتِهِمْ وَعَهْدِهِمْ رَاعُونَ', 'سورة المؤمنون · الآية 8', 'وردية النهارده أمانة في إيدك.'),
    ('إِنَّ خَيْرَ مَنِ اسْتَأْجَرْتَ الْقَوِيُّ الْأَمِينُ', 'سورة القصص · الآية 26', 'القوة في الشغل، والأمانة في الحساب.'),
    ('وَأَوْفُوا الْكَيْلَ وَالْمِيزَانَ بِالْقِسْطِ', 'سورة الأنعام · الآية 152', 'الحساب المظبوط رزق مبارك.'),
    ('يَا أَيُّهَا الَّذِينَ آمَنُوا لَا تَخُونُوا اللَّهَ وَالرَّسُولَ وَتَخُونُوا أَمَانَاتِكُمْ وَأَنتُمْ تَعْلَمُونَ', 'سورة الأنفال · الآية 27', 'اللي بيحفظ الأمانة بيرتاح.'),
  ];

  static (String, String, String) today() {
    final d = DateTime.now();
    final n = d.difference(DateTime(d.year, 1, 1)).inDays;
    return all[n % all.length];
  }
}

// ---------------------------------------------------------------- the console
enum LineKind { code, note }

class ConsoleLine {
  ConsoleLine(this.text, this.kind);
  String text;
  final LineKind kind;
  String tail = '';
  bool warn = false;
}

enum RobotMood { idle, work, happy, worry }

/// Drives one robot scene: its mood, what it says, and the console lines (each typed fast, then thrown into its head).
class StageController extends ChangeNotifier {
  RobotMood mood = RobotMood.idle;
  String said = '';
  final List<ConsoleLine> lines = [];
  final GlobalKey consoleKey = GlobalKey();
  final GlobalKey<RobotViewState> robotKey = GlobalKey<RobotViewState>();
  BuildContext? ctx;
  bool sunrise = false; // opening: a small sun rises behind the robot
  bool sleeping = false; // closing: the robot switches its lights off
  bool _dead = false;
  int _sayId = 0;
  final math.Random _rnd = math.Random();

  bool get dead => _dead;

  @override
  void dispose() {
    _dead = true;
    super.dispose();
  }

  // Repaint at most ~30 times a second: the code is typed a few milliseconds per letter, and re-laying out the whole scene on every
  // letter froze the Windows app.
  bool _pending = false;
  void _ping() {
    if (_dead || _pending) return;
    _pending = true;
    Timer(const Duration(milliseconds: 33), () {
      _pending = false;
      if (!_dead) notifyListeners();
    });
  }

  void setMood(RobotMood m) {
    mood = m;
    _ping();
  }

  void rise() {
    sunrise = true;
    _ping();
  }

  /// The robot waves goodbye (already happy), then its lights go off one by one and the scene darkens.
  void lightsOff() {
    sleeping = true;
    robotKey.currentState?.powerOff();
    _ping();
  }

  Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  /// The robot speaks: the bubble types the sentence (a newer sentence replaces an older one).
  Future<void> say(String text, {int ms = 28}) async {
    final id = ++_sayId;
    said = '';
    _ping();
    for (var i = 1; i <= text.length; i++) {
      if (_dead || id != _sayId) return;
      said = text.substring(0, i);
      _ping();
      await _wait(ms);
    }
  }

  void clear() {
    lines.clear();
    _ping();
  }

  Future<ConsoleLine> typeLine(String text, {LineKind kind = LineKind.code, int ms = 7, bool toss = true}) async {
    final l = ConsoleLine('', kind);
    lines.add(l);
    if (lines.length > 9) lines.removeAt(0);
    for (var i = 1; i <= text.length; i++) {
      if (_dead) return l;
      l.text = text.substring(0, i);
      _ping();
      await _wait(ms);
    }
    if (toss && kind == LineKind.code) this.toss(text);
    return l;
  }

  void tail(ConsoleLine l, String text, {bool warn = false}) {
    l.tail = text;
    l.warn = warn;
    _ping();
  }

  static const _pool = [
    'rows.fetch(page=%d)', 'hash 9f3a1c%d…e7', 'sum(total) = %d.00', 'assert refunds <= limit', 'cursor.next() -> %d',
    'invoice[%d].lines ok', 'checksum 0x%d ok', 'diff = 0.00', 'lock shift.284', 'verify row %d/37',
  ];

  String filler() => _pool[_rnd.nextInt(_pool.length)].replaceAll('%d', '${_rnd.nextInt(900) + 10}');

  /// A fast stream of code for [ms] milliseconds.
  Future<void> stream(int ms) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!_dead && DateTime.now().isBefore(end)) {
      await typeLine('  ${filler()}', ms: 5);
      await _wait(90);
    }
  }

  // ---- flying chips (the line is thrown into the robot's head)
  void toss(String text) {
    final c = ctx;
    if (c == null || _dead) return;
    try {
      final box = consoleKey.currentContext?.findRenderObject() as RenderBox?;
      final rb = robotKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || rb == null || !box.attached || !rb.attached) return;
      final cp = box.localToGlobal(Offset.zero);
      final rp = rb.localToGlobal(Offset.zero);
      final from = Offset(cp.dx + 40 + _rnd.nextInt(60), cp.dy + box.size.height - 28 - _rnd.nextInt(40));
      final to = Offset(rp.dx + rb.size.width * .5, rp.dy + rb.size.height * .29);
      final overlay = Overlay.of(c, rootOverlay: true);
      late OverlayEntry entry;
      entry = OverlayEntry(
        builder: (_) => _FlyingChip(
          text: text.length > 28 ? text.substring(0, 28) : text,
          from: from,
          to: to,
          bend: Offset(-60 - _rnd.nextInt(50).toDouble(), -50 - _rnd.nextInt(60).toDouble()),
          onDone: () {
            entry.remove();
            robotKey.currentState?.pulse();
          },
        ),
      );
      overlay.insert(entry);
    } catch (_) {/* the effect is only decoration */}
  }
}

class _FlyingChip extends StatefulWidget {
  const _FlyingChip({required this.text, required this.from, required this.to, required this.bend, required this.onDone});
  final String text;
  final Offset from, to, bend;
  final VoidCallback onDone;
  @override
  State<_FlyingChip> createState() => _FlyingChipState();
}

class _FlyingChipState extends State<_FlyingChip> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    })
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Offset _at(double t) {
    final ctrl = Offset((widget.from.dx + widget.to.dx) / 2 + widget.bend.dx, math.min(widget.from.dy, widget.to.dy) + widget.bend.dy);
    final a = Offset.lerp(widget.from, ctrl, t)!;
    final b = Offset.lerp(ctrl, widget.to, t)!;
    return Offset.lerp(a, b, t)!;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = Curves.easeInCubic.transform(_c.value);
          final p = _at(t);
          final scale = 1 - .88 * t;
          return Positioned(
            left: p.dx,
            top: p.dy,
            child: FractionalTranslation(
              translation: const Offset(-.5, -.5),
              child: Opacity(
                opacity: (1 - .8 * t).clamp(0.0, 1.0),
                child: Transform.rotate(
                  angle: .3 * t,
                  child: Transform.scale(
                    scale: scale,
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xEB07110F),
                          border: Border.all(color: const Color(0xFF2DC4B2)),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(widget.text, style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: _monoFallback, fontSize: 12, color: Color(0xFF9FE7D6), decoration: TextDecoration.none, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

const _monoFallback = ['Courier New', 'DejaVu Sans Mono', 'monospace'];

/// The dark console box. Put it anywhere; the flying chips start from it.
class StageConsole extends StatelessWidget {
  const StageConsole({super.key, required this.ctl, this.height = 220});
  final StageController ctl;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (_, __) => RepaintBoundary(child: Container(
        key: ctl.consoleKey,
        height: height,
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFF07110F), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF17322E))),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in ctl.lines)
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: l.kind == LineKind.note ? '// ${l.text}' : (l.text.startsWith('  ') ? l.text : '> ${l.text}'),
                      style: TextStyle(color: l.kind == LineKind.note ? const Color(0xFF4F7F75) : const Color(0xFF9FE7D6), fontFamily: l.kind == LineKind.note ? Theme.of(context).textTheme.bodyMedium?.fontFamily : null),
                    ),
                    if (l.tail.isNotEmpty) TextSpan(text: '  ${l.warn ? '▲' : '√'} ${l.tail}', style: TextStyle(color: l.warn ? const Color(0xFFFFB454) : const Color(0xFF4FE0A0))),
                  ]),
                  style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: _monoFallback, fontSize: 12.5, height: 1.65),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
            ],
          ),
        ),
      )),
    );
  }
}

// ---------------------------------------------------------------- the dark scene: bubble + robot
class RobotScene extends StatefulWidget {
  const RobotScene({super.key, required this.ctl, this.robotWidth = 260});
  final StageController ctl;
  final double robotWidth;
  @override
  State<RobotScene> createState() => _RobotSceneState();
}

class _RobotSceneState extends State<RobotScene> {
  @override
  void initState() {
    super.initState();
    widget.ctl.ctx = context;
  }

  @override
  Widget build(BuildContext context) {
    widget.ctl.ctx = context;
    final ctl = widget.ctl;
    return ListenableBuilder(
      listenable: ctl,
      builder: (_, __) => AnimatedContainer(
        duration: const Duration(milliseconds: 1400),
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -.3),
            radius: 1.0,
            colors: ctl.sleeping ? const [Color(0xFF0B1516), Color(0xFF05090A), Color(0xFF020405)] : const [Color(0xFF16403F), Color(0xFF0A1C1F), Color(0xFF050D10)],
            stops: const [0, .55, 1],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
        child: Stack(children: [
          if (ctl.sunrise) const Positioned.fill(child: _Sunrise()),
          Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                constraints: const BoxConstraints(minHeight: 64, maxWidth: 330),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0x1A9FE7D6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0x599FE7D6)),
                ),
                alignment: Alignment.center,
                child: Text(ctl.said.isEmpty ? ' ' : ctl.said,
                    textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFDFFAF3), fontSize: 15, fontWeight: FontWeight.w600, height: 1.5)),
              ),
              const SizedBox(height: 10),
              // on a problem the robot leans in towards the cashier
              AnimatedScale(
                scale: ctl.mood == RobotMood.worry ? 1.14 : 1.0,
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutBack,
                child: SizedBox(width: widget.robotWidth, child: RepaintBoundary(child: RobotView(key: ctl.robotKey, mood: ctl.mood))),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A small sun that rises behind the robot, with slowly turning rays.
class _Sunrise extends StatelessWidget {
  const _Sunrise();
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(seconds: 4),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => CustomPaint(painter: _SunPainter(v)),
    );
  }
}

class _SunPainter extends CustomPainter {
  _SunPainter(this.p);
  final double p;
  @override
  void paint(Canvas c, Size s) {
    final center = Offset(s.width / 2, s.height * (1.05 - .5 * p));
    final r = s.width * .24;
    c.drawRect(Offset.zero & s, Paint()..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color.fromRGBO(255, 160, 60, .35 * p), const Color(0x00FFA03C)]).createShader(Offset.zero & s));
    for (var i = 0; i < 14; i++) {
      final a = i / 14 * 2 * math.pi + p * 1.5;
      c.drawLine(center + Offset(math.cos(a), math.sin(a)) * (r * 1.2), center + Offset(math.cos(a), math.sin(a)) * (r * (1.9 + .2 * math.sin(a * 3))),
          Paint()..color = Color.fromRGBO(255, 200, 90, .5 * p)..strokeWidth = 3..strokeCap = StrokeCap.round);
    }
    final rect = Rect.fromCircle(center: center, radius: r);
    c.drawCircle(center, r, Paint()..shader = const RadialGradient(colors: [Color(0xFFFFF1B0), Color(0xFFFFB347), Color(0xFFFF8A3C)]).createShader(rect));
  }

  @override
  bool shouldRepaint(covariant _SunPainter old) => old.p != p;
}

// ---------------------------------------------------------------- the robot itself
class RobotView extends StatefulWidget {
  const RobotView({super.key, required this.mood});
  final RobotMood mood;
  @override
  State<RobotView> createState() => RobotViewState();
}

class RobotViewState extends State<RobotView> with TickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final AnimationController _dim = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  /// Lights go off one by one: eyes, chest, antenna, then the glow underneath.
  void powerOff() {
    if (mounted) _dim.forward(from: 0);
  }

  /// A short glow in the head: something was taken in.
  void pulse() {
    if (mounted) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _loop.dispose();
    _pulse.dispose();
    _dim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 240 / 300,
      child: CustomPaint(painter: _RobotPainter(_loop, _pulse, _dim, widget.mood)),
    );
  }
}

class _RobotPainter extends CustomPainter {
  _RobotPainter(this.t, this.pulse, this.dim, this.mood) : super(repaint: Listenable.merge([t, pulse, dim]));
  final Animation<double> t, pulse, dim;
  final RobotMood mood;

  static const _line = Color(0xFF5F7679);
  static const _mint = Color(0xFF7FF5DF);

  @override
  void paint(Canvas c, Size size) {
    final s = size.width / 240;
    c.save();
    c.scale(s);
    final ph = t.value * 2 * math.pi;
    final work = mood == RobotMood.work && dim.value < .3;

    // thruster glow under the robot
    final thr = Rect.fromCenter(center: const Offset(120, 284), width: 104 * (1 - .12 * math.sin(ph * 3)), height: 24);
    final d = dim.value;
    final off = ((d - .75) / .25).clamp(0.0, 1.0); // the glow underneath goes out last
    if (off < 1) {
      final a = 1 - off; // no saveLayer: a layer per frame is slow on weak Windows graphics
      c.drawOval(thr, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(127, 245, 223, .9 * a), const Color(0x007FF5DF)]).createShader(thr));
    }

    c.translate(0, math.sin(ph) * 5);
    final metal = (Rect r) => Paint()..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFF4F8F8), Color(0xFFC3D2D2), Color(0xFF8EA3A6)], stops: [0, .55, 1]).createShader(r);
    final metal2 = (Rect r) => Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFDBE6E6), Color(0xFF7F9598)]).createShader(r);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = _line;

    // arms
    double aL = math.sin(ph) * .06, aR = -math.sin(ph) * .06;
    if (work) {
      aL = -.2 + math.sin(ph * 6) * .25;
      aR = .2 + math.sin(ph * 6 + math.pi) * .25;
    } else if (mood == RobotMood.happy) {
      aR = -2.0 + math.sin(ph * 5) * .3;
    } else if (mood == RobotMood.worry) {
      aL = math.sin(ph * 12) * .06;
      aR = -math.sin(ph * 12) * .06;
    }
    void arm(Offset pivot, double a) {
      c.save();
      c.translate(pivot.dx, pivot.dy);
      c.rotate(a);
      final r = RRect.fromRectAndRadius(const Rect.fromLTWH(-11, -2, 22, 64), const Radius.circular(11));
      c.drawRRect(r, metal2(r.outerRect));
      c.drawRRect(r, stroke..strokeWidth = 2);
      final hand = Rect.fromCircle(center: const Offset(0, 68), radius: 14);
      c.drawOval(hand, metal(hand));
      c.drawOval(hand, stroke);
      c.drawCircle(Offset.zero, 9, Paint()..color = _line);
      c.restore();
      stroke.strokeWidth = 2.5;
    }

    arm(const Offset(37, 152), aL);
    arm(const Offset(203, 152), aR);

    // torso
    final torso = RRect.fromLTRBR(48, 150, 192, 250, const Radius.circular(22));
    c.drawRRect(torso, metal(torso.outerRect));
    c.drawRRect(torso, stroke);
    final neck = RRect.fromLTRBR(86, 132, 154, 156, const Radius.circular(8));
    c.drawRRect(neck, metal2(neck.outerRect));
    c.drawRRect(neck, stroke..strokeWidth = 2);
    stroke.strokeWidth = 2.5;
    c.drawCircle(const Offset(120, 196), 30, Paint()..color = const Color(0xFF07181A));
    c.drawCircle(const Offset(120, 196), 30, stroke..strokeWidth = 3);
    stroke.strokeWidth = 2.5;
    c.drawArc(Rect.fromCircle(center: const Offset(120, 196), radius: 23), work ? ph * 2 : -1.2, 1.9, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFF2DC4B2));
    final core = Rect.fromCircle(center: const Offset(120, 196), radius: 9);
    c.drawOval(core, Paint()..shader = const RadialGradient(colors: [Color(0xFFEAFFFA), Color(0xFF8FF3DC), Color(0xFF1FB89F)]).createShader(core));
    if (d > .35) c.drawCircle(const Offset(120, 196), 26, Paint()..color = const Color(0xFF07181A).withValues(alpha: ((d - .35) / .25).clamp(0.0, 1.0))); // chest light off
    c.drawRRect(RRect.fromLTRBR(72, 238, 168, 244, const Radius.circular(3)), Paint()..color = const Color(0x805F7679));

    // head
    c.drawLine(const Offset(120, 22), const Offset(120, 44), Paint()..color = _line..strokeWidth = 4);
    final glow = (.55 + .45 * math.sin(ph * 4)) * (1 - ((d - .55) / .2).clamp(0.0, 1.0));
    c.drawCircle(const Offset(120, 16), 14, Paint()..color = _mint.withValues(alpha: .22));
    c.drawCircle(const Offset(120, 16), 9, Paint()..color = _mint.withValues(alpha: glow));
    for (final x in [52.0, 188.0]) {
      final ear = Rect.fromCircle(center: Offset(x, 88), radius: 15);
      c.drawOval(ear, metal2(ear));
      c.drawOval(ear, stroke);
      c.drawCircle(Offset(x, 88), 6, Paint()..color = const Color(0xFF2DC4B2));
    }
    final head = RRect.fromLTRBR(58, 40, 182, 136, const Radius.circular(34));
    c.drawRRect(head, metal(head.outerRect));
    c.drawRRect(head, stroke);
    final visor = RRect.fromLTRBR(70, 56, 170, 120, const Radius.circular(24));
    c.drawRRect(visor, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0D2A2C), Color(0xFF04100F)]).createShader(visor.outerRect));
    c.drawRRect(visor, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = const Color(0xFF3B5557));

    final blinkT = t.value;
    final bl = (blinkT > .93 && blinkT < .97) ? .1 : 1.0;
    void eye(double x, Color col) {
      final r = Rect.fromCenter(center: Offset(x, 86), width: 22, height: 22 * bl);
      c.drawOval(r, Paint()..shader = RadialGradient(colors: [const Color(0xFFEAFFFA), col, const Color(0xFF1FB89F)], stops: const [0, .5, 1]).createShader(Rect.fromCircle(center: Offset(x, 86), radius: 11)));
      if (bl > .5) c.drawCircle(Offset(x + 4, 82), 3, Paint()..color = Colors.white);
    }

    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    if (d > .12) {
      // eyes shut, a faint smile, then everything dark
      final a = (1 - ((d - .3) / .3).clamp(0.0, 1.0)) * .9;
      p..strokeWidth = 5..color = _mint.withValues(alpha: a);
      c.drawLine(const Offset(86, 90), const Offset(108, 90), p);
      c.drawLine(const Offset(132, 90), const Offset(154, 90), p);
      c.drawPath(Path()..moveTo(108, 104)..quadraticBezierTo(120, 110, 132, 104), p..strokeWidth = 4);
    } else
    switch (mood) {
      case RobotMood.idle:
      case RobotMood.work:
        eye(97, const Color(0xFF8FF3DC));
        eye(143, const Color(0xFF8FF3DC));
        final mh = work ? (.3 + .7 * math.sin(ph * 8).abs()) : 1.0;
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: const Offset(120, 107.5), width: 24, height: 7 * mh), const Radius.circular(3.5)), Paint()..color = _mint);
        if (work) {
          final y = 58 + 26 * ((math.sin(ph * 2) + 1) / 2);
          c.drawRect(Rect.fromLTWH(72, y, 96, 3), Paint()..color = _mint.withValues(alpha: .4));
        }
      case RobotMood.happy:
        p..strokeWidth = 6..color = _mint;
        c.drawPath(Path()..moveTo(84, 92)..quadraticBezierTo(97, 70, 110, 92), p);
        c.drawPath(Path()..moveTo(130, 92)..quadraticBezierTo(143, 70, 156, 92), p);
        p.strokeWidth = 5;
        c.drawPath(Path()..moveTo(104, 102)..quadraticBezierTo(120, 116, 136, 102), p);
      case RobotMood.worry:
        const o = Color(0xFFFFB454);
        for (final x in [97.0, 143.0]) {
          c.drawCircle(Offset(x, 88), 10, Paint()..color = o);
          c.drawCircle(Offset(x + 3, 85), 3, Paint()..color = Colors.white);
        }
        p..strokeWidth = 4..color = o;
        c.drawLine(const Offset(82, 68), const Offset(108, 74), p);
        c.drawLine(const Offset(158, 68), const Offset(132, 74), p);
        p.strokeWidth = 5;
        c.drawPath(Path()..moveTo(108, 110)..quadraticBezierTo(120, 101, 132, 110), p);
        final k = 1 + .12 * math.sin(ph * 6);
        c.save();
        c.translate(200, 40);
        c.scale(k);
        c.drawCircle(Offset.zero, 17, Paint()..color = o);
        c.drawRRect(RRect.fromLTRBR(-2.5, -11, 2.5, 3, const Radius.circular(2.5)), Paint()..color = const Color(0xFF3B1F00));
        c.drawCircle(const Offset(0, 9), 3, Paint()..color = const Color(0xFF3B1F00));
        c.restore();
    }

    // something was just taken in: the head glows
    final f = 1 - pulse.value;
    if (pulse.value > 0 && pulse.value < 1) {
      final r = Rect.fromCircle(center: const Offset(120, 88), radius: 96);
      c.drawCircle(const Offset(120, 88), 96, Paint()..shader = RadialGradient(colors: [_mint.withValues(alpha: .42 * f), _mint.withValues(alpha: 0)]).createShader(r));
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _RobotPainter old) => old.mood != mood;
}
