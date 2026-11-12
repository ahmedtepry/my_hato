// Face ID for the team: the camera scan dialog (record / "is it me" / switch seller) and the member's own profile sheet.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors.dart';
import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../shared/face_scan_anim.dart';
import '../../../shared/motion.dart';
import '../../../shared/states.dart';
import 'face_repository.dart';
import 'face_worker.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

enum FaceMode { enroll, verify, seller }

/// Opens the camera scan. Returns:
///  enroll  -> true when the face was saved
///  verify  -> {ok:true, ...} when the signed-in member matched their own face
///  seller  -> {ok:true, id, name} when the seller was switched
/// and null when cancelled, timed out or not recognised (the caller then falls back to the PIN / password).
Future<Object?> showFaceScan(BuildContext context, FaceMode mode, {String? shiftId}) =>
    showSmoothDialog<Object>(context: context, barrierDismissible: false, builder: (_) => _FaceScanDialog(mode: mode, shiftId: shiftId));

/// True when this computer can do face scans (Windows team build with the models and a camera driver).
Future<bool> faceAvailable() async {
  try {
    await FaceWorker.instance;
    return true;
  } catch (_) {
    return false;
  }
}

class _FaceScanDialog extends ConsumerStatefulWidget {
  const _FaceScanDialog({required this.mode, this.shiftId});
  final FaceMode mode;
  final String? shiftId;
  @override
  ConsumerState<_FaceScanDialog> createState() => _FaceScanDialogState();
}

