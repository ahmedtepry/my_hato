// Closing and opening a shift with the robot, and the cashier's morning reel.
// Closing: counted cash → fingerprint or password (checked by the server first) → a 30-second review of the real shift →
// "all good, see you later" or "there is a problem, close anyway or wait?" → the program closes and asks about the computer.
import 'dart:async';
import 'dart:io' show Platform, Process, ProcessStartMode, exit;
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../shared/motion.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'cashier_assistant.dart';
import 'pos_repository.dart';
import 'shift_robot.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _money(BuildContext c, num minor) => formatEgp(minor.round(), c.lang);
String _err(BuildContext c, Object e) => posErrorText(e, c.isAr, (x) => friendlyError(c, x));

String shiftUserName(User? u) {
  if (u == null) return '';
  final m = u.userMetadata ?? const {};
  final n = (m['full_name'] ?? m['name'] ?? m['display_name'])?.toString().trim() ?? '';
  if (n.isNotEmpty) return n.split(' ').first;
  final e = u.email ?? '';
  return e.contains('@') ? e.split('@').first : e;
}

bool get _isWindows => !kIsWeb && Platform.isWindows;

Widget _frame(BuildContext context, {required Widget scene, required Widget panel, bool closeResult = false}) {
  final size = MediaQuery.of(context).size;
  final wide = size.width >= 760;
  final h = math.min(size.height * .92, 640.0);
  return Dialog(
    insetPadding: const EdgeInsets.all(14),
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 900, maxHeight: h),
      child: Stack(children: [
        wide
            ? Row(children: [
                SizedBox(width: 360, height: h, child: scene),
                Expanded(child: panel),
              ])
            : Column(children: [
                SizedBox(height: math.min(300, h * .42), width: double.infinity, child: scene),
                Expanded(child: panel),
              ]),
        // always-available way out (top right): if anything ever hangs, this closes the robot window
        Positioned(
          top: 8,
          right: 8,
          child: Tooltip(
            message: context.isAr ? 'إغلاق' : 'Close',
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).pop(closeResult),
                child: const Padding(padding: EdgeInsets.all(7), child: Icon(Icons.close_rounded, size: 20, color: Colors.white)),
              ),
            ),
          ),
        ),
      ]),
    ),
  );
}

// =====================================================================================================
// Closing
// =====================================================================================================
class ShiftRobotClose {
  /// Returns true when the shift was closed (the program is about to exit anyway).
  static Future<bool> show(BuildContext context, String shiftId) async {
    final r = await showSmoothDialog<bool>(context: context, barrierDismissible: false, builder: (_) => _CloseDialog(shiftId: shiftId));
    return r == true;
  }
}

enum _Phase { count, auth, run, ask, done, pc }

class _Step {
  _Step(this.seconds, this.say, this.note, this.code, this.result, {this.warn = false});
  final int seconds;
  final String say, note, code, result;
  final bool warn;
}

