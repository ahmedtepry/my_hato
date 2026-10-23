import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

/// Store management from inside the app. Every call runs as the signed-in staff member:
/// the database re-checks permissions (RLS + staff_* functions) and writes the audit log,
/// so the hidden entry point is convenience only — not the security boundary.
class AdminRepository {
  AdminRepository(this._db);
  final SupabaseClient _db;

  Future<bool> isStaff() async {
    if (_db.auth.currentUser == null) return false;
    return await _db.rpc('has_permission', params: {'p_permission': 'orders.manage'}) == true;
  }

  Future<Map<String, dynamic>> stats() async => Map<String, dynamic>.from(await _db.rpc('staff_dashboard_stats') as Map);

  // ---------------- orders
  static const _orderCols =
      'id, reference, customer_name, customer_phone, customer_email, total_minor, delivery_fee_minor, status, fulfillment, payment_method, payment_status, delivery_address, delivery_notes, created_at, closed_at, close_reason, order_items(name_ar, name_en, quantity, unit_price_minor, line_total_minor)';
  static const _repairCols =
      'id, reference, contact_name, contact_phone, device_brand, device_model, problem_description, status, estimated_cost_minor, approved_cost_minor, created_at, closed_at, close_reason';

  /// Find orders and repairs by their number (full or part, any case, Arabic digits OK).
  Future<({List<Map<String, dynamic>> orders, List<Map<String, dynamic>> repairs})> searchByReference(String input) async {
    const ar = '٠١٢٣٤٥٦٧٨٩';
    var q = input.trim().toUpperCase();
    for (var i = 0; i < 10; i++) {
      q = q.replaceAll(ar[i], '$i');
    }
    q = q.replaceAll(RegExp(r'[^A-Z0-9-]'), '');
    if (q.length < 3) return (orders: <Map<String, dynamic>>[], repairs: <Map<String, dynamic>>[]);
    final res = await Future.wait([
      _db.from('orders').select('$_orderCols, cancel_requests(id, reason, status, created_at)').ilike('reference', '%$q%').order('created_at', ascending: false).limit(20),
      _db.from('repair_requests').select('$_repairCols, cancel_requests(id, reason, status, created_at)').ilike('reference', '%$q%').order('created_at', ascending: false).limit(20),
    ]);
    return (orders: List<Map<String, dynamic>>.from(res[0]), repairs: List<Map<String, dynamic>>.from(res[1]));
  }

  /// status: null = all, 'cancel_requests' = orders with an open cancellation request.
  Future<List<Map<String, dynamic>>> orders({String? status}) async {
    final cr = status == 'cancel_requests' ? 'cancel_requests!inner' : 'cancel_requests';
    var q = _db.from('orders').select('$_orderCols, $cr(id, reason, status, created_at)');
    if (status == 'closed') {
      q = q.not('closed_at', 'is', null);
    } else {
      q = q.isFilter('closed_at', null);
      if (status == 'cancel_requests') {
        q = q.eq('cancel_requests.status', 'pending');
      } else if (status != null) {
        q = q.eq('status', status);
      }
    }
    return List<Map<String, dynamic>>.from(await q.order('created_at', ascending: false).limit(200));
  }

  Future<List<String>> nextOrderStatuses(String from, String fulfillment) async {
    final rows = await _db.from('order_transitions').select('to_status, fulfillment').eq('from_status', from);
    return [
      for (final r in rows)
        if (r['fulfillment'] == null || r['fulfillment'] == fulfillment) r['to_status'] as String,
    ];
  }

  /// Status change; an optional message goes on the same timeline entry and notification.
  Future<void> setOrderStatus(String id, String to, {String? note, String? message}) =>
      _db.rpc('staff_set_order_status', params: {'p_order_id': id, 'p_to': to, 'p_note': note, 'p_message': message});

  /// Message to the customer without changing the status (timeline + notification).
  Future<void> postOrderUpdate(String id, String message) =>
      _db.rpc('staff_post_order_update', params: {'p_order_id': id, 'p_message': message});