class _FaceScanDialogState extends ConsumerState<_FaceScanDialog> {
  CameraController? _cam;
  String? _fatal;
  String _title = '', _sub = '';
  bool _recognized = false, _failed = false, _closed = false;
  int _step = 0; // enroll: 0 straight, 1 turn one way, 2 turn the other way. check: 0 straight, 1 small turn
  double _turnSign = 0, _yaw0 = 0;
  final List<List<double>> _prints = [];
  late final DateTime _deadline = DateTime.now().add(widget.mode == FaceMode.enroll ? const Duration(seconds: 75) : const Duration(seconds: 15));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _closed = true;
    _cam?.dispose();
    super.dispose();
  }

  void _say(String title, String sub) {
    if (!mounted || (_title == title && _sub == sub)) return;
    setState(() {
      _title = title;
      _sub = sub;
    });
  }

  Future<void> _start() async {
    _say(_t(context, 'بنجهّز الكاميرا…', 'Starting the camera…'), '');
    final FaceWorker worker;
    try {
      worker = await FaceWorker.instance;
    } catch (_) {
      if (mounted) setState(() => _fatal = _t(context, 'التعرّف على الوش مش متاح على الجهاز ده. استخدم الرقم السري.', 'Face recognition is not available on this computer. Use the PIN.'));
      return;
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw Exception('no camera');
      final front = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final c = CameraController(front, ResolutionPreset.medium, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _cam = c);
    } catch (_) {
      if (mounted) setState(() => _fatal = _t(context, 'مفيش كاميرا شغّالة. وصّل كاميرا أو استخدم الرقم السري.', 'No working camera. Connect one or use the PIN.'));
      return;
    }
    _prompt();
    await _loop(worker);
  }

  void _prompt() {
    switch ((widget.mode, _step)) {
      case (FaceMode.enroll, 0):
        _say(_t(context, 'بص قدام على الكاميرا', 'Look straight at the camera'), _t(context, 'لقطة 1 من 3', 'Shot 1 of 3'));
      case (FaceMode.enroll, 1):
        _say(_t(context, 'لف وشّك يمين شوية', 'Turn your head a little to one side'), _t(context, 'لقطة 2 من 3', 'Shot 2 of 3'));
      case (FaceMode.enroll, _):
        _say(_t(context, 'دلوقتي لف وشّك للناحية التانية', 'Now turn to the other side'), _t(context, 'لقطة 3 من 3', 'Shot 3 of 3'));
      case (_, 0):
        _say(_t(context, 'بص للكاميرا', 'Look at the camera'), _t(context, 'بنقرا ملامحك…', 'Reading your face…'));
      case (_, _):
        _say(_t(context, 'لف وشّك سنة صغيرة', 'Turn your head slightly'), _t(context, 'علشان نتأكد إنه إنت مش صورة', 'So we know it is you, not a photo'));
    }
  }

  Future<void> _loop(FaceWorker worker) async {
    while (!_closed && mounted && !_recognized && !_failed) {
      if (DateTime.now().isAfter(_deadline)) {
        await _fail(_t(context, 'ما عرفتكش', 'Not recognised'), _t(context, 'استخدم الرقم السري', 'Use the PIN'));
        return;
      }
      final c = _cam;
      if (c == null || !c.value.isInitialized || c.value.isTakingPicture) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        continue;
      }
      FaceScan? s;
      try {
        final f = await c.takePicture();
        final bytes = await f.readAsBytes();
        unawaited(File(f.path).delete().catchError((_) => File(f.path)));
        s = await worker.analyze(bytes);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      if (!mounted || _closed) return;
      if (s == null) {
        _say(_t(context, 'مش شايف وشّك', 'I cannot see your face'), _t(context, 'اقعد قدام الكاميرا في نور كويس', 'Sit in front of the camera in good light'));
        continue;
      }
      if (s.faces > 1) {
        _say(_t(context, 'واحد بس قدام الكاميرا', 'Only one person, please'), _t(context, 'في أكتر من وش في الصورة', 'More than one face is in view'));
        continue;
      }
      if (s.sizeRatio < 0.14) {
        _say(_t(context, 'قرّب من الكاميرا شوية', 'Come a little closer'), '');
        continue;
      }
      await _onFace(s);
    }
  }

  static double _dot(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  Future<void> _onFace(FaceScan s) async {
    if (widget.mode == FaceMode.enroll) {
      final ok = switch (_step) {
        0 => s.yaw.abs() < 0.12,
        1 => s.yaw.abs() > 0.2,
        _ => s.yaw.abs() > 0.2 && s.yaw.sign == -_turnSign,
      };
      if (!ok) {
        _prompt();
        return;
      }
      // every shot must be the same person as the first one
      if (_prints.isNotEmpty && _dot(_prints.first, s.print) < 0.45) {
        _say(_t(context, 'الشخص اتغيّر', 'A different person'), _t(context, 'نفس الشخص لازم يكمّل التسجيل', 'The same person must finish'));
        return;
      }
      if (_step == 1) _turnSign = s.yaw.sign;
      _prints.add(s.print);
      HapticFeedback.selectionClick();
      if (_step < 2) {
        setState(() => _step++);
        _prompt();
        return;
      }
      _say(_t(context, 'بنحفظ…', 'Saving…'), '');
      try {
        await ref.read(faceRepoProvider).enroll(_prints);
        await _succeed(_t(context, 'وشّك اتسجّل', 'Your face is saved'), _t(context, 'من النهارده تقدر تفتح بيه', 'You can use it from now on'), true);
      } catch (e) {
        if (mounted) await _fail(_t(context, 'ماتحفظش', 'Not saved'), friendlyError(context, e));
      }
      return;
    }
    // "is it me" / seller: one straight shot, then a small turn (a flat photo cannot change its head angle)
    if (_step == 0) {
      if (s.yaw.abs() > 0.15) {
        _prompt();
        return;
      }
      _prints
        ..clear()
        ..add(s.print);
      _yaw0 = s.yaw;
      setState(() => _step = 1);
      _prompt();
      return;
    }
    if ((s.yaw - _yaw0).abs() < 0.12) return;
    if (_dot(_prints.first, s.print) < 0.45) {
      setState(() => _step = 0);
      _prompt();
      return;
    }
    _say(_t(context, 'ثانية واحدة…', 'One moment…'), '');
    Map<String, dynamic> r;
    try {
      final repo = ref.read(faceRepoProvider);
      r = widget.mode == FaceMode.seller ? await repo.switchSeller(widget.shiftId!, _prints.first) : await repo.checkMe(_prints.first);
    } catch (e) {
      if (mounted) await _fail(_t(context, 'حصلت مشكلة', 'Something went wrong'), friendlyError(context, e));
      return;
    }
    if (!mounted) return;
    if (r['ok'] == true) {
      final name = '${r['name'] ?? ''}'.trim().split(RegExp(r'\s+')).first;
      await _succeed(_t(context, 'أهلاً يا $name', 'Hi $name'), widget.mode == FaceMode.seller ? _t(context, 'إنت البائع دلوقتي', 'You are the seller now') : _t(context, 'اتأكدنا إنه إنت', 'Confirmed'), r);
      return;
    }
    if (r['error'] == 'TOO_MANY') {
      await _fail(_t(context, 'محاولات كتير', 'Too many tries'), _t(context, 'استخدم الرقم السري', 'Use the PIN'));
      return;
    }
    // not matched: try again until the time runs out
    setState(() => _step = 0);
    _say(_t(context, 'لسه ما عرفتكش', 'Not recognised yet'), _t(context, 'بص قدام تاني', 'Look straight again'));
  }

  Future<void> _succeed(String title, String sub, Object result) async {
    setState(() => _recognized = true);
    _say(title, sub);
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    if (mounted) Navigator.pop(context, result);
  }

  Future<void> _fail(String title, String sub) async {
    setState(() => _failed = true);
    _say(title, sub);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(faceScanStyleProvider).valueOrNull ?? 'wave';
    final c = _cam;
    final heading = switch (widget.mode) {
      FaceMode.enroll => _t(context, 'سجّل وشّك', 'Record your face'),
      FaceMode.verify => _t(context, 'اتأكد إنه إنت', 'Confirm it is you'),
      FaceMode.seller => _t(context, 'مين هيبيع دلوقتي؟', 'Who is selling now?'),
    };
    final color = _recognized ? const Color(0xFF5EEAD4) : (_failed ? const Color(0xFFF0A453) : const Color(0xFFBFE6FF));
    return Dialog(
      backgroundColor: const Color(0xFF0A1C36),
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        width: 440,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: Text(heading, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800))),
              IconButton(
                tooltip: _t(context, 'إلغاء', 'Cancel'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
              ),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: AspectRatio(
                aspectRatio: 7 / 8,
                child: Stack(fit: StackFit.expand, children: [
                  const ColoredBox(color: Color(0xFF050F1F)),
                  if (c != null && c.value.isInitialized && c.value.previewSize != null)
                    Opacity(
                      opacity: _recognized ? 0.25 : 0.55,
                      child: FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: Transform.flip(
                          flipX: true, // a mirror feels natural
                          child: SizedBox(
                            width: math.max(c.value.previewSize!.width, 1),
                            height: math.max(c.value.previewSize!.height, 1),
                            child: CameraPreview(c),
                          ),
                        ),
                      ),
                    ),
                  if (_fatal == null) FaceScanView(style: style, recognized: _recognized, failed: _failed),
                  if (_fatal != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.no_photography_outlined, color: Color(0xFFF0A453), size: 44),
                          const SizedBox(height: 12),
                          Text(_fatal!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5)),
                        ]),
                      ),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 14),
            if (_fatal == null) ...[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(_title, key: ValueKey(_title), textAlign: TextAlign.center, style: TextStyle(color: color, fontSize: 21, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 4),
              Text(_sub, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF9DB1CB), fontSize: 14.5)),
              if (widget.mode == FaceMode.enroll) ...[
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < 3; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _step && !_recognized ? 26 : 10,
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        color: i < _step || _recognized ? const Color(0xFF5EEAD4) : (i == _step ? const Color(0xFF4FA8F5) : Colors.white24),
                      ),
                    ),
                ]),
              ],
            ] else
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'OK'))),
              ),
          ]),
        ),
      ),
    );
  }
}

