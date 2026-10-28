import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

/// Cashier, shifts and approvals. Every call runs as the signed-in staff member: prices, stock, limits,
/// branch access and double approval are all decided by the database (see migration 0061), never by the app.
class PosRepository {
  PosRepository(this._db);
  final SupabaseClient _db;

  Map<String, dynamic> _m(Object? v) => Map<String, dynamic>.from(v as Map);
  List<Map<String, dynamic>> _l(Object? v) => [for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

  Future<List<Map<String, dynamic>>> branches() async => _l(await _db.rpc('staff_my_branches'));

  Future<Map<String, dynamic>?> currentShift() async {
    final r = await _db.rpc('pos_current_shift');
    return r == null ? null : _m(r);
  }

  Future<void> openShift(String branchId, int openingMinor) async {
    await _db.rpc('pos_open_shift', params: {'p_branch': branchId, 'p_opening_minor': openingMinor});
  }

  /// Proves the person at the keyboard is the signed-in member: the database checks the typed password (rate-limited) and
  /// returns the account email only when it is right; it must be this session's own account. Nothing is signed in or out.
  Future<bool> verifyLogin(String login, String password) async {
    final email = await _db.rpc('login_email_for', params: {'p_identifier': login.trim(), 'p_password': password}) as String?;
    final mine = _db.auth.currentUser?.email;
    return email != null && mine != null && email.toLowerCase() == mine.toLowerCase();
  }

  Future<Map<String, dynamic>> shiftSummary(String shiftId) async => _m(await _db.rpc('pos_shift_summary', params: {'p_shift': shiftId}));

  /// Closes the shift. The database asks for the closer's own password again and answers `{ok:false, error:'WRONG_PASSWORD'}` when it is wrong.
  /// On success `report` is the final, numbered closing report (it can never be changed afterwards).
  Future<Map<String, dynamic>> closeShift(String shiftId, int countedMinor, String? note, String password) async =>
      _m(await _db.rpc('pos_close_shift', params: {
        'p_shift': shiftId,
        'p_counted_minor': countedMinor,
        'p_password': password,
        'p_note': note,
        'p_device': deviceLabel(),
      }));

  Future<List<Map<String, dynamic>>> shiftReports(int days) async => _l(await _db.rpc('pos_shift_report_list', params: {
        'p_from': DateTime.now().subtract(Duration(days: days)).toUtc().toIso8601String(),
        'p_limit': 200,
      }));

  Future<Map<String, dynamic>> shiftReport(String shiftId) async => _m(await _db.rpc('pos_shift_report_get', params: {'p_shift': shiftId}));

  Future<void> addCorrection(String shiftId, int amountMinor, String reason) async {
    await _db.rpc('pos_add_shift_correction', params: {'p_shift': shiftId, 'p_amount_minor': amountMinor, 'p_reason': reason});
  }

  Future<List<Map<String, dynamic>>> searchProducts(String q) async =>
      _l(await _db.rpc('pos_search_products', params: {'p_q': q.trim().isEmpty ? null : q.trim(), 'p_limit': 40}));

  Future<Map<String, dynamic>> limits() async => _m(await _db.rpc('pos_get_limits'));

  Future<void> setLimits({required num discountPct, required int refundMinor, required bool allowNegative}) async {
    await _db.rpc('pos_set_limits', params: {'p_discount_pct': discountPct, 'p_refund_minor': refundMinor, 'p_allow_negative': allowNegative});
  }

  /// [items]: `[{product_id, quantity}]`. [idempotencyKey] makes a repeated tap or a re-sent request return the SAME invoice.
  Future<Map<String, dynamic>> createSale({
    required String idempotencyKey,
    required String shiftId,
    required List<Map<String, dynamic>> items,
    required int discountMinor,
    required int cashMinor,
    String? approvalId,
  }) async =>
      _m(await _db.rpc('pos_create_sale', params: {
        'p_idempotency_key': idempotencyKey,
        'p_shift': shiftId,
        'p_items': items,
        'p_discount_minor': discountMinor,
        'p_cash_received_minor': cashMinor,
        'p_approval': approvalId,
      }));

  Future<List<Map<String, dynamic>>> recentSales(String shiftId) async => _l(await _db
      .from('pos_sales')
      .select('id, number, total_minor, refunded_minor, created_at')
      .eq('shift_id', shiftId)
      .order('created_at', ascending: false)
      .limit(30));

  Future<Map<String, dynamic>> findSale(String number) async => _m(await _db.rpc('pos_find_sale', params: {'p_number': number}));

  Future<Map<String, dynamic>> refund({
    required String saleId,
    required List<Map<String, dynamic>> items,
    required String reason,
    required bool restock,
    String? approvalId,
  }) async =>
      _m(await _db.rpc('pos_refund', params: {'p_sale': saleId, 'p_items': items, 'p_reason': reason, 'p_restock': restock, 'p_approval': approvalId}));

  Future<String> requestApproval({required String kind, required int amountMinor, required String reason, required String branchId}) async =>
      (await _db.rpc('pos_request_approval', params: {'p_kind': kind, 'p_amount_minor': amountMinor, 'p_reason': reason, 'p_branch': branchId})) as String;

  Future<Map<String, dynamic>?> approvalStatus(String id) async =>
      await _db.from('approvals').select('id, status, decision_note, amount_minor').eq('id', id).maybeSingle();

  Future<List<Map<String, dynamic>>> pendingApprovals() async => _l(await _db.rpc('pos_pending_approvals'));

  Future<void> decideApproval(String id, bool approve, String? note) async {
    await _db.rpc('pos_decide_approval', params: {'p_id': id, 'p_approve': approve, 'p_note': note});
  }

  Future<List<Map<String, dynamic>>> shifts({int days = 7}) async => _l(await _db.rpc('pos_shift_list', params: {
        'p_from': DateTime.now().subtract(Duration(days: days)).toUtc().toIso8601String(),
        'p_limit': 100,
      }));

  Future<List<Map<String, dynamic>>> branchReport(int days) async => _l(await _db.rpc('pos_branch_report', params: {
        'p_from': DateTime.now().subtract(Duration(days: days)).toUtc().toIso8601String(),
      }));

  /// Branch totals since a moment (used by the dashboard for "today").
  Future<List<Map<String, dynamic>>> branchReportSince(DateTime from) async =>
      _l(await _db.rpc('pos_branch_report', params: {'p_from': from.toUtc().toIso8601String()}));

  Future<Map<String, dynamic>> auditVerify() async => _m(await _db.rpc('audit_verify'));

  Future<Map<String, dynamic>> snapshot() async => _m(await _db.rpc('owner_data_snapshot'));

  Future<List<String>> memberBranches(String userId) async =>
      [for (final e in (await _db.rpc('staff_get_branches', params: {'p_user': userId}) as List? ?? const [])) '$e'];

  Future<void> setMemberBranches(String userId, List<String> branchIds) async {
    await _db.rpc('staff_set_branches', params: {'p_user': userId, 'p_branches': branchIds});
  }
}

final posRepoProvider = Provider((ref) => PosRepository(ref.watch(supabaseProvider)));

/// The signed-in member's open shift with live totals (null = no open shift).
final posShiftProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((ref) => ref.watch(posRepoProvider).currentShift());
final posLimitsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(posRepoProvider).limits());
final posBranchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) => ref.watch(posRepoProvider).branches());

