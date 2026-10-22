import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Entrance motion: fades in and rises a few pixels, once, after [delay]. Used to stagger
/// sections and tiles so screens "arrive" instead of popping in all at once.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 18, this.duration = const Duration(milliseconds: 520)});
  final Widget child;
  final Duration delay;
  final double offset;
  final Duration duration;

  /// Stagger helper: index -> delay (capped so long lists don't wait forever).
  static Duration stagger(int i, {int stepMs = 55, int maxMs = 440}) => Duration(milliseconds: math.min(i * stepMs, maxMs));

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.duration);
  late final _a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        child: widget.child,
        builder: (_, child) => Opacity(
          opacity: _a.value,
          child: Transform.translate(offset: Offset(0, widget.offset * (1 - _a.value)), child: child),
        ),
      );
}

/// A gentle wiggle every few seconds while [active] (e.g. the bell when there are unread messages).
class Wiggle extends StatefulWidget {
  const Wiggle({super.key, required this.child, required this.active});
  final Widget child;
  final bool active;
  @override
  State<Wiggle> createState() => _WiggleState();
}

class _WiggleState extends State<Wiggle> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant Wiggle old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat();
    if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (_, child) {
          // swing during the first ~20% of each cycle, then rest
          final t = _c.value;
          final angle = t < 0.2 ? math.sin(t / 0.2 * math.pi * 4) * 0.22 * (1 - t / 0.2) : 0.0;
          return Transform.rotate(angle: angle, alignment: Alignment.topCenter, child: child);
        },
      );
}

/// Slowly drifting two-colour gradient — gives large brand surfaces a living, breathing feel.
class LivingGradient extends StatefulWidget {
  const LivingGradient({super.key, required this.colors, required this.child, this.borderRadius});
  final List<Color> colors;
  final Widget child;
  final BorderRadius? borderRadius;
  @override
  State<LivingGradient> createState() => _LivingGradientState();
}

class _LivingGradientState extends State<LivingGradient> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (_, child) {
          final t = Curves.easeInOut.transform(_c.value);
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              gradient: LinearGradient(
                begin: Alignment(-1 + t * 0.8, -1),
                end: Alignment(1, 1 - t * 0.8),
                colors: widget.colors,
              ),
            ),
            child: child,
          );
        },
      );
}
