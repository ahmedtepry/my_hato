import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/product_card.dart';
import '../../shared/states.dart';
import '../cart/cart_repository.dart';
import 'catalog_repository.dart';

class ProductDetailsScreen extends ConsumerStatefulWidget {
  const ProductDetailsScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends ConsumerState<ProductDetailsScreen> {
  String? _variantId;
  int _qty = 1;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(catalogRepoProvider).recordView(widget.id).catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(productProvider(widget.id));
    return data.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: ErrorView(error: e, onRetry: () => ref.invalidate(productProvider(widget.id)))),
      data: (p) {
        if (p == null) {
          return Scaffold(appBar: AppBar(), body: EmptyState(icon: Icons.search_off, title: context.tr('err_unavailable')));
        }
        return _content(context, p);
      },
    );
  }

  Widget _content(BuildContext context, Map<String, dynamic> p) {
    final images = List<Map<String, dynamic>>.from(p['product_images'] ?? [])..sort((a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int));
    final frames = List<Map<String, dynamic>>.from(p['product_360_assets'] ?? [])..sort((a, b) => (a['frame_index'] as int).compareTo(b['frame_index'] as int));
    final variants = List<Map<String, dynamic>>.from(p['product_variants'] ?? []).where((v) => v['is_active'] == true).toList()
      ..sort((a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int));
    final specs = List<Map<String, dynamic>>.from(p['product_specifications'] ?? [])..sort((a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int));
    if (_variantId == null && variants.isNotEmpty) _variantId = variants.first['id'] as String;
    final variant = variants.where((v) => v['id'] == _variantId).firstOrNull;
    final price = ((variant?['price_minor'] ?? p['price_minor']) as num).toInt();
    final compare = (p['compare_at_price_minor'] as num?)?.toInt();
    final stock = ((variant?['stock_quantity'] ?? p['stock_quantity']) as num).toInt();
    final favIds = ref.watch(favoriteIdsProvider).valueOrNull ?? const <String>{};
    final isFav = favIds.contains(p['id']);
    final signedIn = ref.watch(currentUserProvider) != null;
    final discount = compare != null && compare > price ? ((compare - price) * 100 / compare).round() : 0;

    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(
          tooltip: context.tr('share'),
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: () => Share.share('${context.pick(p, 'name')} — ${formatEgp(price, context.lang)}\nMy Hatō'),
        ),
        IconButton(
          icon: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFav ? BrandColors.error : null),
          onPressed: () async {
            if (!signedIn) {
              context.push('/auth/login?redirect=${Uri.encodeComponent('/product/${widget.id}')}');
              return;
            }
            await ref.read(catalogRepoProvider).setFavorite(p['id'] as String, !isFav);
            ref.invalidate(favoriteIdsProvider);
          },
        ),
      ]),
      body: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
        _Gallery(productId: p['id'] as String, images: images, frames: frames),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (p['brands'] != null)
              Text(context.pick(p['brands'] as Map<String, dynamic>, 'name'), style: const TextStyle(color: BrandColors.electric, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(context.pick(p, 'name'), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('SKU: ${variant?['sku'] ?? p['sku']}${p['model'] != null ? '  •  ${p['model']}' : ''}', style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            const SizedBox(height: 12),
            Row(children: [
              PriceBlock(price: price, compareAt: compare, large: true),
              const SizedBox(width: 8),
              if (discount > 0) StatusChip(label: '-$discount%'),
            ]),
            const SizedBox(height: 8),
            StatusChip(
              label: stock <= 0 ? context.tr('out_of_stock') : stock <= 5 ? context.tr('only_left', {'n': '$stock'}) : context.tr('in_stock'),
              color: stock <= 0 ? BrandColors.error : stock <= 5 ? BrandColors.warning : BrandColors.success,
            ),
            if (variants.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(context.tr('color_variant'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in variants)
                  ChoiceChip(
                    avatar: v['color_hex'] != null
                        ? CircleAvatar(backgroundColor: Color(int.parse('FF${(v['color_hex'] as String).replaceAll('#', '')}', radix: 16)))
                        : null,
                    label: Text(context.pick(v, 'name')),
                    selected: _variantId == v['id'],
                    onSelected: (_) => setState(() {
                      _variantId = v['id'] as String;
                      _qty = 1;
                    }),
                  ),
              ]),
            ],
            const SizedBox(height: 20),
            Row(children: [
              Text(context.tr('quantity'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              _QtyStepper(value: _qty, max: stock.clamp(1, 20).toInt(), onChanged: (v) => setState(() => _qty = v)),
            ]),
            const SizedBox(height: 16),
            _InfoTile(icon: Icons.local_shipping_outlined, text: context.tr('delivery_info')),
            if ((context.pick(p, 'warranty')).isNotEmpty) _InfoTile(icon: Icons.verified_user_outlined, text: context.pick(p, 'warranty')),
            if (context.pick(p, 'description').isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(context.tr('description'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(context.pick(p, 'description'), style: const TextStyle(height: 1.6)),
            ],
            if (specs.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(context.tr('specifications'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Card(
                child: Column(children: [
                  for (final s in specs)
                    ListTile(dense: true, title: Text(context.pick(s, 'label'), style: const TextStyle(color: BrandColors.gray)), trailing: Text(context.pick(s, 'value'), style: const TextStyle(fontWeight: FontWeight.w700))),
                ]),
              ),
            ],
          ]),
        ),
        _Related(categoryId: p['category_id'] as String, excludeId: p['id'] as String),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            icon: _adding ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.add_shopping_cart_rounded),
            label: Text('${context.tr('add_to_cart')} • ${formatEgp(price * _qty, context.lang)}'),
            onPressed: (stock <= 0 || _adding)
                ? null
                : () async {
                    setState(() => _adding = true);
                    try {
                      await ref.read(cartProvider.notifier).add(p['id'] as String, _variantId, _qty);
                      if (!context.mounted) return;
                      showSnack(context, context.tr('added_to_cart'),
                          action: SnackBarAction(label: context.tr('nav_cart'), textColor: BrandColors.electric, onPressed: () => context.go('/cart')));
                    } catch (e) {
                      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                    } finally {
                      if (mounted) setState(() => _adding = false);
                    }
                  },
          ),
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Icon(icon, color: BrandColors.electric, size: 20), const SizedBox(width: 10), Expanded(child: Text(text))]),
      );
}

class _QtyStepper extends StatelessWidget {
  const _QtyStepper({required this.value, required this.max, required this.onChanged, this.min = 1});
  final int value, max, min;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(border: Border.all(color: BrandColors.border), borderRadius: BorderRadius.circular(12), color: Colors.white),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.remove_rounded), onPressed: value > min ? () => onChanged(value - 1) : null),
          Text('$value', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          IconButton(icon: const Icon(Icons.add_rounded), onPressed: value < max ? () => onChanged(value + 1) : null),
        ]),
      );
}

