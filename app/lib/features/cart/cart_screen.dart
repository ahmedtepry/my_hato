import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/product_card.dart';
import '../../shared/states.dart';
import 'cart_repository.dart';

class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final cart = ref.watch(cartProvider);
    final lang = context.lang;

    if (user == null) {
      final guestCount = ref.read(cartRepoProvider).guestItems().length;
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('cart'))),
        body: EmptyState(
          icon: Icons.shopping_bag_outlined,
          title: guestCount > 0 ? '${context.tr('nav_cart')} ($guestCount)' : context.tr('cart_empty'),
          body: context.tr('login_required'),
          action: context.tr('login'),
          onAction: () => context.push('/auth/login?redirect=%2Fcart'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('cart'))),
      body: cart.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(cartProvider)),
        data: (t) {
          if (t.lines.isEmpty) {
            return EmptyState(
              icon: Icons.shopping_bag_outlined,
              title: context.tr('cart_empty'),
              body: context.tr('cart_empty_body'),
              action: context.tr('continue_shopping'),
              onAction: () => context.go('/'),
            );
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final l in t.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(width: 76, height: 76, child: NetImage(path: l.thumb))),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(lang == 'ar' ? l.nameAr : l.nameEn, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                          if (l.variantAr != null) Text(lang == 'ar' ? l.variantAr! : (l.variantEn ?? ''), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                          const SizedBox(height: 4),
                          Text(formatEgp(l.unitPrice, lang), style: const TextStyle(fontWeight: FontWeight.w800)),
                          if (!l.isAvailable)
                            Text(l.availableStock <= 0 ? context.tr('out_of_stock') : context.tr('only_left', {'n': '${l.availableStock}'}),
                                style: const TextStyle(color: BrandColors.error, fontSize: 12, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                      Column(children: [
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: l.quantity >= 20 || l.quantity >= l.availableStock ? null : () => _set(context, ref, l, l.quantity + 1),
                        ),
                        Text('${l.quantity}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        IconButton(
                          icon: Icon(l.quantity == 1 ? Icons.delete_outline : Icons.remove_circle_outline,
                              color: l.quantity == 1 ? BrandColors.error : null),
                          onPressed: () => _set(context, ref, l, l.quantity - 1),
                        ),
                      ]),
                    ]),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            TextButton.icon(onPressed: () => context.go('/'), icon: const Icon(Icons.arrow_back), label: Text(context.tr('continue_shopping'))),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  _row(context.tr('subtotal'), formatEgp(t.listTotal, lang)),
                  if (t.discount > 0) _row(context.tr('discount'), '- ${formatEgp(t.discount, lang)}', color: BrandColors.success),
                  _row(context.tr('delivery_fee'), context.isAr ? 'تُحسب عند إتمام الطلب' : 'Calculated at checkout', muted: true),
                  const Divider(height: 24),
                  _row(context.tr('total'), formatEgp(t.subtotal, lang), bold: true),
                ]),
              ),
            ),
          ]);
        },
      ),
      bottomNavigationBar: cart.maybeWhen(
        data: (t) => t.lines.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton(
                    onPressed: t.allAvailable ? () => context.push('/checkout') : null,
                    child: Text('${context.tr('checkout')} • ${formatEgp(t.subtotal, lang)}'),
                  ),
                ),
              ),
        orElse: () => null,
      ),
    );
  }

  Future<void> _set(BuildContext context, WidgetRef ref, CartLine l, int qty) async {
    try {
      await ref.read(cartProvider.notifier).setQuantity(l.productId, l.variantId, qty);
      if (qty == 0 && context.mounted) {
        showSnack(context, context.tr('removed_from_cart'),
            action: SnackBarAction(
              label: context.tr('undo'),
              textColor: BrandColors.electric,
              onPressed: () => ref.read(cartProvider.notifier).setQuantity(l.productId, l.variantId, 1),
            ));
      }
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  Widget _row(String k, String v, {bool bold = false, bool muted = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500, fontSize: bold ? 17 : 14)),
          const Spacer(),
          Text(v,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
                  fontSize: bold ? 18 : 14,
                  color: color ?? (muted ? BrandColors.gray : BrandColors.navy))),
        ]),
      );
}
