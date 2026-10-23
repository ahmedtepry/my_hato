// A floating gold trophy on the home screen: tap = open the rewards page, drag = put it anywhere.
// Drag it down to the bottom edge (next to the bottom bar) and it is thrown away; it stays gone until the app is
// closed and opened again.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/l10n.dart';

const _gold = Color(0xFFF5B83D);

class LoyaltyShortcut extends ConsumerStatefulWidget {
  const LoyaltyShortcut({super.key});

  /// Lives only in memory: a new app launch brings the trophy back.
  static bool _thrownAway = false;

  @override
  ConsumerState<LoyaltyShortcut> createState() => _LoyaltyShortcutState();
}

class _LoyaltyShortcutState extends ConsumerState<LoyaltyShortcut> with SingleTickerProviderStateMixin {
  static const _size = 58.0;
  static const _binHeight = 96.0;
  late final AnimationController _throw = AnimationController(vsync: this, duration: const Duration(milliseconds: 750))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() {});
    });
  Offset? _pos; // top-left inside the available area
  bool _dragging = false, _overBin = false;

  @override
  void dispose() {
    _throw.dispose();
    super.dispose();
  }

  Offset _initial(Size area) {
    final prefs = ref.read(sharedPrefsProvider);
    final fx = prefs.getDouble('loyalty_fab_x'), fy = prefs.getDouble('loyalty_fab_y');
    final maxX = area.width - _size, maxY = area.height - _size;
    if (fx != null && fy != null) return Offset((fx * maxX).clamp(0, maxX), (fy * maxY).clamp(0, maxY - _binHeight));
    return Offset(area.width - _size - 14, area.height * 0.6);
  }

  void _save(Size area) {
    final p = _pos;
    if (p == null) return;
    final prefs = ref.read(sharedPrefsProvider);
    prefs.setDouble('loyalty_fab_x', p.dx / math.max(area.width - _size, 1));
    prefs.setDouble('loyalty_fab_y', p.dy / math.max(area.height - _size, 1));
  }

  @override
  Widget build(BuildContext context) {
    if (LoyaltyShortcut._thrownAway && !_throw.isAnimating) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      final area = Size(box.maxWidth, box.maxHeight);
      final pos = _pos ??= _initial(area);
      final ar = context.isAr;
      return Stack(children: [
        if (_dragging)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _binHeight,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.red.withValues(alpha: _overBin ? 0.55 : 0.28), Colors.transparent],
                  ),
                ),
                child: Align(
                  alignment: const Alignment(0, 0.55),
                  child: AnimatedScale(
                    scale: _overBin ? 1.25 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 28),
                      Text(ar ? 'سيبها هنا عشان تتشال' : 'Drop here to remove', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        AnimatedBuilder(
          animation: _throw,
          builder: (_, child) {
            final t = Curves.easeIn.transform(_throw.value);
            return Positioned(
              left: pos.dx,
              top: pos.dy + t * 260, // it falls away
              child: Opacity(
                opacity: (1 - t).clamp(0, 1),
                child: Transform.rotate(angle: t * math.pi * 3, child: Transform.scale(scale: 1 - t * 0.6, child: child)),
              ),
            );
          },
          child: GestureDetector(
            onTap: () => context.push('/loyalty'),
            onPanStart: (_) {
              HapticFeedback.selectionClick();
              setState(() => _dragging = true);
            },
            onPanUpdate: (d) => setState(() {
              final p = _pos!;
              _pos = Offset((p.dx + d.delta.dx).clamp(0, area.width - _size), (p.dy + d.delta.dy).clamp(0, area.height - _size));
              _overBin = _pos!.dy + _size / 2 > area.height - _binHeight;
            }),
            onPanEnd: (_) async {
              if (_overBin) {
                HapticFeedback.mediumImpact();
                setState(() => _dragging = false);
                LoyaltyShortcut._thrownAway = true;
                await _throw.forward();
                return;
              }
              setState(() {
                _dragging = false;
                _overBin = false;
              });
              _save(area);
            },
            child: Semantics(
              button: true,
              label: ar ? 'مكافآت My Hatō' : 'My Hatō Rewards',
              child: AnimatedScale(
                scale: _dragging ? 1.12 : 1,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  width: _size,
                  height: _size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFE08A), _gold, Color(0xFFD99A00)]),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.7), width: 2),
                    boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.55), blurRadius: 16, spreadRadius: 1), const BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3))],
                  ),
                  child: const Icon(Icons.emoji_events_rounded, color: Color(0xFF14213D), size: 31),
                ),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}
