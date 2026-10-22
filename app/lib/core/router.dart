import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_screen.dart';
import '../features/auth/phone_otp_screen.dart';
import '../features/cart/cart_repository.dart';
import '../features/cart/cart_screen.dart';
import '../features/catalog/catalog_repository.dart';
import '../features/catalog/catalog_screen.dart';
import '../features/catalog/product_details_screen.dart';
import '../features/catalog/used_screen.dart';
import '../features/checkout/checkout_screen.dart';
import '../features/home/home_screen.dart';
import '../features/home/onboarding_screens.dart';
import '../features/notifications/notifications_repository.dart';
import '../features/orders/orders_screens.dart';
import '../features/payments/payment_flow.dart';
import '../features/payments/payments_screens.dart';
import '../features/profile/profile_screens.dart';
import '../features/repairs/repairs_screens.dart';
import 'l10n.dart';
import 'supabase_providers.dart';

/// Routes that need a signed-in user. The DB enforces access anyway (RLS);
/// this only gives a friendly redirect to the login screen.
const _protected = ['/checkout', '/order-confirmed', '/orders/', '/repairs/new', '/account/', '/notifications', '/pay/', '/payments'];
const _publicAccountRoutes = ['/account/settings', '/account/help', '/account/legal'];

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authStateProvider, (_, __) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = ref.read(supabaseProvider).auth.currentSession != null;
      final loc = state.matchedLocation;
      final needsAuth = _protected.any((p) => loc == p || loc.startsWith(p)) && !_publicAccountRoutes.contains(loc);
      if (needsAuth && !signedIn) return '/auth/login?redirect=${Uri.encodeComponent(state.uri.toString())}';
      if (signedIn && (loc == '/auth/login' || loc == '/auth/register')) {
        return state.uri.queryParameters['redirect'] ?? '/';
      }
      return null;
    },
    errorBuilder: (_, __) => const HomeScreen(),
    routes: [
      // OAuth / magic-link deep link (com.myhato.app://login-callback). supabase_flutter
      // consumes the auth code itself; the router just lands the user on home.
      GoRoute(path: '/login-callback', redirect: (_, __) => '/'),
      // Paymob checkout returns here; the real result comes from the server, not from these URL params.
      GoRoute(path: '/payment-return', redirect: (_, __) => PendingPayment.returnRoute),
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      GoRoute(path: '/auth/login', builder: (_, s) => LoginScreen(redirect: s.uri.queryParameters['redirect'])),
      GoRoute(path: '/auth/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(
        path: '/auth/phone',
        builder: (_, s) => PhoneOtpScreen(mode: s.uri.queryParameters['mode'] ?? 'signin', redirect: s.uri.queryParameters['redirect']),
      ),
      GoRoute(path: '/auth/expired', builder: (_, __) => const SessionExpiredScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _Shell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, __) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/categories', builder: (_, __) => const CategoriesScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/cart', builder: (_, __) => const CartScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/orders', builder: (_, s) => OrdersTab(initialIndex: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0)),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/account', builder: (_, __) => const ProfileScreen())]),
        ],
      ),
      GoRoute(path: '/search', builder: (_, __) => const CatalogScreen(searchMode: true)),
      GoRoute(path: '/catalog/all', builder: (_, s) => CatalogScreen(initial: s.extra as CatalogQuery?)),
      GoRoute(path: '/catalog/:kind', builder: (_, s) => CatalogScreen(kind: s.pathParameters['kind'])),
      GoRoute(path: '/used', builder: (_, __) => const UsedScreen()),
      GoRoute(path: '/product/:id', builder: (_, s) => ProductDetailsScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/checkout', builder: (_, __) => const CheckoutScreen()),
      GoRoute(
        path: '/order-confirmed',
        builder: (_, s) => OrderConfirmationScreen(orderId: s.uri.queryParameters['id'] ?? '', reference: s.uri.queryParameters['ref'] ?? ''),
      ),
      GoRoute(path: '/orders/:id', builder: (_, s) => OrderDetailsScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/repairs/new', builder: (_, __) => const RepairRequestScreen()),
      GoRoute(path: '/repairs/lookup', builder: (_, __) => const RepairLookupScreen()),
      GoRoute(path: '/repairs/:id', builder: (_, s) => RepairDetailsScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
      GoRoute(path: '/account/edit', builder: (_, __) => const EditProfileScreen()),
      GoRoute(path: '/account/addresses', builder: (_, __) => const AddressesScreen()),
      GoRoute(path: '/account/addresses/new', builder: (_, __) => const AddressFormScreen()),
      GoRoute(path: '/account/addresses/edit', builder: (_, s) => AddressFormScreen(existing: s.extra as Map<String, dynamic>?)),
      GoRoute(path: '/account/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(path: '/account/favorites', builder: (_, __) => const FavoritesScreen()),
      GoRoute(path: '/account/help', builder: (_, __) => const HelpScreen()),
      GoRoute(path: '/account/legal', builder: (_, __) => const LegalScreen()),
      GoRoute(path: '/account/cards', builder: (_, __) => const SavedCardsScreen()),
      GoRoute(path: '/payments', builder: (_, __) => const PaymentsHistoryScreen()),
      GoRoute(path: '/payments/:id', builder: (_, s) => PaymentDetailsScreen(id: s.pathParameters['id']!)),
      GoRoute(
        path: '/pay/status',
        builder: (_, s) => PaymentStatusScreen(paymentId: s.uri.queryParameters['payment'] ?? '', orderId: s.uri.queryParameters['order'] ?? ''),
      ),
    ],
  );
});

