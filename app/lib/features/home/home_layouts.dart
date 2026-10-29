// "طريقة عرض الواجهة": how the products on the customers' home screen are laid out. The OWNER picks one in the Windows team app and it applies to
// every customer at once (stored on the server; the phone app only reads it). The default is the original look until the owner picks another.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/motion.dart';
import '../../shared/product_card.dart';

enum HomeLayout { current, compact, list, tri, stagger, rails, hero, shop, toggle }

HomeLayout homeLayoutFromId(Object? id) => HomeLayout.values.firstWhere((l) => l.name == id, orElse: () => HomeLayout.current);

/// Names and one-line descriptions, for the owner's picker.
const homeLayoutInfo = <HomeLayout, (String, String, String, String)>{
  HomeLayout.current: ('الشكل الحالي', 'Current look', 'صف أفقي بكروت كبيرة، بيظهر منتجين تقريبًا', 'A horizontal row of big cards, about two products visible'),
  HomeLayout.compact: ('شبكة مدمجة', 'Compact grid', 'عمودين بصورة أقصر، حوالي 6 منتجات في الشاشة', 'Two columns with shorter photos, about 6 products'),
  HomeLayout.list: ('قائمة صفوف', 'Rows', 'صورة صغيرة جنب الاسم والسعر، أسهل للمقارنة', 'A small photo beside name and price, easy to compare'),
  HomeLayout.tri: ('ثلاث أعمدة', 'Three columns', 'تصفح سريع، حوالي 9 منتجات في الشاشة', 'Fast browsing, about 9 products'),
  HomeLayout.stagger: ('شبكة متدرّجة', 'Staggered grid', 'عمودين بصور بأطوال مختلفة، شكل عصري', 'Two columns with varied heights, a modern look'),
  HomeLayout.rails: ('شرائح أفقية صغيرة', 'Small rails', 'نفس الصفوف الأفقية بكروت أصغر، منتجات أكتر في كل صف', 'The same horizontal rows with smaller cards'),
  HomeLayout.hero: ('منتج مميز ومصغّرات', 'Hero + minis', 'منتج كبير فوق وتحته مصغّرات', 'One big product with small ones below'),
  HomeLayout.shop: ('أسلوب المتاجر', 'Store tabs', 'تبويبات (مميزة، الأكثر مبيعًا، الأحدث، عروض) وشبكة واحدة', 'Tabs (featured, best sellers, new, deals) over one grid'),
  HomeLayout.toggle: ('شبكة وزرار تبديل', 'Grid with switch', 'شبكة مدمجة وزرار يبدّل لقائمة، والعميل بيفتكر اختياره', 'A compact grid with a switch to rows; the customer\'s choice is remembered'),
};

/// The layout the owner picked. Anything unexpected (offline, an older server) keeps the original look.
final homeLayoutProvider = FutureProvider<HomeLayout>((ref) async {
  try {
    return homeLayoutFromId(await ref.watch(supabaseProvider).rpc('storefront_layout_get'));
  } catch (_) {
    return HomeLayout.current;
  }
});

/// The customer's own grid/rows choice for the "grid with switch" layout (remembered on the phone).
class _RowsMode extends StateNotifier<bool> {
  _RowsMode() : super(false) {
    SharedPreferences.getInstance().then((p) {
      final v = p.getBool('home_rows_mode');
      if (v != null && mounted) state = v;
    }).catchError((_) {});
  }
  void set(bool rows) {
    state = rows;
    SharedPreferences.getInstance().then((p) => p.setBool('home_rows_mode', rows)).catchError((_) => false);
  }
}

final _rowsModeProvider = StateNotifierProvider<_RowsMode, bool>((ref) => _RowsMode());

/// The products of one home section, drawn in the owner's chosen layout.
class HomeProducts extends ConsumerWidget {
  const HomeProducts({super.key, required this.items, required this.layout});
  final List<Map<String, dynamic>> items;
  final HomeLayout layout;

