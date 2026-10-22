import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/core/l10n.dart';
import 'package:myhato/core/supabase_providers.dart';
import 'package:myhato/core/theme.dart';
import 'package:myhato/shared/product_card.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Renders the catalog grid on a phone-sized screen (CI publishes it for design review).
void main() {
  testWidgets('product grid preview', (t) async {
    t.view.physicalSize = const Size(1080, 2280);
    t.view.devicePixelRatio = 2.625;
    addTearDown(t.view.reset);
    final items = [
      for (var i = 0; i < 8; i++)
        {
          'id': 'p$i',
          'name_ar': ['سماعة بلوتوث صغيرة (Mini Speaker)', 'حامل سيارة أوتوماتيك بشاحن لاسلكي', 'شاحن GaN سريع 20W', 'كابل 3 في 1 Type-C'][i % 4],
          'name_en': 'Product $i',
          'price_minor': [19000, 28000, 14900, 7900][i % 4],
          'compare_at_price_minor': i % 3 == 0 ? 25000 : null,
          'discount_percent': i % 3 == 0 ? 24 : 0,
          'in_stock': i != 5,
          'thumb_path': null,
        }
    ];
    await t.pumpWidget(ProviderScope(
      overrides: [supabaseProvider.overrideWithValue(SupabaseClient('https://example.supabase.co', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)))],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: supportedLocales,
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: BrandColors.offWhite),
        home: Scaffold(
          appBar: AppBar(title: const Text('إكسسوارات')),
          body: RepaintBoundary(
            key: const ValueKey('grid'),
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.84),
              itemCount: items.length,
              itemBuilder: (_, i) => ProductCard(p: items[i]),
            ),
          ),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/product_grid.png'));
  });
}
