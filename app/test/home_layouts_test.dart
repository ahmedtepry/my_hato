import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/core/l10n.dart';
import 'package:myhato/core/supabase_providers.dart';
import 'package:myhato/core/theme.dart';
import 'package:myhato/features/home/home_layouts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Renders every home layout (with 8, 1 and 0 products) and taps the grid/rows switch, so a build exception shows up here before a customer sees it.
void main() {
  List<Map<String, dynamic>> data(int n) => [
        for (var i = 0; i < n; i++)
          {
            'id': 'p$i',
            'name_ar': 'منتج رقم $i بإسم طويل شوية عشان نشوف الأسطر',
            'name_en': 'Product $i',
            'price_minor': 19000 + i * 100,
            'compare_at_price_minor': i % 3 == 0 ? 25000 : null,
            'discount_percent': i % 3 == 0 ? 24 : 0,
            'in_stock': i != 5,
            'thumb_path': null,
            'brand_name_ar': i.isEven ? 'سامسونج' : null,
            'model': i.isEven ? 'A54' : null,
          }
      ];

  for (final layout in HomeLayout.values) {
    for (final n in [8, 1, 0]) {
      testWidgets('layout ${layout.name} with $n products', (t) async {
        t.view.physicalSize = const Size(1080, 2280);
        t.view.devicePixelRatio = 2.625;
        addTearDown(t.view.reset);
        await t.pumpWidget(ProviderScope(
          overrides: [supabaseProvider.overrideWithValue(SupabaseClient('https://example.supabase.co', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)))],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('ar'),
            supportedLocales: supportedLocales,
            localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
            theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: BrandColors.offWhite),
            home: Scaffold(body: SingleChildScrollView(child: Column(children: [HomeProducts(items: data(n), layout: layout)]))),
          ),
        ));
        await t.pump(const Duration(milliseconds: 600));
        final e1 = t.takeException();
        if (layout == HomeLayout.toggle && n > 0) {
          await t.tap(find.byIcon(Icons.view_agenda_outlined));
          await t.pump(const Duration(milliseconds: 600));
          final e2 = t.takeException();
          expect(e2, isNull, reason: 'toggle to rows: $e2');
          await t.tap(find.byIcon(Icons.grid_view_rounded));
          await t.pump(const Duration(milliseconds: 600));
          final e3 = t.takeException();
          expect(e3, isNull, reason: 'toggle to grid: $e3');
        }
        expect(e1, isNull, reason: 'first build: $e1');
      });
    }
  }
}
