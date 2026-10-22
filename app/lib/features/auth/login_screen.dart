import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/brand_logo.dart';
import '../../shared/states.dart';
import '../../shared/support_contact.dart';
import 'auth_repository.dart';
import 'email_otp_screen.dart' show isValidEmail, passwordError;

/// Sign in with email, mobile number or username + password.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.redirect});
  final String? redirect;
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _redirect => widget.redirect ?? '/';

  Future<void> _signIn() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await ref.read(authRepoProvider).signInWithIdentifier(_id.text, _password.text);
      if (mounted) context.go(_redirect);
    } on AuthException catch (e) {
      if (!mounted) return;
      if (isEmailNotConfirmed(e)) {
        // no verification codes: support activates the account
        showSupportSheet(context,
            title: context.tr('account_pending_title'), body: context.tr('account_pending_body'), whatsappMessage: context.tr('account_pending_wa'));
      } else {
        showSnack(context, friendlyError(context, e), error: true);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    controller: _id,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username, AutofillHints.email],
                    textDirection: TextDirection.ltr,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: context.tr('login_identifier'),
                      helperText: context.tr('login_identifier_help'),
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                    validator: (v) => (v == null || v.trim().length < 3) ? context.tr('required') : null,
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
                child: TextButton(
                  onPressed: () => showSupportSheet(
                    context,
                    title: context.tr('forgot_password_title'),
                    body: context.tr('forgot_password_body'),
                    whatsappMessage: context.tr('forgot_password_wa'),
                  ),
                  child: Text(context.tr('forgot_password')),
                ),
              ),
              FilledButton(
                onPressed: _signIn,
                child: _busy
                    ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : Text(context.tr('login')),
              ),
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

/// New account: name, username, email, mobile number and password; the email is then verified by code.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.redirect});
  final String? redirect;
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  bool _accepted = false;
  String? _usernameError;
  String? _phoneError;

  @override
  void dispose() {
    for (final c in [_name, _username, _email, _phone, _password, _password2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    _usernameError = null;
    _phoneError = null;
    if (!_form.currentState!.validate()) return;
    if (!_accepted) {
      showSnack(context, context.tr('accept_terms_required'), error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final redirect = widget.redirect ?? '/';
    final repo = ref.read(authRepoProvider);
    try {
      final check = await repo.checkSignup(_username.text, _phone.text);
      if (!mounted) return;
      if (!check.usernameAvailable || !check.phoneAvailable) {
        setState(() {
          if (!check.usernameAvailable) _usernameError = context.tr(check.usernameValid ? 'err_username_taken' : 'username_rules');
          if (!check.phoneAvailable) _phoneError = context.tr(check.phoneValid ? 'err_phone_taken' : 'invalid_phone');
        });
        _form.currentState!.validate();
        return;
      }
      final result = await repo.signUpWithEmail(_email.text, _password.text, _name.text, username: _username.text, phone: check.phone);
      if (!mounted) return;
      switch (result) {
        case SignUpResult.signedIn:
          context.go(redirect);
        case SignUpResult.codeSent:
          // account created but the project still requires confirmation: support activates it
          context.go('/auth/login');
          showSupportSheet(context,
              title: context.tr('account_pending_title'), body: context.tr('account_pending_body'), whatsappMessage: context.tr('account_pending_wa'));
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
                  decoration: InputDecoration(labelText: context.tr('full_name'), prefixIcon: const Icon(Icons.badge_outlined)),
                  validator: (v) => (v == null || v.trim().length < 2) ? context.tr('required') : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _username,
                  autofillHints: const [AutofillHints.newUsername],
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  onChanged: (_) => _usernameError == null ? null : setState(() => _usernameError = null),
                  decoration: InputDecoration(
                    labelText: context.tr('username'),
                    helperText: context.tr('username_rules'),
                    prefixIcon: const Icon(Icons.alternate_email),
                  ),
                  // server-side result (taken) wins over the local format check
                  validator: (v) => _usernameError ?? (isValidUsername(v) ? null : context.tr('username_rules')),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: context.tr('email'), prefixIcon: const Icon(Icons.mail_outline)),
                  validator: (v) => isValidEmail(v) ? null : context.tr('invalid_email'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => _phoneError == null ? null : setState(() => _phoneError = null),
                  decoration: InputDecoration(
                    labelText: context.tr('phone'),
                    hintText: '01XXXXXXXXX',
                    prefixIcon: const Icon(Icons.phone_iphone_rounded),
                  ),
                  validator: (v) => _phoneError ?? (normalizeEgyptMobile(v ?? '') == null ? context.tr('invalid_phone') : null),
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
