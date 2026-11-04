// "MyHato Owner": a separate Android app for the shop owner. One screen: a chat with an AI robot that runs the shop's system
// (permissions, reports, products, stock, orders) on the same database. The brain is the Edge Function `owner-assistant`;
// every change it proposes needs the owner's confirmation in a later message. Only an owner account can use it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'core/config.dart';

// "Ghost" look: near-black, terminal green-cyan, secret-ops mood (still the My Hatō robot).
const _bg = Color(0xFF020604);
const _panel = Color(0xFF07130F);
const _panel2 = Color(0xFF0C241D);
const _electric = Color(0xFF14B8A0);
const _cyan = Color(0xFF2DD4BF);
const _ink = Color(0xFFD8F5EC);
const _muted = Color(0xFF5F8F83);
const _danger = Color(0xFFFF6B6B);

const int _kBuild = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!AppConfig.isConfigured) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Missing configuration')))));
    return;
  }
  await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: AppConfig.supabaseAnonKey, debug: false);
  final prefs = await SharedPreferences.getInstance();
  runApp(OwnerApp(prefs: prefs));
}

/// One updater for the whole app: it works on the login and lock screens too, so the app never gets stuck on an old build.
final OwnerUpdater ownerUpdater = OwnerUpdater();

class OwnerApp extends StatefulWidget {
  const OwnerApp({super.key, required this.prefs});
  final SharedPreferences prefs;
  @override
  State<OwnerApp> createState() => _OwnerAppState();
}

class _OwnerAppState extends State<OwnerApp> {
  SharedPreferences get prefs => widget.prefs;

  @override
  void initState() {
    super.initState();
    ownerUpdater.start();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyHato Owner',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      theme: () {
        final base = ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _bg,
          colorScheme: const ColorScheme.dark(primary: _electric, secondary: _cyan, surface: _panel),
        );
        return base.copyWith(textTheme: GoogleFonts.tajawalTextTheme(base.textTheme));
      }(),
      builder: (context, child) => Stack(fit: StackFit.expand, children: [
        child ?? const SizedBox.shrink(),
        const IgnorePointer(child: SizedBox.expand(child: CustomPaint(painter: _Scanlines()))),
      ]),
      home: StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, child) {
          final signedIn = Supabase.instance.client.auth.currentSession != null;
          return signedIn ? LockGate(child: ChatPage(prefs: prefs)) : LoginPage(prefs: prefs);
        },
      ),
    );
  }
}

class _Scanlines extends CustomPainter {
  const _Scanlines();
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = const Color(0x0B2DD4BF)..strokeWidth = 1;
    for (double y = 0; y < s.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(s.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_Scanlines o) => false;
}

// ------------------------------------------------------------------ the robot

class RobotFace extends StatefulWidget {
  const RobotFace({super.key, this.size = 56, this.thinking = false});
  final double size;
  final bool thinking;
  @override
  State<RobotFace> createState() => _RobotFaceState();
}

class _RobotFaceState extends State<RobotFace> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(animation: _c, builder: (_, __) => CustomPaint(painter: _RobotPainter(_c.value, widget.thinking))),
      );
}

class _RobotPainter extends CustomPainter {
  _RobotPainter(this.t, this.thinking);
  final double t;
  final bool thinking;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi * (thinking ? 3 : 1));
    // antenna
    canvas.drawLine(Offset(w * .5, h * .22), Offset(w * .5, h * .08), Paint()..color = _muted..strokeWidth = w * .035);
    canvas.drawCircle(Offset(w * .5, h * .07), w * (.06 + .02 * pulse), Paint()..color = _cyan.withValues(alpha: .35 + .65 * pulse));
    // ears
    final ear = Paint()..color = _panel2;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * .02, h * .48, w * .09, h * .22), Radius.circular(w * .04)), ear);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * .89, h * .48, w * .09, h * .22), Radius.circular(w * .04)), ear);
    // head
    final head = RRect.fromRectAndRadius(Rect.fromLTWH(w * .1, h * .22, w * .8, h * .66), Radius.circular(w * .24));
    canvas.drawRRect(head, Paint()..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_panel2, _panel]).createShader(head.outerRect));
    canvas.drawRRect(head, Paint()..style = PaintingStyle.stroke..strokeWidth = w * .025..color = _electric.withValues(alpha: .8));
    // visor
    final visor = RRect.fromRectAndRadius(Rect.fromLTWH(w * .2, h * .36, w * .6, h * .3), Radius.circular(w * .14));
    canvas.drawRRect(visor, Paint()..color = const Color(0xFF031022));
    // eyes (blink once per loop)
    final blink = (t > .9 && t < .95) ? 0.12 : 1.0;
    final eye = Paint()..color = _cyan;
    final glow = Paint()..color = _cyan.withValues(alpha: .35)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .05);
    for (final cx in [.36, .64]) {
      final r = Rect.fromCenter(center: Offset(w * cx, h * .51), width: w * .11, height: h * .15 * blink);
      canvas.drawOval(r.inflate(w * .02), glow);
      canvas.drawOval(r, eye);
    }
    // mouth
    final m = Path()..moveTo(w * .4, h * .76)..quadraticBezierTo(w * .5, h * (thinking ? .76 : .8), w * .6, h * .76);
    canvas.drawPath(m, Paint()..style = PaintingStyle.stroke..strokeCap = StrokeCap.round..strokeWidth = w * .03..color = _cyan);
  }

  @override
  bool shouldRepaint(_RobotPainter o) => o.t != t || o.thinking != thinking;
}

