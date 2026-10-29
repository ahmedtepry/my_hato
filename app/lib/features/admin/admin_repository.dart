import 'dart:async';
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

  Future<bool> isStaff() async => (await staffContext()).roles.isNotEmpty;

  /// The signed-in member's roles + permissions (the console shows only what they can use;
  /// the database still checks every action).
  Future<List<Map<String, dynamic>>> customers(String? search, {int offset = 0, int limit = 200}) async => List<Map<String, dynamic>>.from(
      await _db.rpc('staff_customers', params: {'p_search': (search ?? '').trim().isEmpty ? null : search!.trim(), 'p_limit': limit, 'p_offset': offset}) as List);

  Future<void> setCustomerPassword(String userId, String password) async {
    await _db.rpc('staff_set_customer_password', params: {'p_user': userId, 'p_password': password});
  }

  Future<List<String>> customerEmails() async => List<String>.from(await _db.rpc('staff_customer_emails') as List);

  Future<void> setOccasion(String key, String stamp) async {
    await _db.rpc('set_occasion', params: {'p_key': key, 'p_stamp': stamp});
  }

  Future<int> occasionSend({
    required String key,
    required int year,
    required String title,
    required String body,
    required String gift,
    String? code,
    int? percent,
    int? validDays,
    int? coins,
    String scope = 'all',
  }) async =>
      ((await _db.rpc('occasion_send', params: {
        'p_key': key,
        'p_year': year,
        'p_title': title,
        'p_body': body,
        'p_gift': gift,
        'p_code': gift == 'code' ? code : null,
        'p_percent': gift == 'code' ? percent : null,
        'p_valid_days': gift == 'code' ? validDays : null,
        'p_coins': gift == 'coins' ? coins : null,
        'p_scope': scope,
      })) as num)
          .toInt();

  Future<void> setAppName(String ar, String en) async {
    await _db.rpc('set_app_name', params: {'p_ar': ar, 'p_en': en});
  }

  Future<void> setAppearance(Map<String, String> palette, String animation, String icon) async {
    await _db.rpc('set_appearance', params: {'p_palette': palette, 'p_animation': animation, 'p_icon': icon});
  }

  Future<Map<String, dynamic>> salesReport(String period) async =>
      Map<String, dynamic>.from(await _db.rpc('sales_report', params: {'p_period': period}) as Map);

  Future<Map<String, dynamic>> salesExport(String period) async =>
      Map<String, dynamic>.from(await _db.rpc('sales_export', params: {'p_period': period}) as Map);

  /// The member's own console layout (section order + pinned sections), or null when never changed.
  Future<ConsoleLayout?> consoleLayout() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    final r = await _db.from('staff_console_prefs').select('section_order, pinned').eq('user_id', uid).maybeSingle();
    if (r == null) return null;
    List<String> l(Object? v) => List<String>.from((v as List? ?? const []).map((e) => '$e'));
    return ConsoleLayout(l(r['section_order']), l(r['pinned']));
  }

  Future<void> saveConsoleLayout(ConsoleLayout layout) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    await _db.from('staff_console_prefs').upsert({
      'user_id': uid,
      'section_order': layout.order,
      'pinned': layout.pinned,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<StaffContext> staffContext() async {
    if (_db.auth.currentUser == null) return const StaffContext({}, {});
    final r = Map<String, dynamic>.from(await _db.rpc('my_staff_context') as Map);
    return StaffContext(
      Set<String>.from((r['roles'] as List? ?? const []).map((e) => '$e')),
      Set<String>.from((r['permissions'] as List? ?? const []).map((e) => '$e')),
    );
  }

  // ---------------- new accounts waiting for approval
  Future<List<Map<String, dynamic>>> accounts(String status) async =>
      List<Map<String, dynamic>>.from(await _db.rpc('staff_accounts', params: {'p_status': status}) as List);

  /// Latest customer notifications for an order / repair with their read receipt (read_at).
  Future<List<Map<String, dynamic>>> entitySeen(String type, String id) async =>
      List<Map<String, dynamic>>.from(await _db.rpc('staff_entity_seen', params: {'p_type': type, 'p_id': id}) as List);

  Future<int> pendingAccountsCount() async {
    try {
      return ((await _db.rpc('staff_pending_accounts_count')) as num).toInt();
    } catch (_) {
      return 0;
    }
  }

  /// Confirms the account in Auth (service role, server side) so the customer can sign in now.
  Future<void> activateAccount(String userId) async {
    final res = await _db.functions.invoke('admin-customer', body: {'action': 'activate', 'user_id': userId});
    final data = res.data;
    if (data is Map && data['ok'] != true) throw Exception(data['error'] ?? 'UPDATE_FAILED');
  }

  Future<void> rejectAccount(String userId, String? reason) =>
      _db.rpc('staff_reject_account', params: {'p_user_id': userId, 'p_reason': (reason ?? '').isEmpty ? null : reason});

  // ---------------- discount codes & offers
  Future<List<Map<String, dynamic>>> coupons() async =>
      List<Map<String, dynamic>>.from(await _db.from('coupons').select().order('created_at', ascending: false));

  Future<String> saveCoupon({
    required String code,
    String? title,
    int? percentOff,
    int? amountOffMinor,
    int minOrderMinor = 0,
    int? maxUses,
    int perCustomer = 1,
    DateTime? endsAt,
    bool active = true,
  }) async =>
      await _db.rpc('staff_save_coupon', params: {
        'p_code': code.trim().toUpperCase(),
        'p_title_ar': title,
        'p_percent_off': percentOff,
        'p_amount_off_minor': amountOffMinor,
        'p_min_order_minor': minOrderMinor,
        'p_max_uses': maxUses,
        'p_per_customer_limit': perCustomer,
        'p_ends_at': endsAt?.toUtc().toIso8601String(),
        'p_is_active': active,
      }) as String;

  /// Sends the offer to every customer's notifications; returns how many received it.
  Future<int> broadcastOffer({required String title, required String body, String? couponCode, String? imageUrl}) async =>
      ((await _db.rpc('staff_broadcast_offer', params: {
        'p_title': title.trim(),
        'p_body': body.trim(),
        'p_coupon_code': couponCode,
        if (imageUrl != null) 'p_image_url': imageUrl,
      })) as num)
          .toInt();

  /// Uploads an offer picture to the public banners bucket (offers/ folder) and returns its public URL.
  Future<String> uploadOfferImage(Uint8List bytes) async {
    final path = 'offers/${DateTime.now().microsecondsSinceEpoch}.jpg';
    await _db.storage.from('banners').uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    return _db.storage.from('banners').getPublicUrl(path);
  }

  Future<Map<String, dynamic>> stats() async => Map<String, dynamic>.from(await _db.rpc('staff_dashboard_stats') as Map);

  // ---------------- orders
  // the address column is only requested by members who hold orders.address
  static String _orderCols({required bool address}) =>
      'id, reference, customer_name, customer_phone, customer_email, total_minor, delivery_fee_minor, status, fulfillment, payment_method, payment_status, ${address ? 'delivery_address, ' : ''}delivery_notes, created_at, closed_at, close_reason, coupon_code, coupon_discount_minor, order_items(name_ar, name_en, quantity, unit_price_minor, line_total_minor)';
  Future<bool> _canSeeAddress() async => (await staffContext()).permissions.contains('orders.address');
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
    final addr = await _canSeeAddress();
    final res = await Future.wait([
      _db.from('orders').select('${_orderCols(address: addr)}, cancel_requests(id, reason, status, created_at)').ilike('reference', '%$q%').order('created_at', ascending: false).limit(20),
      _db.from('repair_requests').select('$_repairCols, cancel_requests(id, reason, status, created_at)').ilike('reference', '%$q%').order('created_at', ascending: false).limit(20),
    ]);
    return (orders: List<Map<String, dynamic>>.from(res[0]), repairs: List<Map<String, dynamic>>.from(res[1]));
  }

  /// status: null = all, 'cancel_requests' = orders with an open cancellation request.
  Future<List<Map<String, dynamic>>> orders({String? status}) async {
    final cr = status == 'cancel_requests' ? 'cancel_requests!inner' : 'cancel_requests';
    final addr = await _canSeeAddress();
    var q = _db.from('orders').select('${_orderCols(address: addr)}, $cr(id, reason, status, created_at)');
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

  /// Exact SKU / barcode lookup (archived products excluded).
  Future<Map<String, dynamic>?> productBySku(String sku) async => await _db
      .from('products')
      .select('id, sku, name_ar, name_en, price_minor, compare_at_price_minor, stock_quantity, status, product_images(storage_path, sort_order)')
      .eq('sku', sku.trim())
      .neq('status', 'archived')
      .maybeSingle();

  /// Every product (for the Excel export / import), with category and brand names.
  Future<List<Map<String, dynamic>>> allProductsForSheet() async => List<Map<String, dynamic>>.from(await _db
      .from('products')
      .select('id, sku, name_ar, name_en, model, price_minor, compare_at_price_minor, stock_quantity, status, categories(name_ar), brands(name_en)')
      .neq('status', 'archived')
      .order('sku'));

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

class ConsoleLayout {
  const ConsoleLayout(this.order, this.pinned);
  final List<String> order, pinned;
}

class ConsoleLayoutController extends AsyncNotifier<ConsoleLayout> {
  @override
  Future<ConsoleLayout> build() async {
    try {
      return await ref.read(adminRepoProvider).consoleLayout() ?? const ConsoleLayout([], []);
    } catch (_) {
      return const ConsoleLayout([], []); // never block the console because the layout could not load
    }
  }

  /// Shows the change at once, then saves it on the account.
  Future<void> set(ConsoleLayout layout) async {
    state = AsyncData(layout);
    try {
      await ref.read(adminRepoProvider).saveConsoleLayout(layout);
    } catch (_) {}
  }
}

final consoleLayoutProvider = AsyncNotifierProvider<ConsoleLayoutController, ConsoleLayout>(ConsoleLayoutController.new);

class StaffContext {
  const StaffContext(this.roles, this.permissions);
  final Set<String> roles;
  final Set<String> permissions;
}

/// The signed-in member's roles and permissions. Re-read every few seconds, so whatever the owner switches on or off
/// reaches the person's screen almost at once (no need to close and reopen the app). It only publishes a change when something differs.
class StaffContextController extends AsyncNotifier<StaffContext> {
  Timer? _timer;

  bool _same(StaffContext a, StaffContext b) =>
      a.roles.length == b.roles.length && a.roles.containsAll(b.roles) && a.permissions.length == b.permissions.length && a.permissions.containsAll(b.permissions);

  @override
  Future<StaffContext> build() async {
    final user = ref.watch(currentUserProvider);
    ref.onDispose(() => _timer?.cancel());
    _timer?.cancel();
    final first = await ref.read(adminRepoProvider).staffContext();
    if (user != null && first.roles.isNotEmpty) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) async {
        try {
          final now = await ref.read(adminRepoProvider).staffContext();
          final cur = state.valueOrNull;
          if (cur == null || !_same(cur, now)) state = AsyncData(now);
        } catch (_) {/* offline for a moment: keep what we have */}
      });
    }
    return first;
  }
}

