import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
import '../../core/errors.dart' show isEmailNotConfirmed;
import '../../core/supabase_providers.dart';

/// Why a 6-digit email code was sent. Each purpose maps to the Supabase Auth OTP type that
/// verifies it, and to the email template that carries the code ({{ .Token }}).
enum EmailCodePurpose {
  /// New account: "Confirm signup" email. Verifying confirms the email and signs the user in.
  signup,

  /// Passwordless sign-in for an existing account: "Magic link" email.
  login,

  /// Forgot password: "Reset password" email. Verifying signs in for the password change only.
  recovery;

  static EmailCodePurpose parse(String? v) =>
      EmailCodePurpose.values.firstWhere((p) => p.name == v, orElse: () => EmailCodePurpose.signup);

  OtpType get otpType => switch (this) {
        EmailCodePurpose.signup => OtpType.signup,
        EmailCodePurpose.login => OtpType.email,
        EmailCodePurpose.recovery => OtpType.recovery,
      };
}

class SignupCheck {
  const SignupCheck({required this.usernameValid, required this.usernameAvailable, required this.phoneValid, required this.phoneAvailable, this.phone});
  final bool usernameValid, usernameAvailable, phoneValid, phoneAvailable;
  final String? phone;
}

/// Result of a sign-up attempt.
enum SignUpResult { signedIn, codeSent, alreadyRegistered }

/// All authentication goes through Supabase Auth. Codes (email and SMS) are generated, delivered,
/// rate-limited, expired and verified server-side by Supabase Auth; the app never generates,
/// stores or checks a code itself.
class AuthRepository {
  AuthRepository(this._db);
  final SupabaseClient _db;
  GoTrueClient get _auth => _db.auth;

  static String normalizeEmail(String email) => email.trim().toLowerCase();

  /// Signs in. A brand-new account that Auth has not confirmed yet is opened first (account-open
  /// checks the password server side), so customers never wait to get in; ordering stays locked
  /// until the team approves the account.
  Future<void> signInWithEmail(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: normalizeEmail(email), password: password);
    } on AuthException catch (e) {
      if (!isEmailNotConfirmed(e) || !await openAccount(email, password)) rethrow;
      await _auth.signInWithPassword(email: normalizeEmail(email), password: password);
    }
  }

  /// true when the server unlocked sign-in for this (correct) email/identifier + password.
  Future<bool> openAccount(String identifier, String password) async {
    try {
      final res = await _db.functions.invoke('account-open', body: {'identifier': identifier.trim(), 'password': password});
      return res.data is Map && (res.data as Map)['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Sign in with email, mobile number or username + password. For a mobile number or username the
  /// database checks the password and returns the account email only when it is correct
  /// (login_email_for); the session itself always comes from Supabase Auth. Returns the email used.
  Future<String> signInWithIdentifier(String identifier, String password) async {
    final id = identifier.trim();
    if (id.contains('@')) {
      await signInWithEmail(id, password);
      return normalizeEmail(id);
    }
    final email = await _db.rpc('login_email_for', params: {'p_identifier': id, 'p_password': password}) as String?;
    if (email == null) throw const AuthException('Invalid login credentials', code: 'invalid_credentials');
    await signInWithEmail(email, password);
    return normalizeEmail(email);
  }

  /// Username / mobile availability before creating the account.
  Future<SignupCheck> checkSignup(String username, String phone) async {
    final r = Map<String, dynamic>.from(await _db.rpc('signup_check', params: {'p_username': username, 'p_phone': phone}) as Map);
    return SignupCheck(
      usernameValid: r['username_valid'] == true,
      usernameAvailable: r['username_available'] == true,
      phoneValid: r['phone_valid'] == true,
      phoneAvailable: r['phone_available'] == true,
      phone: r['phone'] as String?,
    );
  }

  /// Changes (or adds) the account email. The current password proves the owner; accounts that
  /// have no email yet add one without it. Throws the function's error code as an Exception message.
  Future<void> changeEmail(String newEmail, String? password) async {
    try {
      await _db.functions.invoke('account-change-email', body: {'new_email': newEmail.trim().toLowerCase(), 'password': password ?? ''});
    } on FunctionException catch (e) {
      final d = e.details;
      throw Exception(d is Map ? '${d['error']}' : 'FAILED');
    }
    await _auth.refreshSession();
  }

  /// Creates the account server side (account-signup), already confirmed, then signs in. No email is sent.
  Future<SignUpResult> signUpWithEmail(String email, String password, String fullName, {String? username, String? phone}) async {
    // The account is created server side already confirmed (no confirmation email: the built-in
    // mailer is limited to a few emails per hour and blocked real sign-ups).
    try {
      await _db.functions.invoke('account-signup', body: {
        'email': normalizeEmail(email),
        'password': password,
        'full_name': fullName.trim(),
        if (username != null) 'username': username.trim().toLowerCase(),
        if (phone != null) 'phone': phone,
      });
    } on FunctionException catch (e) {
      final d = e.details;
      final code = d is Map ? '${d['error']}' : '';
      if (code == 'ALREADY_REGISTERED') return SignUpResult.alreadyRegistered;
      if (code == 'invalid_password') throw const AuthException('weak_password', code: 'weak_password');
      rethrow;
    }
    // No verification codes: accounts are confirmed on creation (Supabase "Confirm email" off).
    // If the project still asks for confirmation, try signing in; otherwise support activates it.
    try {
      await signInWithEmail(email, password);
      return SignUpResult.signedIn;
    } on AuthException {
      return SignUpResult.codeSent;
    }
  }

  /// Sends (or re-sends) the code for [purpose]. Each new code invalidates the previous one.
  Future<void> sendEmailCode(String email, EmailCodePurpose purpose) {
    final e = normalizeEmail(email);
    return switch (purpose) {
      EmailCodePurpose.signup => _auth.resend(type: OtpType.signup, email: e, emailRedirectTo: AppConfig.oauthRedirect),
      // shouldCreateUser: false -> a code never creates an account; sign-up always goes through the form
      EmailCodePurpose.login => _auth.signInWithOtp(email: e, shouldCreateUser: false, emailRedirectTo: AppConfig.oauthRedirect),
      EmailCodePurpose.recovery => _auth.resetPasswordForEmail(e, redirectTo: AppConfig.oauthRedirect),
    };
  }

  /// Verifies a 6-digit email code. On success Supabase returns a session; for [EmailCodePurpose.signup]
  /// it also sets auth.users.email_confirmed_at, which marks the profile as verified (migration 0013).
  Future<void> verifyEmailCode(String email, String code, EmailCodePurpose purpose) async {
    final res = await _auth.verifyOTP(type: purpose.otpType, email: normalizeEmail(email), token: code.trim());
    if (res.session == null) throw const AuthException('otp_expired', code: 'otp_expired');
  }

  Future<void> updatePassword(String password) => _auth.updateUser(UserAttributes(password: password));

  Future<void> signInWithGoogle() => _auth.signInWithOAuth(OAuthProvider.google,
      redirectTo: AppConfig.oauthRedirect, authScreenLaunchMode: LaunchMode.externalApplication);

  Future<void> signInWithFacebook() => _auth.signInWithOAuth(OAuthProvider.facebook,
      redirectTo: AppConfig.oauthRedirect, authScreenLaunchMode: LaunchMode.externalApplication);

  /// Phone sign-in (new or existing account). Needs an SMS provider in Supabase Auth.
  Future<void> sendPhoneOtp(String e164) => _auth.signInWithOtp(phone: e164);

  Future<void> verifyPhoneOtp(String e164, String code) =>
      _auth.verifyOTP(type: OtpType.sms, phone: e164, token: code);

  /// For users signed in with email/Google/Facebook: attach & verify a phone.
  /// Supabase links it to the SAME identity only after the code is verified.
  Future<void> startPhoneChange(String e164) => _auth.updateUser(UserAttributes(phone: e164));

  Future<void> verifyPhoneChange(String e164, String code) =>
      _auth.verifyOTP(type: OtpType.phoneChange, phone: e164, token: code);

  Future<void> signOut() => _auth.signOut();
}

final authRepoProvider = Provider((ref) => AuthRepository(ref.watch(supabaseProvider)));

final profileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  return ref.watch(supabaseProvider).from('profiles').select().eq('id', user.id).maybeSingle();
});