/// Which machine is doing this (recorded with the shift closing): system + computer name.
String deviceLabel() {
  try {
    return '${Platform.operatingSystem} · ${Platform.localHostname}';
  } catch (_) {
    return 'unknown';
  }
}

/// Backend error code -> message for the cashier (Egyptian Arabic / English).
String posErrorText(Object e, bool ar, String Function(Object) fallback) {
  final m = e is PostgrestException ? '${e.message} ${e.details ?? ''}' : e.toString();
  String pick(String ar_, String en) => ar ? ar_ : en;
  if (m.contains('OUT_OF_STOCK')) {
    final sku = e is PostgrestException && e.details != null ? ' (${e.details})' : '';
    return pick('الكمية مش متاحة في المخزون$sku', 'Not enough stock$sku');
  }
  if (m.contains('APPROVAL_REQUIRED')) return pick('الخصم أو المرتجع ده محتاج موافقة مسؤول', 'This needs a manager approval');
  if (m.contains('SELF_APPROVAL')) return pick('مينفعش توافق على طلبك إنت', 'You cannot approve your own request');
  if (m.contains('CASH_SHORT')) return pick('المبلغ المستلم أقل من الإجمالي', 'Cash received is less than the total');
  if (m.contains('NO_OPEN_SHIFT')) return pick('لازم تفتح وردية الأول', 'Open a shift first');
  if (m.contains('SHIFT_ALREADY_OPEN')) return pick('عندك وردية مفتوحة بالفعل', 'You already have an open shift');
  if (m.contains('SHIFT_CLOSED')) return pick('الوردية دي اتقفلت', 'This shift is closed');
  if (m.contains('NOTE_REQUIRED')) return pick('فيه فرق في الدرج، اكتب سببه', 'There is a cash difference, write the reason');
  if (m.contains('REASON_REQUIRED')) return pick('اكتب سبب المرتجع', 'Write the refund reason');
  if (m.contains('REFUND_EXCEEDS_SOLD')) return pick('الكمية أو المبلغ أكبر من اللي اتباع', 'More than was sold');
  if (m.contains('ALREADY_DECIDED')) return pick('الطلب ده اتقرر فيه قبل كده', 'Already decided');
  if (m.contains('TOO_MANY_PENDING')) return pick('عندك طلبات موافقة كتير مستنية', 'Too many pending requests');
  if (m.contains('WRONG_PASSWORD')) return pick('الباسورد غلط', 'Wrong password');
  if (m.contains('SHIFT_NOT_CLOSED')) return pick('الوردية لسه مفتوحة', 'The shift is still open');
  if (m.contains('RATE_LIMITED')) return pick('محاولات غلط كتير، استنى شوية وجرّب تاني', 'Too many wrong attempts, wait a bit');
  if (m.contains('NOT_FOUND')) return pick('مش لاقي الفاتورة أو المنتج', 'Not found');
  if (m.contains('FORBIDDEN')) return pick('مش مسموحلك بالعملية دي', 'Not allowed');
  if (m.contains('INVALID_INPUT')) return pick('البيانات مش صحيحة', 'Invalid input');
  return fallback(e);
}

/// True when the server definitely refused the request (nothing was saved), so the idempotency key can be dropped.
bool posDefinitiveError(Object e) {
  if (e is! PostgrestException) return false;
  const codes = [
    'OUT_OF_STOCK', 'APPROVAL_REQUIRED', 'CASH_SHORT', 'NO_OPEN_SHIFT', 'INVALID_INPUT', 'FORBIDDEN', 'NOT_FOUND', 'REFUND_EXCEEDS_SOLD', 'REASON_REQUIRED',
  ];
  final m = '${e.message}';
  return codes.any(m.contains);
}