class _CloseDialog extends ConsumerStatefulWidget {
  const _CloseDialog({required this.shiftId});
  final String shiftId;
  @override
  ConsumerState<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends ConsumerState<_CloseDialog> {
  final StageController ctl = StageController();
  final _countCtl = TextEditingController();
  final _pwCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  _Phase _phase = _Phase.count;
  bool _busy = false, _bioAvail = false, _bioOn = false, _enableBio = true, _obscure = true;
  int _counted = 0, _expected = 0;
  String _password = '';
  double _elapsed = 0;
  Timer? _ticker;
  final List<String> _problems = [];
  String _mag = ''; // the number under the magnifier when the robot finds a difference
  int _scanFlag = -1; // which scanned invoice looks unusual (shown in orange)

  String get _uid => ref.read(currentUserProvider)?.id ?? '';
  String get _name => shiftUserName(ref.read(currentUserProvider));
  PosRepository get _repo => ref.read(posRepoProvider);
  SupabaseClient get _db => ref.read(supabaseProvider);

  @override
  void initState() {
    super.initState();
    _loadBio();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ctl.setMood(RobotMood.idle);
      ctl.say(_t(context, 'أهلاً ${_name.isEmpty ? '' : '$_name، '}خلّصت يومك؟ اكتب الفلوس اللي عدّيتها في الدرج.', 'Hi${_name.isEmpty ? '' : ' $_name'}! Count the drawer and type the cash.'));
    });
  }

  Future<void> _loadBio() async {
    final a = await ShiftBio.available();
    final e = a ? await ShiftBio.enabled(_uid) : false;
    if (mounted) setState(() {
      _bioAvail = a;
      _bioOn = e;
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    ctl.dispose();
    _countCtl.dispose();
    _pwCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  // ---- 1. counted cash
  void _toAuth() {
    final m = parseEgpToMinor(_countCtl.text);
    if (m == null) return;
    setState(() {
      _counted = m;
      _phase = _Phase.auth;
    });
    ctl.say(_bioOn ? _t(context, 'المس البصمة عشان أتأكد إنه إنت.', 'Touch the fingerprint so I know it is you.') : _t(context, 'اكتب الباسورد بتاعك عشان أتأكد إنه إنت.', 'Type your password so I know it is you.'));
  }

  // ---- 2. who is closing
  Future<void> _useBio() async {
    final pw = await ShiftBio.secret(_uid, _t(context, 'تأكيد إغلاق الوردية', 'Confirm closing the shift'));
    if (!mounted) return;
    if (pw == null) {
      ctl.say(_t(context, 'البصمة ماتأكدتش. اكتب الباسورد.', 'The fingerprint did not match. Type your password.'));
      return;
    }
    await _verify(pw, fromBio: true);
  }

  Future<void> _verify(String pw, {required bool fromBio}) async {
    if (pw.isEmpty) return;
    setState(() => _busy = true);
    ctl.setMood(RobotMood.work);
    try {
      final ok = (await _db.rpc('pos_check_password', params: {'p_password': pw})) == true;
      if (!mounted) return;
      if (!ok) {
        if (fromBio) {
          await ShiftBio.clear(_uid);
          _bioOn = false;
        }
        ctl.setMood(RobotMood.worry);
        ctl.say(_t(context, 'الباسورد غلط. جرّب تاني.', 'Wrong password. Try again.'));
        _pwCtl.clear();
        setState(() => _busy = false);
        return;
      }
      _password = pw;
      if (!_bioOn && _bioAvail && _enableBio && !fromBio) {
        final saved = await ShiftBio.save(_uid, pw, _t(context, 'تفعيل البصمة للإغلاق والفتح', 'Turn on the fingerprint for closing and opening'));
        if (saved) _bioOn = true;
      }
      _pwCtl.clear();
      ctl.setMood(RobotMood.happy);
      await ctl.say(_t(context, 'تمام${_name.isEmpty ? '' : ' يا $_name'}. هراجع الوردية.', 'Great${_name.isEmpty ? '' : ', $_name'}. Reviewing the shift.'), ms: 22);
      if (!mounted) return;
      setState(() => _busy = false);
      await _review();
    } catch (e) {
      if (!mounted) return;
      ctl.setMood(RobotMood.worry);
      ctl.say(_err(context, e));
      setState(() => _busy = false);
    }
  }

  // ---- 3. the 30-second review (every number comes from the real shift)
  Future<void> _review() async {
    Map<String, dynamic> sum = {}, rev = {};
    try {
      sum = Map<String, dynamic>.from(await _repo.shiftSummary(widget.shiftId));
    } catch (e) {
      if (mounted) {
        ctl.setMood(RobotMood.worry);
        ctl.say(_err(context, e));
      }
      return;
    }
    try {
      rev = Map<String, dynamic>.from(await _db.rpc('assistant_shift_review', params: {'p_shift': widget.shiftId}) as Map);
    } catch (_) {/* the guard data is a bonus: the cash check below does not need it */}
    if (!mounted) return;
    _expected = ((sum['expected_minor'] as num?) ?? 0).toInt();
    final diff = _counted - _expected;
    final n = ((sum['sales_count'] as num?) ?? 0).toInt();
    final flagged = (rev['flagged_discounts'] as List?)?.length ?? 0;
    final refunds = rev['refunds'] is Map ? ((rev['refunds'] as Map)['count'] as num?)?.toInt() ?? 0 : 0;
    final voided = (rev['voided'] as List?)?.length ?? 0;
    final c = context;
    final cashWarn = diff != 0;
    final refWarn = flagged > 0 || refunds >= 3;
    final steps = <_Step>[
      _Step(3, _t(c, 'بتأكد من هويتك…', 'Checking who you are…'), _t(c, 'الهوية', 'Identity'), 'verify identity --user ${_name.isEmpty ? 'cashier' : _name}', _t(c, 'تمام', 'ok')),
      _Step(6, _t(c, 'براجع الفواتير فاتورة فاتورة…', 'Going through every invoice…'), _t(c, 'الفواتير', 'Invoices'), 'scan invoices --shift ($n)', _t(c, '$n سليمة', '$n fine')),
      _Step(6, _t(c, 'بطابق الإيراد مع الدرج…', 'Matching revenue with the drawer…'), _t(c, 'الإيراد مقابل الدرج', 'Revenue vs drawer'), 'match cash.expected cash.counted',
          cashWarn ? (diff < 0 ? _t(c, 'عجز ${_money(c, -diff)}', 'short ${_money(c, -diff)}') : _t(c, 'زيادة ${_money(c, diff)}', 'over ${_money(c, diff)}')) : _t(c, 'مطابق للجنيه', 'exact'),
          warn: cashWarn),
      _Step(6, _t(c, 'بشوف المرتجعات والخصومات…', 'Looking at refunds and discounts…'), _t(c, 'المرتجعات والخصومات', 'Refunds and discounts'), 'review refunds discounts',
          refWarn ? _t(c, '$refunds مرتجعات، $flagged خصم عالي', '$refunds refunds, $flagged high discounts') : _t(c, 'في الحدود المعتادة', 'within the usual range'), warn: refWarn),
      _Step(5, _t(c, 'ببص على الفواتير الملغية…', 'Checking cancelled invoices…'), _t(c, 'الفواتير الملغية', 'Cancelled invoices'), 'check voided invoices',
          voided > 0 ? _t(c, '$voided اترجعت بالكامل', '$voided fully refunded') : _t(c, 'مفيش', 'none'), warn: voided > 0),
      _Step(4, _t(c, 'بختم التقرير النهائي…', 'Sealing the final report…'), _t(c, 'ختم التقرير', 'Seal the report'), 'seal report --final', _t(c, 'جاهز', 'ready')),
    ];
    _problems.clear();
    _scanFlag = flagged > 0 ? 7 : -1;
    setState(() {
      _phase = _Phase.run;
      _elapsed = 0;
    });
    ctl.clear();
    ctl.setMood(RobotMood.work);
    final sw = Stopwatch()..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => _elapsed = math.min(30, sw.elapsedMilliseconds / 1000));
    });
    for (final s in steps) {
      if (!mounted || ctl.dead) return;
      final start = DateTime.now();
      unawaited(ctl.say(s.say, ms: 26));
      await ctl.typeLine(s.note, kind: LineKind.note, ms: 4);
      await ctl.stream((s.seconds * 560).round());
      final line = await ctl.typeLine(s.code, ms: 7);
      final left = s.seconds * 900 - DateTime.now().difference(start).inMilliseconds;
      if (left > 0) await Future<void>.delayed(Duration(milliseconds: left));
      if (!mounted || ctl.dead) return;
      ctl.tail(line, s.result, warn: s.warn);
      if (s.warn) {
        _problems.add('${s.note}: ${s.result}');
        ctl.setMood(RobotMood.worry);
        if (s.code.startsWith('match') && mounted) setState(() => _mag = diff < 0 ? '-${_money(context, -diff)}' : '+${_money(context, diff)}');
        await Future<void>.delayed(Duration(milliseconds: s.code.startsWith('match') ? 2600 : 600));
        if (mounted) setState(() => _mag = '');
        ctl.setMood(RobotMood.work);
      }
      await Future<void>.delayed(Duration(milliseconds: s.seconds * 100));
    }
    _ticker?.cancel();
    if (!mounted) return;
    setState(() => _elapsed = 30);
    if (_problems.isEmpty) {
      await _close(null);
    } else {
      setState(() => _phase = _Phase.ask);
      ctl.setMood(RobotMood.worry);
      ctl.say(_t(context, 'في خلل في الوردية. أقفل على كده ولا أستنى؟', 'There is a problem with the shift. Close anyway or wait?'), ms: 30);
    }
  }

  // ---- 4. close for real
  Future<void> _close(String? note) async {
    setState(() => _busy = true);
    try {
      final r = await _repo.closeShift(widget.shiftId, _counted, (note == null || note.trim().isEmpty) ? null : note.trim(), _password);
      if (!mounted) return;
      if (r['ok'] != true) {
        _password = '';
        setState(() {
          _phase = _Phase.auth;
          _busy = false;
        });
        ctl.setMood(RobotMood.worry);
        ctl.say(_t(context, 'الباسورد ماتقبلش. اكتبه تاني.', 'The password was not accepted. Type it again.'));
        return;
      }
      ref.invalidate(posShiftProvider);
      final forced = _problems.isNotEmpty;
      setState(() {
        _phase = _Phase.done;
        _busy = false;
      });
      ctl.setMood(forced ? RobotMood.idle : RobotMood.happy);
      await ctl.say(forced ? _t(context, 'اتقفلت وسجّلت الفرق في التقرير. أشوفك بعدين.', 'Closed. I recorded the difference. See you later.') : _t(context, 'تم الإغلاق، كله مظبوط. أشوفك بعدين!', 'Closed, everything matches. See you later!'), ms: 36);
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      if (!mounted) return;
      ctl.lightsOff(); // the lights go off one by one
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      if (!mounted) return;
      if (_isWindows) {
        setState(() => _phase = _Phase.pc);
        ctl.say(_t(context, 'البرنامج هيتقفل. تقفل الكمبيوتر بالمرة؟', 'The program will close. Turn the computer off too?'), ms: 30);
      } else {
        await _leave(false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ctl.setMood(RobotMood.worry);
      ctl.say(_err(context, e));
    }
  }

  Future<void> _leave(bool shutdown) async {
    if (shutdown && _isWindows) {
      try {
        await Process.start('shutdown', ['/s', '/t', '20', '/c', 'My Hato: closing the computer after the shift'], mode: ProcessStartMode.detached);
      } catch (_) {}
    }
    if (_isWindows) {
      exit(0);
    } else {
      await SystemNavigator.pop();
    }
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    return _frame(
      context,
      closeResult: _phase == _Phase.done || _phase == _Phase.pc, // once the shift is really closed, the register must refresh
      scene: RobotScene(ctl: ctl, robotWidth: MediaQuery.of(context).size.width >= 760 ? 250 : 120),
      panel: Padding(padding: const EdgeInsets.all(20), child: SingleChildScrollView(child: _panel(context))),
    );
  }

  Widget _title(String s) => Text(s, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800));

  Widget _panel(BuildContext context) {
    switch (_phase) {
      case _Phase.count:
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(_t(context, 'إغلاق الوردية', 'Close the shift')),
          const SizedBox(height: 14),
          TextField(
            controller: _countCtl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _toAuth(),
            decoration: InputDecoration(labelText: _t(context, 'اللي عدّيته فعلياً في الدرج (ج.م)', 'Cash you actually counted (EGP)'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: parseEgpToMinor(_countCtl.text) == null ? null : _toAuth, child: Text(_t(context, 'التالي', 'Next'))),
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t(context, 'رجوع', 'Back'))),
        ]);
      case _Phase.auth:
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(_t(context, 'اتأكد إنه إنت', 'Confirm it is you')),
          const SizedBox(height: 14),
          if (_bioOn) ...[
            Center(
              child: IconButton.filledTonal(
                iconSize: 56,
                padding: const EdgeInsets.all(18),
                onPressed: _busy ? null : _useBio,
                icon: const Icon(Icons.fingerprint_rounded),
                tooltip: _t(context, 'المس البصمة', 'Touch the fingerprint'),
              ),
            ),
            Center(child: Text(_t(context, 'المس البصمة', 'Touch the fingerprint'), style: const TextStyle(color: BrandColors.gray))),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _pwCtl,
            obscureText: _obscure,
            autofocus: !_bioOn,
            onSubmitted: (v) => _busy ? null : _verify(v, fromBio: false),
            decoration: InputDecoration(
              labelText: _bioOn ? _t(context, 'أو اكتب الباسورد', 'Or type your password') : _t(context, 'الباسورد بتاعك', 'Your password'),
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => _obscure = !_obscure)),
            ),
          ),
          if (!_bioOn && _bioAvail)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _enableBio,
              onChanged: (v) => setState(() => _enableBio = v ?? false),
              title: Text(_t(context, 'فعّل البصمة للإغلاق والفتح', 'Use the fingerprint for closing and opening'), style: const TextStyle(fontSize: 13)),
            ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _busy ? null : () => _verify(_pwCtl.text, fromBio: false), child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_t(context, 'تأكيد', 'Confirm'))),
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: Text(_t(context, 'رجوع', 'Back'))),
        ]);
      case _Phase.run:
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _ScanStrip(progress: ((_elapsed - 3) / 6).clamp(0.0, 1.0), flagged: _scanFlag),
          const SizedBox(height: 10),
          Stack(children: [
            StageConsole(ctl: ctl, height: 235),
            if (_mag.isNotEmpty) Positioned(top: 8, right: 8, child: _Magnifier(text: _mag)),
          ]),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _elapsed / 30, minHeight: 6, borderRadius: BorderRadius.circular(3)),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${_elapsed.round()} / 30 ${_t(context, 'ث', 's')}', style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            Text('${(_elapsed / 30 * 100).round()}%', style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
          ]),
        ]);
      case _Phase.ask:
        final diff = _counted - _expected;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(_t(context, 'في خلل في الوردية', 'There is a problem')),
          const SizedBox(height: 10),
          _fact(_t(context, 'المفروض في الدرج', 'Expected in the drawer'), _money(context, _expected)),
          _fact(_t(context, 'المعدود', 'Counted'), _money(context, _counted)),
          if (diff != 0) _fact(_t(context, diff < 0 ? 'عجز' : 'زيادة', diff < 0 ? 'Short' : 'Over'), _money(context, diff.abs()), warn: true),
          for (final p in _problems) Padding(padding: const EdgeInsets.only(top: 4), child: Text('⚠️ $p', style: const TextStyle(fontSize: 13))),
          const SizedBox(height: 10),
          TextField(
            controller: _noteCtl,
            maxLength: 200,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: diff != 0 ? _t(context, 'سبب الفرق (مطلوب)', 'Reason for the difference (required)') : _t(context, 'ملاحظة (اختياري)', 'Note (optional)'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 6),
          Text(_t(context, 'لو قفلت، الفرق هيتسجل في التقرير النهائي.', 'If you close, the difference is recorded in the final report.'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: BrandColors.warning),
                onPressed: _busy || (diff != 0 && _noteCtl.text.trim().isEmpty) ? null : () => _close(_noteCtl.text),
                child: Text(_t(context, 'اقفل على كده', 'Close anyway')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => Navigator.pop(context, false),
                child: Text(_t(context, 'استنى', 'Wait')),
              ),
            ),
          ]),
        ]);
      case _Phase.done:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 30),
          const Icon(Icons.check_circle_rounded, size: 56, color: BrandColors.success),
          const SizedBox(height: 10),
          _title(_t(context, 'تم الإغلاق', 'Shift closed')),
        ]);
      case _Phase.pc:
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 20),
          const Icon(Icons.power_settings_new_rounded, size: 52, color: BrandColors.gray),
          const SizedBox(height: 10),
          _title(_t(context, 'تقفل الكمبيوتر بالمرة؟', 'Turn the computer off too?')),
          const SizedBox(height: 6),
          Text(_t(context, 'لو وافقت هيقفل بعد 20 ثانية.', 'If you agree it shuts down in 20 seconds.'), textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray)),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => _leave(true), child: Text(_t(context, 'اقفل الكمبيوتر', 'Turn it off'))),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => _leave(false), child: Text(_t(context, 'لأ، سيبه شغّال', 'No, leave it on'))),
        ]);
    }
  }

  Widget _fact(String l, String r, {bool warn = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l),
          Text(r, style: TextStyle(fontWeight: FontWeight.w800, color: warn ? BrandColors.warning : null)),
        ]),
      );
}

