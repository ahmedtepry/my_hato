import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/reduce_motion.dart';

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
  late final bool _skip = ReduceMotion.on || (widget.id != null && FadeSlideIn._seen.contains(widget.id));
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

/// Section switch for the team console: the old page fades away fast, the new one fades in while rising a few pixels.
class SoftPageSwitch extends StatelessWidget {
  const SoftPageSwitch({super.key, required this.index, required this.children});
  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ReduceMotion.on
      ? KeyedSubtree(key: ValueKey(index), child: children[index])
      : AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        reverseDuration: const Duration(milliseconds: 110),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(position: Tween(begin: const Offset(0, .018), end: Offset.zero).animate(anim), child: child),
        ),
        child: KeyedSubtree(key: ValueKey(index), child: children[index]),
      );
}

/// Counts a number up from 0 (and between values when it changes): "1,250 ج.م" keeps its prefix, suffix and thousands separators.
class CountUpText extends StatelessWidget {
  const CountUpText(this.text, {super.key, this.style, this.duration = const Duration(milliseconds: 750)});
  final String text;
  final TextStyle? style;
  final Duration duration;

  static final _num = RegExp(r'[0-9][0-9,]*(?:\.[0-9]+)?');

  @override
  Widget build(BuildContext context) {
    final m = _num.firstMatch(text);
    if (m == null || ReduceMotion.on) return Text(text, style: style);
    final raw = m.group(0)!;
    final target = double.tryParse(raw.replaceAll(',', ''));
    if (target == null) return Text(text, style: style);
    final decimals = raw.contains('.') ? raw.split('.').last.length : 0;
    final grouped = raw.contains(',');
    String fmt(double v) {
      var s = v.toStringAsFixed(decimals);
      if (grouped) {
        final parts = s.split('.');
        parts[0] = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
        s = parts.join('.');
      }
      return s;
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => Text('${text.substring(0, m.start)}${fmt(v)}${text.substring(m.end)}', style: style),
    );
  }
}

/// Dialog that scales in softly over a blurred, dimmed backdrop (instead of the plain fade).
Future<T?> showSmoothDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
}) {
  if (ReduceMotion.on) {
    // fast mode: a plain dialog, no blur and no zoom
    return showDialog<T>(context: context, barrierDismissible: barrierDismissible, barrierColor: barrierColor, useRootNavigator: useRootNavigator, builder: builder);
  }
  final theme = Theme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 240),
    useRootNavigator: useRootNavigator,
    pageBuilder: (ctx, a, b) => Theme(data: theme, child: SafeArea(child: Builder(builder: builder))),
    transitionBuilder: (ctx, anim, _, child) {
      final c = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeIn);
      return AnimatedBuilder(
        animation: c,
        builder: (_, __) => Stack(fit: StackFit.expand, children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: barrierDismissible ? () => Navigator.of(ctx, rootNavigator: useRootNavigator).maybePop() : null,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6 * c.value, sigmaY: 6 * c.value),
                child: ColoredBox(color: (barrierColor ?? Colors.black54).withValues(alpha: (barrierColor ?? Colors.black54).a * c.value)),
              ),
            ),
          ),
          Opacity(opacity: c.value, child: Transform.scale(scale: .94 + .06 * c.value, child: child)),
        ]),
      );
    },
  );
}

/// Disposes a dialog's text box once the dialog's closing animation is over.
/// Disposing it right after the dialog returns breaks that animation ("TextEditingController used after being disposed").
void disposeLater(ChangeNotifier c) => Future<void>.delayed(const Duration(milliseconds: 700), c.dispose);
