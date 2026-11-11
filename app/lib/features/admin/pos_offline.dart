import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/l10n.dart' show sharedPrefsProvider;
import 'pos_repository.dart';

// =====================================================================================================================
// Selling without internet.
// When the server cannot be reached, the invoice is kept on this computer (with its idempotency key, real time, seller
// and a ready 8-digit number) and the till goes on selling. A background loop sends the waiting invoices as soon as the
// connection is back. The same key is used every time, so an invoice can never be recorded twice, even if a send
// reached the server before the line dropped.
// =====================================================================================================================

/// True when an error means "the server was not reached / did not answer" (not a refusal from the server).
bool posIsNetworkError(Object e) => e is! PostgrestException;

/// A random 8-digit invoice number for an offline receipt (the server keeps it if it is still free).
String posOfflineNumber() {
  final r = Random.secure();
  return '${10000000 + r.nextInt(90000000)}';
}

class PosOfflineQueue extends Notifier<List<Map<String, dynamic>>> {
  static const _key = 'pos_offline_queue_v1';
  Timer? _timer;
  bool _syncing = false;

  @override
  List<Map<String, dynamic>> build() {
    ref.onDispose(() => _timer?.cancel());
    final list = _read();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => sync());
    if (list.isNotEmpty) Future.microtask(sync);
    return list;
  }

  List<Map<String, dynamic>> _read() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(_key);
      if (raw == null) return [];
      return [for (final e in (jsonDecode(raw) as List)) Map<String, dynamic>.from(e as Map)];
    } catch (_) {
      return [];
    }
  }

  void _write(List<Map<String, dynamic>> list) {
    state = list;
    try {
      ref.read(sharedPrefsProvider).setString(_key, jsonEncode(list));
    } catch (_) {}
  }

  int pendingFor(String shiftId) => state.where((e) => e['shift_id'] == shiftId).length;

  /// Keeps an invoice on this computer and tries to send it right away.
  void add(Map<String, dynamic> sale) {
    if (state.any((e) => e['key'] == sale['key'])) return; // the same invoice twice: keep one
    _write([...state, sale]);
    unawaited(sync());
  }

  void _patch(String key, Map<String, dynamic> changes) {
    _write([for (final e in state) e['key'] == key ? {...e, ...changes} : e]);
  }

  void _remove(String key) => _write([for (final e in state) if (e['key'] != key) e]);

  /// Sends the waiting invoices, oldest first. Stops at the first network failure (still offline);
  /// a refusal from the server is written on that invoice and the next ones are still tried.
  Future<int> sync() async {
    if (_syncing || state.isEmpty) return 0;
    _syncing = true;
    var sent = 0;
    try {
      final repo = ref.read(posRepoProvider);
      final list = [...state]..sort((a, b) => '${a['sold_at']}'.compareTo('${b['sold_at']}'));
      for (final e in list) {
        final key = e['key'] as String;
        try {
          final sale = await repo.createSale(
            idempotencyKey: key,
            shiftId: e['shift_id'] as String,
            items: [for (final i in (e['items'] as List)) {'product_id': (i as Map)['product_id'], 'quantity': i['quantity']}],
            discountMinor: (e['discount_minor'] as num).toInt(),
            cashMinor: (e['cash_minor'] as num).toInt(),
            approvalId: e['approval_id'] as String?,
            customerId: e['customer_id'] as String?,
            soldAt: DateTime.tryParse('${e['sold_at']}') ?? DateTime.now(),
            sellerId: e['seller_id'] as String?,
            number: e['number'] as String?,
          );
          final id = '${sale['id']}';
          final pm = '${e['pm'] ?? 'cash'}';
          if (e['paid_done'] != true) {
            if (pm == 'split') {
              final sp = Map<String, dynamic>.from(e['split'] as Map);
              await repo.setSaleSplit(id, cash: (sp['cash'] as num).toInt(), card: (sp['card'] as num).toInt(), wallet: (sp['wallet'] as num).toInt());
            } else if (pm == 'card' || pm == 'wallet') {
              await repo.setSalePayment(id, pm);
            }
            _patch(key, {'paid_done': true});
          }
          if (e['tip'] == true && e['tip_done'] != true) {
            await repo.markTip(id, inDrawer: e['tip_in_drawer'] == true);
            _patch(key, {'tip_done': true});
          }
          _remove(key);
          sent++;
        } catch (err) {
          if (posIsNetworkError(err)) break; // still no connection: try again on the next round
          _patch(key, {'error': '$err', 'tried_at': DateTime.now().toIso8601String()});
        }
      }
    } finally {
      _syncing = false;
    }
    if (sent > 0) ref.invalidate(posShiftProvider);
    return sent;
  }
}

final posOfflineQueueProvider = NotifierProvider<PosOfflineQueue, List<Map<String, dynamic>>>(PosOfflineQueue.new);

// ---- the price list and the open shift, kept on this computer for when the server cannot be reached

const _catalogKey = 'pos_catalog_v1';

List<Map<String, dynamic>> posCachedCatalog(SharedPreferences p) {
  try {
    final raw = p.getString(_catalogKey);
    if (raw == null) return [];
    return [for (final e in (jsonDecode(raw) as List)) Map<String, dynamic>.from(e as Map)];
  } catch (_) {
    return [];
  }
}

void posSaveCatalog(SharedPreferences p, List<Map<String, dynamic>> list) {
  try {
    p.setString(_catalogKey, jsonEncode(list));
  } catch (_) {}
}

/// Searches the kept price list the way the server does (exact code first, then names and codes containing the text).
List<Map<String, dynamic>> posSearchOffline(List<Map<String, dynamic>> all, String q) {
  final v = q.trim().toLowerCase();
  if (v.isEmpty) return all.take(40).toList();
  bool exact(Map p) => '${p['sku']}'.toLowerCase() == v || '${p['barcode']}' == v;
  final hits = all.where((p) =>
      exact(p) ||
      '${p['name_ar']}'.toLowerCase().contains(v) ||
      '${p['name_en']}'.toLowerCase().contains(v) ||
      '${p['sku']}'.toLowerCase().contains(v) ||
      '${p['barcode']}'.startsWith(v)).toList()
    ..sort((a, b) => (exact(b) ? 1 : 0) - (exact(a) ? 1 : 0));
  return hits.take(40).toList();
}

/// Takes what was sold offline off the kept stock, so the same piece is not sold twice before the sync.
void posCatalogSold(SharedPreferences p, Map<String, int> qtyById) {
  final all = posCachedCatalog(p);
  if (all.isEmpty) return;
  posSaveCatalog(p, [
    for (final p in all)
      qtyById.containsKey(p['id']) ? {...p, 'stock_quantity': ((p['stock_quantity'] as num?) ?? 0).toInt() - qtyById[p['id']]!} : p,
  ]);
}

const _shiftKey = 'pos_shift_cache_v1';

void posSaveShift(SharedPreferences p, Map<String, dynamic>? shift) {
  try {
    if (shift == null) {
      p.remove(_shiftKey);
    } else {
      p.setString(_shiftKey, jsonEncode(shift));
    }
  } catch (_) {}
}

Map<String, dynamic>? posCachedShift(SharedPreferences p) {
  try {
    final raw = p.getString(_shiftKey);
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return null;
  }
}
