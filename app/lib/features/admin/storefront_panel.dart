// "طريقة عرض الواجهة": the owner picks how products are laid out on the customers' home screen (Windows team app).
// The choice is stored on the server and every customer's phone app picks it up (no new install needed once the app has this feature).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/motion.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import '../home/home_layouts.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

class StorefrontLayoutPanel extends ConsumerStatefulWidget {
  const StorefrontLayoutPanel({super.key});
  @override
  ConsumerState<StorefrontLayoutPanel> createState() => _StorefrontLayoutPanelState();
}

class _StorefrontLayoutPanelState extends ConsumerState<StorefrontLayoutPanel> {
  HomeLayout? _pick;
  bool _busy = false;

  Future<void> _apply(HomeLayout l) async {
    final info = homeLayoutInfo[l]!;
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'تطبّق «${info.$1}» على كل العملاء؟', 'Apply "${info.$2}" to all customers?')),
        content: Text(_t(d, 'الصفحة الرئيسية في تطبيق العملا هتتغيّر عند الكل مرة واحدة. تقدر ترجع للي قبله في أي وقت.',
            'The home screen of every customer will change at once. You can switch back any time.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'لأ', 'No'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'أيوه، طبّق', 'Yes, apply'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('storefront_layout_set', params: {'p_layout': l.name});
      ref.invalidate(homeLayoutProvider);
      if (mounted) showSnack(context, _t(context, 'اتطبّق على كل العملاء', 'Applied to all customers'));
    } catch (e) {
      if (mounted) showSnack(context, '$e'.contains('FORBIDDEN') ? _t(context, 'مش مسموحلك.', 'Not allowed.') : friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(homeLayoutProvider);
    final active = cur.valueOrNull ?? HomeLayout.current;
    final sel = _pick ?? active;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(
        _t(context, 'اختار شكل عرض المنتجات في الصفحة الرئيسية لتطبيق العملا. بيتطبق على كل العملاء مع بعض. الشكل الشغّال دلوقتي عليه علامة.',
            'Pick how products are shown on the customers\' home screen. It applies to every customer. The active one is marked.'),
        style: const TextStyle(color: BrandColors.gray),
      ),
      const SizedBox(height: 12),
      for (final l in HomeLayout.values)
        Card(
          color: sel == l ? const Color(0x140E9384) : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _busy ? null : () => setState(() => _pick = l),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                _MiniPreview(layout: l),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(child: Text(_t(context, homeLayoutInfo[l]!.$1, homeLayoutInfo[l]!.$2), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                      if (active == l) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.check_circle_rounded, color: BrandColors.success, size: 18),
                        Text(_t(context, ' شغّال دلوقتي', ' active'), style: const TextStyle(color: BrandColors.success, fontSize: 12, fontWeight: FontWeight.w700)),
                      ],
                    ]),
                    const SizedBox(height: 3),
                    Text(_t(context, homeLayoutInfo[l]!.$3, homeLayoutInfo[l]!.$4), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                    if (sel == l && active != l) ...[
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _apply(l),
                        icon: const Icon(Icons.publish_rounded, size: 18),
                        label: Text(_t(context, 'طبّق على كل العملاء', 'Apply to all customers')),
                      ),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}

/// A tiny drawing of the layout (grey boxes), so the choice is visible without opening the phone app.
class _MiniPreview extends StatelessWidget {
  const _MiniPreview({required this.layout});
  final HomeLayout layout;

  Widget _box(double w, double h) => Container(width: w, height: h, decoration: BoxDecoration(color: const Color(0xFFC9D3E8), borderRadius: BorderRadius.circular(3)));

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (layout) {
      case HomeLayout.current:
        body = Row(children: [_box(24, 46), const SizedBox(width: 4), _box(24, 46), const SizedBox(width: 4), _box(8, 46)]);
      case HomeLayout.compact:
      case HomeLayout.toggle:
      case HomeLayout.shop:
        body = Column(children: [for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 3), child: Row(children: [_box(26, 17), const SizedBox(width: 4), _box(26, 17)]))]);
      case HomeLayout.list:
        body = Column(children: [for (var i = 0; i < 4; i++) Padding(padding: const EdgeInsets.only(bottom: 3), child: Row(children: [_box(14, 11), const SizedBox(width: 3), _box(38, 11)]))]);
      case HomeLayout.tri:
        body = Column(children: [for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 3), child: Row(children: [_box(17, 17), const SizedBox(width: 3), _box(17, 17), const SizedBox(width: 3), _box(17, 17)]))]);
      case HomeLayout.stagger:
        body = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(children: [_box(26, 30), const SizedBox(height: 3), _box(26, 18)]),
          const SizedBox(width: 4),
          Column(children: [_box(26, 18), const SizedBox(height: 3), _box(26, 30)]),
        ]);
      case HomeLayout.rails:
        body = Column(children: [for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 3), child: Row(children: [_box(14, 14), const SizedBox(width: 3), _box(14, 14), const SizedBox(width: 3), _box(14, 14), const SizedBox(width: 3), _box(6, 14)]))]);
      case HomeLayout.hero:
        body = Column(children: [_box(56, 24), const SizedBox(height: 3), Row(children: [_box(17, 16), const SizedBox(width: 3), _box(17, 16), const SizedBox(width: 3), _box(17, 16)])]);
    }
    return Container(
      width: 74,
      height: 74,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(color: const Color(0xFFF4F7FB), borderRadius: BorderRadius.circular(12), border: Border.all(color: BrandColors.border)),
      child: ClipRect(child: body),
    );
  }
}