/// A section the console should open as soon as it is shown (set by a notification link like /hato-console?tab=accounts).
final pendingConsoleTabProvider = StateProvider<String?>((ref) => null);

final staffContextProvider = AsyncNotifierProvider<StaffContextController, StaffContext>(StaffContextController.new);

final isStaffProvider = Provider<AsyncValue<bool>>((ref) => ref.watch(staffContextProvider).whenData((c) => c.roles.isNotEmpty));

/// What a team member works in after signing in. Decided by his role, never by what he types or picks:
/// a cashier lands on the cashier screen only, an accountant on the books, and so on. Owner and manager keep the full console.
enum Workspace { full, cashier, accountant, sales, repairs, support }

Workspace workspaceOf(Set<String> roles) {
  if (roles.contains('owner') || roles.contains('manager')) return Workspace.full;
  if (roles.contains('accountant')) return Workspace.accountant;
  if (roles.contains('cashier')) return Workspace.cashier;
  if (roles.contains('sales')) return Workspace.sales;
  if (roles.contains('technician')) return Workspace.repairs;
  if (roles.contains('support')) return Workspace.support;
  return Workspace.full;
}

final workspaceProvider = Provider<Workspace>((ref) => workspaceOf(ref.watch(staffContextProvider).valueOrNull?.roles ?? const <String>{}));

