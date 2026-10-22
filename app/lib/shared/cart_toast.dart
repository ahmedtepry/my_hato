import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

OverlayEntry? _current;

/// Small animated "added to cart" badge near the top of the screen. It pops in, shows a check
/// that draws itself, and disappears on its own after ~3 seconds, so it never covers the
/// buttons at the bottom. Tapping it opens the cart.
void showAddedToCart(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final router = GoRouter.maybeOf(context);
  _current?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _CartToast(
      label: context.tr('added_to_cart'),
      onTap: router == null ? null : () => router.go('/cart'),
      onDone: () {
        if (_current == entry) _current = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _current = entry;
  overlay.insert(entry);
}

class _CartToast extends StatefulWidget {
  const _CartToast({required this.label, required this.onDone, this.onTap});
  final String label;
  final VoidCallback onDone;
  final VoidCallback? onTap;
  @override
  State<_CartToast> createState() => _CartToastState();
}

class _CartToastState extends State<_CartToast> with SingleTickerProviderStateMixin {
  // 0.00–0.15 pop in · 0.15–0.85 hold (check draws) · 0.85–1.00 fade out  => 3 s total
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3000));
  late final _in = CurvedAnimation(parent: _c, curve: const Interval(0, 0.15, curve: Curves.easeOutBack));
  late final _check = CurvedAnimation(parent: _c, curve: const Interval(0.08, 0.3, curve: Curves.easeOutCubic));
  late final _out = CurvedAnimation(parent: _c, curve: const Interval(0.85, 1, curve: Curves.easeIn));

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _close() {
    if (_c.value < 0.85) _c.animateTo(1, duration: const Duration(milliseconds: 220));
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 10;
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            final v = _in.value * (1 - _out.value);
            return Opacity(
              opacity: v.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, -24 * (1 - _in.value) - 12 * _out.value),
                child: Transform.scale(scale: 0.7 + 0.3 * _in.value - 0.08 * _out.value, child: child),
              ),
            );
          },
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: () {
                widget.onTap?.call();
                _close();
              },
              onVerticalDragEnd: (_) => _close(),
              child: Container(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 7, 16, 7),
                decoration: BoxDecoration(
                  color: BrandColors.navy,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 6))],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: const BoxDecoration(color: BrandColors.electric, shape: BoxShape.circle),
                    child: AnimatedBuilder(
                      animation: _check,
                      builder: (_, __) => CustomPaint(painter: _CheckPainter(_check.value)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.shopping_bag_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Text(widget.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Check mark that draws itself from 0 to 1.
class _CheckPainter extends CustomPainter {
  _CheckPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Offset(size.width * 0.28, size.height * 0.53);
    final p2 = Offset(size.width * 0.44, size.height * 0.68);
    final p3 = Offset(size.width * 0.73, size.height * 0.36);
    final first = (p2 - p1).distance, second = (p3 - p2).distance;
    var len = (first + second) * t;
    final path = Path()..moveTo(p1.dx, p1.dy);
    if (len <= first) {
      final e = Offset.lerp(p1, p2, len / first)!;
      path.lineTo(e.dx, e.dy);
    } else {
      path.lineTo(p2.dx, p2.dy);
      len -= first;
      final e = Offset.lerp(p2, p3, (len / second).clamp(0.0, 1.0))!;
      path.lineTo(e.dx, e.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t;
}
