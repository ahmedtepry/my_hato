import 'package:flutter/material.dart';

import '../core/theme.dart';

/// One button of the console's left control column: a 22px icon over a short 10px label, the same size for every button.
/// A small dot (e.g. "assistant is on") or a count bubble (e.g. unread messages) sits on its corner instead of extra text.
class RailTile extends StatelessWidget {
  const RailTile({super.key, required this.icon, required this.label, required this.tooltip, required this.onTap, this.dot, this.count, this.bg = Colors.white, this.fg = BrandColors.navy, this.glow = false, this.glass = false});
  final Widget icon;
  final String label, tooltip;
  final VoidCallback? onTap;
  final Color? dot;
  final String? count;
  final Color bg, fg;
  final bool glow, glass;

  static const double width = 62, height = 54;

  @override
  Widget build(BuildContext context) => Center(
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: width,
            height: height,
            child: Material(
              color: bg,
              elevation: glass ? 0 : (glow ? 4 : 1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: glass ? Colors.white24 : BrandColors.border)),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: Stack(alignment: Alignment.center, children: [
                  Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(height: 24, width: 28, child: FittedBox(child: icon)),
                    const SizedBox(height: 3),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 10, height: 1.1, fontWeight: FontWeight.w700, color: onTap == null ? (glass ? Colors.white38 : BrandColors.gray) : fg)),
                    ),
                  ]),
                  if (dot != null) PositionedDirectional(top: 6, end: 8, child: Container(width: 9, height: 9, decoration: BoxDecoration(color: dot, shape: BoxShape.circle, border: Border.all(color: bg, width: 1.5)))),
                  if (count != null)
                    PositionedDirectional(
                      top: 3,
                      end: 5,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: BrandColors.error, borderRadius: BorderRadius.circular(8)),
                        child: Text(count!, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800, height: 1.2)),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// A thin line between groups of buttons in the column.
class RailSep extends StatelessWidget {
  const RailSep({super.key});
  @override
  Widget build(BuildContext context) => Center(child: Container(width: 36, height: 1, margin: const EdgeInsets.symmetric(vertical: 6), color: Colors.grey.withValues(alpha: .45)));
}