  static Widget _grid(List<Map<String, dynamic>> items, int cols, double aspect, {double gap = 10}) => GridView.count(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: cols,
        childAspectRatio: aspect,
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        children: [for (var i = 0; i < items.length; i++) FadeSlideIn(id: 'g-$cols-${items[i]['id']}', delay: FadeSlideIn.stagger(i), child: ProductCard(p: items[i]))],
      );

  static Widget _rows(List<Map<String, dynamic>> items) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(children: [for (final p in items) Padding(padding: const EdgeInsets.only(bottom: 8), child: ProductCard(p: p, listStyle: true))]),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (layout) {
      case HomeLayout.current:
        return HorizontalProducts(items: items);
      case HomeLayout.compact:
        return _grid(items.take(6).toList(), 2, 0.9);
      case HomeLayout.list:
        return _rows(items.take(5).toList());
      case HomeLayout.tri:
        return _grid(items.take(9).toList(), 3, 0.58, gap: 8);
      case HomeLayout.stagger:
        final l = <Widget>[], r = <Widget>[];
        final src = items.take(6).toList();
        for (var i = 0; i < src.length; i++) {
          final tall = ((i ~/ 2) + i) % 2 == 0;
          final w = Padding(padding: const EdgeInsets.only(bottom: 10), child: SizedBox(height: tall ? 250 : 206, child: ProductCard(p: src[i])));
          (i.isEven ? l : r).add(w);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Column(children: l)), const SizedBox(width: 10), Expanded(child: Column(children: r))]),
        );
      case HomeLayout.rails:
        return SizedBox(
          height: 200,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            scrollDirection: Axis.horizontal,
            itemCount: items.length > 12 ? 12 : items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => SizedBox(width: 124, child: ProductCard(p: items[i])),
          ),
        );
      case HomeLayout.hero:
        return Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: SizedBox(height: 250, child: ProductCard(p: items.first))),
          if (items.length > 1) _grid(items.skip(1).take(6).toList(), 3, 0.58, gap: 8),
        ]);
      case HomeLayout.shop:
        return _grid(items.take(6).toList(), 2, 0.9); // the shop layout normally replaces the sections by tabs (see ShopTabs); this is the fallback
      case HomeLayout.toggle:
        final rows = ref.watch(_rowsModeProvider);
        return Column(children: [
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [ButtonSegment(value: false, icon: Icon(Icons.grid_view_rounded, size: 18)), ButtonSegment(value: true, icon: Icon(Icons.view_agenda_outlined, size: 18))],
                selected: {rows},
                onSelectionChanged: (v) => ref.read(_rowsModeProvider.notifier).set(v.first),
              ),
            ),
          ),
          rows ? _rows(items.take(5).toList()) : _grid(items.take(6).toList(), 2, 0.9),
        ]);
    }
  }
}

/// "Store style": one grid under tabs instead of several separate sections.
class ShopTabs extends StatefulWidget {
  const ShopTabs({super.key, required this.tabs});
  final List<(String, List<Map<String, dynamic>>)> tabs; // (l10n title key, items)
  @override
  State<ShopTabs> createState() => _ShopTabsState();
}

class _ShopTabsState extends State<ShopTabs> {
  int _i = 0;
  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs.where((t) => t.$2.isNotEmpty).toList();
    if (tabs.isEmpty) return const SizedBox.shrink();
    final i = _i.clamp(0, tabs.length - 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 56,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(16, 14, 16, 6), children: [
          for (var k = 0; k < tabs.length; k++)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                label: Text(context.tr(tabs[k].$1), style: TextStyle(fontWeight: FontWeight.w700, color: k == i ? Colors.white : BrandColors.navy)),
                selected: k == i,
                selectedColor: BrandColors.navy,
                onSelected: (_) => setState(() => _i = k),
              ),
            ),
        ]),
      ),
      HomeProducts._grid(tabs[i].$2.take(8).toList(), 2, 0.9),
    ]);
  }
}