  // ---------------- repairs
  /// status: null = all active repairs, 'all' = everything, 'cancel_requests' = open cancellation
  /// requests, otherwise that status only.
  Future<List<Map<String, dynamic>>> repairs({String? status}) async {
    final cr = status == 'cancel_requests' ? 'cancel_requests!inner' : 'cancel_requests';
    var q = _db.from('repair_requests').select('$_repairCols, $cr(id, reason, status, created_at)');
    if (status == 'closed') {
      q = q.not('closed_at', 'is', null);
    } else {
      q = q.isFilter('closed_at', null);
    }
    if (status == 'closed' || status == 'all') {
      // no status filter
    } else if (status == 'cancel_requests') {
      q = q.eq('cancel_requests.status', 'pending');
    } else if (status == null) {
      q = q.not('status', 'in', '(delivered,cancelled,unrepairable)');
    } else if (status != 'all') {
      q = q.eq('status', status);
    }
    return List<Map<String, dynamic>>.from(await q.order('created_at', ascending: false).limit(200));
  }

  Future<List<String>> nextRepairStatuses(String from) async {
    final rows = await _db.from('repair_transitions').select('to_status').eq('from_status', from);
    // approval steps only happen through a quote the customer accepts
    return [for (final r in rows) r['to_status'] as String]..removeWhere((s) => s == 'awaiting_approval' || s == 'repair_approved');
  }

  Future<void> setRepairStatus(String id, String to, {String? note}) =>
      _db.rpc('staff_update_repair_status', params: {'p_repair_id': id, 'p_to': to, 'p_customer_note': note});

  Future<void> sendQuote(String id, int amountMinor, String description, String? diagnosis) => _db.rpc('staff_create_repair_quote',
      params: {'p_repair_id': id, 'p_amount_minor': amountMinor, 'p_description': description, 'p_diagnosis': diagnosis});

  Future<void> postRepairUpdate(String id, String message) =>
      _db.rpc('staff_post_repair_update', params: {'p_repair_id': id, 'p_message_ar': message});

  /// Final close: the order/repair disappears from the customer's app for good (kept here as closed).
  Future<void> closeOperation(String kind, String id, String reason) =>
      _db.rpc('staff_close', params: {'p_kind': kind, 'p_id': id, 'p_reason': reason});

  // ---------------- reviews
  /// status: 'pending' | 'published' | 'removed'
  Future<List<Map<String, dynamic>>> reviews(String status) async => List<Map<String, dynamic>>.from(await _db
      .from('product_reviews')
      .select('id, rating, comment, author_name, status, flagged_words, verified_purchase, created_at, updated_at, products(id, name_ar, name_en, sku)')
      .eq('status', status)
      .order('updated_at', ascending: false)
      .limit(200));

  Future<int> pendingReviewsCount() async =>
      (await _db.from('product_reviews').select('id').eq('status', 'pending') as List).length;

  /// action: 'approve' (publish) | 'remove' (hidden from the store)
  Future<void> moderateReview(String id, String action) => _db.rpc('staff_moderate_review', params: {'p_review_id': id, 'p_action': action});

  // ---------------- cancellation requests
  Future<int> pendingCancelCount() async {
    final rows = await _db.from('cancel_requests').select('id').eq('status', 'pending');
    return (rows as List).length;
  }

  Future<void> decideCancel(String requestId, bool approve, {String? note}) =>
      _db.rpc('staff_decide_cancel', params: {'p_request_id': requestId, 'p_approve': approve, 'p_note': note});

  // ---------------- products
  Future<List<Map<String, dynamic>>> products({String? search, bool lowStockOnly = false}) async {
    var q = _db.from('products').select(
        'id, sku, name_ar, name_en, model, brand_id, price_minor, compare_at_price_minor, stock_quantity, status, is_featured, category_id, brands(name_ar, name_en), product_images(storage_path, sort_order)');
    if (search != null && search.trim().isNotEmpty) {
      final s = search.trim().replaceAll(RegExp(r'[,()%*]'), ' ');
      q = q.or('name_ar.ilike.*$s*,name_en.ilike.*$s*,sku.ilike.*$s*');
    }
    if (lowStockOnly) q = q.lte('stock_quantity', 5).eq('status', 'published');
    return List<Map<String, dynamic>>.from(await q.neq('status', 'archived').order('created_at', ascending: false).limit(300));
  }

