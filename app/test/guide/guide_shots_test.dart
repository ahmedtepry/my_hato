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
    ('NotoSans', 'build/fonts/NotoSans.ttf'),
    ('NotoColorEmoji', 'build/fonts/NotoColorEmoji.ttf'),
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

var _shotKey = GlobalKey();

/// Opens the console as [roles]/[perms] against the fake server.
Future<void> openConsole(WidgetTester t, {required Set<String> roles, required Set<String> perms, required Map<String, Object> rpc, String lang = 'ar', String look = 'midnight', Size size = const Size(1440, 900)}) async {
  _shotKey = GlobalKey();
  _missing.clear();
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
  var none = true;
  try {
    none = f.evaluate().isEmpty;
  } catch (_) {}
  if (none) {
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

Future<bool> tapTip(WidgetTester t, String tip) async {
  final f = find.byTooltip(tip);
  if (f.evaluate().isEmpty) {
    // ignore: avoid_print
    print('MISSING tooltip "$tip"');
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

/// Opens a console section (same as clicking it in the side list).
Future<bool> goTab(WidgetTester t, String id) async {
  final f = find.descendant(of: find.byType(DefaultTabController), matching: find.byType(AnimatedBuilder));
  if (f.evaluate().isEmpty) return false;
  final ctx = f.evaluate().first;
  final tabs = ProviderScope.containerOf(ctx).read(consoleTabsProvider);
  final i = tabs.indexOf(id);
  if (i < 0) {
    // ignore: avoid_print
    print('MISSING tab $id in $tabs');
    return false;
  }
  DefaultTabController.of(ctx).animateTo(i);
  await settle(t, rounds: 8);
  return true;
}

Future<void> typeInto(WidgetTester t, Set<String> labels, String text) async {
  for (final e in find.byType(TextField).evaluate()) {
    final w = e.widget as TextField;
    if (labels.contains(w.decoration?.labelText ?? '')) {
      await t.enterText(find.byWidget(w), text);
      await settle(t, rounds: 2);
      return;
    }
  }
  // ignore: avoid_print
  print('MISSING field $labels');
}

/// One job's guide pictures, in both languages.
void job(String name, Set<String> roles, Set<String> perms, Map<String, Object> Function() rpc, Future<void> Function(WidgetTester t, String lang, bool ar) steps) {
  for (final lang in const ['ar', 'en']) {
    testWidgets('$name $lang', (t) async {
      await openConsole(t, roles: roles, perms: perms, rpc: rpc(), lang: lang);
      await steps(t, lang, lang == 'ar');
    });
  }
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await _loadIcons();
  });

  job('cashier', {'cashier'}, cashierPerms, cashierRpc, (t, lang, ar) async {
    final p = '${lang}_cashier';
    await shot(t, '${p}_01_register');
    // the seller (only with an empty cart)
    await tapTip(t, ar ? 'تبديل البائع' : 'Switch seller');
    await shot(t, '${p}_05_seller');
    await tapText(t, 'محمد');
    await shot(t, '${p}_06_seller_pin');
    await closeDialog(t);
    await tapText(t, ar ? 'إسكرينة زجاج كاملة 9D / 11D / 21D' : 'Full-cover tempered glass 9D');
    await tapText(t, ar ? 'كابل Type-C مضفّر 1م' : 'Braided Type-C cable 1m');
    await tapText(t, ar ? 'كابل Type-C مضفّر 1م' : 'Braided Type-C cable 1m');
    await shot(t, '${p}_02_cart');
    await tapIcon(t, Icons.call_split_rounded);
    await typeInto(t, {'فيزا', 'Visa'}, '200');
    await shot(t, '${p}_03_split');
    await tapIcon(t, Icons.payments_outlined);
    await tapTip(t, ar ? 'تفاصيل الدرج' : 'Drawer details');
    await shot(t, '${p}_04_drawer');
    await closeDialog(t);
    await tapTip(t, ar ? 'المساعد' : 'Assistant');
    await shot(t, '${p}_07_assistant_menu');
    await closeDialog(t);
    // the tools sit in the "more" menu when the screen is narrow
    Future<void> tool(String arName, String enName, String name) async {
      if (!await tapTip(t, ar ? 'المزيد' : 'More')) return;
      await shot(t, '${p}_more_menu');
      await tapText(t, ar ? arName : enName);
      await shot(t, name);
    }

    await tool('مرتجع', 'Refund', '${p}_08_refund_find');
    await typeInto(t, {'رقم الفاتورة', 'Invoice number'}, '49988498');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    await shot(t, '${p}_09_refund');
    await closeDialog(t);
    await tool('مصروف', 'Expense', '${p}_10_expense');
    await closeDialog(t);
    await tapText(t, ar ? 'فاتورة جديدة' : 'New invoice');
    await tool('إقفال الوردية', 'Close shift', '${p}_11_close_shift');
    await closeDialog(t);
    await goTab(t, 'invoices');
    await shot(t, '${p}_12_invoices');
    await tapText(t, '49988498');
    await shot(t, '${p}_13_invoice_detail');
    await closeDialog(t);
    await goTab(t, 'mytarget');
    await shot(t, '${p}_14_my_target');
    await tapText(t, ar ? 'الشكل' : 'Look');
    await shot(t, '${p}_15_look');
    await closeDialog(t);
    await tapText(t, ar ? 'الألوان' : 'Colours');
    await shot(t, '${p}_16_colors');
    await closeDialog(t);
  });

  job('sales', {'sales'}, salesPerms, salesRpc, (t, lang, ar) async {
    final p = '${lang}_sales';
    await shot(t, '${p}_01_orders');
    await tapText(t, 'MH-24117');
    await shot(t, '${p}_02_order_detail');
    await closeDialog(t);
    await goTab(t, 'pos');
    await shot(t, '${p}_03_pos');
    await goTab(t, 'products');
    await shot(t, '${p}_04_products');
    await goTab(t, 'stock');
    await shot(t, '${p}_05_stock');
    await goTab(t, 'mytarget');
    await shot(t, '${p}_06_my_target');
  });

  job('repairs', {'technician'}, technicianPerms, repairsRpc, (t, lang, ar) async {
    final p = '${lang}_repairs';
    await shot(t, '${p}_01_list');
    await tapText(t, 'RP-1042');
    await shot(t, '${p}_02_detail');
    await closeDialog(t);
  });

  job('online', {'support'}, supportPerms, onlineRpc, (t, lang, ar) async {
    final p = '${lang}_online';
    await shot(t, '${p}_01_orders');
    await tapText(t, 'MH-24117');
    await shot(t, '${p}_02_order_detail');
    await closeDialog(t);
    await goTab(t, 'repairs');
    await shot(t, '${p}_03_repairs');
    await goTab(t, 'accounts');
    await shot(t, '${p}_04_accounts');
    await goTab(t, 'assistant');
    await shot(t, '${p}_05_assistant');
  });

  job('marketing', {'marketing'}, marketingPerms, marketingRpc, (t, lang, ar) async {
    final p = '${lang}_marketing';
    await shot(t, '${p}_01_home');
    await goTab(t, 'contests');
    await shot(t, '${p}_02_contests');
    await goTab(t, 'occasions');
    await shot(t, '${p}_03_occasions');
    await goTab(t, 'reviews');
    await shot(t, '${p}_04_reviews');
    await goTab(t, 'app_banners');
    await shot(t, '${p}_05_banners');
  });
}
