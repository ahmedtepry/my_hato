import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/shared/app_banner.dart';

Widget _host(Map<String, dynamic> b, {VoidCallback? onTap}) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 360, child: AppBannerCard(banner: b, onTap: onTap))))),
    );

void main() {
  test('every look has its height and every colour has a gradient', () {
    expect(bannerHeight('gradient'), 88);
    expect(bannerHeight('pill'), 56);
    expect(bannerHeight('product'), 96);
    expect(bannerHeight('image'), 160);
    for (final c in bannerColors) {
      expect(bannerGradient(c).length, 2);
    }
    expect(bannerGradient('unknown'), bannerGradient('blue'));
  });

  testWidgets('gradient banner shows title, button word and opens on tap', (t) async {
    var taps = 0;
    await t.pumpWidget(_host({'style': 'gradient', 'color': 'blue', 'title_ar': 'خصم 20%', 'title_en': 'خصم 20%', 'cta_ar': 'تسوق', 'emoji': '📱'}, onTap: () => taps++));
    expect(find.text('خصم 20%'), findsOneWidget);
    expect(find.text('تسوق'), findsOneWidget);
    await t.tap(find.text('خصم 20%'));
    expect(taps, 1);
  });

  testWidgets('pill banner has a default button word', (t) async {
    await t.pumpWidget(_host({'style': 'pill', 'color': 'orange', 'title_ar': 'شحن مجاني', 'title_en': 'شحن مجاني'}, onTap: () {}));
    expect(find.text('شحن مجاني'), findsOneWidget);
    expect(find.text('شوف').evaluate().length + find.text('View').evaluate().length, 1);
  });

  testWidgets('product banner shows price, old price and badge', (t) async {
    await t.pumpWidget(_host({'style': 'product', 'title_ar': 'سماعة', 'title_en': 'Headset', 'price_text': '375 ج.م', 'old_price_text': '500 ج.م', 'badge': '-25%', 'emoji': '🎧'}));
    expect(find.text('375 ج.م'), findsOneWidget);
    expect(find.text('500 ج.م'), findsOneWidget);
    expect(find.text('-25%'), findsOneWidget);
  });
}