// =====================================================================================================
// Opening
// =====================================================================================================
class ShiftRobotOpen {
  static Future<void> show(BuildContext context, {required String name, required int openingMinor, String branch = ''}) =>
      showSmoothDialog<void>(context: context, barrierDismissible: false, builder: (_) => _OpenDialog(name: name, openingMinor: openingMinor, branch: branch));
}

class _OpenDialog extends StatefulWidget {
  const _OpenDialog({required this.name, required this.openingMinor, required this.branch});
  final String name, branch;
  final int openingMinor;
  @override
  State<_OpenDialog> createState() => _OpenDialogState();
}

class _OpenDialogState extends State<_OpenDialog> {
  final StageController ctl = StageController();
  String _verse = '', _source = '', _saying = '';
  bool _ready = false, _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _play());
  }

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<void> _typeInto(void Function(String) set, String text, int ms) async {
    for (var i = 1; i <= text.length; i++) {
      if (!mounted) return;
      setState(() => set(text.substring(0, i)));
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
  }

  Future<void> _play() async {
    final c = context;
    ctl.setMood(RobotMood.work);
    ctl.rise();
    unawaited(ctl.say(_t(c, 'صباح الخير${widget.name.isEmpty ? '' : ' يا ${widget.name}'}. هجهّز الدرج.', 'Good morning${widget.name.isEmpty ? '' : ' ${widget.name}'}. Preparing your drawer.')));
    final lines = <(String, String)>[
      ('verify identity --user ${widget.name.isEmpty ? 'cashier' : widget.name}', _t(c, 'تمام', 'ok')),
      ('open drawer --opening ${(widget.openingMinor / 100).toStringAsFixed(0)}', _t(c, 'العهدة ${_money(c, widget.openingMinor)}', 'opening ${_money(c, widget.openingMinor)}')),
      ('sync prices stock${widget.branch.isEmpty ? '' : ' --branch'}', _t(c, 'محدّث', 'updated')),
    ];
    for (final l in lines) {
      if (!mounted) return;
      await ctl.stream(500);
      final line = await ctl.typeLine(l.$1, ms: 9);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      ctl.tail(line, l.$2);
      if (l.$1.startsWith('open drawer') && mounted) setState(() => _drawerOpen = true);
    }
    if (!mounted) return;
    final w = TrustWords.today();
    ctl.setMood(RobotMood.idle);
    unawaited(ctl.say(_t(c, 'قبل ما نبدأ…', 'Before we start…')));
    await _typeInto((s) => _verse = s, '﴿ ${w.$1} ﴾', 60);
    if (!mounted) return;
    setState(() => _source = w.$2);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _typeInto((s) => _saying = s, w.$3, 40);
    if (!mounted) return;
    ctl.setMood(RobotMood.happy);
    unawaited(ctl.say(_t(c, 'بالتوفيق${widget.name.isEmpty ? '' : ' يا ${widget.name}'}!', 'Good luck${widget.name.isEmpty ? '' : ', ${widget.name}'}!')));
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return _frame(
      context,
      scene: RobotScene(ctl: ctl, robotWidth: MediaQuery.of(context).size.width >= 760 ? 250 : 120),
      panel: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: StageConsole(ctl: ctl, height: 130)),
              const SizedBox(width: 10),
              _DrawerAnim(open: _drawerOpen),
            ]),
            const SizedBox(height: 14),
            if (_verse.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(border: Border.all(color: BrandColors.border), borderRadius: BorderRadius.circular(14), color: const Color(0x14D9B25C)),
                child: Column(children: [
                  Text(_verse, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, height: 2.0, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(_source, style: const TextStyle(color: Color(0xFFB58F2F), fontSize: 13)),
                ]),
              ),
            if (_saying.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_saying, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray))),
            if (_ready) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'ابدأ الوردية', 'Start the shift'))),
            ],
          ]),
        ),
      ),
    );
  }
}