class _Shell extends ConsumerWidget {
  const _Shell({required this.shell});
  final StatefulNavigationShell shell;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cartCount = ref.watch(cartProvider).valueOrNull?.count ?? 0;
    // keep realtime notifications alive while the shell is mounted
    ref.watch(notificationsProvider);
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: context.tr('nav_home')),
          NavigationDestination(icon: const Icon(Icons.grid_view_outlined), selectedIcon: const Icon(Icons.grid_view_rounded), label: context.tr('nav_categories')),
          NavigationDestination(
            icon: Badge(isLabelVisible: cartCount > 0, label: Text('$cartCount'), child: const Icon(Icons.shopping_bag_outlined)),
            selectedIcon: const Icon(Icons.shopping_bag_rounded),
            label: context.tr('nav_cart'),
          ),
          NavigationDestination(icon: const Icon(Icons.receipt_long_outlined), selectedIcon: const Icon(Icons.receipt_long_rounded), label: context.tr('nav_orders')),
          NavigationDestination(icon: const Icon(Icons.person_outline), selectedIcon: const Icon(Icons.person_rounded), label: context.tr('nav_account')),
        ],
      ),
    );
  }
}

/// Categories tab: the same four top sections + every admin-managed category.
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phones = ref.watch(categoriesProvider('phones')).valueOrNull ?? const [];
    final acc = ref.watch(categoriesProvider('accessories')).valueOrNull ?? const [];
    final usedOn = ref.watch(usedEnabledProvider).valueOrNull ?? false;
    Widget group(String title, List<Map<String, dynamic>> cats) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 8), child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in cats)
              ActionChip(
                label: Text(context.pick(c, 'name')),
                onPressed: () => context.push('/catalog/all', extra: CatalogQuery(categoryId: c['id'] as String)),
              ),
          ]).paddingH(16),
        ]);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('nav_categories'))),
      body: ListView(children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.6,
          children: [
            for (final s in mainSections)
              Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => context.push(s.route),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(s.icon, size: 32),
                    const SizedBox(height: 6),
                    Text(context.tr(s.key), style: const TextStyle(fontWeight: FontWeight.w800)),
                    if (s.comingSoon && !usedOn) Text(context.tr('used_coming_soon'), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                ),
              ),
          ],
        ),
        if (phones.isNotEmpty) group(context.tr('sec_phones'), phones),
        if (acc.isNotEmpty) group(context.tr('sec_accessories'), acc),
        const SizedBox(height: 24),
      ]),
    );
  }
}

extension on Widget {
  Widget paddingH(double h) => Padding(padding: EdgeInsets.symmetric(horizontal: h), child: this);
}
