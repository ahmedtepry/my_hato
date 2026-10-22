import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabaseProvider = Provider<SupabaseClient>((_) => Supabase.instance.client);

/// Emits on every auth change (sign in/out, token refresh, user update).
final authStateProvider = StreamProvider<AuthState>((ref) => ref.watch(supabaseProvider).auth.onAuthStateChange);

final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser;
});

String publicImageUrl(SupabaseClient c, String? path, {String bucket = 'product-images', int? width}) {
  if (path == null || path.isEmpty) return '';
  if (path.startsWith('http')) return path;
  return c.storage.from(bucket).getPublicUrl(
        path,
        transform: width == null ? null : TransformOptions(width: width, quality: 75),
      );
}