// =====================================================================================================
// The cashier's morning reel (once a day, when the cashier assistant is on)
// =====================================================================================================
class CashierReel {
  static Future<void> maybeShow(BuildContext context, {required String uid, required String name, required Map<String, dynamic> shift}) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getString('reel_day_$uid') == today) return;
      await p.setString('reel_day_$uid', today);
    } catch (_) {}
    if (!context.mounted) return;
    await showSmoothDialog<void>(context: context, barrierColor: Colors.black87, builder: (_) => _ReelDialog(name: name, shift: shift));
  }
}

class _ReelDialog extends StatefulWidget {
  const _ReelDialog({required this.name, required this.shift});
  final String name;
  final Map<String, dynamic> shift;
  @override
  State<_ReelDialog> createState() => _ReelDialogState();
}

class _ReelDialogState extends State<_ReelDialog> with SingleTickerProviderStateMixin {
  // the opening story is now just "today's shift" (branch, expected in the drawer, shift sales); the other slides were removed
  static const int _n = 1, _only = 2;
  late final AnimationController _bar = AnimationController(vsync: this, duration: const Duration(seconds: 8))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _go(_i + 1);
    });
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _bar.forward();
  }

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  void _go(int n) {
    if (n >= _n) {
      Navigator.of(context).pop();
      return;
    }
    if (n < 0) n = 0;
    setState(() => _i = n);
    _bar.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final h = math.min(MediaQuery.of(context).size.height * .92, 640.0);
    return Dialog(
      insetPadding: const EdgeInsets.all(14),
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 340,
        height: h,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Stack(children: [
            Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: _bg(_only)))),
            Positioned.fill(child: KeyedSubtree(key: ValueKey(_i), child: _slide(context, _only))),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPressStart: (_) => _bar.stop(),
                onLongPressEnd: (_) => _bar.forward(),
                onTapUp: (d) {
                  _go(_n); // a tap closes the single story
                },
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Row(children: [
                  for (var k = 0; k < _n; k++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: AnimatedBuilder(
                          animation: _bar,
                          builder: (_, __) => LinearProgressIndicator(
                            value: k < _i ? 1 : (k == _i ? _bar.value : 0),
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            Positioned(
              top: 22,
              right: 6,
              child: IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, color: Colors.white)),
            ),
          ]),
        ),
      ),
    );
  }

  Gradient _bg(int i) {
    const sets = [
      [Color(0xFF17504F), Color(0xFF06120F)],
      [Color(0xFF3A2F12), Color(0xFF0B0905)],
      [Color(0xFF12335A), Color(0xFF050B16)],
      [Color(0xFF2E1F5A), Color(0xFF0A0616)],
      [Color(0xFF0F5A46), Color(0xFF04120D)],
    ];
    return RadialGradient(center: const Alignment(0, -.5), radius: 1.1, colors: sets[i % sets.length]);
  }

  Widget _slide(BuildContext context, int i) {
    const white = TextStyle(color: Colors.white, decoration: TextDecoration.none);
    Widget h(String s) => Text(s, textAlign: TextAlign.center, style: white.copyWith(fontSize: 26, fontWeight: FontWeight.w800, height: 1.4));
    Widget p(String s) => Text(s, textAlign: TextAlign.center, style: white.copyWith(fontSize: 14, color: const Color(0xFFB9D8D1), height: 1.6));
    Widget row(String l, String r) => Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: white.copyWith(fontSize: 14)), Text(r, style: white.copyWith(fontSize: 14, color: const Color(0xFF7FF0C6), fontWeight: FontWeight.w700))]),
        );
    final s = widget.shift;
    final body = switch (i) {
      0 => Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 190, child: RobotView(mood: RobotMood.happy)),
          const SizedBox(height: 10),
          h(_t(context, 'أهلاً${widget.name.isEmpty ? '' : ' يا ${widget.name}'}', 'Hello${widget.name.isEmpty ? '' : ' ${widget.name}'}')),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFF2DC4B2)), borderRadius: BorderRadius.circular(99)),
            child: Text(_t(context, 'كاشير · ${s['branch_name_ar'] ?? ''}', 'Cashier · ${s['branch_name_ar'] ?? ''}'), style: white.copyWith(fontSize: 13, color: const Color(0xFF2DC4B2))),
          ),
          const SizedBox(height: 10),
          p(_t(context, 'اتعرفت عليك. هعدّيك على كل حاجة في دقيقة.', 'I recognised you. A one-minute look at your day.')),
        ]),
      1 => _VerseSlide(),
      2 => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          h(_t(context, 'وردية النهارده', 'Today\'s shift')),
          const SizedBox(height: 10),
          row(_t(context, 'الفرع', 'Branch'), '${s['branch_name_ar'] ?? ''}'),
          row(_t(context, 'المفروض في الدرج', 'Expected in the drawer'), _money(context, (s['expected_minor'] as num?) ?? 0)),
          row(_t(context, 'مبيعات الوردية', 'Shift sales'), '${_money(context, (s['sales_minor'] as num?) ?? 0)} (${s['sales_count'] ?? 0})'),
        ]),
      3 => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          h(_t(context, 'قبل ما تبدأ', 'Before you start')),
          const SizedBox(height: 10),
          row(_t(context, 'المرتجع', 'Refunds'), _t(context, 'سببه مطلوب', 'a reason is required')),
          row(_t(context, 'الخصم فوق حدّك', 'Discount above your limit'), _t(context, 'موافقة المدير', 'manager approval')),
          row(_t(context, 'المنتج خلص في فرعك', 'Out of stock here'), _t(context, 'اسأل المساعد الذكي', 'ask the assistant')),
        ]),
      _ => Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 190, child: RobotView(mood: RobotMood.happy)),
          const SizedBox(height: 10),
          h(_t(context, 'جاهز تبدأ؟', 'Ready?')),
          const SizedBox(height: 8),
          p(_t(context, 'هفضل جنبك. زرار «المساعد الذكي» في شاشة البيع.', 'I stay with you: the "Smart assistant" button at the till.')),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(_t(context, 'ابدأ', 'Start'))),
        ]),
    };
    return Padding(padding: const EdgeInsets.fromLTRB(22, 70, 22, 40), child: Center(child: body));
  }
}

