// Face ID for the team: the camera scan dialog (record / "is it me" / switch seller) and the member's own profile sheet.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors.dart';
import '../../../core/l10n.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../shared/face_scan_anim.dart';
import '../../../shared/motion.dart';
import '../../../shared/states.dart';
import 'face_repository.dart';
import 'face_worker.dart';
import '../../../core/reduce_motion.dart';
import 'quick_login.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

enum FaceMode { enroll, verify, seller, login }

/// Opens the camera scan. Returns:
///  enroll  -> true when the face was saved
///  verify  -> {ok:true, ...} when the signed-in member matched their own face
///  seller  -> {ok:true, id, name} when the seller was switched
/// and null when cancelled, timed out or not recognised (the caller then falls back to the PIN / password).
///  login   -> {ok:true, name} when [onPrint] signed the member in (Windows sign-in screen)
Future<Object?> showFaceScan(BuildContext context, FaceMode mode, {String? shiftId, Future<Map<String, dynamic>> Function(List<double> print)? onPrint}) =>
    showSmoothDialog<Object>(context: context, barrierDismissible: false, builder: (_) => _FaceScanDialog(mode: mode, shiftId: shiftId, onPrint: onPrint));

/// Starts the face engine in the background (models + ONNX session), so the first scan opens instantly. Never throws.
void faceWarmUp() {
  if (kIsWebOrNotWindows) return;
  FaceWorker.instance.then((_) {}, onError: (_) {});
}

bool get kIsWebOrNotWindows {
  try {
    return !Platform.isWindows;
  } catch (_) {
    return true;
  }
}

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
  const _FaceScanDialog({required this.mode, this.shiftId, this.onPrint});
  final FaceMode mode;
  final String? shiftId;
  final Future<Map<String, dynamic>> Function(List<double> print)? onPrint;
  @override
  ConsumerState<_FaceScanDialog> createState() => _FaceScanDialogState();
}

