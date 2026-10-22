import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Entrance motion: fades in and rises a few pixels, once. Uses FadeTransition / SlideTransition
/// (handled by the compositor, no rebuilds per frame). Items with an [id] animate only the first
/// time they appear in this app session — scrolling back never replays them.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 18, this.duration = const Duration(milliseconds: 420), this.id});
  final Widget child;
  final Duration delay;
  final double offset;
  final Duration duration;
  final Object? id;

  static final _seen = <Object>{};

  /// Stagger helper: index -> delay (capped so long lists don't wait).
  static Duration stagger(int i, {int stepMs = 50, int maxMs = 300}) => Duration(milliseconds: math.min(i * stepMs, maxMs));

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final bool _skip = widget.id != null && FadeSlideIn._seen.contains(widget.id);
  late final _c = AnimationController(vsync: this, duration: widget.duration, value: _skip ? 1 : 0);
  late final _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final _slide = Tween(begin: Offset(0, widget.offset / 200), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  Timer? _t;

  @override
  void initState() {
    super.initState();
    if (_skip) return;
    if (widget.id != null) FadeSlideIn._seen.add(widget.id!);
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _t = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _skip ? widget.child : FadeTransition(opacity: _fade, child: SlideTransition(position: _slide, child: widget.child));
}

/// A short wiggle every few seconds while [active] (e.g. the bell with unread messages).
/// Idle between wiggles: a timer starts each 0.6 s animation, so nothing renders in between.
class Wiggle extends StatefulWidget {
  const Wiggle({super.key, required this.child, required this.active});
  final Widget child;
  final bool active;
  @override
  State<Wiggle> createState() => _WiggleState();
}

class _WiggleState extends State<Wiggle> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  Timer? _timer;

  void _sync() {
    if (widget.active && _timer == null) {
      _c.forward(from: 0);
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) _c.forward(from: 0);
      });
    } else if (!widget.active && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant Wiggle old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        alignment: Alignment.topCenter,
        turns: _c.drive(TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.035), weight: 1),
          TweenSequenceItem(tween: Tween(begin: 0.035, end: -0.03), weight: 1),
          TweenSequenceItem(tween: Tween(begin: -0.03, end: 0.02), weight: 1),
          TweenSequenceItem(tween: Tween(begin: 0.02, end: 0.0), weight: 1),
        ])),
        child: widget.child,
      );
}

/// Brand gradient surface (static — a constantly moving gradient repaints every frame and costs battery).
class LivingGradient extends StatelessWidget {
  const LivingGradient({super.key, required this.colors, required this.child, this.borderRadius});
  final List<Color> colors;
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: colors),
        ),
        child: child,
      );
}
