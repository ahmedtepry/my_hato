import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:myhato/core/l10n.dart';
import 'package:myhato/features/catalog/catalog_repository.dart';
import 'package:myhato/features/catalog/used_screen.dart';

Widget _wrap(Locale locale) => ProviderScope(
      overrides: [usedEnabledProvider.overrideWith((ref) async => false)],
      child: MaterialApp(
        locale: locale,
        supportedLocales: supportedLocales,
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        home: const UsedScreen(),
      ),
    );

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('Used section shows Coming Soon in Arabic (RTL)', (t) async {
    await t.pumpWidget(_wrap(const Locale('ar')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('قريبًا'), findsOneWidget);
    expect(find.text('الأجهزة المستعملة'), findsOneWidget);
    expect(Directionality.of(t.element(find.text('قريبًا'))), TextDirection.rtl);
  });

  testWidgets('Used section shows Coming soon in English (LTR)', (t) async {
    await t.pumpWidget(_wrap(const Locale('en')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Coming soon'), findsOneWidget);
    expect(Directionality.of(t.element(find.text('Coming soon'))), TextDirection.ltr);
  });
}
