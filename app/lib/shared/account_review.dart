// New accounts can browse and fill the cart right away; ordering, repair requests and reviews open
// once the team approves the account. This shows the customer where they stand.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/l10n.dart';
import '../core/supabase_providers.dart';
import '../core/theme.dart';
import 'support_contact.dart';

/// 'approved' | 'pending' | 'rejected' for the signed-in customer (null when signed out).
final accountReviewProvider = FutureProvider<String?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  final db = ref.watch(supabaseProvider);
  try {
    final row = await db.from('customers').select('review_status').eq('user_id', user.id).maybeSingle();
    return (row?['review_status'] as String?) ?? 'approved';
  } catch (_) {
    return 'approved'; // never block the UI on this; the server enforces the rule anyway
  }
});

bool isAccountPendingError(Object e) => e.toString().contains('ACCOUNT_PENDING');

/// Friendly explanation when a locked action is tried.
Future<void> showAccountPendingSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _PendingSheet(),
    );

class _PendingSheet extends StatelessWidget {
  const _PendingSheet();
  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            width: 78,
            height: 78,
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(horizontal: 120),
            decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: const Icon(Icons.verified_user_rounded, color: BrandColors.electric, size: 40),
          ),
          const SizedBox(height: 14),
          Text(ar ? 'حسابك بيتوثّق دلوقتي ⏳' : 'Your account is being verified ⏳',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            ar
                ? 'تقدر تتصفح المنتجات وتضيف للسلة عادي. أول ما فريقنا يوثّق حسابك هتقدر تطلب وتبعت طلبات صيانة، وهيوصلك إشعار.'
                : 'Browse and add to your cart as usual. As soon as our team verifies your account you can order and request repairs — we will notify you.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: BrandColors.gray, height: 1.5),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366), minimumSize: const Size.fromHeight(50)),
            icon: const Icon(Icons.chat_rounded),
            label: Text(ar ? 'سرّع التوثيق على واتساب' : 'Speed it up on WhatsApp'),
            onPressed: () => launchUrl(
              whatsappUri(ar ? 'أهلاً My Hatō، عملت حساب جديد وعايز أوثّقه.' : 'Hello My Hatō, I created an account and would like it verified.'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(ar ? 'تمام، هتصفح' : 'OK, keep browsing')),
        ]),
      ),
    );
  }
}

/// Slim banner for home / cart / checkout while the account waits for verification.
class PendingAccountBanner extends ConsumerWidget {
  const PendingAccountBanner({super.key, this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 0)});
  final EdgeInsets margin;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(accountReviewProvider).valueOrNull;
    if (status == null || status == 'approved') return const SizedBox.shrink();
    final ar = context.isAr;
    final rejected = status == 'rejected';
    final color = rejected ? BrandColors.error : BrandColors.electric;
    return Padding(
      padding: margin,
      child: Material(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => rejected
              ? launchUrl(whatsappUri(ar ? 'أهلاً My Hatō، بخصوص حسابي.' : 'Hello My Hatō, about my account.'), mode: LaunchMode.externalApplication)
              : showAccountPendingSheet(context),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: color.withValues(alpha: 0.3))),
            child: Row(children: [
              Icon(rejected ? Icons.info_rounded : Icons.hourglass_top_rounded, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    rejected ? (ar ? 'حسابك محتاج مراجعة' : 'Your account needs a review') : (ar ? 'حسابك بيتوثّق — شوية وهيتفعّل' : 'Verifying your account — almost there'),
                    style: TextStyle(fontWeight: FontWeight.w800, color: color),
                  ),
                  Text(
                    rejected
                        ? (ar ? 'كلّم خدمة العملاء على واتساب علشان نكمّل' : 'Contact support on WhatsApp to continue')
                        : (ar ? 'اتصفح وضيف للسلة، والطلب هيتفتح أول ما نوثّقه' : 'Browse and fill your cart; ordering opens once verified'),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ]),
              ),
              Icon(Icons.chevron_left_rounded, color: color),
            ]),
          ),
        ),
      ),
    );
  }
}
