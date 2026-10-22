import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
import '../../core/supabase_providers.dart';

/// All authentication goes through Supabase Auth. OTP codes are generated,
/// delivered and verified server-side by Supabase + the configured SMS provider;
/// the app never generates, stores or validates a code locally.
class AuthRepository {
  AuthRepository(this._db);
  final SupabaseClient _db;
  GoTrueClient get _auth => _db.auth;

  Future<void> signInWithEmail(String email, String password) =>
      _auth.signInWithPassword(email: email.trim(), password: password);

  /// Returns true when the session is active immediately (email confirmation disabled).
  Future<bool> signUpWithEmail(String email, String password, String fullName) async {
    final res = await _auth.signUp(
      email: email.trim(),
      password: password,
      data: {'full_name': fullName.trim()},
      emailRedirectTo: AppConfig.oauthRedirect,
    );
    return res.session != null;
  }

  Future<void> resetPassword(String email) =>
      _auth.resetPasswordForEmail(email.trim(), redirectTo: AppConfig.oauthRedirect);

  Future<void> signInWithGoogle() => _auth.signInWithOAuth(OAuthProvider.google,
      redirectTo: AppConfig.oauthRedirect, authScreenLaunchMode: LaunchMode.externalApplication);

  Future<void> signInWithFacebook() => _auth.signInWithOAuth(OAuthProvider.facebook,
      redirectTo: AppConfig.oauthRedirect, authScreenLaunchMode: LaunchMode.externalApplication);

  /// Phone sign-in (new or existing account).
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