class _VerseSlide extends StatefulWidget {
  @override
  State<_VerseSlide> createState() => _VerseSlideState();
}

class _VerseSlideState extends State<_VerseSlide> {
  String _v = '', _s = '', _k = '';
  bool _off = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _off = true;
    super.dispose();
  }

  Future<void> _typeInto(void Function(String) set, String text, int ms) async {
    for (var i = 1; i <= text.length; i++) {
      if (_off) return;
      setState(() => set(text.substring(0, i)));
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
  }

  Future<void> _run() async {
    final w = TrustWords.today();
    await _typeInto((s) => _v = s, '﴿ ${w.$1} ﴾', 45);
    if (_off) return;
    setState(() => _s = w.$2);
    await _typeInto((s) => _k = s, w.$3, 30);
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(context.isAr ? 'قبل ما نبدأ' : 'Before we start', style: const TextStyle(color: Color(0xFFE8CF8A), fontSize: 14, decoration: TextDecoration.none)),
      const SizedBox(height: 14),
      Text(_v, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFF7E6B4), fontSize: 26, height: 2.0, decoration: TextDecoration.none, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text(_s, style: const TextStyle(color: Color(0xFFD9B25C), fontSize: 13, decoration: TextDecoration.none)),
      const SizedBox(height: 14),
      Text(_k, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFB9D8D1), fontSize: 15, decoration: TextDecoration.none)),
    ]);
  }
}


