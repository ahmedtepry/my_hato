import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/avatars.dart';
import '../../shared/brand_logo.dart';
import '../../shared/product_card.dart';
import '../../shared/smooth_pages.dart';
import '../../shared/motion.dart';
import '../../shared/press_scale.dart';
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

/// Shared by the home list and the logo button (tap the logo on home -> smooth scroll to top).
final homeScrollController = ScrollController();

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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
      body: RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(controller: homeScrollController, slivers: [
          SliverToBoxAdapter(child: _HomeHeader(signedIn: user != null)),
          const SliverToBoxAdapter(child: FadeSlideIn(delay: Duration(milliseconds: 120), child: _SectionsBar())),
          const SliverToBoxAdapter(child: FadeSlideIn(delay: Duration(milliseconds: 220), child: _BannerCarousel())),
          const SliverToBoxAdapter(child: _ActiveUpdates()),
          _section(context, 'featured', featured, const CatalogQuery(featuredOnly: true)),
          const SliverToBoxAdapter(child: FadeSlideIn(delay: Duration(milliseconds: 380), child: _RepairPromo())),
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
            : FadeSlideIn(
                delay: const Duration(milliseconds: 300),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 22, 8, 6),
                    child: Row(children: [
                      Container(
                        width: 5,
                        height: 20,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [BrandColors.electric, BrandColors.navy]),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(context.tr(titleKey), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, fontSize: 19)),
                      const Spacer(),
                      if (seeAll != null)
                        TextButton.icon(
                          onPressed: () => context.push('/catalog/all', extra: seeAll),
                          icon: Text(context.tr('see_all'), style: const TextStyle(fontWeight: FontWeight.w700)),
                          label: const Icon(Icons.arrow_back_ios_new_rounded, size: 13),
                        ),
                    ]),
                  ),
                  HorizontalProducts(items: items),
                ]),
              ),
      ),
    );
  }
}

const _sectionColors = <String, List<Color>>{
  'sec_phones': [Color(0xFF2F6BFF), Color(0xFF00A3FF)],
  'sec_accessories': [Color(0xFFFF6A88), Color(0xFFFF9A5A)],
  'sec_used': [Color(0xFF16B89A), Color(0xFF7BE0C3)],
  'sec_repair': [Color(0xFF7B5CFF), Color(0xFFB79CFF)],
};

class _SectionsBar extends ConsumerWidget {
  const _SectionsBar();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usedEnabled = ref.watch(usedEnabledProvider).valueOrNull ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 4),
      child: Row(children: [
        for (var i = 0; i < mainSections.length; i++)
          Expanded(
            child: FadeSlideIn(
              delay: FadeSlideIn.stagger(i, stepMs: 70),
              child: _SectionTile(section: mainSections[i], soon: mainSections[i].comingSoon && !usedEnabled),
            ),
          ),
      ]),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section, required this.soon});
  final MainSection section;
  final bool soon;
  @override
  Widget build(BuildContext context) {
    final colors = _sectionColors[section.key] ?? const [BrandColors.navy, BrandColors.electric];
    return PressScale(
      scale: 0.92,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.push(section.route),
        child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: colors.first.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 6))],
              ),
              child: Icon(section.icon, color: Colors.white, size: 30),
            ),
            if (soon)
              PositionedDirectional(
                top: -8,
                end: -10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: BrandColors.navy, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white, width: 1.5)),
                  child: Text(context.tr('soon'), style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          Text(context.tr(section.key), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
      ),
    );
  }
}

