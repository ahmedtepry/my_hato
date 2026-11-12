// Server calls for the employee profile and the face (migrations 0177-0179). Prints never come back from the server.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import 'face_core.dart' show faceModelId;

class FaceRepository {
  FaceRepository(this._db);
  final SupabaseClient _db;

  static String vec(List<double> v) => '[${v.map((x) => x.toStringAsFixed(6)).join(',')}]';
  Map<String, dynamic> _m(Object? r) => r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};

  // ---- the member's own profile
  Future<Map<String, dynamic>> myProfile() async => _m(await _db.rpc('my_profile'));
  Future<void> setName(String name) => _db.rpc('my_name_set', params: {'p_name': name});
  Future<Map<String, dynamic>> setPin(String? oldPin, String newPin) async => _m(await _db.rpc('my_pin_set', params: {'p_old': oldPin, 'p_new': newPin}));
  Future<Map<String, dynamic>> enroll(List<List<double>> prints) async =>
      _m(await _db.rpc('my_face_enroll', params: {'p_prints': prints, 'p_model': faceModelId}));
  Future<void> clearMine() => _db.rpc('my_face_clear');

  // ---- recognition
  Future<Map<String, dynamic>> checkMe(List<double> print) async => _m(await _db.rpc('my_face_check', params: {'p_print': vec(print), 'p_model': faceModelId}));
  Future<Map<String, dynamic>> switchSeller(String shiftId, List<double> print) async =>
      _m(await _db.rpc('pos_switch_seller_face', params: {'p_shift': shiftId, 'p_print': vec(print), 'p_model': faceModelId}));

  // ---- owner
  Future<Map<String, dynamic>> overview() async => _m(await _db.rpc('staff_bio_overview'));
  Future<void> setSelfService(String userId, bool on) => _db.rpc('staff_self_service_set', params: {'p_user': userId, 'p_on': on});
  Future<void> clearFace(String userId) => _db.rpc('staff_face_clear', params: {'p_user': userId});
  Future<void> setStyle(String style) => _db.rpc('face_scan_style_set', params: {'p_style': style});
}

final faceRepoProvider = Provider((ref) => FaceRepository(ref.watch(supabaseProvider)));
final myProfileProvider = FutureProvider.autoDispose((ref) => ref.watch(faceRepoProvider).myProfile());
final bioOverviewProvider = FutureProvider.autoDispose((ref) => ref.watch(faceRepoProvider).overview());