// ================================================================================================ my profile
/// "ملفي": the signed-in member's name, PIN and face. Opens from the member's own name.
Future<void> showMyProfile(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _MyProfileSheet(),
    );

class _MyProfileSheet extends ConsumerStatefulWidget {
  const _MyProfileSheet();
  @override
  ConsumerState<_MyProfileSheet> createState() => _MyProfileSheetState();
}

class _MyProfileSheetState extends ConsumerState<_MyProfileSheet> {
  final _name = TextEditingController();
  bool _busy = false, _nameLoaded = false;

  @override
  void dispose() {
    disposeLater(_name);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) showSnack(context, done);
      ref.invalidate(myProfileProvider);
      ref.invalidate(bioOverviewProvider);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePin(bool hasPin) async {
    final r = await showSmoothDialog<(String?, String)>(context: context, builder: (_) => _ChangePinDialog(hasPin: hasPin));
    if (r == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(faceRepoProvider).setPin(r.$1, r.$2);
      if (!mounted) return;
      if (res['ok'] == true) {
        showSnack(context, _t(context, 'الرقم السري اتغيّر ✅', 'PIN changed ✅'));
        ref.invalidate(myProfileProvider);
      } else {
        showSnack(
            context,
            res['error'] == 'PIN_LOCKED'
                ? _t(context, 'اتقفل 5 دقايق من كتر المحاولات', 'Locked for 5 minutes after too many tries')
                : _t(context, 'الرقم القديم غلط', 'The old PIN is wrong'),
            error: true);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enroll() async {
    final agree = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.face_retouching_natural_rounded, size: 36),
        title: Text(_t(context, 'تسجيل الوش', 'Record your face')),
        content: Text(_t(context,
            'هناخد 3 لقطات: قدام، ويمين، وشمال. مش بنحفظ صورتك، بنحفظ أرقام بتمثّل ملامحك علشان تفتح بيها الوردية وتبدّل البائع. تقدر تمسحها في أي وقت.\n\nموافق؟',
            'We take 3 shots: straight, one side, the other side. Your photo is not kept, only numbers that describe your face, used to open your shift and switch the seller. You can delete them anytime.\n\nDo you agree?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(context, 'لا', 'No'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(context, 'موافق، ابدأ', 'Agree and start'))),
        ],
      ),
    );
    if (agree != true || !mounted) return;
    final ok = await showFaceScan(context, FaceMode.enroll);
    if (ok == true) {
      ref.invalidate(myProfileProvider);
      ref.invalidate(bioOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(myProfileProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: p.when(
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Padding(padding: const EdgeInsets.all(24), child: Text(friendlyError(context, e))),
          data: (m) {
            final allowed = m['allowed'] == true;
            final faces = (m['faces'] as num?)?.toInt() ?? 0;
            final hasPin = m['pin'] == true;
            if (!_nameLoaded) {
              _name.text = '${m['name'] ?? ''}';
              _nameLoaded = true;
            }
            final ink = inkColor(context);
            Widget card({required IconData icon, required String title, required String sub, Widget? action, bool hi = false}) => Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: hi ? BrandColors.electric.withValues(alpha: 0.10) : panelColor(context),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: hi ? BrandColors.electric : panelLine(context), width: hi ? 1.6 : 1),
                  ),
                  child: Row(children: [
                    Icon(icon, size: 28, color: hi ? BrandColors.electric : ink.withValues(alpha: 0.7)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                        Text(sub, style: TextStyle(fontSize: 13, color: ink.withValues(alpha: 0.65))),
                      ]),
                    ),
                    if (action != null) action,
                  ]),
                );
            return ListView(shrinkWrap: true, children: [
              Text(_t(context, 'ملفي', 'My profile'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              if (m['login'] != null) Text('${_t(context, 'اسم الدخول', 'Login')}: ${m['login']}', style: TextStyle(color: ink.withValues(alpha: 0.6))),
              if (!allowed)
                card(
                  icon: Icons.lock_outline_rounded,
                  title: _t(context, 'ملفك لسه مقفول', 'Your profile is locked'),
                  sub: _t(context, 'الأونر لازم يفعّلّك «يعدّل ملفه بنفسه» من شاشة الفريق.', 'The owner must turn on “self service” for you in Team.'),
                ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    enabled: allowed && !_busy,
                    decoration: InputDecoration(labelText: _t(context, 'الاسم اللي بيظهر', 'Display name')),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(80, 52)),
                  onPressed: !allowed || _busy ? null : () => _run(() => ref.read(faceRepoProvider).setName(_name.text.trim()), _t(context, 'الاسم اتحفظ ✅', 'Name saved ✅')),
                  child: Text(_t(context, 'حفظ', 'Save')),
                ),
              ]),
              card(
                icon: Icons.pin_outlined,
                title: _t(context, 'الرقم السري', 'PIN'),
                sub: hasPin ? _t(context, '4 أرقام · بتكتب القديم الأول', '4 digits · type the old one first') : _t(context, 'لسه مالكش رقم سري', 'No PIN yet'),
                action: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(80, 46)),
                  onPressed: !allowed || _busy ? null : () => _changePin(hasPin),
                  child: Text(hasPin ? _t(context, 'غيّر', 'Change') : _t(context, 'حدّد', 'Set')),
                ),
              ),
              card(
                hi: allowed && faces == 0,
                icon: Icons.face_retouching_natural_rounded,
                title: _t(context, 'بصمة الوش', 'Face ID'),
                sub: faces > 0 ? _t(context, 'متسجّلة ✓ ($faces لقطات)', 'Saved ✓ ($faces shots)') : _t(context, 'لسه ما سجّلتش · بتاخد 20 ثانية', 'Not recorded · takes 20 seconds'),
                action: Wrap(spacing: 6, children: [
                  if (faces > 0)
                    TextButton(
                      onPressed: !allowed || _busy ? null : () => _run(() => ref.read(faceRepoProvider).clearMine(), _t(context, 'بصمة الوش اتمسحت', 'Face deleted')),
                      child: Text(_t(context, 'امسح', 'Delete')),
                    ),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(90, 46)),
                    onPressed: !allowed || _busy ? null : _enroll,
                    child: Text(faces > 0 ? _t(context, 'سجّل تاني', 'Redo') : _t(context, 'سجّل وشّك', 'Record')),
                  ),
                ]),
              ),
              card(
                icon: Icons.fingerprint_rounded,
                title: _t(context, 'بصمة الصباع', 'Fingerprint'),
                sub: _t(context, 'محتاج جهاز بصمة متوصّل بالكمبيوتر', 'Needs a fingerprint reader on this computer'),
              ),
              const SizedBox(height: 12),
              Text(_t(context, 'مش بنحفظ صورة وشّك. بنحفظ أرقام بتمثّل ملامحك، وتقدر تمسحها في أي وقت.', 'Your photo is never stored, only numbers describing your face. Delete them anytime.'),
                  style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.6))),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
            ]);
          },
        ),
      ),
    );
  }
}

