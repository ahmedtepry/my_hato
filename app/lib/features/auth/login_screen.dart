import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/brand_logo.dart';
import '../../shared/states.dart';
import 'auth_repository.dart';

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

  Future<void> _run(Future<void> Function() action, {bool navigate = true}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && navigate) context.go(widget.redirect ?? '/');
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
                  decoration: InputDecoration(labelText: context.tr('email'), prefixIcon: const Icon(Icons.mail_outline)),
                  validator: (v) => (v == null || !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) ? context.tr('invalid') : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: context.tr('password'),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure)),
                  ),
                  validator: (v) => (v == null || v.length < 8) ? context.tr('invalid') : null,
                ),
              ]),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () {
                  if (_email.text.trim().isEmpty) return;
                  _run(() async {
                    await auth.resetPassword(_email.text);
                    if (mounted) showSnack(context, context.tr('reset_sent'));
                  }, navigate: false);
                },
                child: Text(context.tr('forgot_password')),
              ),
            ),
            FilledButton(
              onPressed: () {
                if (_form.currentState!.validate()) _run(() => auth.signInWithEmail(_email.text, _password.text));
              },
              child: _busy ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : Text(context.tr('login')),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Expanded(child: Divider()),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(context.tr('or'), style: const TextStyle(color: BrandColors.gray))),
              const Expanded(child: Divider()),
            ]),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.phone_iphone_rounded),
              label: Text(context.tr('continue_phone')),
              onPressed: () => context.push('/auth/phone?mode=signin&redirect=${Uri.encodeComponent(widget.redirect ?? '/')}'),
            ),
            const SizedBox(height: 12),
            // OAuth opens the system browser; the session arrives through the deep link and
            // the router redirects automatically once onAuthStateChange fires.
            OutlinedButton.icon(
              icon: const Text('G', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF4285F4))),
              label: Text(context.tr('continue_google')),
              onPressed: () => _run(auth.signInWithGoogle, navigate: false),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.facebook, color: Color(0xFF1877F2)),
              label: Text(context.tr('continue_facebook')),
              onPressed: () => _run(auth.signInWithFacebook, navigate: false),
            ),
            const SizedBox(height: 24),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(context.tr('no_account')),
              TextButton(onPressed: () => context.push('/auth/register'), child: Text(context.tr('register'))),
            ]),
          ]),
        ),
      ),
    );
  }
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final active = await ref.read(authRepoProvider).signUpWithEmail(_email.text, _password.text, _name.text);
      if (!mounted) return;
      if (active) {
        // next: verify phone number (required to place orders)
        context.go('/auth/phone?mode=verify&redirect=%2F');
      } else {
        showSnack(context, context.tr('check_email_confirm'));
        context.go('/auth/login');
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
        body: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(24), children: [
            TextFormField(
              controller: _name,
              decoration: InputDecoration(labelText: context.tr('full_name'), prefixIcon: const Icon(Icons.person_outline)),
              validator: (v) => (v == null || v.trim().length < 2) ? context.tr('required') : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(labelText: context.tr('email'), prefixIcon: const Icon(Icons.mail_outline)),
              validator: (v) => (v == null || !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) ? context.tr('invalid') : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(labelText: context.tr('password'), helperText: '8+', prefixIcon: const Icon(Icons.lock_outline)),
              validator: (v) => (v == null || v.length < 8) ? context.tr('invalid') : null,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _submit, child: Text(context.tr('register'))),
            const SizedBox(height: 12),
            TextButton(onPressed: () => context.go('/auth/login'), child: Text('${context.tr('have_account')} ${context.tr('login')}')),
          ]),
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
