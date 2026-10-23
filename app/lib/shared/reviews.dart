import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'account_review.dart';
import 'like_reward.dart';
import '../core/errors.dart';
import '../core/l10n.dart';
import '../core/supabase_providers.dart';
import '../core/theme.dart';
import 'states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

/// Published reviews of a product + the signed-in customer's own review (any status), newest first.
final productReviewsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, productId) async {
  ref.watch(currentUserProvider);
  final rows = await ref
      .watch(supabaseProvider)
      .from('product_reviews')
      .select('id, user_id, author_name, rating, comment, status, verified_purchase, created_at, updated_at, like_count')
      .eq('product_id', productId)
      .neq('status', 'removed')
      .order('updated_at', ascending: false)
      .limit(50);
  return List<Map<String, dynamic>>.from(rows);
});

/// Ids of the reviews the signed-in customer has liked.
final myReviewLikesProvider = FutureProvider.autoDispose<Set<String>>((ref) async {
  final me = ref.watch(currentUserProvider);
  if (me == null) return <String>{};
  final rows = await ref.watch(supabaseProvider).from('review_likes').select('review_id').eq('user_id', me.id);
  return {for (final r in rows) r['review_id'] as String};
});

/// Read-only stars (supports halves).
class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.value, this.size = 16, this.color = const Color(0xFFFFB400)});
  final double value;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              value >= i ? Icons.star_rounded : (value >= i - 0.5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
              size: size,
              color: value >= i - 0.5 ? color : BrandColors.border,
            ),
        ]),
      );
}

/// Product page block: rating summary, "write a review" button and the reviews list.
class ReviewsSection extends ConsumerWidget {
  const ReviewsSection({super.key, required this.productId, required this.ratingAvg, required this.ratingCount});
  final String productId;
  final double ratingAvg;
  final int ratingCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserProvider);
    final data = ref.watch(productReviewsProvider(productId));
    final list = data.valueOrNull ?? const <Map<String, dynamic>>[];
    final mine = me == null ? null : list.where((r) => r['user_id'] == me.id).firstOrNull;
    final others = [for (final r in list) if (r['status'] == 'published' && r['user_id'] != me?.id) r];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_t(context, 'تقييمات العملاء', 'Customer reviews'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: BrandColors.border)),
          child: Row(children: [
            Column(children: [
              Text(ratingCount == 0 ? '—' : ratingAvg.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: BrandColors.navy, height: 1)),
              const SizedBox(height: 6),
              StarRating(value: ratingAvg, size: 18),
              const SizedBox(height: 4),
              Text(ratingCount == 0 ? _t(context, 'لسه مفيش تقييمات', 'No reviews yet') : _t(context, '$ratingCount تقييم', '$ratingCount reviews'),
                  style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            ]),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                icon: Icon(mine == null ? Icons.rate_review_rounded : Icons.edit_rounded, size: 20),
                label: Text(mine == null ? _t(context, 'قيّم المنتج', 'Write a review') : _t(context, 'عدّل تقييمك', 'Edit your review')),
                onPressed: () {
                  if (me == null) {
                    context.push('/auth/login?redirect=${Uri.encodeComponent('/product/$productId')}');
                    return;
                  }
                  showReviewSheet(context, ref, productId: productId, existing: mine);
                },
              ),
            ),
          ]),
        ),
        if (mine != null) ...[
          const SizedBox(height: 10),
          _ReviewTile(review: mine, own: true),
        ],
        for (final r in others) ...[
          const SizedBox(height: 10),
          _ReviewTile(review: r, productId: productId),
        ],
      ]),
    );
  }
}

class _ReviewTile extends ConsumerWidget {
  const _ReviewTile({required this.review, this.own = false, this.productId});
  final Map<String, dynamic> review;
  final bool own;
  final String? productId;

  Future<void> _like(BuildContext context, WidgetRef ref) async {
    if (ref.read(currentUserProvider) == null) {
      context.push('/auth/login?redirect=${Uri.encodeComponent('/product/$productId')}');
      return;
    }
    try {
      HapticFeedback.selectionClick();
      final res = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('toggle_review_like', params: {'p_review': review['id']}) as Map);
      if (productId != null) ref.invalidate(productReviewsProvider(productId!));
      ref.invalidate(myReviewLikesProvider);
      if (context.mounted) await showLikeReward(context, res, review: true);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liked = ref.watch(myReviewLikesProvider).valueOrNull?.contains(review['id']) ?? false;
    final likes = (review['like_count'] as num?)?.toInt() ?? 0;
    final pending = review['status'] == 'pending';
    final when = DateTime.parse((review['updated_at'] ?? review['created_at']) as String).toLocal();
    final name = (review['author_name'] as String?)?.trim();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: own ? const Color(0xFFF0F8FF) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: own ? BrandColors.electric.withValues(alpha: 0.35) : BrandColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: BrandColors.navy,
            child: Text((name?.isNotEmpty == true ? name! : 'M').characters.first.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(own ? _t(context, 'تقييمك', 'Your review') : (name?.isNotEmpty == true ? name! : _t(context, 'عميل', 'Customer')),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                if (review['verified_purchase'] == true) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.verified_rounded, size: 15, color: BrandColors.success),
                  const SizedBox(width: 2),
                  Text(_t(context, 'مشتري مؤكد', 'Verified buyer'), style: const TextStyle(color: BrandColors.success, fontSize: 11.5, fontWeight: FontWeight.w700)),
                ],
              ]),
              Text(DateFormat.yMMMd(context.lang).format(when), style: const TextStyle(color: BrandColors.gray, fontSize: 11.5)),
            ]),
          ),
          StarRating(value: (review['rating'] as num).toDouble(), size: 15),
        ]),
        if ((review['comment'] as String?)?.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(review['comment'] as String, style: const TextStyle(height: 1.5)),
        ],
        if (!own && review['status'] == 'published') ...[
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: liked ? BrandColors.electric : BrandColors.gray,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: Icon(liked ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined, size: 18),
              label: Text(likes > 0 ? '$likes' : _t(context, 'مفيد', 'Helpful')),
              onPressed: () => _like(context, ref),
            ),
          ),
        ] else if (own && likes > 0) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.thumb_up_alt_rounded, size: 16, color: BrandColors.electric),
            const SizedBox(width: 6),
            Text(_t(context, '$likes لايك على تقييمك', '$likes likes on your review'), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
          ]),
        ],
        if (own && pending) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.hourglass_top_rounded, size: 15, color: BrandColors.warning),
            const SizedBox(width: 6),
            Expanded(
              child: Text(_t(context, 'قيد المراجعة — هيتثبت بعد ما الفريق يراجعه.', 'Under review — it will be published after our team checks it.'),
                  style: const TextStyle(color: BrandColors.warning, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ]),
        ],
      ]),
    );
  }
}

