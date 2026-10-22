import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

class ProfileRepository {
  ProfileRepository(this._db);
  final SupabaseClient _db;
  String get _uid => _db.auth.currentUser!.id;

  /// Only columns customers are granted UPDATE on (see migration 0006).
  Future<void> update({String? fullName, String? contactPhone, String? locale, bool? notifyOrders, bool? notifyRepairs, bool? notifyPromotions, String? avatarPath}) async {
    final data = <String, dynamic>{
      if (fullName != null) 'full_name': fullName.trim(),
      if (contactPhone != null) 'contact_phone': contactPhone.isEmpty ? null : contactPhone,
      if (locale != null) 'preferred_locale': locale,
      if (notifyOrders != null) 'notify_orders': notifyOrders,
      if (notifyRepairs != null) 'notify_repairs': notifyRepairs,
      if (notifyPromotions != null) 'notify_promotions': notifyPromotions,
      if (avatarPath != null) 'avatar_path': avatarPath,
    };
    if (data.isEmpty) return;
    await _db.from('profiles').update(data).eq('id', _uid);
  }

  Future<String> uploadAvatar(Uint8List bytes) async {
    final path = '$_uid/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _db.storage.from('avatars').uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    await update(avatarPath: path);
    return path;
  }

  Future<String?> avatarUrl(String? path) async =>
      path == null ? null : _db.storage.from('avatars').createSignedUrl(path, 3600);

  Future<List<Map<String, dynamic>>> addresses() async => List<Map<String, dynamic>>.from(
      await _db.from('customer_addresses').select().order('is_default', ascending: false).order('created_at'));

  Future<String> saveAddress(Map<String, dynamic> a, {String? id}) async {
    final data = {...a, 'user_id': _uid};
    if (data['is_default'] == true) {
      await _db.from('customer_addresses').update({'is_default': false}).eq('user_id', _uid).eq('is_default', true);
    }
    if (id == null) {
      final row = await _db.from('customer_addresses').insert(data).select('id').single();
      return row['id'] as String;
    }
    await _db.from('customer_addresses').update(data).eq('id', id);
    return id;
  }

  Future<void> deleteAddress(String id) => _db.from('customer_addresses').delete().eq('id', id);

  Future<void> requestDeletion() => _db.rpc('request_account_deletion');

  Future<void> sendSupport(String subject, String message, String? phone) =>
      _db.from('customer_support_requests').insert({'user_id': _uid, 'subject': subject, 'message': message, 'contact_phone': phone});
}

final profileRepoProvider = Provider((ref) => ProfileRepository(ref.watch(supabaseProvider)));
final addressesProvider = FutureProvider((ref) {
  ref.watch(currentUserProvider);
  return ref.watch(profileRepoProvider).addresses();
});

const egyptGovernorates = [
  'القاهرة', 'الجيزة', 'الإسكندرية', 'القليوبية', 'الشرقية', 'الدقهلية', 'الغربية', 'المنوفية', 'البحيرة', 'كفر الشيخ',
  'دمياط', 'بورسعيد', 'الإسماعيلية', 'السويس', 'الفيوم', 'بني سويف', 'المنيا', 'أسيوط', 'سوهاج', 'قنا', 'الأقصر',
  'أسوان', 'البحر الأحمر', 'الوادي الجديد', 'مطروح', 'شمال سيناء', 'جنوب سيناء',
];
