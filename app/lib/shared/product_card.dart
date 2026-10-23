import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import '../features/cart/cart_repository.dart';
import 'cart_toast.dart';
import 'motion.dart';
import 'press_scale.dart';

import '../core/l10n.dart';
import '../core/money.dart';
import '../core/supabase_providers.dart';
import '../core/theme.dart';

class NetImage extends ConsumerWidget {
  const NetImage({super.key, required this.path, this.bucket = 'product-images', this.fit = BoxFit.cover, this.thumb = false});
  final String? path;
  final String bucket;
  final BoxFit fit;

  /// Small tiles: ask for a ~480px image instead of 900px (4× fewer pixels to download and decode).
  final bool thumb;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var url = publicImageUrl(ref.watch(supabaseProvider), path, bucket: bucket);
    if (thumb && url.contains('images.unsplash.com')) {
      url = url.replaceAll('w=900', 'w=480').replaceAll('h=900', 'h=480').replaceAll('q=80', 'q=70');
    }
    if (url.isEmpty) {
      return Container(color: BrandColors.offWhite, child: const Icon(Icons.smartphone_rounded, size: 40, color: BrandColors.border));
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      memCacheWidth: thumb ? 420 : 900,
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: const Duration(milliseconds: 100),
      placeholder: (_, __) => Container(color: BrandColors.offWhite),
      errorWidget: (_, __, ___) => Container(color: BrandColors.offWhite, child: const Icon(Icons.broken_image_outlined, color: BrandColors.gray)),
    );
  }
}

class PriceBlock extends StatelessWidget {
  const PriceBlock({super.key, required this.price, this.compareAt, this.large = false});
  final int price;
  final int? compareAt;
  final bool large;
  @override
  Widget build(BuildContext context) {
    final lang = context.lang;
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
      Text(formatEgp(price, lang),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: large ? 22 : 15, color: BrandColors.navy)),
      if (compareAt != null && compareAt! > price)
        Text(formatEgp(compareAt, lang),
            style: TextStyle(
                decoration: TextDecoration.lineThrough, color: BrandColors.gray, fontSize: large ? 14 : 12)),
    ]);
  }
}

