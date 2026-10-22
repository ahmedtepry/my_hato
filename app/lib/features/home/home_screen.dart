import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/brand_logo.dart';
import '../../shared/product_card.dart';
import '../../shared/states.dart';
import '../auth/auth_repository.dart';
import '../catalog/catalog_repository.dart';
import '../notifications/notifications_repository.dart';

/// The four main sections shown at the top of the home screen.
/// "مستعمل / Used" opens a Coming Soon page until enabled from the dashboard.
class MainSection {
  const MainSection(this.key, this.icon, this.route, {this.comingSoon = false});
  final String key;
  final IconData icon;
  final String route;
  final bool comingSoon;
}

const mainSections = [
  MainSection('sec_phones', Icons.smartphone_rounded, '/catalog/phones'),
  MainSection('sec_accessories', Icons.headphones_rounded, '/catalog/accessories'),
  MainSection('sec_used', Icons.recycling_rounded, '/used', comingSoon: true),
  MainSection('sec_repair', Icons.build_rounded, '/repairs/new'),
];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final featured = ref.watch(productsSectionProvider(const CatalogQuery(featuredOnly: true)));
    final newest = ref.watch(productsSectionProvider(const CatalogQuery()));
    final best = ref.watch(productsSectionProvider(const CatalogQuery(sort: SortOption.popular)));
    final deals = ref.watch(productsSectionProvider(const CatalogQuery(discountedOnly: true)));
    final recent = ref.watch(recentlyViewedProvider);
    final user = ref.watch(currentUserProvider);

    Future<void> refresh() async {
      ref.invalidate(productsSectionProvider);
      ref.invalidate(bannersProvider);
      ref.invalidate(recentlyViewedProvider);
      ref.invalidate(publicSettingsProvider);
    }

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  const BrandWordmark(size: 22),
                  const Spacer(),
                  const _NotificationsBell(),
                  const SizedBox(width: 4),
                  // Profile icon -> profile screen (session is preserved).
                  _ProfileAvatar(signedIn: user != null),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => context.push('/search'),
                  child: IgnorePointer(
                    child: TextField(
                      decoration: InputDecoration(hintText: context.tr('search_hint'), prefixIcon: const Icon(Icons.search_rounded)),
                    ),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: _SectionsBar()),
            const SliverToBoxAdapter(child: _BannerCarousel()),
            const SliverToBoxAdapter(child: _ActiveUpdates()),
            _section(context, 'featured', featured, const CatalogQuery(featuredOnly: true)),
            const SliverToBoxAdapter(child: _RepairPromo()),
            _section(context, 'new_arrivals', newest, const CatalogQuery()),
            _section(context, 'discounts', deals, const CatalogQuery(discountedOnly: true)),
            _section(context, 'best_sellers', best, const CatalogQuery(sort: SortOption.popular)),
            if (user != null) _section(context, 'recently_viewed', recent, null),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ]),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String titleKey, AsyncValue<List<Map<String, dynamic>>> data, CatalogQuery? seeAll) {
    return SliverToBoxAdapter(
      child: data.when(
        loading: () => Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: const [Expanded(child: Skeleton(height: 240)), SizedBox(width: 12), Expanded(child: Skeleton(height: 240))]),
        ),
        error: (e, _) => const SizedBox.shrink(),
        data: (items) => items.isEmpty
            ? const SizedBox.shrink()
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
                  child: Row(children: [
                    Text(context.tr(titleKey), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const Spacer(),
                    if (seeAll != null)
                      TextButton(onPressed: () => context.push('/catalog/all', extra: seeAll), child: Text(context.tr('see_all'))),
                  ]),
                ),
                HorizontalProducts(items: items),
              ]),
      ),
    );
  }
}

