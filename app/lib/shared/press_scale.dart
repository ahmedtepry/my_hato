import 'package:flutter/material.dart';

/// Subtle press feedback: the child sinks a little while pressed and springs back on release.
/// Uses raw pointer events, so the child's own taps / ripples keep working; a scroll that starts on
/// it releases the press right away (no shrinking while the user is scrolling a list).
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.scale = 0.965, this.enabled = true});
  final Widget child;
  final double scale;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  Offset? _start;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _start = e.position;
        _set(true);
      },
      onPointerMove: (e) {
        if (_start != null && (e.position - _start!).distance > 12) _set(false);
      },
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down ? const Duration(milliseconds: 110) : const Duration(milliseconds: 260),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