  Future<List<Map<String, dynamic>>> brands() async =>
      List<Map<String, dynamic>>.from(await _db.from('brands').select('id, name_ar, name_en').eq('is_active', true).order('sort_order').order('name_en'));

  /// New brand from the product editor; returns its id.
  Future<String> createBrand(String nameAr, String nameEn) async {
    final en = nameEn.trim().isEmpty ? nameAr.trim() : nameEn.trim();
    final slug = '${en.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '')}-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final row = await _db.from('brands').insert({'slug': slug, 'name_ar': nameAr.trim(), 'name_en': en, 'sort_order': 50}).select('id').single();
    return row['id'] as String;
  }

  Future<List<Map<String, dynamic>>> categories() async =>
      List<Map<String, dynamic>>.from(await _db.from('categories').select('id, name_ar, name_en, kind').order('kind').order('sort_order'));

  /// True when another product (archived ones included) already uses this SKU / barcode.
  Future<bool> skuTaken(String sku, {String? exceptId}) async {
    var q = _db.from('products').select('id').eq('sku', sku.trim());
    if (exceptId != null) q = q.neq('id', exceptId);
    return (await q.limit(1) as List).isNotEmpty;
  }

  Future<void> updateProduct(String id, Map<String, dynamic> fields) async {
    if (fields.isEmpty) return;
    await _db.from('products').update(fields).eq('id', id);
  }

  /// Stock changes go through the audited inventory function (never a blind overwrite).
  Future<void> setStock(String id, int current, int target, {String note = 'in-app console'}) async {
    final delta = target - current;
    if (delta == 0) return;
    await _db.rpc('staff_adjust_stock',
        params: {'p_product_id': id, 'p_variant_id': null, 'p_delta': delta, 'p_reason': delta > 0 ? 'restock' : 'correction', 'p_note': note});
  }

  /// "Delete": products are archived (hidden from the store) so past orders keep their history.
  Future<void> archiveProduct(String id) => _db.from('products').update({'status': 'archived', 'is_featured': false}).eq('id', id);

  Future<String> createProduct({
    required String categoryId,
    required String nameAr,
    required String nameEn,
    String? descriptionAr,
    String? descriptionEn,
    required int priceMinor,
    required int stock,
    Uint8List? imageBytes,
    String? imageUrl,
    String? sku,
    String? brandId,
    String? model,
  }) async {
    final code = (sku == null || sku.trim().isEmpty) ? 'MH-${DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()}' : sku.trim();
    if (await skuTaken(code)) throw Exception('SKU_TAKEN');
    final row = await _db
        .from('products')
        .insert({
          'sku': code,
          'slug': 'p-${code.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
          'category_id': categoryId,
          'brand_id': brandId,
          'model': (model == null || model.trim().isEmpty) ? null : model.trim(),
          'name_ar': nameAr.trim(),
          'name_en': nameEn.trim().isEmpty ? nameAr.trim() : nameEn.trim(),
          'description_ar': descriptionAr,
          'description_en': descriptionEn,
          'price_minor': priceMinor,
          'stock_quantity': 0,
          'status': 'published',
        })
        .select('id')
        .single();
    final id = row['id'] as String;
    String? path = imageUrl;
    if (imageBytes != null) {
      path = '$id/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await _db.storage.from('product-images').uploadBinary(path, imageBytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    }
    if (path != null && path.isNotEmpty) {
      await _db.from('product_images').insert({'product_id': id, 'storage_path': path, 'alt_ar': nameAr, 'alt_en': nameEn, 'sort_order': 0});
    }
    if (stock > 0) await setStock(id, 0, stock, note: 'opening stock (in-app console)');
    return id;
  }

  Future<void> addImage(String productId, Uint8List bytes, int sortOrder) async {
    final path = '$productId/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _db.storage.from('product-images').uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    await _db.from('product_images').insert({'product_id': productId, 'storage_path': path, 'sort_order': sortOrder});
  }
}

final adminRepoProvider = Provider((ref) => AdminRepository(ref.watch(supabaseProvider)));

final isStaffProvider = FutureProvider<bool>((ref) async {
  ref.watch(currentUserProvider);
  return ref.watch(adminRepoProvider).isStaff();
});
