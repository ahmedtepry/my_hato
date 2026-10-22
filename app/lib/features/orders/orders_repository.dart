import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/supabase_providers.dart';

class OrdersRepository {
  OrdersRepository(this._db);
  final SupabaseClient _db;

  Future<List<Map<String, dynamic>>> branches() async =>
      List<Map<String, dynamic>>.from(await _db.from('branches').select().eq('is_active', true));

  Future<int> deliveryFee(String governorate, int subtotal) async =>
      (await _db.rpc('quote_delivery_fee', params: {'p_governorate': governorate, 'p_subtotal_minor': subtotal}) as num).toInt();

  /// One idempotency key per checkout attempt: retries after a network error
  /// return the same order instead of creating a duplicate.
  static String newIdempotencyKey() => const Uuid().v4();

  Future<Map<String, dynamic>> placeOrder({
    required String idempotencyKey,
    required String fulfillment,
    required String paymentMethod,
    String? branchId,
    String? addressId,
    String? notes,
  }) async {
    final res = await _db.rpc('place_order', params: {
      'p_idempotency_key': idempotencyKey,
      'p_fulfillment': fulfillment,
      'p_payment_method': paymentMethod,
      'p_branch_id': branchId,
      'p_address_id': addressId,
      'p_delivery_notes': notes,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  Future<List<Map<String, dynamic>>> myOrders() async => List<Map<String, dynamic>>.from(await _db
      .from('orders')
      .select('id, reference, status, total_minor, fulfillment, payment_status, created_at, order_items(name_ar, name_en, quantity)')
      .order('created_at', ascending: false)
      .limit(100));

  Future<Map<String, dynamic>> order(String id) async => await _db
      .from('orders')
      .select('*, order_items(*), order_status_history(*), branches(*)')
      .eq('id', id)
      .single();

  Future<void> cancel(String id) => _db.rpc('customer_cancel_order', params: {'p_order_id': id});
}

final ordersRepoProvider = Provider((ref) => OrdersRepository(ref.watch(supabaseProvider)));
final branchesProvider = FutureProvider((ref) => ref.watch(ordersRepoProvider).branches());
final myOrdersProvider = FutureProvider((ref) {
  ref.watch(currentUserProvider);
  return ref.watch(ordersRepoProvider).myOrders();
});
final orderProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, id) => ref.watch(ordersRepoProvider).order(id));