class _Gallery extends StatefulWidget {
  const _Gallery({required this.productId, required this.images, required this.frames});
  final String productId;
  final List<Map<String, dynamic>> images;
  final List<Map<String, dynamic>> frames;
  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _i = 0;
  // A true 360° view is offered only when a real frame sequence was uploaded.
  bool get _has360 => widget.frames.length >= 12;

  @override
  Widget build(BuildContext context) {
    final imgs = widget.images;
    return Column(children: [
      AspectRatio(
        aspectRatio: 1,
        child: imgs.isEmpty
            ? const NetImage(path: null)
            : PageView.builder(
                itemCount: imgs.length,
                onPageChanged: (i) => setState(() => _i = i),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    fullscreenDialog: true,
                    builder: (_) => _FullscreenGallery(images: imgs, initial: i),
                  )),
                  child: i == 0
                      ? Hero(tag: 'p-${widget.productId}', child: NetImage(path: imgs[i]['storage_path'] as String, fit: BoxFit.contain))
                      : NetImage(path: imgs[i]['storage_path'] as String, fit: BoxFit.contain),
                ),
              ),
      ),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < imgs.length; i++)
          Container(
            margin: const EdgeInsets.all(3),
            width: i == _i ? 18 : 7,
            height: 7,
            decoration: BoxDecoration(color: i == _i ? BrandColors.electric : BrandColors.border, borderRadius: BorderRadius.circular(6)),
          ),
      ]),
      if (_has360)
        TextButton.icon(
          icon: const Icon(Icons.threesixty_rounded),
          label: Text(context.tr('view_360')),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => Viewer360(frames: widget.frames))),
        ),
    ]);
  }
}

class _FullscreenGallery extends StatelessWidget {
  const _FullscreenGallery({required this.images, required this.initial});
  final List<Map<String, dynamic>> images;
  final int initial;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: PageView.builder(
          controller: PageController(initialPage: initial),
          itemCount: images.length,
          itemBuilder: (_, i) => InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(child: NetImage(path: images[i]['storage_path'] as String, fit: BoxFit.contain)),
          ),
        ),
      );
}

/// Drag horizontally to rotate through uploaded 360° frames.
class Viewer360 extends ConsumerStatefulWidget {
  const Viewer360({super.key, required this.frames});
  final List<Map<String, dynamic>> frames;
  @override
  ConsumerState<Viewer360> createState() => _Viewer360State();
}

class _Viewer360State extends ConsumerState<Viewer360> {
  double _pos = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final db = ref.read(supabaseProvider);
    for (final f in widget.frames) {
      precacheImage(NetworkImage(publicImageUrl(db, f['storage_path'] as String, bucket: 'product-360')), context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.frames.length;
    final idx = (_pos.round() % n + n) % n;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('view_360'))),
      body: GestureDetector(
        onHorizontalDragUpdate: (d) => setState(() => _pos -= d.delta.dx / 8),
        child: Column(children: [
          Expanded(child: Center(child: NetImage(path: widget.frames[idx]['storage_path'] as String, bucket: 'product-360', fit: BoxFit.contain))),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.swipe_rounded, color: BrandColors.gray),
              const SizedBox(width: 8),
              Text(context.tr('drag_to_rotate'), style: const TextStyle(color: BrandColors.gray)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Related extends ConsumerWidget {
  const _Related({required this.categoryId, required this.excludeId});
  final String categoryId, excludeId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(productsSectionProvider(CatalogQuery(categoryId: categoryId, sort: SortOption.popular)));
    final items = (data.valueOrNull ?? const []).where((p) => p['id'] != excludeId).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(context.tr('related'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      ),
      HorizontalProducts(items: items),
    ]);
  }
}