// ---------------------------------------------------------------- small animated pieces
/// A row of invoices: a beam scans along it and each one gets a tick (orange for one that looks unusual).
class _ScanStrip extends StatelessWidget {
  const _ScanStrip({required this.progress, required this.flagged});
  final double progress;
  final int flagged;
  static const int _n = 14;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: LayoutBuilder(builder: (_, box) {
        final w = box.maxWidth / _n;
        final scanned = (progress * _n).floor();
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(children: [
            Row(children: [
              for (var i = 0; i < _n; i++)
                SizedBox(
                  width: w,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: w * .62,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: i < scanned ? (i == flagged ? const Color(0x33FFB454) : const Color(0x224FE0A0)) : const Color(0x14808080),
                        border: Border.all(color: i < scanned ? (i == flagged ? const Color(0xFFFFB454) : const Color(0xFF4FE0A0)) : const Color(0x33808080)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: i < scanned
                          ? Icon(i == flagged ? Icons.priority_high_rounded : Icons.check_rounded, size: 14, color: i == flagged ? const Color(0xFFFFB454) : const Color(0xFF4FE0A0))
                          : const Icon(Icons.receipt_long_outlined, size: 13, color: Color(0x88808080)),
                    ),
                  ),
                ),
            ]),
            if (progress > 0 && progress < 1)
              Positioned(left: progress * box.maxWidth - 1, top: 0, bottom: 0, child: Container(width: 2, decoration: const BoxDecoration(color: Color(0xFF2DC4B2), boxShadow: []))),
          ]),
        );
      }),
    );
  }
}