/// Bottom sheet: tap 1–5 stars, optional comment, "publish". The server decides right away:
/// published, or "under review" when the language filter flags it.
Future<void> showReviewSheet(BuildContext context, WidgetRef ref, {required String productId, Map<String, dynamic>? existing}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ReviewSheet(productId: productId, existing: existing),
    );

class _ReviewSheet extends ConsumerStatefulWidget {
  const _ReviewSheet({required this.productId, this.existing});
  final String productId;
  final Map<String, dynamic>? existing;
  @override
  ConsumerState<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends ConsumerState<_ReviewSheet> {
  late int _stars = (widget.existing?['rating'] as num?)?.toInt() ?? 0;
  late final _comment = TextEditingController(text: widget.existing?['comment'] as String? ?? '');
  bool _busy = false;
  String? _error;

  static const _labelsAr = ['', 'وحش', 'مش أحسن حاجة', 'كويس', 'حلو جدًا', 'ممتاز'];
  static const _labelsEn = ['', 'Poor', 'Fair', 'Good', 'Very good', 'Excellent'];

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(supabaseProvider).rpc('submit_review',
          params: {'p_product_id': widget.productId, 'p_rating': _stars, 'p_comment': _comment.text.trim().isEmpty ? null : _comment.text.trim()});
      final published = (res as Map)['status'] == 'published';
      ref.invalidate(productReviewsProvider(widget.productId));
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final msg = published
          ? _t(context, 'تم قبول تقييمك وتثبيته، شكرًا ليك! ✅', 'Your review is published — thank you! ✅')
          : _t(context, 'تقييمك قيد المراجعة وهيتثبت بعد ما الفريق يراجعه.', 'Your review is under review and will be published after a check.');
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3), persist: false));
    } catch (e) {
      if (mounted && isAccountPendingError(e)) {
        Navigator.of(context).maybePop();
        showAccountPendingSheet(context);
      } else if (mounted) {
        setState(() => _error = friendlyError(context, e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_t(context, 'قيّم المنتج', 'Rate this product'),
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 1; i <= 5; i++)
                GestureDetector(
                  onTap: _busy
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          setState(() => _stars = i);
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: AnimatedScale(
                      scale: _stars == i ? 1.25 : 1,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      child: Icon(_stars >= i ? Icons.star_rounded : Icons.star_outline_rounded,
                          size: 44, color: _stars >= i ? const Color(0xFFFFB400) : BrandColors.border),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              _stars == 0 ? _t(context, 'اختار من نجمة لـ 5 نجوم', 'Choose 1 to 5 stars') : (ar ? _labelsAr[_stars] : _labelsEn[_stars]),
              key: ValueKey(_stars),
              textAlign: TextAlign.center,
              style: TextStyle(color: _stars == 0 ? BrandColors.gray : BrandColors.navy, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _comment,
            maxLines: 4,
            maxLength: 1000,
            decoration: InputDecoration(hintText: _t(context, 'اكتب رأيك في المنتج (اختياري)…', 'Tell others what you think (optional)…')),
          ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!, style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 10),
          FilledButton.icon(
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : const Icon(Icons.push_pin_rounded),
            label: Text(_t(context, 'تثبيت التقييم', 'Publish review')),
            onPressed: (_stars == 0 || _busy) ? null : _submit,
          ),
          const SizedBox(height: 6),
          Text(
            _t(context, 'التقييمات اللي فيها ألفاظ غير لائقة أو أرقام تليفونات بتتراجع قبل ما تتنشر.',
                'Reviews with offensive words or phone numbers are checked before publishing.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: BrandColors.gray, fontSize: 11.5),
          ),
        ]),
      ),
    );
  }
}

// keep showSnack import used for callers that want the shared style
void showReviewSnack(BuildContext context, String msg) => showSnack(context, msg);