class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog({required this.hasPin});
  final bool hasPin;
  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final _old = TextEditingController(), _new = TextEditingController();

  @override
  void dispose() {
    disposeLater(_old);
    disposeLater(_new);
    super.dispose();
  }

  bool get _ok => _new.text.length == 4 && (!widget.hasPin || _old.text.length == 4);

  Widget _field(TextEditingController c, String label, {bool autofocus = false}) => TextField(
        controller: c,
        autofocus: autofocus,
        obscureText: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 4,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 24, letterSpacing: 10, fontWeight: FontWeight.w800),
        decoration: InputDecoration(counterText: '', labelText: label),
        onChanged: (_) => setState(() {}),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t(context, 'الرقم السري', 'PIN')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.hasPin) ...[_field(_old, _t(context, 'الرقم القديم', 'Old PIN'), autofocus: true), const SizedBox(height: 10)],
          _field(_new, _t(context, 'الرقم الجديد (4 أرقام)', 'New PIN (4 digits)'), autofocus: !widget.hasPin),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
          FilledButton(
            onPressed: _ok ? () => Navigator.pop(context, (widget.hasPin ? _old.text : null, _new.text)) : null,
            child: Text(_t(context, 'حفظ', 'Save')),
          ),
        ],
      );
}

// ================================================================================================ owner controls
/// In a member's sheet (owner only): turn self service on/off, see whether a face is saved, delete it.
class OwnerFaceControls extends ConsumerStatefulWidget {
  const OwnerFaceControls({super.key, required this.userId});
  final String userId;
  @override
  ConsumerState<OwnerFaceControls> createState() => _OwnerFaceControlsState();
}