class _FaceScanDialogState extends ConsumerState<_FaceScanDialog> {
  _WinCam? _cam;
  String? _fatal;
  String _title = '', _sub = '';
  bool _recognized = false, _failed = false, _closed = false;
  int _step = 0; // enroll: 0 straight, 1 turn one way, 2 turn the other way. check: 0 straight, 1 small turn
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
    final c = _cam;
    _cam = null;
    // turn the camera (and its light) off now, plus anything a half-finished start left behind
    (c?.dispose() ?? Future<void>.value()).whenComplete(_WinCam.closeAll);
    super.dispose();
  }

  bool get _login => widget.mode == FaceMode.login;
  String _fbAr() => _login ? 'ادخل بكلمة السر' : 'استخدم الرقم السري';
  String _fbEn() => _login ? 'Use your password' : 'Use the PIN';

  void _say(String title, String sub) {
    if (!mounted || (_title == title && _sub == sub)) return;
    setState(() {
      _title = title;
      _sub = sub;
    });
  }

  Future<void> _start() async {
    _say(_t(context, 'بنجهّز الكاميرا…', 'Starting the camera…'), _t(context, 'أول مرة بس ممكن تاخد دقيقة (بنحمّل ملف التعرّف)', 'The first time may take a minute (downloading the recognizer)'));
    // the camera and the engine start at the same time (each takes about a second)
    final camF = _WinCam.open();
    camF.then((_) {}, onError: (_) {});
    final FaceWorker worker;
    try {
      worker = await FaceWorker.instance;
    } catch (_) {
      camF.then((c) => c.dispose(), onError: (_) {});
      if (mounted) setState(() => _fatal = _t(context, 'التعرّف على الوش مش متاح على الجهاز ده. ${_fbAr()}.', 'Face recognition is not available on this computer. ${_fbEn()}.'));
      return;
    }
    try {
      final c = await camF;
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _cam = c);
    } catch (_) {
      if (mounted) setState(() => _fatal = _t(context, 'مفيش كاميرا شغّالة. وصّل كاميرا أو ${_fbAr()}.', 'No working camera. Connect one or ${_fbEn().toLowerCase()}.'));
      return;
    }
    _prompt();
    await _loop(worker);
  }

  void _prompt() {
    if (widget.mode == FaceMode.enroll) {
      final msg = switch (_step) {
        0 => _t(context, 'بص على الكاميرا', 'Look at the camera'),
        1 => _t(context, 'حرّك راسك سنة صغيرة يمين', 'Move your head slightly to one side'),
        _ => _t(context, 'وسنة صغيرة شمال', 'And slightly to the other side'),
      };
      _say(msg, '${_t(context, 'لقطة', 'Shot')} ${_step + 1} ${_t(context, 'من', 'of')} 3');
    } else {
      _say(_t(context, 'بص للكاميرا', 'Look at the camera'), _t(context, 'بنقرا ملامحك…', 'Reading your face…'));
    }
  }

  int _errors = 0;
  String _diag = '';
  DateTime _lastShot = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _loop(FaceWorker worker) async {
    while (!_closed && mounted && !_recognized && !_failed) {
      if (DateTime.now().isAfter(_deadline)) {
        await _fail(_t(context, 'ما عرفتكش', 'Not recognised'), _t(context, _fbAr(), _fbEn()));
        return;
      }
      final c = _cam;
      if (c == null || c.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        continue;
      }
      FaceScan? s;
      final sw = Stopwatch()..start();
      try {
        s = await _grab(worker, c);
        _errors = 0;
      } catch (e) {
        // never fail silently: after a few errors in a row, say what is wrong
        _errors++;
        if (mounted) {
          setState(() => _diag = '$e'.contains('capture path')
              ? _t(context, 'ويندوز مش لاقي فولدر «الصور» (Pictures) علشان يحفظ اللقطة. افتح File Explorer واعمل فولدر Pictures، أو رجّعه من OneDrive.',
                  'Windows cannot find the Pictures folder to save the shot. Create it in File Explorer or restore it from OneDrive.')
              : '${_t(context, 'خطأ', 'Error')}: ${'$e'.split('\n').first}');
        }
        if (_errors >= 6 && mounted) {
          setState(() => _fatal = '${_t(context, 'الكاميرا مش بتدّي صورة للبرنامج.', 'The camera is not giving pictures.')}\n$_diag');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
        continue;
      }
      if (!mounted || _closed) return;
      final ms = sw.elapsedMilliseconds;
      setState(() => _diag = s == null
          ? '${_t(context, 'مفيش وش', 'no face')} · $ms ms'
          : '${s.faces} ${_t(context, 'وش', 'face')} · ${(s.score * 100).round()}% · ${_t(context, 'زاوية', 'angle')} ${s.yaw.toStringAsFixed(2)} · $ms ms');
      if (s == null) {
        _say(_t(context, 'مش شايف وشّك', 'I cannot see your face'), _t(context, 'خلّي وشّك في نص الكاميرا في نور كويس', 'Keep your face in the middle, in good light'));
        continue;
      }
      if (s.faces > 1) {
        _say(_t(context, 'واحد بس قدام الكاميرا', 'Only one person, please'), _t(context, 'في أكتر من وش في الصورة', 'More than one face is in view'));
        continue;
      }
      if (s.sizeRatio < 0.12) {
        _say(_t(context, 'قرّب من الكاميرا شوية', 'Come a little closer'), '');
        continue;
      }
      await _onFace(s);
    }
  }

  final _snapKey = GlobalKey();
  bool _useFile = false; // the preview snapshot came out black: save pictures through the camera instead
  int _blank = 0;

  /// One picture: a snapshot of the preview on screen (fast, no file), or a saved photo when snapshots do not work here.
  Future<FaceScan?> _grab(FaceWorker worker, _WinCam c) async {
    if (!_useFile) {
      final b = _snapKey.currentContext?.findRenderObject();
      if (b is RenderRepaintBoundary) {
        final img = await b.toImage(pixelRatio: 1);
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final w = img.width, h = img.height;
        img.dispose();
        if (data != null && w > 32 && h > 32) {
          final px = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
          var sum = 0;
          for (var i = 0; i < px.length; i += 4 * 997) {
            sum += px[i] + px[i + 1] + px[i + 2];
          }
          if (sum > (px.length ~/ (4 * 997)) * 12) {
            _blank = 0;
            return worker.analyzeRgba(px, w, h);
          }
        }
        if (++_blank >= 6) _useFile = true; // the camera picture never reaches the snapshot on this computer
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return null;
      }
    }
    final f = await c.takePicture();
    final bytes = await f.readAsBytes();
    unawaited(File(f.path).delete().then((_) => null, onError: (_) => null));
    return worker.analyze(bytes);
  }

  static double _dot(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  final List<double> _yaws = [];
  DateTime _firstAt = DateTime.now();

  Future<void> _onFace(FaceScan s) async {
    if (widget.mode == FaceMode.enroll) {
      // three good shots, a moment apart; a small head movement between them gives better prints, but it is never required
      if (DateTime.now().difference(_lastShot) < const Duration(milliseconds: 350)) return;
      if (_prints.isEmpty && s.yaw.abs() > 0.35) {
        _say(_t(context, 'بص قدام على الكاميرا', 'Look at the camera'), _t(context, 'وشّك لافف زيادة', 'Your head is turned too much'));
        return;
      }
      if (_prints.isNotEmpty && _dot(_prints.first, s.print) < 0.45) {
        _say(_t(context, 'الشخص اتغيّر', 'A different person'), _t(context, 'نفس الشخص لازم يكمّل التسجيل', 'The same person must finish'));
        return;
      }
      _lastShot = DateTime.now();
      _prints.add(s.print);
      _yaws.add(s.yaw);
      HapticFeedback.selectionClick();
      if (_prints.length < 3) {
        setState(() => _step = _prints.length);
        _prompt();
        return;
      }
      setState(() => _step = 3);
      _say(_t(context, 'بنحفظ…', 'Saving…'), '');
      try {
        await ref.read(faceRepoProvider).enroll(_prints);
        await _succeed(_t(context, 'وشّك اتسجّل', 'Your face is saved'), _t(context, 'من دلوقتي تقدر تفتح بيه', 'You can use it from now on'), true);
      } catch (e) {
        if (mounted) {
          await _fail(
              _t(context, 'ماتحفظش', 'Not saved'),
              '$e'.contains('FACE_TAKEN')
                  ? _t(context, 'الوش ده متسجّل لموظف تاني. كل موظف لازم يسجّل وشّه هو بنفسه.', 'This face belongs to another member. Everyone records their own face.')
                  : friendlyError(context, e));
        }
      }
      return;
    }
    // seller switch: the first good picture goes straight to the server (fast, like a phone's face unlock)
    // closing the shift (money): one picture, then any small head movement (a photo cannot change its angle)
    if (s.yaw.abs() > 0.4) {
      _say(_t(context, 'بص للكاميرا', 'Look at the camera'), '');
      return;
    }
    if (widget.mode == FaceMode.verify) {
      if (_prints.isEmpty) {
        _prints.add(s.print);
        _yaws.add(s.yaw);
        setState(() => _step = 1);
        _say(_t(context, 'حرّك راسك سنة صغيرة', 'Move your head slightly'), _t(context, 'علشان نتأكد إنه إنت مش صورة', 'So we know it is you, not a photo'));
        return;
      }
      if (_dot(_prints.first, s.print) < 0.45) {
        _prints.clear();
        _yaws.clear();
        setState(() => _step = 0);
        _prompt();
        return;
      }
      if ((s.yaw - _yaws.first).abs() < 0.08) return; // still the same angle: wait for the movement
    }
    if (_login) {
      // sign-in: a living face is never perfectly still, so the natural tiny movement over a few pictures (~0.3 s)
      // is enough and nobody is asked to move. A printed photo held still never changes its angle; only then we ask.
      if (_prints.isEmpty || _dot(_prints.first, s.print) < 0.45) {
        _prints
          ..clear()
          ..add(s.print);
        _yaws
          ..clear()
          ..add(s.yaw);
        _firstAt = DateTime.now();
        return;
      }
      _yaws.add(s.yaw);
      final spread = _yaws.reduce(math.max) - _yaws.reduce(math.min);
      if (spread < 0.03) {
        if (DateTime.now().difference(_firstAt) > const Duration(milliseconds: 1300)) {
          _say(_t(context, 'حرّك راسك سنة صغيرة', 'Move your head slightly'), _t(context, 'علشان نتأكد إنه إنت مش صورة', 'So we know it is you, not a photo'));
        }
        return;
      }
    }
    _say(_t(context, 'ثانية واحدة…', 'One moment…'), '');
    Map<String, dynamic> r;
    try {
      final repo = ref.read(faceRepoProvider);
      r = widget.mode == FaceMode.seller
          ? await repo.switchSeller(widget.shiftId!, s.print)
          : _login
              ? await widget.onPrint!(s.print)
              : await repo.checkMe(s.print);
    } catch (e) {
      if (mounted) await _fail(_t(context, 'حصلت مشكلة', 'Something went wrong'), friendlyError(context, e));
      return;
    }
    if (!mounted) return;
    if (r['ok'] == true) {
      final full = '${r['name'] ?? ''}'.trim();
      final name = full.length <= 18 ? full : full.split(RegExp(r'\s+')).first;
      await _succeed(_t(context, 'أهلاً يا $name', 'Hi $name'), widget.mode == FaceMode.seller
              ? _t(context, 'إنت البائع دلوقتي', 'You are the seller now')
              : _login
                  ? _t(context, 'بندخّلك…', 'Signing you in…')
                  : _t(context, 'اتأكدنا إنه إنت', 'Confirmed'),
          r);
      return;
    }
    if (r['error'] == 'NO_DEVICE') {
      await _fail(_t(context, 'الدخول بالوش مش متفعّل هنا', 'Face sign-in is not set up here'),
          _t(context, 'ادخل بكلمة السر مرة على الجهاز ده، وسجّل وشّك من «ملفي»', 'Sign in with your password once on this computer and record your face in My profile'));
      return;
    }
    if (r['error'] == 'TOO_MANY') {
      await _fail(_t(context, 'محاولات كتير', 'Too many tries'), _t(context, _fbAr(), _fbEn()));
      return;
    }
    _prints.clear();
    _yaws.clear();
    if (mounted) setState(() => _step = 0);
    _say(_t(context, 'لسه ما عرفتكش', 'Not recognised yet'), _t(context, 'بص للكاميرا', 'Look at the camera'));
  }

  Future<void> _succeed(String title, String sub, Object result) async {
    setState(() => _recognized = true);
    _say(title, sub);
    await Future<void>.delayed(Duration(milliseconds: widget.mode == FaceMode.verify ? 900 : 550));
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
      FaceMode.login => _t(context, 'ادخل بوشّك', 'Sign in with your face'),
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
                  if (c != null && style == 'circle')
                    // phone-style: the picture in a circle, bright, with the ring of lines around it
                    LayoutBuilder(builder: (_, box) {
                      final d = (faceCircleRadius(box.biggest) - 20) * 2;
                      return Center(
                        child: ClipOval(
                          child: SizedBox(
                            width: d,
                            height: d,
                            child: AnimatedOpacity(
                              duration: ReduceMotion.d(const Duration(milliseconds: 300)),
                              opacity: _recognized ? 0.35 : 1,
                              child: FittedBox(
                                fit: BoxFit.cover,
                                clipBehavior: Clip.hardEdge,
                                child: RepaintBoundary(key: _snapKey, child: SizedBox(width: math.max(c.width, 1), height: math.max(c.height, 1), child: c.preview())),
                              ),
                            ),
                          ),
                        ),
                      );
                    })
                  else if (c != null)
                    Opacity(
                      opacity: _recognized ? 0.25 : 0.55,
                      child: FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: Transform.flip(
                          flipX: false, // the Windows preview is already a mirror
                          child: SizedBox(
                            width: math.max(c.width, 1),
                            height: math.max(c.height, 1),
                            child: RepaintBoundary(key: _snapKey, child: c.preview()),
                          ),
                        ),
                      ),
                    ),
                  if (_fatal == null)
                    FaceScanView(
                      style: style,
                      recognized: _recognized,
                      failed: _failed,
                      progress: widget.mode == FaceMode.enroll ? _prints.length / 3 : (widget.mode == FaceMode.verify && _prints.isNotEmpty ? 0.5 : null),
                    ),
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
                duration: ReduceMotion.d(const Duration(milliseconds: 220)),
                child: Text(_title, key: ValueKey(_title), textAlign: TextAlign.center, style: TextStyle(color: color, fontSize: 21, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 4),
              Text(_sub, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF9DB1CB), fontSize: 14.5)),
              if (_diag.isNotEmpty && !_recognized)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_diag, textAlign: TextAlign.center, style: const TextStyle(color: Color(0x889DB1CB), fontSize: 11.5)),
                ),
              if (widget.mode == FaceMode.enroll) ...[
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < 3; i++)
                    AnimatedContainer(
                      duration: ReduceMotion.d(const Duration(milliseconds: 250)),
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
Future<void> showMyProfile(BuildContext context) => showSmoothDialog<void>(
      context: context,
      builder: (d) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(d).height * 0.88),
          child: const _MyProfileSheet(),
        ),
      ),
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
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
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
              Row(children: [
                Expanded(child: Text(_t(context, 'ملفي', 'My profile'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900))),
                IconButton(tooltip: _t(context, 'إغلاق', 'Close'), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
              ]),
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
              if (QuickLogin.supported)
                _HelloCard(allowed: allowed, card: card)
              else
                card(
                  icon: Icons.fingerprint_rounded,
                  title: _t(context, 'بصمة الصباع', 'Fingerprint'),
                  sub: _t(context, 'متاحة على برنامج الويندوز', 'Available in the Windows app'),
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

/// Appearance → Windows: the face scan look as a page (owner picks; everybody sees the picked one).
class FaceStylePanel extends ConsumerWidget {
  const FaceStylePanel({super.key, required this.isOwner});
  final bool isOwner;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cur = ref.watch(faceScanStyleProvider).valueOrNull ?? 'wave';
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text(_t(context, 'شكل مسح الوش', 'Face scan look'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      Text(
          isOwner
              ? _t(context, 'اللي تختاره بيظهر لكل الفريق وهو بيفتح الوردية أو بيبدّل البائع بوشّه.', 'What you pick is shown to the whole team when they use Face ID.')
              : _t(context, 'المالك بس اللي يقدر يغيّره.', 'Only the owner can change it.'),
          style: TextStyle(color: inkColor(context).withValues(alpha: 0.65))),
      const SizedBox(height: 16),
      Wrap(spacing: 14, runSpacing: 14, children: [
        for (final s in faceScanStyles)
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: !isOwner || s == cur
                ? null
                : () async {
                    try {
                      await ref.read(faceRepoProvider).setStyle(s);
                      ref.invalidate(faceScanStyleProvider);
                      if (context.mounted) showSnack(context, _t(context, 'شكل المسح: ${faceScanStyleName(s, true)} ✅', 'Scan look: ${faceScanStyleName(s, false)} ✅'));
                    } catch (e) {
                      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                    }
                  },
            child: Container(
              width: 200,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0A1C36),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: s == cur ? const Color(0xFF4FA8F5) : Colors.white12, width: s == cur ? 2.4 : 1),
              ),
              child: Column(children: [
                SizedBox(height: 190, child: FaceScanView(style: s)),
                Text(faceScanStyleName(s, context.isAr), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                Text(s == cur ? _t(context, 'المختار ✓', 'Selected ✓') : (s == 'wave' ? _t(context, 'الأساسي', 'Default') : ' '),
                    style: TextStyle(color: s == cur ? const Color(0xFF5EEAD4) : const Color(0xFF9DB1CB), fontSize: 12.5)),
              ]),
            ),
          ),
      ]),
    ]);
  }
}


