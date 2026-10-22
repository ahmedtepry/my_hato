import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/brand_logo.dart';
import '../../shared/states.dart';
import 'auth_repository.dart';
import 'email_otp_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.redirect});
  final String? redirect;
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _redirect => widget.redirect ?? '/';

  void _goToCode(EmailCodePurpose purpose, {bool alreadySent = true}) {
    final q = Uri(queryParameters: {
      'email': AuthRepository.normalizeEmail(_email.text),
      'purpose': purpose.name,
      if (!alreadySent) 'send': '1',
      'redirect': _redirect,
    }).query;
    context.push('/auth/verify-email?$q');
  }

  /// Email must be typed first for code sign-in and password reset.
  bool _requireEmail() {
    if (isValidEmail(_email.text)) return true;
    showSnack(context, context.tr('enter_email_first'), error: true);
    return false;
  }

  Future<void> _signIn() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(authRepoProvider).signInWithEmail(_email.text, _password.text);
      if (mounted) context.go(_redirect);
    } on AuthException catch (e) {
      if (!mounted) return;
      if (isEmailNotConfirmed(e)) {
        // account exists but the email was never confirmed: send a fresh code and ask for it
        showSnack(context, context.tr('email_not_confirmed'));
        _goToCode(EmailCodePurpose.signup, alreadySent: false);
      } else {
        showSnack(context, friendlyError(context, e), error: true);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode(EmailCodePurpose purpose) async {
    if (!_requireEmail()) return;
    setState(() => _busy = true);
    try {
      await ref.read(authRepoProvider).sendEmailCode(_email.text, purpose);
      if (mounted) _goToCode(purpose);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _oauth(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.read(authRepoProvider);
    return Scaffold(
      appBar: AppBar(leading: CloseButton(onPressed: () => context.canPop() ? context.pop() : context.go('/'))),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: AutofillGroup(
            child: ListView(padding: const EdgeInsets.all(24), children: [
              const Center(child: BrandWordmark(size: 30, showSlogan: true)),
              const SizedBox(height: 32),
              Text(context.tr('login'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              Form(
                key: _form,
                child: Column(children: [
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textDirection: TextDirection.ltr,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(labelText: context.tr('email'), prefixIcon: const Icon(Icons.mail_outline)),
                    validator: (v) => isValidEmail(v) ? null : context.tr('invalid_email'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _signIn(),
                    decoration: InputDecoration(
                      labelText: context.tr('password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure)),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? context.tr('required') : null,
                  ),
                ]),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(onPressed: () => _sendCode(EmailCodePurpose.recovery), child: Text(context.tr('forgot_password'))),
              ),
              FilledButton(
                onPressed: _signIn,
                child: _busy
                    ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : Text(context.tr('login')),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.pin_outlined),
                label: Text(context.tr('login_with_email_code')),
                onPressed: () => _sendCode(EmailCodePurpose.login),
              ),
              Builder(builder: (context) {
                final providers = ref.watch(authProvidersProvider).valueOrNull ?? const AuthProviders();
                if (!providers.google && !providers.facebook && !providers.phone) return const SizedBox.shrink();
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const SizedBox(height: 20),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(context.tr('or'), style: const TextStyle(color: BrandColors.gray))),
                    const Expanded(child: Divider()),
                  ]),
                  // OAuth opens the system browser; the session arrives through the deep link and
                  // the router redirects automatically once onAuthStateChange fires.
                  if (providers.google) ...[
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      icon: const Text('G', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF4285F4))),
                      label: Text(context.tr('continue_google')),
                      onPressed: () => _oauth(auth.signInWithGoogle),
                    ),
                  ],
                  if (providers.facebook) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.facebook, color: Color(0xFF1877F2)),
                      label: Text(context.tr('continue_facebook')),
                      onPressed: () => _oauth(auth.signInWithFacebook),
                    ),
                  ],
                  if (providers.phone) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.phone_iphone_rounded),
                      label: Text(context.tr('continue_phone')),
                      onPressed: () => context.push('/auth/phone?mode=signin&redirect=${Uri.encodeComponent(_redirect)}'),
                    ),
                  ],
                ]);
              }),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(context.tr('no_account')),
                TextButton(onPressed: () => context.push('/auth/register?redirect=${Uri.encodeComponent(_redirect)}'), child: Text(context.tr('register'))),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.redirect});
  final String? redirect;
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  bool _accepted = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _password2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_accepted) {
      showSnack(context, context.tr('accept_terms_required'), error: true);
      return;
    }
    setState(() => _busy = true);
    final redirect = widget.redirect ?? '/';
    try {
      final result = await ref.read(authRepoProvider).signUpWithEmail(_email.text, _password.text, _name.text);
      if (!mounted) return;
      switch (result) {
        case SignUpResult.signedIn:
          context.go(redirect);
        case SignUpResult.codeSent:
          final q = Uri(queryParameters: {
            'email': AuthRepository.normalizeEmail(_email.text),
            'purpose': EmailCodePurpose.signup.name,
            'redirect': redirect,
          }).query;
          context.go('/auth/verify-email?$q');
        case SignUpResult.alreadyRegistered:
          showSnack(context, context.tr('email_already_registered'), error: true);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.tr('register'))),
        body: AbsorbPointer(
          absorbing: _busy,
          child: Form(
            key: _form,
            child: AutofillGroup(
              child: ListView(padding: const EdgeInsets.all(24), children: [
                Text(context.tr('register_intro'), style: const TextStyle(color: BrandColors.gray, height: 1.6)),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _name,
                  autofillHints: const [AutofillHints.name],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(labelText: context.tr('full_name'), prefixIcon: const Icon(Icons.person_outline)),
                  validator: (v) => (v == null || v.trim().length < 2) ? context.tr('required') : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(labelText: context.tr('email'), prefixIcon: const Icon(Icons.mail_outline)),
                  validator: (v) => isValidEmail(v) ? null : context.tr('invalid_email'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: context.tr('password'),
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
                  controller: _password2,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(labelText: context.tr('confirm_password'), prefixIcon: const Icon(Icons.lock_outline)),
                  validator: (v) => v != _password.text ? context.tr('passwords_mismatch') : null,
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: _accepted,
                  onChanged: (v) => setState(() => _accepted = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(context.tr('accept_terms'), style: const TextStyle(fontSize: 13)),
                  secondary: TextButton(onPressed: () => context.push('/account/legal'), child: Text(context.tr('read'))),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _submit,
                  child: _busy
                      ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                      : Text(context.tr('register')),
                ),
                const SizedBox(height: 12),
                TextButton(onPressed: () => context.go('/auth/login'), child: Text('${context.tr('have_account')} ${context.tr('login')}')),
              ]),
            ),
          ),
        ),
      );
}

class SessionExpiredScreen extends StatelessWidget {
  const SessionExpiredScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: EmptyState(
          icon: Icons.lock_clock_outlined,
          title: context.tr('session_expired'),
          body: context.tr('session_expired_body'),
          action: context.tr('login'),
          onAction: () => context.go('/auth/login'),
        ),
      );
}