/// Console tabs for the signed-in member, in order. The first one is where he lands.
final consoleTabsProvider = Provider<List<String>>((ref) {
  final ctx = ref.watch(staffContextProvider).valueOrNull;
  final p = ctx?.permissions ?? const <String>{};
  final all = [
    'overview',
    if (p.contains('pos.sell')) 'pos',
    if (p.contains('pos.approve') || p.contains('shifts.review')) 'shifts',
    if (p.contains('shifts.review') || p.contains('sales.view') || p.contains('shifts.reports')) 'books',
    if (p.contains('orders.view')) 'orders',
    if (p.contains('sales.view') || p.contains('profit.view')) 'sales',
    if (p.contains('ops.live')) 'ops',
    if (p.contains('targets.view') && !p.contains('commission.view')) 'targets', // with the KPI page, targets live inside it
    if (p.contains('commission.view')) 'kpi',
    if (p.contains('targets.mine')) 'mytarget',
    if (p.contains('appearance.manage')) 'appearance',
    if (p.contains('occasions.manage')) 'occasions',
    if (p.contains('contest.manage')) 'contests',
    if (p.contains('features.manage')) 'features',
    if (p.contains('storefront.layout')) 'storefront',
    if (p.contains('wheel.manage')) 'wheel',
    if (p.contains('stock.view')) 'stock',
    if (p.contains('shortcut.goods_receipt') || p.contains('shortcut.stocktake') || p.contains('shortcut.price_edit') || p.contains('shortcut.export')) 'shortcuts',
    if (p.contains('assistant.accountant') || p.contains('assistant.support') || p.contains('assistant.cashier') || p.contains('assistant.guard')) 'assistant',
    if (p.contains('repairs.view')) 'repairs',
    if (p.contains('products.manage')) 'products',
    if (p.contains('products.manage')) 'reviews',
    if (p.contains('support.manage')) 'accounts',
    if (p.contains('gifts.manage')) 'gifts',
  ];
  // the pages of each job, in order
  final List<String> first;
  switch (workspaceOf(ctx?.roles ?? const <String>{})) {
    case Workspace.full:
      return all.where((k) => k != 'books').toList(); // owner / manager: the full console, unchanged
    case Workspace.cashier:
      first = const ['pos'];
    case Workspace.accountant:
      first = const ['books', 'kpi', 'sales', 'orders'];
    case Workspace.sales:
      first = const ['orders', 'pos', 'products', 'sales'];
    case Workspace.repairs:
      first = const ['repairs', 'orders'];
    case Workspace.support:
      first = const ['orders', 'repairs', 'accounts'];
  }
  // a focused job lands on its own pages first; anything else the owner switches on for this person is added after them
  // (the database still decides every action)
  final out = first.where(all.contains).toList();
  out.addAll(all.where((k) => k != 'overview' && !out.contains(k)));
  return out.isEmpty ? ['overview'] : out;
});