/// Product tile: edge-to-edge photo with discount badge and a quick "add to cart" button,
/// compact name and price underneath — about 6 tiles fit on a phone screen.
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.p, this.listStyle = false});
  final Map<String, dynamic> p;
  final bool listStyle;

  @override
  Widget build(BuildContext context) {
    final discount = (p['discount_percent'] as num?)?.toInt() ?? 0;
    final inStock = p['in_stock'] == true;
    final price = (p['price_minor'] as num).toInt();
    final compare = (p['compare_at_price_minor'] as num?)?.toInt();
    final brand = (p['brand_name_${context.lang}'] ?? p['brand_name_ar']) as String?;
    final model = p['model'] as String?;
    final fits = [if (brand != null && brand.isNotEmpty) brand, if (model != null && model.isNotEmpty) model].join(' · ');
    final name = Text(context.pick(p, 'name'),
        maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.3));
    final rating = (p['rating_avg'] as num?)?.toDouble() ?? 0;
    final ratingCount = (p['rating_count'] as num?)?.toInt() ?? 0;
    final priceRow = Row(children: [
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(formatEgp(price, context.lang), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5, color: BrandColors.navy)),
        ),
      ),
      if (ratingCount > 0) ...[
        const Spacer(),
        const Icon(Icons.star_rounded, size: 14, color: Color(0xFFFFB400)),
        Text(rating.toStringAsFixed(1), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
      ],
      if (ratingCount == 0 && compare != null && compare > price) ...[
        const SizedBox(width: 6),
        Flexible(
          child: Text(formatEgp(compare, context.lang),
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: const TextStyle(decoration: TextDecoration.lineThrough, color: BrandColors.gray, fontSize: 11.5)),
        ),
      ],
    ]);

    final photo = Stack(fit: StackFit.expand, children: [
      Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF4F7FB), Color(0xFFE9EEF6)])),
      ),
      // No Hero here: the same product appears in several home sections at once, and duplicate hero
      // tags break the page transition (the screen freezes half-faded). See test/no_hero_test.dart.
      NetImage(path: p['thumb_path'] as String?, thumb: true),
      if (discount > 0)
        PositionedDirectional(
          top: 8,
          start: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFFF5B5B), Color(0xFFFF8A3D)]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('-$discount%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11.5)),
          ),
        ),
      if (!inStock)
        Container(
          color: Colors.white.withValues(alpha: 0.65),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: BrandColors.navy, borderRadius: BorderRadius.circular(20)),
            child: Text(context.tr('out_of_stock'), style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white, fontSize: 12)),
          ),
        ),
      if (inStock) PositionedDirectional(end: 8, bottom: 8, child: _QuickAdd(productId: p['id'] as String)),
    ]);

    void open() => context.push('/product/${p['id']}');

    if (listStyle) {
      return PressScale(
        child: _Shell(
          onTap: open,
          child: Row(children: [
            SizedBox(width: 108, height: 108, child: photo),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [name, const SizedBox(height: 8), priceRow]),
              ),
            ),
          ]),
        ),
      );
    }
    return RepaintBoundary(
      child: PressScale(
      child: _Shell(
        onTap: open,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: photo),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (fits.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(fits, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrandColors.electric, fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
              SizedBox(height: fits.isNotEmpty ? 18 : 36, child: Align(alignment: AlignmentDirectional.topStart, child: fits.isNotEmpty ? Text(context.pick(p, 'name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)) : name)),
              const SizedBox(height: 4),
              priceRow,
            ]),
          ),
        ]),
      ),
    ),
    );
  }
}

/// White rounded tile with a soft shadow instead of a flat grey border.
class _Shell extends StatelessWidget {
  const _Shell({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: BrandColors.navy.withValues(alpha: 0.06), blurRadius: 6, offset: const Offset(0, 3))],
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: child),
        ),
      );
}

/// Round "+" on the photo: adds one to the cart without opening the product (works for guests too).
class _QuickAdd extends ConsumerStatefulWidget {
  const _QuickAdd({required this.productId});
  final String productId;
  @override
  ConsumerState<_QuickAdd> createState() => _QuickAddState();
}

class _QuickAddState extends ConsumerState<_QuickAdd> {
  bool _busy = false;
  bool _done = false;

  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(cartProvider.notifier).add(widget.productId, null, 1);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      showAddedToCart(context);
      setState(() => _done = true);
      await Future.delayed(const Duration(milliseconds: 1400));
      if (mounted) setState(() => _done = false);
    } catch (e) {
      // products with options (colour / storage) are added from their page
      if (mounted) context.push('/product/${widget.productId}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
        color: _done ? BrandColors.success : BrandColors.navy,
        shape: const CircleBorder(),
        elevation: 3,
        shadowColor: Colors.black38,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _add,
          child: SizedBox.square(
            dimension: 34,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: _busy
                  ? const Padding(
                      key: ValueKey('busy'), padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_done ? Icons.check_rounded : Icons.add_rounded, key: ValueKey(_done), color: Colors.white, size: 20),
            ),
          ),
        ),
      );
}

class HorizontalProducts extends StatelessWidget {
  const HorizontalProducts({super.key, required this.items});
  final List<Map<String, dynamic>> items;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 236,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          clipBehavior: Clip.none,
          scrollDirection: Axis.horizontal,
          itemCount: items.length > 10 ? 10 : items.length, // home rows: 10 tiles, "see all" for the rest
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => FadeSlideIn(id: 'h-${items[i]['id']}', delay: FadeSlideIn.stagger(i), child: SizedBox(width: 158, child: ProductCard(p: items[i]))),
        ),
      );
}
