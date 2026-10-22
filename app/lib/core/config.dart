/// Build-time configuration. Supply with:
///   flutter build apk --release \
///     --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=<publishable anon key>
///
/// Only the publishable (anon) key belongs in the app. It is safe because every
/// table is protected by Row Level Security. NEVER put the service_role key here.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const oauthRedirect = 'com.myhato.app://login-callback';
  static const guestLookupFunction = 'secure-guest-repair-lookup';
  static const supportPhone = String.fromEnvironment('SUPPORT_PHONE', defaultValue: '+201118819464');
  static const supportWhatsapp = String.fromEnvironment('SUPPORT_WHATSAPP', defaultValue: '201118819464');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
