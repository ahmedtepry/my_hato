import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'brand_logo.dart';
import 'launch_art.dart';
import 'welcome_robot.dart';

/// The opening animations the owner can choose from the console (classic, zoom, slide, plus the six artwork ones).
class LaunchAnimation extends StatefulWidget {
  const LaunchAnimation({super.key, required this.variant, this.scale = 1});
  final String variant;
  final double scale;
  @override
  State<LaunchAnimation> createState() => _LaunchAnimationState();
}

class _LaunchAnimationState extends State<LaunchAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _iv(double a, double b, [Curve curve = Curves.easeOut]) => curve.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        switch (widget.variant) {
          case 'peek' || 'call':
            return WelcomeRobot(key: ValueKey(widget.variant), variant: widget.variant, scale: s);
          case 'zoom':
            final pop = _iv(0, 0.6, Curves.easeOutBack);
            final ring = _iv(0.1, 0.9);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 150 * s,
                height: 130 * s,
                child: Stack(alignment: Alignment.center, children: [
                  Container(
                    width: (70 + 80 * ring) * s,
                    height: (70 + 80 * ring) * s,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: BrandColors.electric.withValues(alpha: (1 - ring) * 0.7), width: 3)),
                  ),
                  Transform.scale(scale: 0.3 + 0.7 * pop, child: Opacity(opacity: _iv(0, 0.3), child: BrandMark(size: 96 * s, onDark: true))),
                ]),
              ),
              SizedBox(height: 18 * s),
              Opacity(opacity: _iv(0.5, 1), child: BrandWordmark(size: 30 * s, onDark: true, showSlogan: true)),
            ]);
          case 'slide':
            final up = _iv(0, 0.55, Curves.easeOutCubic);
            final word = _iv(0.3, 0.9, Curves.easeOutCubic);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Transform.translate(offset: Offset(0, 40 * s * (1 - up)), child: Opacity(opacity: up, child: BrandMark(size: 96 * s, onDark: true))),
              SizedBox(height: 16 * s),
              Container(width: 120 * s * word, height: 3, decoration: BoxDecoration(color: BrandColors.electric, borderRadius: BorderRadius.circular(2))),
              SizedBox(height: 16 * s),
              Transform.translate(offset: Offset(0, 24 * s * (1 - word)), child: Opacity(opacity: word, child: BrandWordmark(size: 30 * s, onDark: true, showSlogan: true))),
            ]);
          case 'liquid' || 'orbit' || 'phone' || 'neon' || 'pulse' || 'bird':
            final w = _iv(0.55, 1, Curves.easeOutCubic);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              LaunchArt(id: widget.variant, t: _c.value, size: 112 * s),
              SizedBox(height: 20 * s),
              Transform.translate(offset: Offset(0, 10 * s * (1 - w)), child: Opacity(opacity: w, child: BrandWordmark(size: 30 * s, onDark: true, showSlogan: true))),
            ]);
          default:
            return Column(mainAxisSize: MainAxisSize.min, children: [
              BrandMark(size: 96 * s, onDark: true, progress: Curves.easeOut.transform(_iv(0, 0.85, Curves.linear))),
              SizedBox(height: 24 * s),
              Opacity(opacity: _iv(0, 0.85, Curves.linear), child: BrandWordmark(size: 30 * s, onDark: true, showSlogan: true)),
            ]);
        }
      },
    );
  }
}
