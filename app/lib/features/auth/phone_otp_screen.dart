import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl_phone_field/intl_phone_field.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'auth_repository.dart';

/// Phone OTP flow.
/// mode=signin  -> sign in / sign up with phone
/// mode=verify  -> attach + verify a phone for an already signed-in account
///
/// The 2-minute countdown is UX only. Validity is enforced by Supabase Auth
/// (set "SMS OTP Expiry" = 120 seconds in the dashboard). An expired code is
/// rejected by the server even if typed; the client also blocks submission.
class PhoneOtpScreen extends ConsumerStatefulWidget {
  const PhoneOtpScreen({super.key, required this.mode, this.redirect});
  final String mode;
  final String? redirect;
  @override
  ConsumerState<PhoneOtpScreen> createState() => _PhoneOtpScreenState();
}

class _PhoneOtpScreenState extends ConsumerState<PhoneOtpScreen> {
  static const otpLifetime = Duration(minutes: 2);
  static const resendCooldown = Duration(seconds: 60);

  String? _e164;
  bool _codeSent = false;
  bool _busy = false;
  final _code = TextEditingController();
  Timer? _timer;
  DateTime? _sentAt;
  Duration _now = Duration.zero;

  bool get _expired => _sentAt != null && _now >= otpLifetime;
  Duration get _remaining => otpLifetime - _now;
  bool get _canResend => _sentAt != null && _now >= resendCooldown;

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _sentAt = DateTime.now();
    _now = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now().difference(_sentAt!));
      if (_now >= otpLifetime) _timer?.cancel();
    });
  }

  Future<void> _send() async {
    if (_e164 == null) return;
    setState(() => _busy = true);
    try {
      final auth = ref.read(authRepoProvider);
      if (widget.mode == 'verify') {
        await auth.startPhoneChange(_e164!);
      } else {
        await auth.sendPhoneOtp(_e164!);
      }
      _code.clear();
      setState(() => _codeSent = true);
      _startTimer();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_expired || _code.text.length != 6) return;
    setState(() => _busy = true);
    try {
      final auth = ref.read(authRepoProvider);
      if (widget.mode == 'verify') {
        await auth.verifyPhoneChange(_e164!, _code.text);
      } else {
        await auth.verifyPhoneOtp(_e164!, _code.text);
      }
      ref.invalidate(profileProvider);
      if (mounted) context.go(widget.redirect ?? '/');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final title = widget.mode == 'verify' ? context.tr('verify_phone_title') : context.tr('continue_phone');
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        if (widget.mode == 'verify')
          Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(context.tr('verify_phone_body'), style: const TextStyle(color: BrandColors.gray))),
        Directionality(
          textDirection: TextDirection.ltr,
          child: IntlPhoneField(
            initialCountryCode: 'EG',
            enabled: !_codeSent || _canResend || _expired,
            decoration: InputDecoration(labelText: context.tr('phone')),
            languageCode: context.lang,
            disableLengthCheck: false,
            onChanged: (p) => _e164 = p.completeNumber,
          ),
        ),
        const SizedBox(height: 12),
        if (!_codeSent)
          FilledButton(onPressed: _busy ? null : _send, child: Text(context.tr('send_code')))
        else ...[
          Text(context.tr('otp_sent_to', {'phone': _e164 ?? ''}), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Directionality(
            textDirection: TextDirection.ltr,
            child: TextField(
              controller: _code,
              enabled: !_expired,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              autofillHints: const [AutofillHints.oneTimeCode],
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 28, letterSpacing: 14, fontWeight: FontWeight.w800),
              decoration: InputDecoration(counterText: '', labelText: context.tr('otp_title')),
              onChanged: (v) {
                setState(() {});
                if (v.length == 6) _verify();
              },
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: _expired
                ? Text(context.tr('otp_expired'), style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w700))
                : Text(context.tr('otp_expires_in', {'time': _fmt(_remaining)}), style: const TextStyle(color: BrandColors.gray)),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: (_busy || _expired || _code.text.length != 6) ? null : _verify,
            child: Text(context.tr('verify')),
          ),
          const SizedBox(height: 8),
          TextButton(
            // each resend asks Supabase for a NEW code; the previous one becomes invalid server-side
            onPressed: (_busy || !_canResend) ? null : _send,
            child: Text(_canResend
                ? context.tr('resend_code')
                : context.tr('resend_in', {'s': (resendCooldown - _now).inSeconds.clamp(0, 60).toString()})),
          ),
        ],
      ]),
    );
  }
}
