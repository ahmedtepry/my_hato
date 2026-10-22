import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/motion.dart';
import '../../shared/product_card.dart';
import '../../shared/states.dart';
import 'catalog_repository.dart';

/// Phones / Accessories / Used catalog, "see all" lists and search results.
/// Sorting, filters and search are all applied server-side together, with
/// paginated lazy loading.
class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key, this.kind, this.initial, this.searchMode = false});
  final String? kind;
  final CatalogQuery? initial;
  final bool searchMode;
  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  late CatalogQuery _q = (widget.initial ?? const CatalogQuery()).copyWith(kind: widget.kind);
  final _items = <Map<String, dynamic>>[];
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;
  int _page = 0;
  bool _loading = false;
  bool _done = false;
  bool _grid = true;
  Object? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
    });
    if (!widget.searchMode) _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    _items.clear();
    _page = 0;
    _done = false;
    _error = null;
    await _loadMore(force: true);
  }

  Future<void> _loadMore({bool force = false}) async {
    if ((_loading && !force) || _done) return;
    final id = ++_requestId;
    setState(() => _loading = true);
    try {
      final rows = await ref.read(catalogRepoProvider).products(_q, page: _page);
      if (id != _requestId || !mounted) return; // a newer query superseded this one
      setState(() {
        _items.addAll(rows);
        _page++;
        _done = rows.length < CatalogRepository.pageSize;
      });
    } catch (e) {
      if (mounted && id == _requestId) setState(() => _error = e);
    } finally {
      if (mounted && id == _requestId) setState(() => _loading = false);
    }
  }

  void _apply(CatalogQuery q) {
    setState(() => _q = q);
    _reload();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _apply(_q.copyWith(search: v)));
  }

  String _title(BuildContext context) => switch (widget.kind) {
        'phones' => context.tr('sec_phones'),
        'accessories' => context.tr('sec_accessories'),
        'used' => context.tr('sec_used'),
        'electronics' => context.tr('sec_electronics'),
        _ => context.tr('all'),
      };

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoriesProvider(widget.kind));
    return Scaffold(
      appBar: AppBar(
        title: widget.searchMode
            ? TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(hintText: context.tr('search_hint'), border: InputBorder.none, filled: false),
                onChanged: _onSearch,
              )
            : Text(_title(context)),
        actions: [
          IconButton(
            tooltip: _grid ? context.tr('list') : context.tr('grid'),
            icon: Icon(_grid ? Icons.view_list_rounded : Icons.grid_view_rounded),
            onPressed: () => setState(() => _grid = !_grid),
          ),
        ],
      ),
      body: Column(children: [
        // category chips
        if (!widget.searchMode)
          cats.maybeWhen(
            data: (list) => SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(context.tr('all')),
                      selected: _q.categoryId == null,
                      onSelected: (_) => _apply(_q.copyWith(categoryId: null)),
                    ),
                  ),
                  for (final c in list)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(context.pick(c, 'name')),
                        selected: _q.categoryId == c['id'],
                        onSelected: (_) => _apply(_q.copyWith(categoryId: c['id'] as String)),
                      ),
                    ),
                ],
              ),
            ),
            orElse: () => const SizedBox(height: 8),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                icon: const Icon(Icons.swap_vert_rounded, size: 20),
                label: Text(_sortLabel(context, _q.sort), overflow: TextOverflow.ellipsis),
                onPressed: _pickSort,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                icon: const Icon(Icons.tune_rounded, size: 20),
                label: Text(context.tr('filter')),
                onPressed: _openFilters,
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Expanded(child: _body(context)),
      ]),
    );
  }

  Widget _body(BuildContext context) {
    if (widget.searchMode && _q.search.isEmpty) {
      return EmptyState(icon: Icons.search_rounded, title: context.tr('search_hint'));
    }
    if (_items.isEmpty && _loading) return const SingleChildScrollView(child: ProductGridSkeleton());
    if (_items.isEmpty && _error != null) return ErrorView(error: _error!, onRetry: _reload);
    if (_items.isEmpty) {
      return EmptyState(icon: Icons.search_off_rounded, title: context.tr('no_results'), body: context.tr('no_results_body'));
    }
    final footer = _loading
        ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        : const SizedBox(height: 16);
    return RefreshIndicator(
      onRefresh: _reload,
      child: _grid
          ? CustomScrollView(controller: _scroll, slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.84),
                  delegate: SliverChildBuilderDelegate((_, i) => FadeSlideIn(id: 'g-${_items[i]['id']}', delay: FadeSlideIn.stagger(i % 8), child: ProductCard(p: _items[i])), childCount: _items.length),
                ),
              ),
              SliverToBoxAdapter(child: footer),
            ])
          : ListView.separated(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: _items.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => i == _items.length ? footer : FadeSlideIn(id: 'l-${_items[i]['id']}', delay: FadeSlideIn.stagger(i % 8), child: ProductCard(p: _items[i], listStyle: true)),
            ),
    );
  }

  String _sortLabel(BuildContext c, SortOption s) => switch (s) {
        SortOption.newest => c.tr('sort_newest'),
        SortOption.priceAsc => c.tr('sort_price_asc'),
        SortOption.priceDesc => c.tr('sort_price_desc'),
        SortOption.popular => c.tr('sort_popular'),
        SortOption.rating => c.tr('sort_rating'),
      };

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<SortOption>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final s in SortOption.values)
            RadioListTile<SortOption>(
              value: s,
              groupValue: _q.sort,
              title: Text(_sortLabel(c, s)),
              onChanged: (v) => Navigator.pop(c, v),
            ),
        ]),
      ),
    );
    if (picked != null) _apply(_q.copyWith(sort: picked));
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<CatalogQuery>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FilterSheet(initial: _q),
    );
    if (result != null) _apply(result);
  }
}

class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({required this.initial});
  final CatalogQuery initial;
  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late CatalogQuery _q = widget.initial;
  late final _min = TextEditingController(text: _q.minPriceMinor == null ? '' : '${_q.minPriceMinor! ~/ 100}');
  late final _max = TextEditingController(text: _q.maxPriceMinor == null ? '' : '${_q.maxPriceMinor! ~/ 100}');

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brands = ref.watch(brandsProvider).valueOrNull ?? const [];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(context.tr('brand'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: Text(context.tr('all')), selected: _q.brandId == null, onSelected: (_) => setState(() => _q = _q.copyWith(brandId: null))),
            for (final b in brands)
              ChoiceChip(
                label: Text(context.pick(b, 'name')),
                selected: _q.brandId == b['id'],
                onSelected: (_) => setState(() => _q = _q.copyWith(brandId: b['id'] as String)),
              ),
          ]),
          const SizedBox(height: 20),
          Text(context.tr('price_range'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _min, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.tr('min_price')))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _max, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.tr('max_price')))),
          ]),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: BrandColors.electric,
            title: Text(context.tr('in_stock_only')),
            value: _q.inStockOnly,
            onChanged: (v) => setState(() => _q = _q.copyWith(inStockOnly: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: BrandColors.electric,
            title: Text(context.tr('discounted_only')),
            value: _q.discountedOnly,
            onChanged: (v) => setState(() => _q = _q.copyWith(discountedOnly: v)),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context, CatalogQuery(kind: _q.kind, search: _q.search, sort: _q.sort)),
                child: Text(context.tr('reset')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  _q.copyWith(
                    minPriceMinor: _min.text.trim().isEmpty ? null : parseEgpToMinor(_min.text),
                    maxPriceMinor: _max.text.trim().isEmpty ? null : parseEgpToMinor(_max.text),
                  ),
                ),
                child: Text(context.tr('apply')),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
