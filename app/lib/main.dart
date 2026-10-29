import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/app_update.dart';
import 'core/config.dart';
import 'core/dark_mode.dart';
import 'features/admin/direct_chat.dart' show chatFloatProvider, chatOpenProvider, chatPanelSpace;
import 'core/l10n.dart';
import 'core/router.dart';
import 'core/appearance.dart';
import 'core/team_theme.dart';
import 'core/theme.dart';
import 'shared/connection_gate.dart';
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
  if (!await _startSupabase()) {
    // no connection at launch: show the offline page and keep retrying until the server is reachable
    runApp(_StartupOffline(onReady: () => _launch(prefs)));
    return;
  }
  await _launch(prefs);
}

Future<bool> _startSupabase() async {
  try {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
      debug: false, // never log auth/session details in release
    ).timeout(const Duration(seconds: 10));
    return true;
  } catch (_) {
    try {
      final _ = Supabase.instance.client; // already initialised (only the session refresh failed)
      return true;
    } catch (_) {
      return false;
    }
  }
}

Future<void> _launch(SharedPreferences prefs) async {
  await PhoneNotifications.init();
  applySavedPalette(prefs);
  runApp(ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const MyHatoApp(),
  ));
}

/// Shown when the app is opened with no internet, before anything could be loaded.
class _StartupOffline extends StatefulWidget {
  const _StartupOffline({required this.onReady});
  final Future<void> Function() onReady;
  @override
  State<_StartupOffline> createState() => _StartupOfflineState();
}

class _StartupOfflineState extends State<_StartupOffline> {
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _retry());
  }

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _startSupabase();
    if (!mounted) return;
    if (ok) {
      _timer?.cancel();
      await widget.onReady();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(const Locale('ar')),
      locale: const Locale('ar'),
      supportedLocales: supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.10), shape: BoxShape.circle),
                  child: const Icon(Icons.wifi_off_rounded, size: 42, color: BrandColors.electric),
                ),
                const SizedBox(height: 24),
                Builder(builder: (c) => Text(c.tr('no_internet_title'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: BrandColors.navy))),
                const SizedBox(height: 10),
                Builder(builder: (c) => Text(c.tr('no_internet_body'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, height: 1.7, color: BrandColors.gray))),
                const SizedBox(height: 28),
                Builder(
                  builder: (c) => FilledButton.icon(
                    onPressed: _busy ? null : _retry,
                    icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.refresh_rounded),
                    label: Text(c.tr(_busy ? 'no_internet_checking' : 'no_internet_retry')),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class MyHatoApp extends ConsumerWidget {
  const MyHatoApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final dark = ref.watch(darkModeProvider);
    final chatOpen = AppConfig.teamOnly && ref.watch(chatOpenProvider) && !ref.watch(chatFloatProvider);
    ref.watch(appearanceProvider); // rebuilds the theme when the owner changes the colours
    if (AppConfig.teamOnly) ref.watch(teamThemeProvider); // the team app's own colour theme
    return MaterialApp.router(
      title: AppName.en,
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
      builder: (context, child) {
        Widget app = StaffPresenceScope(child: ConnectionGate(child: child ?? const SizedBox.shrink()));
        if (AppConfig.teamOnly) {
          // wide desktop window: keep the console in a comfortable centred column
          app = ColoredBox(color: BrandColors.offWhite, child: Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: chatOpen ? 1100 + chatPanelSpace : 1100), child: app)));
        }
        if (!AppConfig.teamOnly) app = Stack(children: [Positioned.fill(child: app), const Positioned(top: 0, left: 0, right: 0, child: AppUpdateBanner())]);
        return applyDarkMode(dark, app);
      },
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
