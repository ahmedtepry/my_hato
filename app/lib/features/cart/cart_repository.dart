import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';

class CartLine {
  CartLine.fromRow(Map<String, dynamic> r)
      : productId = r['product_id'] as String,
        variantId = r['variant_id'] as String?,
        sku = r['sku'] as String,
        nameAr = r['name_ar'] as String,
        nameEn = r['name_en'] as String,
        variantAr = r['variant_name_ar'] as String?,
        variantEn = r['variant_name_en'] as String?,
        thumb = r['thumb_path'] as String?,
        unitPrice = (r['unit_price_minor'] as num).toInt(),
        listPrice = (r['list_price_minor'] as num).toInt(),
        quantity = (r['quantity'] as num).toInt(),
        lineTotal = (r['line_total_minor'] as num).toInt(),
        availableStock = (r['available_stock'] as num).toInt(),
        isAvailable = r['is_available'] == true;
  final String productId;
  final String? variantId;
  final String sku, nameAr, nameEn;
  final String? variantAr, variantEn, thumb;
  final int unitPrice, listPrice, quantity, lineTotal, availableStock;
  final bool isAvailable;
}

class CartTotals {
  const CartTotals(this.lines);
  final List<CartLine> lines;
  int get subtotal => lines.fold(0, (s, l) => s + l.lineTotal);
  int get listTotal => lines.fold(0, (s, l) => s + l.listPrice * l.quantity);
  int get discount => listTotal - subtotal;
  int get count => lines.fold(0, (s, l) => s + l.quantity);
  bool get allAvailable => lines.every((l) => l.isAvailable);
}

/// Server-persisted cart for signed-in users. Guests keep a local cart that is
/// merged (server-validated) right after sign-in via cart_merge().
class CartRepository {
  CartRepository(this._db, this._ref);
  final SupabaseClient _db;
  final Ref _ref;
  static const _guestKey = 'guest_cart_v1';

  bool get _signedIn => _db.auth.currentUser != null;

  Future<List<CartLine>> load() async {
    if (!_signedIn) return [];
    final rows = await _db.rpc('get_cart') as List;
    return rows.map((r) => CartLine.fromRow(Map<String, dynamic>.from(r))).toList();
  }

  Future<void> setQuantity(String productId, String? variantId, int qty) async {
    if (!_signedIn) {
      _saveGuest(productId, variantId, qty);
      return;
    }
    await _db.rpc('cart_set_item', params: {'p_product_id': productId, 'p_variant_id': variantId, 'p_quantity': qty});
  }

  // ---- guest cart ----
  List<Map<String, dynamic>> guestItems() {
    final raw = _ref.read(sharedPrefsProvider).getString(_guestKey);
    if (raw == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(raw) as List);
  }

  void _saveGuest(String productId, String? variantId, int qty) {
    final items = guestItems()..removeWhere((i) => i['product_id'] == productId && i['variant_id'] == variantId);
    if (qty > 0) items.add({'product_id': productId, 'variant_id': variantId, 'quantity': qty});
    _ref.read(sharedPrefsProvider).setString(_guestKey, jsonEncode(items));
  }

  Future<void> mergeGuestCart() async {
    final items = guestItems();
    if (items.isEmpty || !_signedIn) return;
    await _db.rpc('cart_merge', params: {'p_items': items});
    await _ref.read(sharedPrefsProvider).remove(_guestKey);
  }
}

final cartRepoProvider = Provider((ref) => CartRepository(ref.watch(supabaseProvider), ref));

class CartController extends AsyncNotifier<CartTotals> {
  @override
  Future<CartTotals> build() async {
    final user = ref.watch(currentUserProvider);
    final repo = ref.read(cartRepoProvider);
    if (user != null) await repo.mergeGuestCart();
    return CartTotals(await repo.load());
  }

  int quantityOf(String productId, String? variantId) {
    final lines = state.valueOrNull?.lines ?? const [];
    for (final l in lines) {
      if (l.productId == productId && l.variantId == variantId) return l.quantity;
    }
    final guest = ref.read(cartRepoProvider).guestItems();
    for (final g in guest) {
      if (g['product_id'] == productId && g['variant_id'] == variantId) return (g['quantity'] as num).toInt();
    }
    return 0;
  }

  Future<void> add(String productId, String? variantId, int qty) =>
      setQuantity(productId, variantId, (quantityOf(productId, variantId) + qty).clamp(1, 20).toInt());

  Future<void> setQuantity(String productId, String? variantId, int qty) async {
    await ref.read(cartRepoProvider).setQuantity(productId, variantId, qty);
    ref.invalidateSelf();
    await future;
  }
}

final cartProvider = AsyncNotifierProvider<CartController, CartTotals>(CartController.new);
