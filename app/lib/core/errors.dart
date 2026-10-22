import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'l10n.dart';

/// Maps backend error codes (raised by our PL/pgSQL functions) and transport
/// errors to friendly, non-leaking messages. Never shows raw DB internals.
String friendlyError(BuildContext context, Object error) {
  if (error is SocketException || error is TimeoutException) return context.tr('offline');
  if (error is AuthException) {
    final m = error.message.toLowerCase();
    if (m.contains('invalid login') || m.contains('invalid credentials')) return context.tr('err_invalid_credentials');
    if (m.contains('expired') || m.contains('invalid') && m.contains('otp') || m.contains('token')) return context.tr('err_invalid_code');
    if (m.contains('rate') || error.statusCode == '429') return context.tr('err_rate_limited');
    return context.tr('auth_error');
  }
  final msg = error is PostgrestException ? error.message : error.toString();
  if (msg.startsWith('OUT_OF_STOCK')) return context.tr('err_out_of_stock');
  if (msg.startsWith('PRODUCT_UNAVAILABLE') || msg.startsWith('VARIANT_UNAVAILABLE')) return context.tr('err_unavailable');
  const map = {
    'CART_EMPTY': 'err_cart_empty',
    'PHONE_NOT_VERIFIED': 'err_phone_not_verified',
    'INVALID_ADDRESS': 'err_invalid_address',
    'INVALID_BRANCH': 'err_invalid_branch',
    'QUOTE_NOT_PENDING': 'err_quote_not_pending',
    'FORBIDDEN': 'err_forbidden',
    'AUTH_REQUIRED': 'login_required',
    'rate_limited': 'err_rate_limited',
    'invalid_or_expired_code': 'err_invalid_code',
    'SMS_NOT_CONFIGURED': 'sms_not_configured',
    'ONLINE_PAYMENTS_DISABLED': 'pay_unavailable',
    'PROVIDER_NOT_CONFIGURED': 'pay_unavailable',
    'PAYMENT_IN_PROGRESS': 'pay_in_progress',
    'PAYMENT_METHOD_DISABLED': 'pay_unavailable',
    'ALREADY_PAID': 'pay_already_paid',
    'CANNOT_CANCEL_PAID': 'cannot_cancel_paid',
    'ORDER_CANCELLED': 'err_unavailable',
  };
  for (final e in map.entries) {
    if (msg.contains(e.key)) return context.tr(e.value);
  }
  return context.tr('err_generic');
}
