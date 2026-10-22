import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
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

  Future<void> signInWithEmail(String email, String password) =>
      _auth.signInWithPassword(email: normalizeEmail(email), password: password);

  /// Creates the account. With "Confirm email" on (production), Supabase emails a 6-digit code and
  /// no session exists until it is verified. Supabase does not reveal whether an email is already
  /// registered: for a confirmed address it returns a user with no identities and sends nothing.
  Future<SignUpResult> signUpWithEmail(String email, String password, String fullName) async {
    final res = await _auth.signUp(
      email: normalizeEmail(email),
      password: password,
      data: {'full_name': fullName.trim()},
      emailRedirectTo: AppConfig.oauthRedirect,
    );
    if (res.session != null) return SignUpResult.signedIn;
    if (res.user != null && (res.user!.identities?.isEmpty ?? false)) return SignUpResult.alreadyRegistered;
    return SignUpResult.codeSent;
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
