import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'core/l10n.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'shared/phone_notifications.dart';
import 'shared/staff_presence.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // In a release build a screen that throws while drawing turns into a blank grey box. Show a readable message instead,
  // and keep errors from other code from taking the app down.
  ErrorWidget.builder = (details) => const _BrokenScreen();
  FlutterError.onError = (d) => FlutterError.presentError(d);
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: $error');
    return true;
  };
  final prefs = await SharedPreferences.getInstance();

  if (!AppConfig.isConfigured) {
    runApp(const _MisconfiguredApp());
    return;
  }
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
    debug: false, // never log auth/session details in release
  );

  await PhoneNotifications.init();

  runApp(ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const MyHatoApp(),
  ));
}

class MyHatoApp extends ConsumerWidget {
  const MyHatoApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'My Hatō',
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: supportedLocales,
      // Provides RTL for Arabic and LTR for English automatically.
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(locale),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => StaffPresenceScope(child: child ?? const SizedBox.shrink()),
    );
  }
}

class _MisconfiguredApp extends StatelessWidget {
  const _MisconfiguredApp();
  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'التطبيق غير متصل بالخادم.\nBuild with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
}

/// Replaces the grey box Flutter paints in release when a screen fails to build.
class _BrokenScreen extends StatelessWidget {
  const _BrokenScreen();
  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          color: const Color(0xFFF4F6FA),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.sentiment_dissatisfied_rounded, size: 48, color: Color(0xFF6B7488)),
                SizedBox(height: 12),
                Text('حصلت مشكلة في الشاشة دي',
                    textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF14213D))),
                SizedBox(height: 6),
                Text('ارجع للشاشة اللي قبلها وافتحها تاني.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Color(0xFF6B7488))),
              ]),
            ),
          ),
        ),
      );
}