class _OwnerFaceControlsState extends ConsumerState<OwnerFaceControls> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      ref.invalidate(bioOverviewProvider);
      if (mounted) showSnack(context, done);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = ref.watch(bioOverviewProvider).valueOrNull?[widget.userId];
    final m = o is Map ? o : const {};
    final on = m['self_service'] == true;
    final faces = (m['faces'] as num?)?.toInt() ?? 0;
    final repo = ref.read(faceRepoProvider);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(16), border: Border.all(color: panelLine(context))),
      child: Column(children: [
        SwitchListTile(
          value: on,
          onChanged: _busy
              ? null
              : (v) => _run(() => repo.setSelfService(widget.userId, v),
                  v ? _t(context, 'يقدر دلوقتي يعدّل ملفه ويسجّل وشّه ✅', 'Self service on ✅') : _t(context, 'ملفه اتقفل', 'Self service off')),
          secondary: const Icon(Icons.face_retouching_natural_rounded),
          title: Text(_t(context, 'يعدّل ملفه بنفسه', 'Self service'), style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(_t(context, 'الاسم والرقم السري وبصمة الوش', 'Name, PIN and Face ID')),
        ),
        ListTile(
          dense: true,
          leading: Icon(faces > 0 ? Icons.verified_rounded : Icons.face_outlined, color: faces > 0 ? BrandColors.success : null),
          title: Text(faces > 0 ? _t(context, 'وشّه متسجّل ($faces لقطات)', 'Face saved ($faces shots)') : _t(context, 'لسه ما سجّلش وشّه', 'No face yet')),
          trailing: faces > 0
              ? TextButton(
                  onPressed: _busy ? null : () => _run(() => repo.clearFace(widget.userId), _t(context, 'وشّه اتمسح', 'Face deleted')),
                  child: Text(_t(context, 'امسح وشّه', 'Delete face')),
                )
              : null,
        ),
      ]),
    );
  }
}

