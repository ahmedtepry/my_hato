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
import 'core/reduce_motion.dart';


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
  ErrorWidget.builder = (details) {
    _reportError(details.exceptionAsString(), details.stack?.toString());
    return _BrokenScreen(error: details.exceptionAsString());
  };
  FlutterError.onError = (d) {
    FlutterError.presentError(d);
    _reportError(d.exceptionAsString(), d.stack?.toString());
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: $error');
    _reportError('$error', stack.toString());
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
    final fast = ref.watch(reduceMotionProvider); // fast mode: no animations (old computers)
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
        Widget app = ConnectionGate(child: child ?? const SizedBox.shrink());
        if (!AppConfig.customerOnly) app = StaffPresenceScope(child: app);
        if (AppConfig.teamOnly) {
          // fill the whole window (the console draws its own full-bleed backdrop)
          app = ColoredBox(color: BrandColors.offWhite, child: SizedBox.expand(child: app));
        }
        if (!AppConfig.teamOnly) app = Stack(children: [Positioned.fill(child: app), const Positioned.fill(child: AppUpdateBanner())]);
        if (fast) app = MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app);
        // the team app has its own dark look (glass); inverting colours on top of it broke every page, so it is customer-app only
        return applyDarkMode(dark && !AppConfig.teamOnly, app);
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

final _reported = <String>{};

/// Sends a screen/app error to the server log (once per message, at most 8 per run) so it can be fixed without a screenshot.
void _reportError(String message, String? stack) {
  try {
    if (kDebugMode || _reported.length >= 8 || !_reported.add(message.length > 120 ? message.substring(0, 120) : message)) return;
    Supabase.instance.client
        .rpc('log_client_error', params: {'p_message': message, 'p_stack': stack ?? '', 'p_platform': defaultTargetPlatform.name, 'p_build': kBuildNumber})
        .then((_) {}, onError: (_) {});
  } catch (_) {/* never let reporting break the app */}
}

/// Replaces the grey box Flutter paints in release when a screen fails to build.
class _BrokenScreen extends StatelessWidget {
  const _BrokenScreen({this.error = ''});
  final String error;
  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          color: const Color(0xFFF4F6FA),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.sentiment_dissatisfied_rounded, size: 48, color: Color(0xFF6B7488)),
                const SizedBox(height: 12),
                const Text('حصلت مشكلة في الشاشة دي',
                    textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF14213D))),
                const SizedBox(height: 6),
                const Text('ارجع للشاشة اللي قبلها وافتحها تاني.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Color(0xFF6B7488))),
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  // technical detail so a screenshot tells us exactly what failed
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(error.length > 320 ? error.substring(0, 320) : error,
                        textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Color(0xFF98A1B3), decoration: TextDecoration.none)),
                  ),
                ],
              ]),
            ),
          ),
        ),
      );
}
