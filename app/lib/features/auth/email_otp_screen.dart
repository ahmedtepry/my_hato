import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'auth_repository.dart';

/// Enter the 6-digit code that Supabase Auth emailed.
///
/// The countdowns are UX only: Supabase enforces expiry ("Email OTP Expiration", set to 180 s),
/// one-time use, the resend interval and rate limits. A wrong or expired code is rejected server-side.
class EmailOtpScreen extends ConsumerStatefulWidget {
  const EmailOtpScreen({super.key, required this.email, required this.purpose, this.alreadySent = true, this.redirect});
  final String email;
  final EmailCodePurpose purpose;

  /// false -> request a code as soon as the screen opens (e.g. "verify my email" from the profile).
  final bool alreadySent;
  final String? redirect;

  @override
  ConsumerState<EmailOtpScreen> createState() => _EmailOtpScreenState();
}

class _EmailOtpScreenState extends ConsumerState<EmailOtpScreen> {
  static const codeLength = 6;
  static const codeLifetime = Duration(minutes: 3);
  static const resendCooldown = Duration(seconds: 60);

  final _code = TextEditingController();
  final _focus = FocusNode();
  Timer? _timer;
  DateTime _sentAt = DateTime.now();
  Duration _elapsed = Duration.zero;
  bool _busy = false;
  String? _error;

  bool get _expired => _elapsed >= codeLifetime;
  bool get _canResend => _elapsed >= resendCooldown;

  @override
  void initState() {
    super.initState();
    if (widget.alreadySent) {
      _startTimer();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resend(initial: true));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _sentAt = DateTime.now();
    _elapsed = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().difference(_sentAt));
      if (_expired) _timer?.cancel();
    });
  }

  Future<void> _resend({bool initial = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepoProvider).sendEmailCode(widget.email, widget.purpose);
      _code.clear();
      _startTimer();
      if (mounted && !initial) showSnack(context, context.tr('code_resent'));
      _focus.requestFocus();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy || _expired || _code.text.length != codeLength) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepoProvider).verifyEmailCode(widget.email, _code.text, widget.purpose);
      ref.invalidate(profileProvider);
      if (!mounted) return;
      if (widget.purpose == EmailCodePurpose.recovery) {
        context.go('/auth/new-password');
      } else {
        showSnack(context, context.tr(widget.purpose == EmailCodePurpose.signup ? 'email_verified_ok' : 'signed_in_ok'));
        context.go(widget.redirect ?? '/');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(context, e));
      _code.clear();
      _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(Duration d) => '${d.inMinutes.toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (widget.purpose) {
      EmailCodePurpose.signup => (context.tr('verify_email_title'), context.tr('verify_email_body')),
      EmailCodePurpose.login => (context.tr('email_code_login_title'), context.tr('email_code_login_body')),
      EmailCodePurpose.recovery => (context.tr('reset_code_title'), context.tr('reset_code_body')),
    };
    final remaining = codeLifetime - _elapsed;
    return Scaffold(
      appBar: AppBar(leading: const BackOrHomeButton(), title: Text(title)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 12, 24, 24), children: [
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: const Icon(Icons.mark_email_unread_outlined, size: 42, color: BrandColors.electric),
            ),
          ),
          const SizedBox(height: 20),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, height: 1.6)),
          const SizedBox(height: 6),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(widget.email, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          const SizedBox(height: 28),
          _CodeBoxes(
            controller: _code,
            focusNode: _focus,
            length: codeLength,
            enabled: !_busy && !_expired,
            hasError: _error != null,
            onChanged: (v) {
              if (_error != null) setState(() => _error = null);
              setState(() {});
              if (v.length == codeLength) _verify();
            },
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w600)),
          Center(
            child: _expired
                ? Text(context.tr('otp_expired'), style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w700))
                : Text(context.tr('otp_expires_in', {'time': _fmt(remaining)}), style: const TextStyle(color: BrandColors.gray)),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_busy || _expired || _code.text.length != codeLength) ? null : _verify,
            child: _busy
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Text(context.tr('verify')),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: (_busy || !(_canResend || _expired)) ? null : _resend,
            child: Text((_canResend || _expired)
                ? context.tr('resend_code')
                : context.tr('resend_in', {'s': (resendCooldown - _elapsed).inSeconds.clamp(0, 60).toString()})),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: BrandColors.offWhite, borderRadius: BorderRadius.circular(12), border: Border.all(color: BrandColors.border)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, size: 18, color: BrandColors.gray),
              const SizedBox(width: 8),
              Expanded(child: Text(context.tr('email_code_tip'), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5, height: 1.5))),
            ]),
          ),
          TextButton(
            onPressed: () => context.canPop() ? context.pop() : context.go('/auth/login'),
            child: Text(context.tr('wrong_email')),
          ),
        ]),
      ),
    );
  }
}

/// Six digit boxes backed by one invisible TextField, so paste and SMS/email autofill keep working.
class _CodeBoxes extends StatelessWidget {
  const _CodeBoxes({
    required this.controller,
    required this.focusNode,
    required this.length,
    required this.enabled,
    required this.hasError,
    required this.onChanged,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final int length;
  final bool enabled;
  final bool hasError;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = controller.text;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        height: 58,
        child: Stack(children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(length, (i) {
              final filled = i < text.length;
              final active = enabled && i == text.length.clamp(0, length - 1) && focusNode.hasFocus;
              final color = hasError ? BrandColors.error : (active ? BrandColors.electric : (filled ? BrandColors.navy : BrandColors.border));
              return Flexible(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  constraints: const BoxConstraints(maxWidth: 50),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color, width: active || hasError ? 2 : 1.4),
                  ),
                  child: Text(filled ? text[i] : '', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: BrandColors.navy)),
                ),
              );
            }),
          ),
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: enabled,
                autofocus: true,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                maxLength: length,
                showCursor: false,
                enableInteractiveSelection: true,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                decoration: const InputDecoration(counterText: '', border: InputBorder.none),
                onChanged: onChanged,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Set a new password after the reset code was verified (Supabase signs the user in for this step).
class NewPasswordScreen extends ConsumerStatefulWidget {
  const NewPasswordScreen({super.key});
  @override
  ConsumerState<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends ConsumerState<NewPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(authRepoProvider).updatePassword(_pw.text);
      if (!mounted) return;
      showSnack(context, context.tr('password_updated'));
      context.go('/');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.tr('new_password_title'))),
        body: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(24), children: [
            Text(context.tr('new_password_body'), style: const TextStyle(color: BrandColors.gray, height: 1.6)),
            const SizedBox(height: 20),
            TextFormField(
              controller: _pw,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: context.tr('new_password'),
                helperText: context.tr('password_rules'),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => passwordError(context, v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pw2,
              obscureText: _obscure,
              decoration: InputDecoration(labelText: context.tr('confirm_password'), prefixIcon: const Icon(Icons.lock_outline)),
              validator: (v) => v != _pw.text ? context.tr('passwords_mismatch') : null,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _save, child: Text(context.tr('save'))),
          ]),
        ),
      );
}

/// 8+ characters with at least one letter and one digit.
String? passwordError(BuildContext context, String? v) {
  if (v == null || v.length < 8 || !RegExp(r'[A-Za-z؀-ۿ]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) {
    return context.tr('password_rules');
  }
  return null;
}

/// Basic email shape check; the server is the real authority.
bool isValidEmail(String? v) => v != null && RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(v.trim());