// ------------------------------------------------------------------ login

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.prefs});
  final SharedPreferences prefs;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _email = TextEditingController(text: widget.prefs.getString('owner_email') ?? '');
  final _pass = TextEditingController();
  bool _busy = false;
  String? _err;

  Future<void> _go() async {
    setState(() { _busy = true; _err = null; });
    final db = Supabase.instance.client;
    try {
      var id = _email.text.trim();
      if (id.isEmpty || _pass.text.isEmpty) {
        setState(() => _err = 'اكتب اسم المستخدم وكلمة السر.');
        return;
      }
      var email = id.toLowerCase();
      if (!id.contains('@')) {
        // a username or mobile number: the database checks the password and gives back the account email (same as the team app)
        final e = await db.rpc('login_email_for', params: {'p_identifier': id, 'p_password': _pass.text}) as String?;
        if (e == null) throw const AuthException('Invalid login credentials', code: 'invalid_credentials');
        email = e.trim().toLowerCase();
      }
      await db.auth.signInWithPassword(email: email, password: _pass.text);
      // only the owner holds this permission
      final ok = await db.rpc('has_permission', params: {'p_permission': 'permissions.manage'});
      if (ok != true) {
        await db.auth.signOut();
        setState(() => _err = 'الحساب ده مش حساب المالك.');
      } else {
        await widget.prefs.setString('owner_email', id);
      }
    } on AuthException {
      setState(() => _err = 'اسم المستخدم أو كلمة السر غلط.');
    } catch (_) {
      setState(() => _err = 'مفيش اتصال، جرب تاني.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const RobotFace(size: 120),
                const SizedBox(height: 14),
                const Text('MyHato Owner', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: _ink, letterSpacing: .5)),
                const SizedBox(height: 4),
                const Text('// RESTRICTED ACCESS — OWNER ONLY', textDirection: TextDirection.ltr, style: TextStyle(color: _cyan, fontSize: 12, letterSpacing: 2.5, fontFamily: 'monospace')),
                const SizedBox(height: 26),
                _field(_email, 'اسم المستخدم أو الإيميل', TextInputType.emailAddress, false),
                const SizedBox(height: 12),
                _field(_pass, 'كلمة السر', TextInputType.visiblePassword, true),
                if (_err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_err!, style: const TextStyle(color: _danger))),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _electric, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    onPressed: _busy ? null : _go,
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : const Text('[ AUTHENTICATE ]', textDirection: TextDirection.ltr, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 2, fontFamily: 'monospace')),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, TextInputType type, bool secret) => TextField(
        controller: c,
        keyboardType: type,
        obscureText: secret,
        textDirection: TextDirection.ltr,
        style: const TextStyle(color: _ink),
        onSubmitted: (_) => _go(),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: _muted),
          filled: true,
          fillColor: _panel,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        ),
      );
}


// ------------------------------------------------------------------ owner lock (phone fingerprint / lock code)

