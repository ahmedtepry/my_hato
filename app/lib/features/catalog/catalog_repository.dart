import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

enum SortOption { newest, priceAsc, priceDesc, popular, rating }

class CatalogQuery {
  const CatalogQuery({
    this.kind,
    this.categoryId,
    this.brandId,
    this.search = '',
    this.minPriceMinor,
    this.maxPriceMinor,
    this.inStockOnly = false,
    this.discountedOnly = false,
    this.featuredOnly = false,
    this.sort = SortOption.newest,
  });
  final String? kind; // phones | accessories | used
  final String? categoryId;
  final String? brandId;
  final String search;
  final int? minPriceMinor;
  final int? maxPriceMinor;
  final bool inStockOnly;
  final bool discountedOnly;
  final bool featuredOnly;
  final SortOption sort;

  CatalogQuery copyWith({
    String? kind,
    Object? categoryId = _keep,
    Object? brandId = _keep,
    String? search,
    Object? minPriceMinor = _keep,
    Object? maxPriceMinor = _keep,
    bool? inStockOnly,
    bool? discountedOnly,
    bool? featuredOnly,
    SortOption? sort,
  }) =>
      CatalogQuery(
        kind: kind ?? this.kind,
        categoryId: identical(categoryId, _keep) ? this.categoryId : categoryId as String?,
        brandId: identical(brandId, _keep) ? this.brandId : brandId as String?,
        search: search ?? this.search,
        minPriceMinor: identical(minPriceMinor, _keep) ? this.minPriceMinor : minPriceMinor as int?,
        maxPriceMinor: identical(maxPriceMinor, _keep) ? this.maxPriceMinor : maxPriceMinor as int?,
        inStockOnly: inStockOnly ?? this.inStockOnly,
        discountedOnly: discountedOnly ?? this.discountedOnly,
        featuredOnly: featuredOnly ?? this.featuredOnly,
        sort: sort ?? this.sort,
      );

  @override
  bool operator ==(Object o) =>
      o is CatalogQuery &&
      o.kind == kind &&
      o.categoryId == categoryId &&
      o.brandId == brandId &&
      o.search == search &&
      o.minPriceMinor == minPriceMinor &&
      o.maxPriceMinor == maxPriceMinor &&
      o.inStockOnly == inStockOnly &&
      o.discountedOnly == discountedOnly &&
      o.featuredOnly == featuredOnly &&
      o.sort == sort;

  @override
  int get hashCode => Object.hash(kind, categoryId, brandId, search, minPriceMinor, maxPriceMinor, inStockOnly,
      discountedOnly, featuredOnly, sort);
}

const _keep = Object();

