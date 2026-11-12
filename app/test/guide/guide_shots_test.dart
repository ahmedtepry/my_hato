// Takes pictures of the real team-app screens for the staff guides (PDF).
// The screens are the app's own widgets, opened against a fake server that answers with sample data, so nothing is
// read from or written to the real database. Run by .github/workflows/guide-shots.yml; pictures go to build/guide_shots.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myhato/core/l10n.dart';
import 'package:myhato/core/supabase_providers.dart';
import 'package:myhato/core/theme.dart';
import 'package:myhato/features/admin/admin_repository.dart';
import 'package:myhato/features/admin/admin_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fixtures.dart';

final _missing = <String>{};

class _Obs extends ProviderObserver {
  @override
  void providerDidFail(ProviderBase<Object?> provider, Object error, StackTrace stackTrace, ProviderContainer container) {
    // ignore: avoid_print
    print('FAIL ${provider.name ?? provider.runtimeType}: ${'$error'.split('\n').first}');
  }
}

class _Staff extends StaffContextController {
  _Staff(this.roles, this.perms);
  final Set<String> roles, perms;
  @override
  Future<StaffContext> build() async => StaffContext(roles, perms);
}

Future<void> _loadIcons() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  for (final (family, file) in [
    ('MaterialIcons', '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'),
  ]) {
    final f = File(file);
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('MISSING font $file');
      continue;
    }
    final l = FontLoader(family)..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
    await l.load();
  }
}

final _shotKey = GlobalKey();

/// Opens the console as [roles]/[perms] against the fake server.
Future<void> openConsole(WidgetTester t, {required Set<String> roles, required Set<String> perms, required Map<String, Object> rpc, String lang = 'ar', String look = 'midnight', Size size = const Size(1440, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  SharedPreferences.setMockInitialValues({'app_locale': lang, 'console_look': look, 'welcome_seen_v2': true});
  final prefs = await SharedPreferences.getInstance();
  final client = MockClient.streaming((req, body) async {
    final raw = await body.toBytes();
    final name = req.url.pathSegments.isEmpty ? '' : req.url.pathSegments.last;
    Object? res = rpc[name];
    if (res is Object Function(Map<String, dynamic>)) {
      Map<String, dynamic> args = {};
      try {
        args = Map<String, dynamic>.from(jsonDecode(utf8.decode(raw)) as Map);
      } catch (_) {}
      res = res(args);
    }
    if (res == null) {
      if (_missing.add(name)) {
        // ignore: avoid_print
        print('MISSING ${req.method} ${req.url.path}${req.url.query.isEmpty ? '' : '?${req.url.query}'}');
      }
    }
    final bytes = utf8.encode(jsonEncode(res ?? (req.url.path.contains('/rpc/') ? null : <Object>[])));
    return http.StreamedResponse(Stream.value(bytes), 200, request: req, headers: {'content-type': 'application/json; charset=utf-8'}, contentLength: bytes.length);
  });
  final sb = SupabaseClient('https://example.supabase.co', 'anon', httpClient: client, authOptions: const AuthClientOptions(autoRefreshToken: false));
  final user = User(
    id: fakeUserId,
    appMetadata: const {},
    userMetadata: const {'full_name': 'أحمد'},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
    email: 'ahmed@myhato.app',
  );
  final locale = Locale(lang);
  await t.pumpWidget(ProviderScope(
    observers: [_Obs()],
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      supabaseProvider.overrideWithValue(sb),
      currentUserProvider.overrideWithValue(user),
      staffContextProvider.overrideWith(() => _Staff(roles, perms)),
    ],
    child: RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        supportedLocales: supportedLocales,
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        theme: AppTheme.light(locale),
        builder: (context, child) => ColoredBox(color: BrandColors.offWhite, child: SizedBox.expand(child: child)),
        home: const AdminHomeScreen(),
      ),
    ),
  ));
  await settle(t);
}

/// Lets requests answer and animations finish.
Future<void> settle(WidgetTester t, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await t.pump(const Duration(milliseconds: 250));
  }
}

/// Saves the whole window as build/guide_shots/[name].png.
Future<void> shot(WidgetTester t, String name) async {
  await settle(t, rounds: 3);
  final b = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final img = await b.toImage(pixelRatio: 1.5);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('build/guide_shots/$name.png');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(data!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('SHOT $name');
}

/// Taps the first widget showing [text] (if it is there).
Future<bool> tapText(WidgetTester t, String text) async {
  final f = find.text(text);
  if (f.evaluate().isEmpty) {
    // ignore: avoid_print
    print('MISSING text "$text"');
    return false;
  }
  await t.tap(f.first, warnIfMissed: false);
  await settle(t);
  return true;
}

Future<bool> tapIcon(WidgetTester t, IconData icon) async {
  final f = find.byIcon(icon);
  if (f.evaluate().isEmpty) {
    // ignore: avoid_print
    print('MISSING icon ${icon.codePoint}');
    return false;
  }
  await t.tap(f.first, warnIfMissed: false);
  await settle(t);
  return true;
}

Future<void> closeDialog(WidgetTester t) async {
  final nav = find.byType(Navigator);
  if (nav.evaluate().isEmpty) return;
  t.state<NavigatorState>(nav.last).maybePop();
  await settle(t);
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await _loadIcons();
  });

  for (final lang in const ['ar', 'en']) {
    testWidgets('cashier $lang', (t) async {
      await openConsole(t, roles: {'cashier'}, perms: cashierPerms, rpc: cashierRpc(), lang: lang);
      await shot(t, '${lang}_cashier_01_register');
      // two products in the cart
      final ar = lang == 'ar';
      await tapText(t, ar ? 'إسكرينة زجاج كاملة 9D / 11D / 21D' : 'Full-cover tempered glass 9D');
      await tapText(t, ar ? 'كابل Type-C مضفّر 1م' : 'Braided Type-C cable 1m');
      await tapText(t, ar ? 'كابل Type-C مضفّر 1م' : 'Braided Type-C cable 1m');
      await shot(t, '${lang}_cashier_02_cart');
      // split payment
      await tapIcon(t, Icons.call_split_rounded);
      final fields = find.byType(TextField);
      for (final e in fields.evaluate()) {
        final w = e.widget as TextField;
        final label = w.decoration?.labelText ?? '';
        if (label == 'فيزا' || label == 'Visa') await t.enterText(find.byWidget(w), '200');
      }
      await settle(t);
      await shot(t, '${lang}_cashier_03_split');
    });
  }
}