/// After the first sign-in the session stays, but the app opens only after the owner proves it is him with the phone's
/// fingerprint / face / lock code. It asks again when the app comes back after more than a minute in the background.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  final _auth = LocalAuthentication();
  bool _open = false, _asking = false;
  DateTime? _away;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ask();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState st) {
    // the system fingerprint sheet itself pauses the app: that is not "leaving the app"
    if (st == AppLifecycleState.paused && !_asking) _away = DateTime.now();
    if (st == AppLifecycleState.resumed && !_asking) {
      final away = _away;
      _away = null;
      if (_open && away != null && DateTime.now().difference(away) > const Duration(minutes: 1)) {
        setState(() => _open = false);
        _ask();
      }
    }
  }

  Future<void> _ask() async {
    if (_asking) return;
    _asking = true;
    try {
      // a phone with no lock at all cannot prove anything: let it in (the owner should set a lock code)
      if (!await _auth.isDeviceSupported()) {
        if (mounted) setState(() => _open = true);
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'افتح MyHato Owner',
        // stickyAuth must stay false: with it some phones re-open the fingerprint sheet again and again after a correct fingerprint
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: false),
      );
      if (mounted) setState(() => _open = ok);
    } catch (_) {
      if (mounted) setState(() => _open = false);
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_open) return widget.child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const RobotFace(size: 120),
            const SizedBox(height: 16),
            const Text('MyHato Owner', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: _ink)),
            const SizedBox(height: 6),
            const Text('مقفول: اثبت إنك المالك', style: TextStyle(color: _muted)),
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _electric, padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: _ask,
              icon: const Icon(Icons.fingerprint_rounded),
              label: const Text('افتح بالبصمة أو الرمز', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            TextButton(onPressed: () => Supabase.instance.client.auth.signOut(), child: const Text('تسجيل الخروج', style: TextStyle(color: _muted))),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ auto update (same key as the installed app, so it installs over it)

class OwnerUpdater extends ChangeNotifier {
  static const _ch = MethodChannel('myhato/update');
  String status = ''; // '' | 'downloading' | 'ready' | 'need_permission'
  double progress = 0;
  int? build;
  String note = ''; // result of a manual check, shown by the update button
  bool _busy = false;
  Timer? _timer;

  void start() {
    if (_kBuild <= 0 || !Platform.isAndroid) return;
    check();
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> check({bool manual = false}) async {
    if (_busy) {
      if (manual) note = 'بيحمّل تحديث بالفعل…';
      return;
    }
    _busy = true;
    try {
      final db = Supabase.instance.client;
      final rows = (await db.rpc('latest_owner_update')) as List? ?? const [];
      if (rows.isEmpty) {
        if (manual) note = 'مفيش تحديث جديد';
        return;
      }
      final r = Map<String, dynamic>.from(rows.first as Map);
      final b = (r['build'] as num).toInt();
      if (b <= _kBuild) {
        if (manual) note = 'إنت على أحدث نسخة (رقم $_kBuild) ✔';
        return;
      }
      build = b;
      status = 'downloading';
      progress = 0;
      notifyListeners();
      final dir = await _ch.invokeMethod<String>('cacheDir') ?? Directory.systemTemp.path;
      final file = File('$dir/updates/owner-$b.apk');
      await file.parent.create(recursive: true);
      final url = db.storage.from('app-updates').getPublicUrl('${r['path']}');
      final want = '${r['sha256']}'.toLowerCase();
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      try {
        final res = await (await client.getUrl(Uri.parse(url))).close();
        if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
        final total = res.contentLength > 0 ? res.contentLength : ((r['size_bytes'] as num?)?.toInt() ?? 0);
        final sink = file.openWrite();
        final out = _DigestSink();
        final h = sha256.startChunkedConversion(out);
        var got = 0;
        await for (final c in res) {
          sink.add(c);
          h.add(c);
          got += c.length;
          if (total > 0) {
            progress = got / total;
            notifyListeners();
          }
        }
        await sink.flush();
        await sink.close();
        h.close();
        if (out.value.toString() != want) {
          await file.delete();
          throw const FormatException('CHECKSUM');
        }
      } finally {
        client.close();
      }
      status = 'ready';
      notifyListeners();
      await install();
    } catch (_) {
      status = '';
      if (manual) note = 'ما قدرتش أحمّل التحديث، اتأكد من النت وجرب تاني';
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<void> install() async {
    if (build == null) return;
    final dir = await _ch.invokeMethod<String>('cacheDir') ?? Directory.systemTemp.path;
    final res = await _ch.invokeMethod<String>('install', '$dir/updates/owner-$build.apk');
    status = res == 'need_permission' ? 'need_permission' : 'ready';
    notifyListeners();
  }
}

// ------------------------------------------------------------------ voice

/// Records the owner until he stops talking (silence detection), then Gemini writes down what he said.
/// Works on every phone: it does not depend on the phone's own speech recognizer.
class VoiceCapture {
  final AudioRecorder _rec = AudioRecorder();
  bool _stop = false;

  static Uint8List _wav(Uint8List pcm, int rate) {
    final h = ByteData(44);
    void w(int o, String t) {
      for (var i = 0; i < t.length; i++) {
        h.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    w(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    w(8, 'WAVE');
    w(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, rate, Endian.little);
    h.setUint32(28, rate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    w(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...pcm]);
  }

  /// Returns what he said, '' when nothing was said, or throws a short Arabic message.
  Future<String> listen({int noSpeechMs = 9000, int maxMs = 25000, void Function()? onSpeechStart, void Function()? onSpeechEnd}) async {
    _stop = false;
    if (!await _rec.hasPermission()) throw 'اسمح للتطبيق بالميكروفون من إعدادات الموبايل';
    final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1));
    final buf = BytesBuilder(copy: false);
    final done = Completer<void>();
    var speaking = false, n = 0;
    var noise = 0.0, quietMs = 0.0;
    final sw = Stopwatch()..start();
    final sub = stream.listen((chunk) {
      buf.add(chunk);
      final bd = ByteData.sublistView(chunk);
      final cnt = chunk.length ~/ 2;
      if (cnt == 0) return;
      var sum = 0.0;
      for (var i = 0; i < cnt; i++) {
        final v = bd.getInt16(i * 2, Endian.little);
        sum += v * v;
      }
      final rms = math.sqrt(sum / cnt);
      final ms = cnt * 1000 / 16000;
      if (n < 3) {
        noise = noise == 0 ? rms : (noise + rms) / 2;
        n++;
        return;
      }
      final thr = math.min(math.max(650.0, noise * 2.5), 2500.0);
      if (rms > thr) {
        if (!speaking) onSpeechStart?.call();
        speaking = true;
        quietMs = 0;
      } else if (speaking) {
        quietMs += ms;
      }
      if (done.isCompleted) return;
      if (_stop || (speaking && quietMs >= 900) || (!speaking && sw.elapsedMilliseconds > noSpeechMs) || sw.elapsedMilliseconds > maxMs) done.complete();
    });
    await done.future;
    await sub.cancel();
    await _rec.stop();
    if (!speaking || buf.length < 16000) return '';
    onSpeechEnd?.call();
    final wav = _wav(buf.toBytes(), 16000);
    try {
      final r = await Supabase.instance.client.functions.invoke('owner-stt', body: {'audio': base64Encode(wav)}).timeout(const Duration(seconds: 25));
      final d = r.data;
      return d is Map ? (d['text'] ?? '').toString().trim() : '';
    } catch (_) {
      throw 'مقدرتش أفهم الصوت دلوقتي، جرب تاني';
    }
  }

  void stopNow() => _stop = true;

  Future<void> dispose() async {
    _stop = true;
    try {
      await _rec.dispose();
    } catch (_) {}
  }
}

// ------------------------------------------------------------------ chat

class _Msg {
  _Msg(this.role, this.text, {this.pending = const []});
  final String role; // user | assistant
  final String text;
  final List<String> pending;
  Map<String, dynamic> toJson() => {'r': role, 't': text};
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.prefs});
  final SharedPreferences prefs;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _key = 'owner_chat_v1';
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  bool _busy = false, _listening = false;
  final _upd = ownerUpdater;
  final _cap = VoiceCapture();

  static const _quick = ['مبيعات النهارده', 'الأوردرات الجديدة', 'مين في الفريق؟', 'صلاحيات الكاشير', 'التحويلات اللي وصلت'];

  void _note(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// Tap the mic, talk; when you stop talking the command is written down and sent by itself.
  Future<void> _mic() async {
    if (_busy) return;
    if (_listening) {
      _cap.stopNow();
      return;
    }
    setState(() => _listening = true);
    try {
      final t = await _cap.listen();
      if (mounted) setState(() => _listening = false);
      if (t.isNotEmpty) {
        await _send(t);
      } else {
        _note('مسمعتش حاجة، جرب تاني');
      }
    } catch (e) {
      if (mounted) setState(() => _listening = false);
      _note('$e');
    }
  }

  void _onUpd() => mounted ? setState(() {}) : null;

  @override
  void dispose() {
    _cap.dispose();
    _upd.removeListener(_onUpd);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _upd.addListener(_onUpd);
    try {
      final raw = widget.prefs.getString(_key);
      if (raw != null) {
        for (final m in (jsonDecode(raw) as List)) {
          _msgs.add(_Msg((m['r'] ?? 'assistant') as String, (m['t'] ?? '') as String));
        }
      }
    } catch (_) {}
  }

  void _save() {
    final keep = _msgs.length > 40 ? _msgs.sublist(_msgs.length - 40) : _msgs;
    widget.prefs.setString(_key, jsonEncode(keep.map((m) => m.toJson()).toList()));
  }

  void _down() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent + 200, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  Future<String> _send(String text, {bool voice = false}) async {
    text = text.trim();
    if (text.isEmpty || _busy) return '';
    _input.clear();
    setState(() { _msgs.add(_Msg('user', text)); _busy = true; });
    _save();
    _down();
    String answer;
    List<String> pending = const [];
    try {
      final hist = _msgs.length > 16 ? _msgs.sublist(_msgs.length - 16) : _msgs;
      final res = await Supabase.instance.client.functions.invoke('owner-assistant', body: {
        'messages': [for (final m in hist) {'role': m.role, 'content': m.text}],
        if (voice) 'voice': true,
      });
      final d = res.data is Map ? res.data as Map : <dynamic, dynamic>{};
      answer = (d['reply'] ?? 'تمام.').toString();
      pending = ((d['pending'] ?? const []) as List).map((e) => e.toString()).toList();
    } on FunctionException catch (e) {
      final code = e.details is Map ? (e.details as Map)['error'] : null;
      answer = switch (code) {
        'no_ai_key' => 'المخ لسه ما اتوصلش: ضيف مفتاح Gemini المجاني (GEMINI_API_KEY) في إعدادات Supabase.',
        'ai_failed' => 'الذكاء الاصطناعي المجاني مزحوم دلوقتي، جرب تاني بعد دقيقة.',
        'ai_busy' => 'الذكاء الاصطناعي مشغول (حد الاستخدام المجاني)، جرب بعد دقيقة.',
        'bad_ai_key' => 'مفتاح الذكاء الاصطناعي غلط أو منتهي.',
        'owner_only' => 'التطبيق ده للمالك بس.',
        'unauthorized' => 'سجّل دخول تاني.',
        _ => 'حصلت مشكلة في الاتصال، جرب تاني.',
      };
    } catch (_) {
      answer = 'مفيش اتصال، جرب تاني.';
    }
    if (!mounted) return answer;
    setState(() { _msgs.add(_Msg('assistant', answer, pending: pending)); _busy = false; });
    _save();
    _down();
    return answer;
  }

  Future<void> _updateTap() async {
    if (_upd.status == 'ready' || _upd.status == 'need_permission') {
      await _upd.install();
      return;
    }
    if (_upd.status == 'downloading') return;
    _upd.note = '';
    _note('بدوّر على تحديث…');
    await _upd.check(manual: true);
    if (mounted && _upd.note.isNotEmpty) _note(_upd.note);
  }

  void _call() {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, __, ___) => CallScreen(ask: (t) => _send(t, voice: true)),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
    ));
  }

  void _clear() {
    setState(() => _msgs.clear());
    widget.prefs.remove(_key);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: _panel,
          elevation: 0,
          titleSpacing: 8,
          title: Row(children: [
            RobotFace(size: 40, thinking: _busy),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('MyHato Owner', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: _ink)),
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: _busy ? Colors.amber : _cyan, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(_busy ? 'بيشتغل…' : 'متصل بالنظام', style: const TextStyle(fontSize: 12, color: _muted)),
              ]),
            ]),
          ]),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
              child: (_upd.status == 'ready' || _upd.status == 'need_permission')
                  ? FilledButton.icon(
                      onPressed: _updateTap,
                      icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                      label: const Text('ثبّت التحديث', style: TextStyle(fontWeight: FontWeight.w800)),
                      style: FilledButton.styleFrom(backgroundColor: _cyan, foregroundColor: const Color(0xFF031022), padding: const EdgeInsets.symmetric(horizontal: 12), visualDensity: VisualDensity.compact),
                    )
                  : OutlinedButton.icon(
                      onPressed: _upd.status == 'downloading' ? null : _updateTap,
                      icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                      label: Text(_upd.status == 'downloading' ? 'بيحمّل…' : 'تحديث', style: const TextStyle(fontWeight: FontWeight.w700)),
                      style: OutlinedButton.styleFrom(foregroundColor: _cyan, side: BorderSide(color: _cyan.withValues(alpha: .7)), padding: const EdgeInsets.symmetric(horizontal: 12), visualDensity: VisualDensity.compact),
                    ),
            ),
            IconButton(tooltip: 'اتصل بالسكرتيرة', icon: const Icon(Icons.call_rounded, color: _cyan), onPressed: _call),
            PopupMenuButton<String>(
              color: _panel,
              onSelected: (v) async {
                if (v == 'clear') _clear();
                if (v == 'out') await Supabase.instance.client.auth.signOut();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'clear', child: Text('مسح المحادثة')),
                PopupMenuItem(value: 'out', child: Text('تسجيل الخروج')),
              ],
            ),
          ],
        ),
        body: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_bg, Color(0xFF010302)])),
          child: Column(children: [
            if (_upd.status.isNotEmpty) _updateBar(),
            Expanded(
              child: _msgs.isEmpty
                  ? _welcome()
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
                      itemCount: _msgs.length + (_busy ? 1 : 0),
                      itemBuilder: (_, i) => i == _msgs.length ? const _Typing() : _bubble(_msgs[i], i == _msgs.length - 1),
                    ),
            ),
            if (_msgs.isNotEmpty && !_busy) _chips(),
            _composer(),
          ]),
        ),
      ),
    );
  }

  Widget _updateBar() {
    final dl = _upd.status == 'downloading';
    return Material(
      color: const Color(0xFF0A1C17),
      child: InkWell(
        onTap: dl ? null : _upd.install,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(children: [
            const Icon(Icons.system_update_alt_rounded, color: _cyan, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: dl
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('بنحمّل تحديث جديد…', style: TextStyle(color: _ink, fontSize: 13)),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: _upd.progress > 0 ? _upd.progress : null, color: _cyan, backgroundColor: _panel),
                    ])
                  : Text(_upd.status == 'need_permission' ? 'اسمح بتثبيت التطبيقات من المصدر ده، وارجع اضغط هنا' : 'التحديث جاهز: اضغط للتثبيت', style: const TextStyle(color: _ink, fontSize: 13)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _welcome() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const RobotFace(size: 110),
            const SizedBox(height: 14),
            const Text('أنا رجلك في النظام', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _ink)),
            const SizedBox(height: 6),
            const Text('اكتبلي اللي عايزه: أجيب تقارير، أعدّل منتج أو سعر، أقفل أو أفتح صلاحية.\nأي تعديل بسألك قبل ما أنفّذه.', textAlign: TextAlign.center, style: TextStyle(color: _muted, height: 1.6)),
            const SizedBox(height: 18),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [for (final q in _quick) _chip(q)]),
          ]),
        ),
      );

  Widget _chips() => SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [for (final q in _quick) Padding(padding: const EdgeInsets.only(left: 8), child: _chip(q))]),
      );

  Widget _chip(String q) => ActionChip(
        label: Text(q, style: const TextStyle(color: _ink, fontSize: 13)),
        backgroundColor: _panel,
        side: BorderSide(color: _electric.withValues(alpha: .5)),
        onPressed: () => _send(q),
      );

  Widget _bubble(_Msg m, bool last) {
    final mine = m.role == 'user';
    return Align(
      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.start : CrossAxisAlignment.end, children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .82),
          decoration: BoxDecoration(
            gradient: mine ? const LinearGradient(colors: [_electric, Color(0xFF0E8C7A)]) : null,
            color: mine ? null : _panel,
            border: mine ? null : Border.all(color: _electric.withValues(alpha: .25)),
            borderRadius: BorderRadius.only(
              topRight: const Radius.circular(18),
              topLeft: const Radius.circular(18),
              bottomRight: Radius.circular(mine ? 4 : 18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
            ),
          ),
          child: SelectableText(m.text, style: const TextStyle(color: _ink, fontSize: 15.5, height: 1.5)),
        ),
        if (!mine && last && m.pending.isNotEmpty && !_busy) _confirmCard(m.pending),
      ]),
    );
  }

  Widget _confirmCard(List<String> items) => Container(
        margin: const EdgeInsets.only(top: 4, bottom: 6),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .82),
        decoration: BoxDecoration(color: const Color(0xFF0A1C17), borderRadius: BorderRadius.circular(16), border: Border.all(color: _cyan.withValues(alpha: .6))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [Icon(Icons.bolt_rounded, color: _cyan, size: 18), SizedBox(width: 6), Text('جاهز للتنفيذ', style: TextStyle(color: _cyan, fontWeight: FontWeight.w800))]),
          const SizedBox(height: 6),
          for (final s in items) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('• $s', style: const TextStyle(color: _ink, height: 1.4))),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: _cyan, foregroundColor: const Color(0xFF031022)), onPressed: () => _send('أيوه نفّذ'), child: const Text('نفّذ', style: TextStyle(fontWeight: FontWeight.w900)))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: _ink, side: const BorderSide(color: _muted)), onPressed: () => _send('لأ إلغاء'), child: const Text('إلغاء'))),
          ]),
        ]),
      );

  Widget _composer() => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: const BoxDecoration(color: _panel, border: Border(top: BorderSide(color: Color(0x332DD4BF)))),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                style: const TextStyle(color: _ink),
                decoration: InputDecoration(
                  hintText: _listening ? 'بسمعك… اتكلم' : 'اكتب أو اضغط المايك واتكلم…',
                  hintStyle: const TextStyle(color: _muted),
                  filled: true,
                  fillColor: _bg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: _busy ? null : _mic,
              borderRadius: BorderRadius.circular(24),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _listening ? _danger.withValues(alpha: .18) : _bg,
                  border: Border.all(color: _listening ? _danger : _cyan.withValues(alpha: .7), width: _listening ? 2 : 1),
                  boxShadow: _listening ? [BoxShadow(color: _danger.withValues(alpha: .5), blurRadius: 16, spreadRadius: 2)] : null,
                ),
                child: Icon(_listening ? Icons.graphic_eq_rounded : Icons.mic_rounded, color: _listening ? _danger : _cyan, size: 22),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: _busy ? null : () => _send(_input.text),
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: _busy ? [_muted, _muted] : [_electric, _cyan])),
                child: const Icon(Icons.send_rounded, color: Colors.white, size: 22),
              ),
            ),
          ]),
        ),
      );
}

