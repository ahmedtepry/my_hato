import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

/// Order / repair number with a copy button, so the customer can paste it when contacting us.
class CopyCode extends StatefulWidget {
  const CopyCode({super.key, required this.code, this.style, this.color = BrandColors.electric, this.center = false});
  final String code;
  final TextStyle? style;
  final Color color;
  final bool center;

  @override
  State<CopyCode> createState() => _CopyCodeState();
}

class _CopyCodeState extends State<CopyCode> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    HapticFeedback.lightImpact();
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(context.isAr ? 'اتنسخ الرقم ${widget.code}' : 'Copied ${widget.code}'),
        duration: const Duration(seconds: 2),
        persist: false,
      ));
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: _copy,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            // shrinks to fit narrow spaces instead of running out of its card
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Directionality(textDirection: TextDirection.ltr, child: Text(widget.code, style: widget.style, maxLines: 1)),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(
                _copied ? Icons.check_circle_rounded : Icons.copy_rounded,
                key: ValueKey(_copied),
                size: ((widget.style?.fontSize ?? 16) * 0.85).clamp(16, 24),
                color: _copied ? BrandColors.success : widget.color,
              ),
            ),
          ]),
        ),
      );
}
