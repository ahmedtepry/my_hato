import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

/// Online payments (Paymob, Egypt). The app never sees card numbers: Paymob's
/// Unified Checkout page collects them, and our server stores only Paymob's references.
/// The app NEVER decides that a payment succeeded — it waits for the server
/// (HMAC-verified Paymob callback) to update public.payments.
class CheckoutSession {
  CheckoutSession.fromJson(Map<String, dynamic> j)
      : paymentId = j['payment_id'] as String,
        checkoutUrl = j['checkout_url'] as String;
  final String paymentId, checkoutUrl;
}

class PaymentsRepository {
  PaymentsRepository(this._db);
  final SupabaseClient _db;

  Future<CheckoutSession> createIntent(String orderId, {required bool saveCard}) async {
    final res = await _db.functions.invoke('payments-create-intent', body: {'order_id': orderId, 'save_card': saveCard});
    return CheckoutSession.fromJson(Map<String, dynamic>.from(res.data as Map));
  }

  Future<List<Map<String, dynamic>>> savedCards() async => List<Map<String, dynamic>>.from(await _db
      .from('payment_methods')
      .select('id, brand, card_subtype, last4, expiry_month, expiry_year, wallet, is_default, created_at')
      .order('is_default', ascending: false)
      .order('created_at', ascending: false));

  Future<void> removeCard(String id) => _db.functions.invoke('payments-methods', body: {'action': 'remove', 'method_id': id});
  Future<void> setDefaultCard(String id) => _db.functions.invoke('payments-methods', body: {'action': 'set_default', 'method_id': id});

  Future<List<Map<String, dynamic>>> myPayments() async => List<Map<String, dynamic>>.from(await _db
      .from('payments')
      .select('id, order_id, amount_minor, currency, status, payment_method_type, card_brand, card_last4, refunded_minor, created_at, orders(reference)')
      .order('created_at', ascending: false)
      .limit(100));

  Future<Map<String, dynamic>> payment(String id) async => await _db
      .from('payments')
      .select('id, order_id, amount_minor, currency, status, payment_method_type, card_brand, card_last4, refunded_minor, '
          'provider_transaction_id, created_at, updated_at, orders(reference, total_minor, status)')
      .eq('id', id)
      .single();

  /// Emits the payment row whenever the server changes it (realtime + polling fallback).
  Stream<Map<String, dynamic>> watch(String paymentId) {
    final controller = StreamController<Map<String, dynamic>>();
    Timer? poll;
    Future<void> load() async {
      try {
        controller.add(await payment(paymentId));
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    final channel = _db
        .channel('payment:$paymentId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'payments',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: paymentId),
          callback: (_) => load(),
        )
        .subscribe();
    load();
    poll = Timer.periodic(const Duration(seconds: 4), (_) => load());
    controller.onCancel = () {
      poll?.cancel();
      _db.removeChannel(channel);
    };
    return controller.stream;
  }
}

final paymentsRepoProvider = Provider((ref) => PaymentsRepository(ref.watch(supabaseProvider)));
final savedCardsProvider = FutureProvider((ref) {
  ref.watch(currentUserProvider);
  return ref.watch(paymentsRepoProvider).savedCards();
});
final myPaymentsProvider = FutureProvider((ref) {
  ref.watch(currentUserProvider);
  return ref.watch(paymentsRepoProvider).myPayments();
});
final paymentProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, id) => ref.watch(paymentsRepoProvider).payment(id));
final paymentWatchProvider =
    StreamProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) => ref.watch(paymentsRepoProvider).watch(id));

/// Online payments are offered only when the owner enabled them after Paymob verification.
final onlinePaymentsEnabledProvider = FutureProvider<bool>((ref) async {
  final rows = await ref.watch(supabaseProvider).from('application_settings').select('value').eq('key', 'enabled_payment_methods');
  if (rows.isEmpty) return false;
  final v = rows.first['value'];
  return v is List && v.contains('online');
});