/// A phone call with the secretary: she picks up, greets, listens, answers aloud, and keeps going until you hang up.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.ask});
  final Future<String> Function(String text) ask;
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _tts = FlutterTts();
  final _player = AudioPlayer();
  final _cap = VoiceCapture();
  Future<void>? _fillerPlaying;
  String _state = 'ring'; // ring | speak | listen | think
  String _caption = '';
  bool _ended = false;
  int _secs = 0;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => mounted && _state != 'ring' ? setState(() => _secs++) : null);
    _run();
  }

  @override
  void dispose() {
    _ended = true;
    _clock?.cancel();
    _tts.stop();
    _player.dispose();
    _cap.dispose();
    super.dispose();
  }

  void _set(String st, [String cap = '']) {
    if (mounted) setState(() { _state = st; _caption = cap; });
  }

  String _spoken(String t) => t
      .replaceAll(RegExp(r'[*_`#>|~]'), ' ')
      .replaceAll('ج.م', 'جنيه')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<File?> _cacheFile(String t) async {
    try {
      final dir = await const MethodChannel('myhato/update').invokeMethod<String>('cacheDir') ?? Directory.systemTemp.path;
      final d = Directory('$dir/voice');
      if (!await d.exists()) await d.create(recursive: true);
      return File('${d.path}/v2_${t.hashCode}.wav');
    } catch (_) {
      return null;
    }
  }

  /// A natural Egyptian female voice from the server (free Gemini TTS); the phone's own voice is only the fallback.
  /// Fixed phrases (greeting, fillers) are kept on the phone so they play at once.
  Future<Uint8List?> _synth(String t, {bool cache = false}) async {
    File? f;
    if (cache) {
      f = await _cacheFile(t);
      if (f != null && await f.exists()) return f.readAsBytes();
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await Supabase.instance.client.functions.invoke('owner-tts', body: {'text': _spoken(t)}).timeout(const Duration(seconds: 35));
        final d = r.data;
        if (d is Map && d['audio'] is String) {
          final b = base64Decode(d['audio'] as String);
          if (f != null) await f.writeAsBytes(b);
          return b;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> _playBytes(Uint8List bytes) async {
    final done = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    await _player.play(BytesSource(bytes, mimeType: 'audio/wav'));
    await done.future.timeout(const Duration(seconds: 90), onTimeout: () {});
    await sub.cancel();
  }

  /// First sentence is voiced as soon as it is ready while the rest is still being prepared.
  List<String> _chunks(String t) {
    final m = RegExp(r'[.!؟?]\s').firstMatch(t);
    if (m != null && m.end < t.length - 2 && m.end > 12) return [t.substring(0, m.end).trim(), t.substring(m.end).trim()];
    return [t];
  }

  Future<void> _say(String t, {Future<Uint8List?>? pre}) async {
    if (_ended) return;
    _set('speak', t);
    final parts = pre != null ? [t] : _chunks(t);
    final futures = [for (var i = 0; i < parts.length; i++) i == 0 && pre != null ? pre : _synth(parts[i])];
    try {
      await _fillerPlaying;
    } catch (_) {}
    for (var i = 0; i < parts.length && !_ended; i++) {
      final bytes = await futures[i];
      if (_ended) return;
      try {
        if (bytes != null) {
          await _playBytes(bytes);
        } else {
          await _tts.speak(_spoken(parts[i]));
        }
      } catch (_) {}
    }
  }

  static const _fillers = ['حاضر يا استاذ أحمد.', 'ثانية واحدة.', 'تمام، بشوفلك.'];
  final Map<String, Uint8List> _fillerAudio = {};

  Future<void> _loadFillers() async {
    for (final f in _fillers) {
      if (_ended) return;
      final b = await _synth(f, cache: true);
      if (b != null) _fillerAudio[f] = b;
    }
  }

  void _filler() {
    if (_ended || _fillerAudio.isEmpty) return;
    final b = _fillerAudio.values.elementAt(math.Random().nextInt(_fillerAudio.length));
    _fillerPlaying = _playBytes(b).catchError((_) {});
  }

  Future<String> _listen() async {
    if (_ended) return '';
    _set('listen');
    try {
      return await _cap.listen(onSpeechEnd: () {
        _set('think');
        _filler();
      });
    } catch (e) {
      if (mounted) setState(() => _caption = '$e');
      await Future<void>.delayed(const Duration(seconds: 3));
      return '';
    }
  }

  Future<void> _run() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      final ar = await _tts.isLanguageAvailable('ar-EG') == true ? 'ar-EG' : 'ar';
      await _tts.setLanguage(ar);
      await _tts.setSpeechRate(0.48);
      await _tts.setPitch(1.05);
    } catch (_) {}
    const hello = 'معاك يا استاذ أحمد، أساعدك إزاي؟';
    final pre = _synth(hello, cache: true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await _say(hello, pre: pre);
    _loadFillers();
    var silent = 0;
    while (!_ended) {
      final heard = await _listen();
      if (_ended) break;
      if (heard.isEmpty) {
        silent++;
        if (silent == 3) await _say('لسه معايا يا استاذ أحمد؟');
        if (silent >= 6) {
          await _say('أنا موجودة لو احتجتني يا استاذ أحمد.');
          break;
        }
        continue;
      }
      silent = 0;
      final low = heard.replaceAll(RegExp(r'\s+'), ' ');
      if (RegExp(r'^(سلام|مع السلامة|باي|اقفلي|اقفل الخط|شكرا مع السلامة)').hasMatch(low)) {
        await _say('في أمان الله يا استاذ أحمد.');
        break;
      }
      _set('think', heard);
      final answer = await widget.ask(heard);
      if (_ended) break;
      await _say(answer.isEmpty ? 'مسمعتش كويس، ممكن تعيد؟' : answer);
    }
    if (mounted && !_ended) Navigator.of(context).maybePop();
  }

  String get _label => switch (_state) {
        'ring' => 'بيرن…',
        'speak' => 'بتتكلم',
        'listen' => 'بسمعك…',
        _ => 'بفكر…',
      };

  @override
  Widget build(BuildContext context) {
    final mm = (_secs ~/ 60).toString().padLeft(2, '0'), ss = (_secs % 60).toString().padLeft(2, '0');
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const SizedBox(height: 28),
          const Text('// SECURE LINE', textDirection: TextDirection.ltr, style: TextStyle(color: _cyan, fontSize: 12, letterSpacing: 3, fontFamily: 'monospace')),
          const SizedBox(height: 8),
          const Text('السكرتيرة', style: TextStyle(color: _ink, fontSize: 26, fontWeight: FontWeight.w900)),
          Text(_state == 'ring' ? _label : '$_label  •  $mm:$ss', style: const TextStyle(color: _muted)),
          const Spacer(),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: _state == 'listen' ? _danger : _cyan.withValues(alpha: .6), width: _state == 'listen' ? 3 : 1),
              boxShadow: [BoxShadow(color: (_state == 'listen' ? _danger : _cyan).withValues(alpha: .35), blurRadius: _state == 'ring' ? 10 : 40, spreadRadius: 4)],
            ),
            child: RobotFace(size: 150, thinking: _state == 'think' || _state == 'speak'),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: SizedBox(
              height: 130,
              width: double.infinity,
              child: Center(child: Text(_caption, maxLines: 5, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: _ink, fontSize: 17, height: 1.6))),
            ),
          ),
          const SizedBox(height: 28),
          InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            customBorder: const CircleBorder(),
            child: Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFE5484D)),
              child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 34),
            ),
          ),
          const SizedBox(height: 10),
          const Text('إنهاء المكالمة', style: TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 28),
        ]),
        ),
      ),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();
  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(18), border: Border.all(color: _electric.withValues(alpha: .25))),
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 3; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: _cyan.withValues(alpha: .3 + .7 * math.max(0, math.sin((_c.value * 2 - i * .3) * math.pi)))),
                ),
            ]),
          ),
        ),
      );
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest d) => value = d;
  @override
  void close() {}
}
