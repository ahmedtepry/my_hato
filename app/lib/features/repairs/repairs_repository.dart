import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
import '../../core/supabase_providers.dart';

class RepairsRepository {
  RepairsRepository(this._db);
  final SupabaseClient _db;

  // internal_notes is never selected (and customers have no column privilege for it).
  static const _cols = 'id, reference, status, device_brand, device_model, imei_or_serial, problem_description, '
      'contact_name, contact_phone, pickup_address, branch_id, preferred_pickup_at, callback_requested, scheduled_pickup_at, '
      'received_at, diagnosis, customer_notes, estimated_cost_minor, approved_cost_minor, expected_completion_at, '
      'warranty_terms, cancel_reason, created_at, updated_at';

  Future<Map<String, dynamic>> submit({
    required String idempotencyKey,
    required String brand,
    required String model,
    String? imei,
    required String problem,
    required String contactName,
    required String contactPhone,
    String? pickupAddressId,
    String? branchId,
    DateTime? preferredPickupAt,
    bool callback = false,
  }) async {
    final res = await _db.rpc('request_repair', params: {
      'p_idempotency_key': idempotencyKey,
      'p_device_brand': brand,
      'p_device_model': model,
      'p_imei_or_serial': (imei == null || imei.trim().isEmpty) ? null : imei.trim(),
      'p_problem': problem,
      'p_contact_name': contactName,
      'p_contact_phone': contactPhone,
      'p_pickup_address_id': pickupAddressId,
      'p_branch_id': branchId,
      'p_preferred_pickup_at': preferredPickupAt?.toUtc().toIso8601String(),
      'p_callback_requested': callback,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  /// Uploads to the PRIVATE bucket: repair-photos/{uid}/{repairId}/{n}.jpg
  Future<void> uploadPhoto(String repairId, Uint8List bytes, String ext, int index) async {
    final uid = _db.auth.currentUser!.id;
    final safeExt = {'jpg', 'jpeg', 'png', 'webp', 'heic'}.contains(ext.toLowerCase()) ? ext.toLowerCase() : 'jpg';
    final path = '$uid/$repairId/${DateTime.now().millisecondsSinceEpoch}_$index.$safeExt';
    await _db.storage.from('repair-photos').uploadBinary(path, bytes,
        fileOptions: FileOptions(contentType: safeExt == 'jpg' ? 'image/jpeg' : 'image/$safeExt', upsert: false));
    await _db.rpc('add_repair_attachment', params: {'p_repair_id': repairId, 'p_storage_path': path});
  }

  Future<List<Map<String, dynamic>>> myRepairs() async => List<Map<String, dynamic>>.from(
      await _db.from('repair_requests').select(_cols).order('created_at', ascending: false).limit(100));

  Future<Map<String, dynamic>> repair(String id) async {
    final r = Map<String, dynamic>.from(await _db.from('repair_requests').select(_cols).eq('id', id).single());
    final results = await Future.wait([
      _db.from('repair_status_history').select().eq('repair_id', id).order('created_at'),
      _db.from('repair_quotes').select().eq('repair_id', id).order('created_at', ascending: false),
      _db.from('repair_attachments').select().eq('repair_id', id).eq('is_internal', false),
    ]);
    r['history'] = results[0];
    r['quotes'] = results[1];
    final photos = <String>[];
    for (final a in results[2]) {
      photos.add(await _db.storage.from('repair-photos').createSignedUrl(a['storage_path'] as String, 300));
    }
    r['photo_urls'] = photos;
    return r;
  }

  Future<void> respondToQuote(String quoteId, bool approve) =>
      _db.rpc('customer_respond_to_quote', params: {'p_quote_id': quoteId, 'p_decision': approve ? 'approved' : 'rejected'});

  Future<List<Map<String, dynamic>>> statusLabels() async =>
      List<Map<String, dynamic>>.from(await _db.from('repair_status_labels').select().order('sort_order'));

  // ---- tracking without an account: repair number + the mobile number on the request ----
  /// Returns the public status view, or null when the pair does not match (same answer for an
  /// unknown repair number). Throws 'RATE_LIMITED' / 'INVALID_INPUT'.
  Future<Map<String, dynamic>?> guestLookup(String reference, String phone) async {
    final r = Map<String, dynamic>.from(
        await _db.rpc('guest_repair_lookup', params: {'p_reference': reference, 'p_phone': phone}) as Map);
    if (r['error'] != null) throw r['error'] as String;
    return r['found'] == true ? Map<String, dynamic>.from(r['repair'] as Map) : null;
  }
}

final repairsRepoProvider = Provider((ref) => RepairsRepository(ref.watch(supabaseProvider)));
final myRepairsProvider = FutureProvider((ref) {
  ref.watch(currentUserProvider);
  return ref.watch(repairsRepoProvider).myRepairs();
});
final repairProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, id) => ref.watch(repairsRepoProvider).repair(id));
final repairLabelsProvider = FutureProvider((ref) async {
  final rows = await ref.watch(repairsRepoProvider).statusLabels();
  return {for (final r in rows) r['status'] as String: r};
});