class _SectionsBar extends ConsumerWidget {
  const _SectionsBar();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usedEnabled = ref.watch(usedEnabledProvider).valueOrNull ?? false;
    return SizedBox(
      height: 104,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: mainSections.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final s = mainSections[i];
          final soon = s.comingSoon && !usedEnabled;
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => context.push(s.route),
            child: Container(
              width: 84,
              decoration: BoxDecoration(
                color: BrandColors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: BrandColors.border),
              ),
              child: Stack(clipBehavior: Clip.none, children: [
                Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(s.icon, color: BrandColors.navy, size: 28),
                    const SizedBox(height: 6),
                    Text(context.tr(s.key), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  ]),
                ),
                if (soon)
                  PositionedDirectional(
                    top: -6,
                    end: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: BrandColors.electric, borderRadius: BorderRadius.circular(8)),
                      child: Text(context.tr('soon'), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _ProfileAvatar extends ConsumerWidget {
  const _ProfileAvatar({required this.signedIn});
  final bool signedIn;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).valueOrNull;
    final name = (profile?['full_name'] as String?) ?? '';
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => context.go(signedIn ? '/account' : '/auth/login'),
      child: CircleAvatar(
        radius: 20,
        backgroundColor: BrandColors.navy,
        child: name.isNotEmpty
            ? Text(name.characters.first.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))
            : const Icon(Icons.person_rounded, color: Colors.white),
      ),
    );
  }
}

class _NotificationsBell extends ConsumerWidget {
  const _NotificationsBell();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadCountProvider).valueOrNull ?? 0;
    return IconButton(
      onPressed: () => context.push('/notifications'),
      icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_none_rounded)),
    );
  }
}

class _BannerCarousel extends ConsumerStatefulWidget {
  const _BannerCarousel();
  @override
  ConsumerState<_BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends ConsumerState<_BannerCarousel> {
  final _pc = PageController(viewportFraction: 0.92);
  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banners = ref.watch(bannersProvider);
    return banners.maybeWhen(
      data: (list) => list.isEmpty
          ? const SizedBox.shrink()
          : SizedBox(
              height: 160,
              child: PageView.builder(
                controller: _pc,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final b = list[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        final v = b['link_value'] as String?;
                        switch (b['link_type']) {
                          case 'product':
                            if (v != null) context.push('/product/$v');
                          case 'repair':
                            context.push('/repairs/new');
                          case 'category':
                            if (v != null) context.push('/catalog/all', extra: CatalogQuery(categoryId: v));
                        }
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(fit: StackFit.expand, children: [
                          NetImage(path: b['image_path'] as String?, bucket: 'banners'),
                          Container(
                            alignment: AlignmentDirectional.bottomStart,
                            padding: const EdgeInsets.all(16),
                            decoration: const BoxDecoration(
                                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xCC0B2D5B)])),
                            child: Text(context.pick(b, 'title'),
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                          ),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
      orElse: () => const Padding(padding: EdgeInsets.all(16), child: Skeleton(height: 144)),
    );
  }
}

class _RepairPromo extends StatelessWidget {
  const _RepairPromo();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [BrandColors.navy, BrandColors.navyDeep]),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.tr('repair_banner_t'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(context.tr('repair_banner_b'), style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: () => context.push('/repairs/new'),
                    child: Text(context.tr('request_repair')),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                    onPressed: () => context.push('/repairs/lookup'),
                    child: Text(context.tr('track_repair')),
                  ),
                ]),
              ]),
            ),
            const Icon(Icons.build_circle_rounded, color: BrandColors.electric, size: 64),
          ]),
        ),
      );
}

/// Shows the most recent unread order/repair update on the home screen.
class _ActiveUpdates extends ConsumerWidget {
  const _ActiveUpdates();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(notificationsProvider).valueOrNull ?? const [];
    final latest = list.where((n) => n['read_at'] == null && (n['entity_type'] == 'order' || n['entity_type'] == 'repair')).take(1).toList();
    if (latest.isEmpty) return const SizedBox.shrink();
    final n = latest.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: ListTile(
          leading: Icon(n['entity_type'] == 'repair' ? Icons.build_rounded : Icons.local_shipping_outlined, color: BrandColors.electric),
          title: Text(context.pick(n, 'title'), style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(context.pick(n, 'body'), maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            ref.read(notificationsRepoProvider).markRead(n['id'] as String);
            final link = n['deep_link'] as String?;
            if (link != null) context.push(link);
          },
        ),
      ),
    );
  }
}