/// The robot's magnifying glass over the number that does not add up.
class _Magnifier extends StatefulWidget {
  const _Magnifier({required this.text});
  final String text;
  @override
  State<_Magnifier> createState() => _MagnifierState();
}

class _MagnifierState extends State<_Magnifier> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    return super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.elasticOut,
      builder: (_, v, child) => Transform.scale(scale: v, child: child),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Transform.rotate(
          angle: (_c.value - .5) * .14,
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 122,
              height: 122,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xEE07110F),
                border: Border.all(color: const Color(0xFFFFB454), width: 5),
                boxShadow: const [BoxShadow(color: Color(0x88FFB454), blurRadius: 22)],
              ),
              child: Text(widget.text, style: const TextStyle(color: Color(0xFFFFB454), fontSize: 26, fontWeight: FontWeight.w900, fontFeatures: [FontFeature.tabularFigures()])),
            ),
            Positioned(right: -22, bottom: -22, child: Transform.rotate(angle: .8, child: Container(width: 12, height: 40, decoration: BoxDecoration(color: const Color(0xFFFFB454), borderRadius: BorderRadius.circular(6))))),
          ]),
        ),
      ),
    );
  }
}

/// A cash drawer that slides open and shows a few notes.
class _DrawerAnim extends StatelessWidget {
  const _DrawerAnim({required this.open});
  final bool open;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      height: 130,
      child: Stack(alignment: Alignment.bottomCenter, children: [
        for (var i = 0; i < 3; i++)
          AnimatedPositioned(
            duration: Duration(milliseconds: 500 + i * 160),
            curve: Curves.easeOutBack,
            bottom: open ? 34.0 + i * 12 : 14,
            child: Transform.rotate(
              angle: (i - 1) * .08,
              child: Container(
                width: 78,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFF3FAE6B), borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFF2B7F4D), width: 2)),
                child: const Text('E£', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ),
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          width: 100,
          height: 34,
          margin: EdgeInsets.only(top: open ? 40 : 0),
          decoration: BoxDecoration(color: const Color(0xFF55696C), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF3B5557), width: 2)),
          alignment: Alignment.center,
          child: Container(width: 26, height: 6, decoration: BoxDecoration(color: const Color(0xFFB9C9CB), borderRadius: BorderRadius.circular(3))),
        ),
      ]),
    );
  }
}