/// Strips characters that have meaning in PostgREST filter syntax.
String sanitizeSearch(String q) => q.replaceAll(RegExp(r'[,()%*\\.:"]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

class CatalogRepository {
  CatalogRepository(this._db);
  final SupabaseClient _db;
  static const pageSize = 20;

  Future<List<Map<String, dynamic>>> categories({String? kind}) async {
    var q = _db.from('categories').select().eq('is_active', true);
    if (kind != null) q = q.eq('kind', kind);
    return List<Map<String, dynamic>>.from(await q.order('sort_order'));
  }

  Future<List<Map<String, dynamic>>> brands() async =>
      List<Map<String, dynamic>>.from(await _db.from('brands').select().eq('is_active', true).order('sort_order'));

  Future<List<Map<String, dynamic>>> products(CatalogQuery q, {int page = 0}) async {
    var f = _db.from('catalog_products').select();
    if (q.categoryId != null) {
      f = f.eq('category_id', q.categoryId!);
    } else if (q.kind != null) {
      final ids = (await categories(kind: q.kind)).map((c) => c['id'] as String).toList();
      if (ids.isEmpty) return [];
      f = f.inFilter('category_id', ids);
    }
    if (q.brandId != null) f = f.eq('brand_id', q.brandId!);
    if (q.minPriceMinor != null) f = f.gte('price_minor', q.minPriceMinor!);
    if (q.maxPriceMinor != null) f = f.lte('price_minor', q.maxPriceMinor!);
    if (q.inStockOnly) f = f.eq('in_stock', true);
    if (q.discountedOnly) f = f.gt('discount_percent', 0);
    if (q.featuredOnly) f = f.eq('is_featured', true);
    final s = sanitizeSearch(q.search);
    if (s.isNotEmpty) {
      // every word must match somewhere (name, brand, model, SKU): "جراب اوبو A73" finds the Oppo A73 case
      for (final w in s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(5)) {
        f = f.or([
          'name_ar.ilike.*$w*', 'name_en.ilike.*$w*', 'model.ilike.*$w*', 'sku.ilike.*$w*',
          'brand_name_ar.ilike.*$w*', 'brand_name_en.ilike.*$w*', 'keywords.cs.{${w.toLowerCase()}}',
        ].join(','));
      }
    }
    final from = page * pageSize;
    final ordered = switch (q.sort) {
      SortOption.priceAsc => f.order('price_minor', ascending: true),
      SortOption.priceDesc => f.order('price_minor', ascending: false),
      SortOption.popular => f.order('sold_count', ascending: false),
      SortOption.rating => f.order('rating_avg', ascending: false),
      SortOption.newest => f.order('published_at', ascending: false),
    };
    // secondary key keeps pagination stable
    return List<Map<String, dynamic>>.from(await ordered.order('id').range(from, from + pageSize - 1));
  }

  Future<Map<String, dynamic>?> product(String id) => _db
      .from('products')
      .select('*, product_images(*), product_variants(*), product_specifications(*), product_360_assets(*), brands(*), categories(*)')
      .eq('id', id)
      .eq('status', 'published')
      .maybeSingle();

  Future<List<Map<String, dynamic>>> banners() async =>
      List<Map<String, dynamic>>.from(await _db.from('banners').select().order('sort_order'));

  Future<Map<String, dynamic>> publicSettings() async {
    final rows = await _db.from('application_settings').select('key, value');
    return {for (final r in rows) r['key'] as String: r['value']};
  }

  Future<void> recordView(String productId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    await _db.from('recently_viewed').upsert({'user_id': uid, 'product_id': productId, 'viewed_at': DateTime.now().toUtc().toIso8601String()});
  }

  Future<List<Map<String, dynamic>>> recentlyViewed() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await _db.from('recently_viewed').select('product_id').eq('user_id', uid).order('viewed_at', ascending: false).limit(10);
    final ids = rows.map((r) => r['product_id'] as String).toList();
    if (ids.isEmpty) return [];
    final products = List<Map<String, dynamic>>.from(await _db.from('catalog_products').select().inFilter('id', ids));
    products.sort((a, b) => ids.indexOf(a['id']).compareTo(ids.indexOf(b['id'])));
    return products;
  }

  Future<Set<String>> favoriteIds() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return {};
    final rows = await _db.from('product_favorites').select('product_id').eq('user_id', uid);
    return rows.map((r) => r['product_id'] as String).toSet();
  }

  Future<List<Map<String, dynamic>>> favorites() async {
    final ids = await favoriteIds();
    if (ids.isEmpty) return [];
    return List<Map<String, dynamic>>.from(await _db.from('catalog_products').select().inFilter('id', ids.toList()));
  }

  /// The heart is the product "like": the server saves it and pays the like reward (once per product, 3 a day).
  Future<Map<String, dynamic>> setFavorite(String productId, bool fav) async {
    final res = await _db.rpc('toggle_product_like', params: {'p_product': productId, 'p_like': fav});
    return Map<String, dynamic>.from(res as Map);
  }
}

final catalogRepoProvider = Provider((ref) => CatalogRepository(ref.watch(supabaseProvider)));

final categoriesProvider = FutureProvider.family<List<Map<String, dynamic>>, String?>(
    (ref, kind) => ref.watch(catalogRepoProvider).categories(kind: kind));
final brandsProvider = FutureProvider((ref) => ref.watch(catalogRepoProvider).brands());
final bannersProvider = FutureProvider((ref) => ref.watch(catalogRepoProvider).banners());
final publicSettingsProvider = FutureProvider((ref) => ref.watch(catalogRepoProvider).publicSettings());
final productProvider = FutureProvider.family<Map<String, dynamic>?, String>((ref, id) => ref.watch(catalogRepoProvider).product(id));
final productsSectionProvider =
    FutureProvider.family<List<Map<String, dynamic>>, CatalogQuery>((ref, q) => ref.watch(catalogRepoProvider).products(q));
final recentlyViewedProvider = FutureProvider((ref) {
  ref.watch(currentUserProvider);
  return ref.watch(catalogRepoProvider).recentlyViewed();
});
final favoriteIdsProvider = FutureProvider((ref) {
  ref.watch(currentUserProvider);
  return ref.watch(catalogRepoProvider).favoriteIds();
});
final favoritesProvider = FutureProvider((ref) {
  ref.watch(favoriteIdsProvider);
  return ref.watch(catalogRepoProvider).favorites();
});

/// Whether the "Used / مستعمل" section is live. false => Coming soon page.
final usedEnabledProvider = FutureProvider<bool>((ref) async {
  final s = await ref.watch(publicSettingsProvider.future);
  return s['used_devices_enabled'] == true;
});
