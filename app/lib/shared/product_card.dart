import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/l10n.dart';
import '../core/money.dart';
import '../core/supabase_providers.dart';
import '../core/theme.dart';

class NetImage extends ConsumerWidget {
  const NetImage({super.key, required this.path, this.bucket = 'product-images', this.fit = BoxFit.cover});
  final String? path;
  final String bucket;
  final BoxFit fit;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = publicImageUrl(ref.watch(supabaseProvider), path, bucket: bucket);
    if (url.isEmpty) {
      return Container(color: BrandColors.offWhite, child: const Icon(Icons.smartphone_rounded, size: 40, color: BrandColors.border));
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      memCacheWidth: 600,
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

class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.p, this.listStyle = false});
  final Map<String, dynamic> p;
  final bool listStyle;

  @override
  Widget build(BuildContext context) {
    final discount = (p['discount_percent'] as num?)?.toInt() ?? 0;
    final inStock = p['in_stock'] == true;
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(fit: StackFit.expand, children: [
        Hero(tag: 'p-${p['id']}', child: NetImage(path: p['thumb_path'] as String?)),
        if (discount > 0)
          PositionedDirectional(
            top: 8,
            start: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: BrandColors.electric, borderRadius: BorderRadius.circular(8)),
              child: Text('-$discount%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          ),
        if (!inStock)
          Container(
            color: Colors.white.withOpacity(0.6),
            alignment: Alignment.center,
            child: Text(context.tr('out_of_stock'), style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.error)),
          ),
      ]),
    );
    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(context.pick(p, 'name'), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, height: 1.3)),
      const SizedBox(height: 6),
      PriceBlock(price: (p['price_minor'] as num).toInt(), compareAt: (p['compare_at_price_minor'] as num?)?.toInt()),
    ]);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/product/${p['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: listStyle
              ? Row(children: [SizedBox(width: 96, height: 96, child: image), const SizedBox(width: 12), Expanded(child: info)])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  AspectRatio(aspectRatio: 1, child: image),
                  const SizedBox(height: 10),
                  info,
                ]),
        ),
      ),
    );
  }
}

class HorizontalProducts extends StatelessWidget {
  const HorizontalProducts({super.key, required this.items});
  final List<Map<String, dynamic>> items;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 268,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => SizedBox(width: 165, child: ProductCard(p: items[i])),
        ),
      );
}
