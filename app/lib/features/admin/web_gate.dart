// The team console in a web browser (owner's request): the owner only, always with two steps — the password, then a
// 6-digit code from an authenticator app (Google Authenticator, Microsoft Authenticator…). The first time the owner
// links the app by scanning a QR code. Idle for 30 minutes = signed out. Staff keep using the Windows app.
// Data stays protected by the same server rules as everywhere else; this gate decides who may open the web console.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import 'admin_repository.dart' show staffContextProvider;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

class WebOwnerGate extends ConsumerStatefulWidget {
  const WebOwnerGate({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<WebOwnerGate> createState() => _WebOwnerGateState();
}

class _WebOwnerGateState extends ConsumerState<WebOwnerGate> {
  static const _idle = Duration(minutes: 30);
  bool? _aal2;
  Timer? _idleTimer;

  SupabaseClient get _db => ref.read(supabaseProvider);

  @override
  void initState() {
    super.initState();
    _check();
    _touch();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  void _touch() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idle, () => _db.auth.signOut());
  }

  void _check() {
    final lvl = _db.auth.mfa.getAuthenticatorAssuranceLevel();
    setState(() => _aal2 = lvl.currentLevel == AuthenticatorAssuranceLevels.aal2);
  }

  @override
  Widget build(BuildContext context) {
    final ctx = ref.watch(staffContextProvider).valueOrNull;
    if (ctx == null || _aal2 == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!ctx.roles.contains('owner')) {
      return _Shell(
        icon: Icons.lock_person_rounded,
        title: _t(context, 'نسخة الويب للمالك بس', 'The web console is for the owner only'),
        body: Text(_t(context, 'الموظفين بيشتغلوا من برنامج الويندوز في الفرع.', 'Staff work from the Windows app in the branch.'),
            textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray)),
        action: FilledButton(onPressed: () => _db.auth.signOut(), child: Text(_t(context, 'خروج', 'Sign out'))),
      );
    }
    if (_aal2 != true) return _SecondStep(onDone: _check);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touch(),
      onPointerHover: (_) => _touch(),
      child: KeyboardListener(focusNode: FocusNode(skipTraversal: true, canRequestFocus: false), onKeyEvent: (_) => _touch(), child: widget.child),
    );
  }
}

/// The 6-digit code. First time: link an authenticator app with a QR code, then confirm one code.
class _SecondStep extends ConsumerStatefulWidget {
  const _SecondStep({required this.onDone});
  final VoidCallback onDone;
  @override
  ConsumerState<_SecondStep> createState() => _SecondStepState();
}

class _SecondStepState extends ConsumerState<_SecondStep> {
  final _code = TextEditingController();
  String? _factorId;
  AuthMFAEnrollResponse? _enroll; // non-null = first time, show the QR
  String? _error;
  bool _busy = true;

  SupabaseClient get _db => ref.read(supabaseProvider);

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final f = await _db.auth.mfa.listFactors();
      final verified = f.totp.where((x) => x.status == FactorStatus.verified).toList();
      if (verified.isNotEmpty) {
        _factorId = verified.first.id;
      } else {
        for (final x in f.all.where((x) => x.status != FactorStatus.verified)) {
          await _db.auth.mfa.unenroll(x.id); // a half-finished link from before
        }
        _enroll = await _db.auth.mfa.enroll(factorType: FactorType.totp, issuer: 'My Hatō', friendlyName: 'My Hatō web');
        _factorId = _enroll!.id;
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _verify() async {
    final c = _code.text.trim();
    if (c.length != 6 || _factorId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _db.auth.mfa.challengeAndVerify(factorId: _factorId!, code: c);
      widget.onDone();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = _t(context, 'الكود غلط أو خلص وقته. اكتب الكود اللي ظاهر دلوقتي في التطبيق.', 'Wrong or expired code. Type the one showing now in the app.');
          _code.clear();
        });
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final first = _enroll != null;
    return _Shell(
      icon: Icons.shield_rounded,
      title: first ? _t(context, 'اربط تطبيق الأكواد مرة واحدة', 'Link your code app once') : _t(context, 'الخطوة التانية', 'Second step'),
      body: Column(mainAxisSize: MainAxisSize.min, children: [
        if (first) ...[
          Text(
              _t(context, 'افتح Google Authenticator (أو Microsoft Authenticator) على موبايلك ← «+» ← «امسح QR»، وامسح الكود ده.',
                  'Open Google Authenticator (or Microsoft Authenticator) on your phone → “+” → “Scan a QR code”, and scan this.'),
              textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(data: _enroll!.totp?.uri ?? '', size: 210, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 8),
          SelectableText(_enroll!.totp?.secret ?? '', style: const TextStyle(fontSize: 12.5, letterSpacing: 1.2, color: BrandColors.gray)),
          const SizedBox(height: 14),
        ],
        Text(_t(context, 'اكتب الكود اللي من ٦ أرقام اللي ظاهر في التطبيق', 'Type the 6-digit code shown in the app'), textAlign: TextAlign.center),
        const SizedBox(height: 10),
        SizedBox(
          width: 240,
          child: TextField(
            controller: _code,
            autofocus: true,
            textAlign: TextAlign.center,
            maxLength: 6,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 8),
            decoration: const InputDecoration(counterText: '', hintText: '••••••'),
            onChanged: (v) {
              if (v.length == 6) _verify();
            },
            onSubmitted: (_) => _verify(),
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.error))),
      ]),
      action: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(onPressed: () => _db.auth.signOut(), child: Text(_t(context, 'خروج', 'Sign out'))),
        const SizedBox(width: 8),
        FilledButton(onPressed: _busy ? null : _verify, child: Text(_busy ? '…' : _t(context, 'تأكيد', 'Confirm'))),
      ]),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.icon, required this.title, required this.body, required this.action});
  final IconData icon;
  final String title;
  final Widget body, action;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFF4F7FC),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 52, color: BrandColors.electric),
                    const SizedBox(height: 12),
                    Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 14),
                    body,
                    const SizedBox(height: 20),
                    action,
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}