/// The computer's camera through the Windows camera plugin directly (no Android camera code in the customer APK).
class _WinCam {
  _WinCam._(this.id, this.width, this.height);
  final int id;
  final double width, height;
  bool busy = false;
  bool _gone = false;

  /// Every camera this app opened and has not released yet. The camera light must go off the moment a face screen
  /// closes, so anything left over (an open that failed half-way, a release that failed) is released here too.
  static final Set<int> _live = {};

  static Future<_WinCam> open() async {
    await closeAll(); // never two cameras at once, and nothing left from a previous scan
    final p = CameraPlatform.instance;
    final cams = await p.availableCameras();
    if (cams.isEmpty) throw Exception('no camera');
    final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
    final id = await p.createCamera(cam, ResolutionPreset.medium);
    _live.add(id);
    try {
      final ready = p.onCameraInitialized(id).first;
      await p.initializeCamera(id);
      final e = await ready.timeout(const Duration(seconds: 10));
      return _WinCam._(id, e.previewWidth, e.previewHeight);
    } catch (_) {
      await _release(id); // half-open camera: turn it off before giving up
      rethrow;
    }
  }

  Widget preview() => CameraPlatform.instance.buildPreview(id);

  Future<XFile> takePicture() async {
    busy = true;
    try {
      return await CameraPlatform.instance.takePicture(id);
    } finally {
      busy = false;
    }
  }