/// Brand header: living navy gradient with the logo, a time-of-day greeting next to a big
/// avatar, and the search box resting on its lower edge.
class _HomeHeader extends ConsumerWidget {
  const _HomeHeader({required this.signedIn});
  final bool signedIn;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).valueOrNull;
    final first = ((profile?['full_name'] as String?) ?? '').trim().split(RegExp(r'\s+')).first;
    final h = DateTime.now().hour;
    final ar = context.isAr;
    final greet = (h >= 5 && h < 12) ? (ar ? 'صباح الخير' : 'Good morning') : (ar ? 'مساء الخير' : 'Good evening');
    final top = MediaQuery.paddingOf(context).top;
    return Stack(children: [
      // the search box rests half on the header: the bottom padding keeps it inside the tap area
      Padding(
        padding: const EdgeInsets.only(bottom: 26),
        child: LivingGradient(
        colors: const [Color(0xFF0B1F4D), Color(0xFF173A8C), Color(0xFF0B5FD8)],
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
        child: Stack(children: [
          // soft light circles for depth
          PositionedDirectional(top: -40, end: -30, child: _Glow(size: 170, alpha: 0.10)),
          PositionedDirectional(bottom: 10, start: -50, child: _Glow(size: 140, alpha: 0.07)),
          Padding(
            padding: EdgeInsets.fromLTRB(16, top + 10, 16, 52),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                HomeLogoButton(
                  size: 21,
                  onDark: true,
                  onTripleTap: () => context.push('/hato-console'),
                  onAlreadyHome: () {
                    if (homeScrollController.hasClients) {
                      homeScrollController.animateTo(0, duration: const Duration(milliseconds: 650), curve: Curves.easeOutCubic);
                    }
                  },
                ),
                const Spacer(),
                const _NotificationsBell(onDark: true),
              ]),
              const SizedBox(height: 16),
              FadeSlideIn(
                child: Row(children: [
                  _ProfileAvatar(signedIn: signedIn),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('$greet 👋', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(
                        signedIn && first.isNotEmpty ? first : (ar ? 'أهلاً بيك في My Hatō' : 'Welcome to My Hatō'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                      ),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
        ),
      ),
      PositionedDirectional(
        start: 16,
        end: 16,
        bottom: 0,
        child: FadeSlideIn(
          delay: const Duration(milliseconds: 80),
          child: Material(
            color: Colors.white,
            elevation: 8,
            shadowColor: BrandColors.navy.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => context.push('/search'),
              child: SizedBox(
                height: 52,
                child: Row(children: [
                  const SizedBox(width: 14),
                  const Icon(Icons.search_rounded, color: BrandColors.electric),
                  const SizedBox(width: 10),
                  Expanded(child: Text(context.tr('search_hint'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BrandColors.gray))),
                  Container(
                    margin: const EdgeInsetsDirectional.only(end: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.tune_rounded, size: 18, color: BrandColors.electric),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.alpha});
  final double size;
  final double alpha;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: alpha)),
      );
}

class _ProfileAvatar extends ConsumerWidget {
  const _ProfileAvatar({required this.signedIn});
  final bool signedIn;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).valueOrNull;
    final name = (profile?['full_name'] as String?) ?? '';
    final avatarId = profile?['avatar_id'] as String?;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => context.go(signedIn ? '/account' : '/auth/login'),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: c),
        child: isAvatarId(avatarId)
            ? Container(
                key: ValueKey(avatarId),
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.9)),
                child: HatoAvatar(id: avatarId!, size: 58),
              )
            : CircleAvatar(
                key: const ValueKey('letter'),
                radius: 32,
                backgroundColor: BrandColors.navy,
                child: name.isNotEmpty
                    ? Text(name.characters.first.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))
                    : const Icon(Icons.person_rounded, color: Colors.white),
              ),
      ),
    );
  }
}

class _NotificationsBell extends ConsumerWidget {
  const _NotificationsBell({this.onDark = false});
  final bool onDark;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadCountProvider).valueOrNull ?? 0;
    return Material(
      color: onDark ? Colors.white.withValues(alpha: 0.14) : Colors.transparent,
      shape: const CircleBorder(),
      child: IconButton(
        onPressed: () => context.push('/notifications'),
        icon: Wiggle(
          active: unread > 0,
          child: Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            child: Icon(Icons.notifications_none_rounded, color: onDark ? Colors.white : null),
          ),
        ),
      ),
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
  Timer? _auto;

  @override
  void initState() {
    super.initState();
    // gentle auto-play; any swipe by the user simply continues from where they are
    _auto = Timer.periodic(const Duration(seconds: 5), (_) {
      final n = ref.read(bannersProvider).valueOrNull?.length ?? 0;
      if (n < 2 || !_pc.hasClients || !_pc.position.haveDimensions) return;
      final next = ((_pc.page ?? 0).round() + 1) % n;
      _pc.animateToPage(next, duration: const Duration(milliseconds: 700), curve: Curves.easeInOutCubic);
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
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
                  return SmoothPage(controller: _pc, index: i, maxScaleDrop: 0.06, maxFade: 0.3, parallax: 0.3, child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: PressScale(scale: 0.98, child: InkWell(
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
                    )),
                  ));
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
