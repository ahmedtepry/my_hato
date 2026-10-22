import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/errors.dart';
import '../core/l10n.dart';
import '../core/theme.dart';

class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.height = 16, this.width, this.radius = 12});
  final double height;
  final double? width;
  final double radius;
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.45, end: 1.0).animate(_c),
        child: Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(color: BrandColors.border, borderRadius: BorderRadius.circular(widget.radius)),
        ),
      );
}

class ProductGridSkeleton extends StatelessWidget {
  const ProductGridSkeleton({super.key, this.count = 6});
  final int count;
  @override
  Widget build(BuildContext context) => GridView.builder(
        padding: const EdgeInsets.all(16),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.84),
        itemCount: count,
        itemBuilder: (_, __) => const Skeleton(height: double.infinity, radius: 16),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action, this.onAction});
  final IconData icon;
  final String title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(color: BrandColors.electric.withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, size: 44, color: BrandColors.electric),
            ),
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray)),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              SizedBox(width: 240, child: FilledButton(onPressed: onAction, child: Text(action!))),
            ],
          ]),
        ),
      );
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.wifi_off_rounded,
        title: friendlyError(context, error),
        action: context.tr('retry'),
        onAction: onRetry,
      );
}

void showSnack(BuildContext context, String msg, {bool error = false, SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? BrandColors.error : BrandColors.navy,
      behavior: SnackBarBehavior.floating,
      action: action,
      // messages with a button (e.g. Undo) also disappear on their own instead of staying on screen
      duration: Duration(seconds: action != null ? 4 : 3),
      persist: false,
    ));
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.color = BrandColors.electric});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      );
}


/// AppBar leading button: back when there is a previous page, otherwise a home button
/// (e.g. right after submitting a repair or placing an order, where the stack was replaced).
class BackOrHomeButton extends StatelessWidget {
  const BackOrHomeButton({super.key});
  @override
  Widget build(BuildContext context) => context.canPop()
      ? const BackButton()
      : IconButton(icon: const Icon(Icons.home_rounded), tooltip: context.tr('back_home'), onPressed: () => context.go('/'));
}

/// "Back to home" button pinned to the bottom of detail screens.
class BackHomeBar extends StatelessWidget {
  const BackHomeBar({super.key});
  @override
  Widget build(BuildContext context) => SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: OutlinedButton.icon(
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.home_rounded),
          label: Text(context.tr('back_home')),
        ),
      );
}