  Future<void> dispose() async {
    if (_gone) return;
    _gone = true;
    // a picture being written keeps the device busy: wait for it (at most 2 s) so the release really happens
    for (var i = 0; busy && i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _release(id);
  }

  static Future<void> _release(int id) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await CameraPlatform.instance.dispose(id);
        _live.remove(id);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    _live.remove(id);
  }

  /// Releases every camera still open (called when a face screen closes and before a new one opens).
  static Future<void> closeAll() async {
    for (final id in _live.toList()) {
      await _release(id);
    }
  }
}


/// "My profile" on Windows: sign in to this computer with the fingerprint (Windows Hello). The face sign-in needs no
/// switch: it works on every computer where the member signed in once with the password and has a recorded face.
class _HelloCard extends ConsumerStatefulWidget {
  const _HelloCard({required this.allowed, required this.card});
  final bool allowed;
  final Widget Function({required IconData icon, required String title, required String sub, Widget? action, bool hi}) card;
  @override
  ConsumerState<_HelloCard> createState() => _HelloCardState();
}

class _HelloCardState extends ConsumerState<_HelloCard> {
  bool? _on;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = ref.read(supabaseProvider).auth.currentUser?.id;
    final a = uid == null ? null : await QuickLogin.account(uid);
    if (mounted) setState(() => _on = a?.hello ?? false);
  }

  Future<void> _toggle(bool v) async {
    setState(() => _busy = true);
    String? err;
    try {
      err = await QuickLogin.setHello(ref.read(supabaseProvider), v, reason: _t(context, 'تفعيل الدخول بالبصمة على My Hatō', 'Turn on fingerprint sign-in for My Hatō'));
    } catch (e) {
      err = 'failed';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) {
      setState(() => _on = v);
      showSnack(context, v ? _t(context, 'الدخول بالبصمة اتفعّل على الجهاز ده ✅', 'Fingerprint sign-in is on for this computer ✅') : _t(context, 'الدخول بالبصمة اتقفل', 'Fingerprint sign-in is off'));
    } else {
      showSnack(
          context,
          err == 'NO_HELLO'
              ? _t(context, 'البصمة مش متظبطة في الويندوز. افتح Settings ← Accounts ← Sign-in options وسجّل بصمتك (Windows Hello) الأول.',
                  'Windows Hello is not set up. Open Settings → Accounts → Sign-in options and add your fingerprint first.')
              : err == 'CANCELED'
                  ? _t(context, 'البصمة ما اتأكدتش', 'Fingerprint not confirmed')
                  : _t(context, 'ما قدرناش نفعّلها، جرّب تاني', 'Could not turn it on, try again'),
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) => widget.card(
        icon: Icons.fingerprint_rounded,
        title: _t(context, 'الدخول بالبصمة', 'Fingerprint sign-in'),
        sub: _t(context, 'على الجهاز ده بس · بصمة Windows Hello', 'This computer only · Windows Hello'),
        hi: false,
        action: _on == null || _busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.2))
            : Switch(value: _on!, onChanged: widget.allowed ? _toggle : null),
      );
}
