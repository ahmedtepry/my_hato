import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/brand_logo.dart';
import 'catalog_repository.dart';
import 'catalog_screen.dart';

/// "مستعمل / Used" section.
/// While application_settings.used_devices_enabled = false (default) it shows a
/// Coming Soon page. When the owner enables it from the dashboard and adds
/// products under a category of kind "used", this screen becomes the used
/// catalog automatically — no app update required.
class UsedScreen extends ConsumerWidget {
  const UsedScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(usedEnabledProvider);
    return enabled.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => const _ComingSoon(),
      data: (on) => on ? const CatalogScreen(kind: 'used') : const _ComingSoon(),
    );
  }
}

class _ComingSoon extends StatefulWidget {
  const _ComingSoon();
  @override
  State<_ComingSoon> createState() => _ComingSoonState();
}

class _ComingSoonState extends State<_ComingSoon> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.tr('used_title'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ScaleTransition(
                scale: Tween(begin: 0.94, end: 1.04).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
                child: Container(
                  padding: const EdgeInsets.all(36),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [BrandColors.navy, BrandColors.navyDeep]),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: BrandColors.electric.withOpacity(0.35), blurRadius: 30)],
                  ),
                  child: const Icon(Icons.phonelink_setup_rounded, size: 80, color: BrandColors.electric),
                ),
              ),
              const SizedBox(height: 32),
              Text(context.tr('used_coming_soon'),
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: BrandColors.navy)),
              const SizedBox(height: 12),
              Text(context.tr('used_coming_soon_body'),
                  textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, fontSize: 16, height: 1.6)),
              const SizedBox(height: 32),
              SizedBox(
                width: 260,
                child: FilledButton(onPressed: () => context.go('/catalog/phones'), child: Text(context.tr('notify_me'))),
              ),
              const SizedBox(height: 24),
              const Opacity(opacity: 0.5, child: BrandWordmark(size: 16)),
            ]),
          ),
        ),
      );
}
