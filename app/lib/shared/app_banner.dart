// "بانرات التطبيق": the small eye-catching banners on the customer home screen.
// One widget draws all four looks, so the customer app and the owner's live preview always match.
//   image (160px, picture)  ·  gradient (88px)  ·  pill (56px)  ·  product (96px)
import 'package:flutter/material.dart';

import '../core/l10n.dart';
import 'product_card.dart' show NetImage;

const bannerStyles = ['gradient', 'pill', 'product', 'image'];
const bannerColors = ['blue', 'navy', 'orange', 'green', 'red', 'purple'];

const _grads = <String, List<Color>>{
  'blue': [Color(0xFF0B2D5B), Color(0xFF00A3FF)],
  'navy': [Color(0xFF071C3A), Color(0xFF0B2D5B)],
  'orange': [Color(0xFFF79009), Color(0xFFD92D20)],
  'green': [Color(0xFF12B76A), Color(0xFF0B2D5B)],
  'red': [Color(0xFFD92D20), Color(0xFF7A271A)],
  'purple': [Color(0xFF7F56D9), Color(0xFF2F6BFF)],
};

List<Color> bannerGradient(String? c) => _grads[c] ?? _grads['blue']!;
double bannerHeight(String style) => switch (style) { 'pill' => 56, 'product' => 96, 'image' => 160, _ => 88 };

class AppBannerCard extends StatelessWidget {
  const AppBannerCard({super.key, required this.banner, this.onTap});
  final Map<String, dynamic> banner;
  final VoidCallback? onTap;

  String _s(String f) => (banner[f] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final style = _s('style').isEmpty ? 'image' : _s('style');
    final title = context.pick(banner, 'title');
    final sub = context.pick(banner, 'subtitle');
    final cta = context.pick(banner, 'cta');
    final g = bannerGradient(_s('color'));
    final emoji = _s('emoji');
    final ar = context.isAr;
    final pr = ar || _s('price_text_en').isEmpty ? 'price_text' : 'price_text_en';
    final opr = ar || _s('old_price_text_en').isEmpty ? 'old_price_text' : 'old_price_text_en';

    Widget pill(String t) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
          child: Text(t, style: TextStyle(color: g.first, fontSize: 11, fontWeight: FontWeight.w800)),
        );

    final child = switch (style) {
      'pill' => Container(
          height: 56,
          padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: g.last, width: 1.5),
            boxShadow: [BoxShadow(color: g.last.withValues(alpha: .14), blurRadius: 0, spreadRadius: 4)],
          ),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: g)),
              child: Text(emoji.isEmpty ? '🔥' : emoji, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF0B2D5B), fontSize: 13, fontWeight: FontWeight.w800)),
                if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF667085), fontSize: 11)),
              ]),
            ),
            if (cta.isNotEmpty || onTap != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(color: const Color(0xFF0B2D5B), borderRadius: BorderRadius.circular(18)),
                child: Text(cta.isEmpty ? (ar ? 'شوف' : 'View') : cta, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      'product' => Container(
          height: 96,
          clipBehavior: Clip.hardEdge,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: g.first == const Color(0xFF071C3A) ? g.first : const Color(0xFF071C3A),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: g.last, width: 1),
          ),
          child: Stack(children: [
            Row(children: [
              Container(
                width: 72,
                height: 72,
                clipBehavior: Clip.hardEdge,
                alignment: Alignment.center,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: Colors.white.withValues(alpha: .12)),
                child: _s('image_path').isNotEmpty
                    ? SizedBox.expand(child: NetImage(path: _s('image_path'), bucket: _s('image_bucket').isEmpty ? 'banners' : _s('image_bucket'), thumb: true))
                    : Text(emoji.isEmpty ? '🎁' : emoji, style: const TextStyle(fontSize: 36)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                  if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF9AD7FF), fontSize: 11)),
                  if (_s(pr).isNotEmpty)
                    Row(children: [
                      Text(_s(pr), style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                      if (_s(opr).isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(_s(opr), style: const TextStyle(color: Color(0xFF98A2B3), fontSize: 11, decoration: TextDecoration.lineThrough)),
                      ],
                    ]),
                ]),
              ),
            ]),
            if (_s('badge').isNotEmpty)
              PositionedDirectional(
                top: -10,
                start: -10,
                child: Container(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 14, 12, 5),
                  decoration: const BoxDecoration(color: Color(0xFFD92D20), borderRadius: BorderRadiusDirectional.only(bottomEnd: Radius.circular(14))),
                  child: Text(_s('badge'), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
      'image' => ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 160,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(path: _s('image_path'), bucket: 'banners'),
              Container(
                alignment: AlignmentDirectional.bottomStart,
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xCC0B2D5B)])),
                child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ),
      _ => Container(
          height: 88,
          clipBehavior: Clip.hardEdge,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: LinearGradient(colors: g)),
          child: Stack(children: [
            PositionedDirectional(
              end: -25,
              top: -35,
              child: Container(width: 110, height: 110, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .15))),
            ),
            Row(children: [
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                  if (sub.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11))),
                  if (cta.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: pill(cta)),
                ]),
              ),
              if (emoji.isNotEmpty) Transform.rotate(angle: -.2, child: Text(emoji, style: const TextStyle(fontSize: 44))),
            ]),
          ]),
        ),
    };

    return Semantics(
      button: onTap != null,
      label: title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(borderRadius: BorderRadius.circular(style == 'pill' ? 28 : 20), onTap: onTap, child: child),
      ),
    );
  }
}
