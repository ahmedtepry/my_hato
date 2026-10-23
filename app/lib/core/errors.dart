import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'l10n.dart';

/// Maps backend error codes (raised by our PL/pgSQL functions) and transport
/// errors to friendly, non-leaking messages. Never shows raw DB internals.
String friendlyError(BuildContext context, Object error) {
  if (error is SocketException || error is TimeoutException) return context.tr('offline');
  if (error is AuthException) return context.tr(authErrorKey(error));
  final msg = error is PostgrestException ? error.message : error.toString();
  if (msg.startsWith('OUT_OF_STOCK')) return context.tr('err_out_of_stock');
  if (msg.startsWith('PRODUCT_UNAVAILABLE') || msg.startsWith('VARIANT_UNAVAILABLE')) return context.tr('err_unavailable');
  const map = {
    'CART_EMPTY': 'err_cart_empty',
    'PHONE_NOT_VERIFIED': 'err_phone_not_verified',
    'ACCOUNT_NOT_VERIFIED': 'err_account_not_verified',
    'PHONE_REQUIRED': 'err_phone_required',
    'RATE_LIMITED': 'err_rate_limited',
    'INVALID_INPUT': 'invalid',
    'USERNAME_TAKEN': 'err_username_taken',
    'PHONE_TAKEN': 'err_phone_taken',
    'INVALID_USERNAME': 'username_rules',
    'INVALID_PHONE': 'invalid_phone',
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
    'CANCEL_ALREADY_REQUESTED': 'err_cancel_already_requested',
    'CANCEL_REASON_REQUIRED': 'err_cancel_reason',
    'ALREADY_DECIDED': 'err_already_decided',
    'CANNOT_CANCEL': 'err_cannot_cancel',
    'SKU_TAKEN': 'err_sku_taken',
    'NOT_FOUND': 'err_not_found',
    'INVALID_RATING': 'err_invalid_rating',
    'products_sku_key': 'err_sku_taken',
  };
  for (final e in map.entries) {
    if (msg.contains(e.key)) return context.tr(e.value);
  }
  return context.tr('err_generic');
}

/// Supabase Auth reports a stable `code` (e.g. otp_expired); older servers only send a message,
/// so both are checked. Messages never reveal whether an email is registered.
String authErrorKey(AuthException e) {
  final code = (e.code ?? '').toLowerCase();
  final m = e.message.toLowerCase();
  bool has(String s) => code == s || m.contains(s.replaceAll('_', ' '));
  if (isEmailNotConfirmed(e)) return 'email_not_confirmed';
  if (has('otp_expired') || code == 'invalid_otp' || m.contains('token has expired') || m.contains('invalid otp') || m.contains('otp has expired')) {
    return 'err_invalid_code';
  }
  if (has('invalid_credentials') || m.contains('invalid login')) return 'err_invalid_credentials';
  if (has('user_already_exists') || has('email_exists') || m.contains('already registered')) return 'email_already_registered';
  if (has('weak_password') || m.contains('password should')) return 'password_rules';
  if (has('otp_disabled') || has('signup_disabled') || m.contains('signups not allowed')) return 'err_no_account_for_code';
  if (has('over_email_send_rate_limit') || has('over_request_rate_limit') || code.contains('rate_limit') || e.statusCode == '429' ||
      m.contains('for security purposes') || m.contains('rate limit')) {
    return 'err_rate_limited';
  }
  if (has('email_address_invalid') || m.contains('invalid format')) return 'invalid_email';
  if (has('email_address_not_authorized') || m.contains('not authorized') || m.contains('error sending')) return 'err_email_send_failed';
  if (has('same_password')) return 'err_same_password';
  if (m.contains('database error saving new user') || code == 'unexpected_failure') return 'err_signup_conflict';
  return 'auth_error';
}

bool isEmailNotConfirmed(AuthException e) =>
    (e.code ?? '') == 'email_not_confirmed' || e.message.toLowerCase().contains('email not confirmed');
