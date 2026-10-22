import 'package:flutter/material.dart';

/// Soft depth transition for a [PageView] page: while swiping, neighbouring pages shrink a little,
/// fade and drift at a slower speed than the swipe (parallax), so switching images feels smooth
/// instead of a flat slide. Pure transforms — no extra rebuilds of the image itself.
class SmoothPage extends StatelessWidget {
  const SmoothPage({
    super.key,
    required this.controller,
    required this.index,
    required this.child,
    this.maxScaleDrop = 0.08,
    this.maxFade = 0.45,
    this.parallax = 0.22,
  });

  final PageController controller;
  final int index;
  final Widget child;
  final double maxScaleDrop;
  final double maxFade;

  /// Fraction of the page width the content lags behind the swipe.
  final double parallax;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: controller,
        child: child,
        builder: (context, child) {
          var page = controller.initialPage.toDouble();
          if (controller.hasClients && controller.position.haveDimensions) page = controller.page ?? page;
          final d = (page - index).clamp(-1.0, 1.0);
          final t = Curves.easeOut.transform(d.abs());
          final shift = d * box.maxWidth * parallax * (rtl ? -1 : 1);
          return Opacity(
            opacity: 1 - maxFade * t,
            child: Transform.scale(
              scale: 1 - maxScaleDrop * t,
              child: ClipRect(child: Transform.translate(offset: Offset(shift, 0), child: child)),
            ),
          );
        },
      ),
    );
  }
}

/// Animated page indicator: the active dot stretches into a pill with a smooth colour change.
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index, required this.activeColor, required this.inactiveColor});
  final int count;
  final int index;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 20 : 7,
            height: 7,
            decoration: BoxDecoration(color: i == index ? activeColor : inactiveColor, borderRadius: BorderRadius.circular(6)),
          ),
      ]);
}

/// Shared timing for programmatic page changes (thumbnail taps, auto-play).
const smoothPageDuration = Duration(milliseconds: 520);
const smoothPageCurve = Curves.easeOutCubic;
