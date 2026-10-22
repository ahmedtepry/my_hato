import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;
import 'package:url_launcher/url_launcher.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'payments_repository.dart';

/// The payment the customer is currently completing in Paymob's checkout.
/// Used when Paymob redirects back to com.myhato.app://payment-return.
class PendingPayment {
  static String? paymentId;
  static String? orderId;
  static String get returnRoute =>
      paymentId == null ? '/orders' : '/pay/status?payment=$paymentId&order=${orderId ?? ''}';
}

/// Opens Paymob's secure Unified Checkout for an online order, then shows the status
/// screen, which waits for the SERVER-confirmed result (HMAC-verified Paymob callback).
/// Paymob shows only the methods enabled on the merchant account that this device supports:
/// Visa / Mastercard / Meeza cards, Apple Pay (Apple devices), mobile wallets, Google Pay if
/// enabled by Paymob, and the customer's saved cards (each use still needs the customer's confirmation).
Future<void> startOnlinePayment(BuildContext context, WidgetRef ref, {required String orderId, required bool saveCard}) async {
  final repo = ref.read(paymentsRepoProvider);
  try {
    final s = await repo.createIntent(orderId, saveCard: saveCard);
    PendingPayment.paymentId = s.paymentId;
    PendingPayment.orderId = orderId;
    final uri = Uri.parse(s.checkoutUrl);
    if (uri.scheme != 'https') throw 'PROVIDER_NOT_CONFIGURED';
    if (!context.mounted) return;
    context.go(PendingPayment.returnRoute);
    // Custom Tab / SFSafariViewController: the card form is Paymob's page, never ours.
    final opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!opened) await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on FunctionException catch (e) {
    if (!context.mounted) return;
    final code = (e.details is Map ? (e.details as Map)['error'] : null)?.toString() ?? '';
    showSnack(context, friendlyError(context, code), error: true);
    context.go('/orders/$orderId');
  } catch (e) {
    if (!context.mounted) return;
    showSnack(context, friendlyError(context, e), error: true);
    context.go('/orders/$orderId');
  }
}

/// Waits for the server-confirmed status. A redirect / sheet "success" alone is never trusted.
class PaymentStatusScreen extends ConsumerWidget {
  const PaymentStatusScreen({super.key, required this.paymentId, required this.orderId});
  final String paymentId;
  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(paymentWatchProvider(paymentId));
    final status = p.valueOrNull?['status'] as String? ?? 'pending';
    final (icon, color, title, body) = switch (status) {
      'succeeded' => (Icons.check_circle_rounded, BrandColors.success, 'pay_success_t', 'pay_success_b'),
      'failed' => (Icons.error_rounded, BrandColors.error, 'pay_failed', 'pay_failed_b'),
      'cancelled' => (Icons.cancel_rounded, BrandColors.gray, 'pay_cancelled', 'pay_failed_b'),
      'refunded' || 'partially_refunded' => (Icons.undo_rounded, BrandColors.warning, 'ps_refunded', 'pay_refund_b'),
      _ => (Icons.hourglass_top_rounded, BrandColors.electric, 'pay_pending_t', 'pay_pending_b'),
    };
    return PopScope(
      canPop: status != 'pending' && status != 'processing',
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (status == 'pending' || status == 'processing')
                const SizedBox(width: 72, height: 72, child: CircularProgressIndicator(strokeWidth: 5))
              else
                Icon(icon, size: 84, color: color),
              const SizedBox(height: 24),
              Text(context.tr(title), textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(context.tr(body), textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, height: 1.6)),
              if (status == 'succeeded') ...[
                const SizedBox(height: 10),
                Text(context.tr('order_sent_msg'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 32),
              if (status == 'failed' || status == 'cancelled')
                FilledButton(onPressed: () => startOnlinePayment(context, ref, orderId: orderId, saveCard: false), child: Text(context.tr('pay_retry'))),
              const SizedBox(height: 10),
              OutlinedButton(onPressed: () => context.go('/orders/$orderId'), child: Text(context.tr('view_order'))),
              TextButton(onPressed: () => context.go('/'), child: Text(context.tr('back_home'))),
            ]),
          ),
        ),
      ),
    );
  }
}
