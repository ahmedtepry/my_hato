// "MyHato Owner": a separate Android app for the shop owner. One screen: a chat with an AI robot that runs the shop's system
// (permissions, reports, products, stock, orders) on the same database. The brain is the Edge Function `owner-assistant`;
// every change it proposes needs the owner's confirmation in a later message. Only an owner account can use it.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';

// My Hatō brand, robot mood: deep navy, electric blue, cyan glow.
const _bg = Color(0xFF061428);
const _panel = Color(0xFF0B2D5B);
const _panel2 = Color(0xFF0E3A73);
const _electric = Color(0xFF00A3FF);
const _cyan = Color(0xFF2DD4BF);
const _ink = Color(0xFFEAF4FF);
const _muted = Color(0xFF8FA9C8);
const _danger = Color(0xFFFF6B6B);

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

class OwnerApp extends StatelessWidget {
  const OwnerApp({super.key, required this.prefs});
  final SharedPreferences prefs;

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
      home: StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, _) {
          final signedIn = Supabase.instance.client.auth.currentSession != null;
          return signedIn ? ChatPage(prefs: prefs) : const LoginPage();
        },
      ),
    );
  }
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
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _err;

  Future<void> _go() async {
    setState(() { _busy = true; _err = null; });
    final db = Supabase.instance.client;
    try {
      await db.auth.signInWithPassword(email: _email.text.trim().toLowerCase(), password: _pass.text);
      // only the owner holds this permission
      final ok = await db.rpc('has_permission', params: {'p_permission': 'permissions.manage'});
      if (ok != true) {
        await db.auth.signOut();
        setState(() => _err = 'الحساب ده مش حساب المالك.');
      }
    } on AuthException {
      setState(() => _err = 'الإيميل أو كلمة السر غلط.');
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
                const Text('كلّم النظام زي ما بتكلّم موظف شاطر', style: TextStyle(color: _muted)),
                const SizedBox(height: 26),
                _field(_email, 'الإيميل', TextInputType.emailAddress, false),
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
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : const Text('دخول', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
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
  bool _busy = false;

  static const _quick = ['مبيعات النهارده', 'الأوردرات الجديدة', 'مين في الفريق؟', 'صلاحيات الكاشير', 'التحويلات اللي وصلت'];

  @override
  void initState() {
    super.initState();
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

  Future<void> _send(String text) async {
    text = text.trim();
    if (text.isEmpty || _busy) return;
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
      });
      final d = res.data is Map ? res.data as Map : <dynamic, dynamic>{};
      answer = (d['reply'] ?? 'تمام.').toString();
      pending = ((d['pending'] ?? const []) as List).map((e) => e.toString()).toList();
    } on FunctionException catch (e) {
      final code = e.details is Map ? (e.details as Map)['error'] : null;
      answer = switch (code) {
        'no_ai_key' => 'المخ لسه ما اتوصلش: لازم تضيف مفتاح الذكاء الاصطناعي (ANTHROPIC_API_KEY) في إعدادات Supabase.',
        'bad_ai_key' => 'مفتاح الذكاء الاصطناعي غلط أو منتهي.',
        'owner_only' => 'التطبيق ده للمالك بس.',
        'unauthorized' => 'سجّل دخول تاني.',
        _ => 'حصلت مشكلة في الاتصال، جرب تاني.',
      };
    } catch (_) {
      answer = 'مفيش اتصال، جرب تاني.';
    }
    if (!mounted) return;
    setState(() { _msgs.add(_Msg('assistant', answer, pending: pending)); _busy = false; });
    _save();
    _down();
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
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_bg, Color(0xFF040E1D)])),
          child: Column(children: [
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
            gradient: mine ? const LinearGradient(colors: [_electric, Color(0xFF0072D6)]) : null,
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
        decoration: BoxDecoration(color: const Color(0xFF0A2447), borderRadius: BorderRadius.circular(16), border: Border.all(color: _cyan.withValues(alpha: .6))),
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
          decoration: const BoxDecoration(color: _panel, border: Border(top: BorderSide(color: Color(0x3300A3FF)))),
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
                  hintText: 'اكتب أمرك للنظام…',
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