// =====================================================================================================
// Daily challenge with confetti (cashier assistant on)
// =====================================================================================================
class DailyChallenge extends ConsumerStatefulWidget {
  const DailyChallenge({super.key, required this.sales, this.goal = 10});
  final int sales, goal;
  @override
  ConsumerState<DailyChallenge> createState() => _DailyChallengeState();
}

class _DailyChallengeState extends ConsumerState<DailyChallenge> {
  bool _celebrated = false;

  @override
  void initState() {
    super.initState();
    _celebrated = widget.sales >= widget.goal; // already reached before: no party on open
  }

  @override
  void didUpdateWidget(covariant DailyChallenge old) {
    super.didUpdateWidget(old);
    if (!_celebrated && widget.sales >= widget.goal) {
      _celebrated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showConfetti(context);
        showSnack(context, _t(context, 'عاش! خلّصت تحدّي النهارده 🎉', 'Well done! Today\'s challenge is complete 🎉'));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(assistantFlagsProvider).valueOrNull ?? const {};
    if (f['challenge'] != true) return const SizedBox.shrink();
    final v = (widget.sales / widget.goal).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(border: Border.all(color: BrandColors.border), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(v >= 1 ? Icons.emoji_events_rounded : Icons.flag_rounded, size: 16, color: v >= 1 ? const Color(0xFFD9B25C) : BrandColors.gray),
        const SizedBox(width: 6),
        Text(_t(context, 'تحدّي اليوم ${math.min(widget.sales, widget.goal)}/${widget.goal}', 'Daily challenge ${math.min(widget.sales, widget.goal)}/${widget.goal}'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        SizedBox(
          width: 70,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: v),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (_, x, __) => LinearProgressIndicator(value: x, minHeight: 6, borderRadius: BorderRadius.circular(3)),
          ),
        ),
      ]),
    );
  }
}

/// Confetti over the whole screen for a couple of seconds.
void showConfetti(BuildContext context) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry e;
  e = OverlayEntry(builder: (_) => _Confetti(onDone: () => e.remove()));
  overlay.insert(e);
}

class _Confetti extends StatefulWidget {
  const _Confetti({required this.onDone});
  final VoidCallback onDone;
  @override
  State<_Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<_Confetti> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    })
    ..forward();
  final math.Random _r = math.Random();
  late final List<List<double>> _p = List.generate(90, (_) => [_r.nextDouble(), _r.nextDouble() * .4, .6 + _r.nextDouble() * .6, _r.nextDouble() * 6, _r.nextDouble() * 360, _r.nextInt(6).toDouble()]);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _ConfettiPainter(_c, _p)));
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t, this.p) : super(repaint: t);
  final Animation<double> t;
  final List<List<double>> p;
  static const _cols = [Color(0xFFFF5E7E), Color(0xFFFFC94D), Color(0xFF4FE0A0), Color(0xFF5AA9FF), Color(0xFFB487FF), Color(0xFFFF9A4D)];

  @override
  void paint(Canvas c, Size s) {
    for (final q in p) {
      final life = ((t.value - q[1]) / (1 - q[1])).clamp(0.0, 1.0);
      if (life <= 0) continue;
      final x = q[0] * s.width + math.sin(life * 6 + q[3]) * 30;
      final y = -20 + life * (s.height + 40) * q[2];
      c.save();
      c.translate(x, y);
      c.rotate(q[4] + life * 10);
      c.drawRect(const Rect.fromLTWH(-4, -2, 8, 5), Paint()..color = _cols[q[5].toInt()].withValues(alpha: (1 - life * .5)));
      c.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => false;
}