/// Verified = email confirmed with a code (or by Google/Facebook) OR phone confirmed by SMS.
bool isAccountVerified(Map<String, dynamic>? profile) =>
    profile?['email_verified'] == true || profile?['phone_verified'] == true;

/// Phone we can reach the customer on: verified phone first, then the contact phone they entered.
String? reachablePhone(Map<String, dynamic>? profile) {
  if (profile == null) return null;
  if (profile['phone_verified'] == true && (profile['phone'] as String?)?.isNotEmpty == true) return profile['phone'] as String;
  final c = profile['contact_phone'] as String?;
  return (c != null && c.isNotEmpty) ? c : null;
}

/// Egyptian mobile in E.164 (+201XXXXXXXXX) from 01XXXXXXXXX / 201XXXXXXXXX / +201XXXXXXXXX; null if invalid.
String? normalizeEgyptMobile(String input) {
  // Arabic-Indic digits typed on Arabic keyboards -> ASCII, then keep digits and '+'
  const ar = '٠١٢٣٤٥٦٧٨٩';
  var d = input;
  for (var i = 0; i < 10; i++) {
    d = d.replaceAll(ar[i], '$i');
  }
  d = d.replaceAll(RegExp(r'[^0-9+]'), '');
  if (d.startsWith('+')) d = d.substring(1);
  if (d.startsWith('0020')) d = d.substring(2);
  if (d.startsWith('01') && d.length == 11) d = '2$d';
  return RegExp(r'^201[0125]\d{8}$').hasMatch(d) ? '+$d' : null;
}

/// Sign-in methods switched on in Supabase Auth (public `/auth/v1/settings`). The login screen only
/// shows buttons for enabled methods, so customers never land on a "provider is not enabled" page.
/// Enabling Google/Facebook/phone in the Supabase dashboard makes the button appear without an update.
class AuthProviders {
  const AuthProviders({this.google = false, this.facebook = false, this.phone = false});
  final bool google, facebook, phone;
}

final authProvidersProvider = FutureProvider<AuthProviders>((ref) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse('${AppConfig.supabaseUrl}/auth/v1/settings'));
    req.headers.set('apikey', AppConfig.supabaseAnonKey);
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const AuthProviders();
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final ext = (body['external'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AuthProviders(google: ext['google'] == true, facebook: ext['facebook'] == true, phone: ext['phone'] == true);
  } catch (_) {
    return const AuthProviders(); // offline / unknown: show email sign-in only
  } finally {
    client.close(force: true);
  }
});

/// The signed-in customer's register row (customer ID, username, phone).
final customerProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  return ref.watch(supabaseProvider).from('customers').select('customer_code, username, phone, email').eq('user_id', user.id).maybeSingle();
});

/// 3–20 characters: English lowercase letters, digits, _ and .
bool isValidUsername(String? v) => v != null && RegExp(r'^[a-z0-9_.]{3,20}$').hasMatch(v.trim().toLowerCase());