/// Owner: pick the scan look everybody sees (Hatō wave by default).
Future<void> showFaceStylePicker(BuildContext context, WidgetRef ref) async {
  final cur = ref.read(faceScanStyleProvider).valueOrNull ?? 'wave';
  final picked = await showSmoothDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(_t(context, 'شكل مسح الوش', 'Face scan look')),
      content: SizedBox(
        width: 640,
        child: Wrap(spacing: 12, runSpacing: 12, children: [
          for (final s in faceScanStyles)
            InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => Navigator.pop(d, s),
              child: Container(
                width: 190,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A1C36),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: s == cur ? const Color(0xFF4FA8F5) : Colors.white12, width: s == cur ? 2 : 1),
                ),
                child: Column(children: [
                  SizedBox(height: 180, child: FaceScanView(style: s)),
                  Text(faceScanStyleName(s, context.isAr), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                  if (s == 'wave') Text(_t(context, 'الأساسي', 'Default'), style: const TextStyle(color: Color(0xFF9DB1CB), fontSize: 12)),
                ]),
              ),
            ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(_t(context, 'إلغاء', 'Cancel')))],
    ),
  );
  if (picked == null || picked == cur || !context.mounted) return;
  try {
    await ref.read(faceRepoProvider).setStyle(picked);
    ref.invalidate(faceScanStyleProvider);
    if (context.mounted) showSnack(context, _t(context, 'شكل المسح اتغيّر لـ ${faceScanStyleName(picked, true)} ✅', 'Scan look: ${faceScanStyleName(picked, false)} ✅'));
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
  }
}
