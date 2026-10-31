import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/core/l10n.dart';
import 'package:myhato/core/theme.dart';
import 'package:myhato/shared/launch_animation.dart';
import 'package:myhato/shared/welcome_robot.dart';

/// Plays both "APK welcome logo" robot animations from start to finish in Arabic and English (no exception, the greeting shows).
void main() {
  for (final v in ['peek', 'call']) {
    for (final lang in ['ar', 'en']) {
      testWidgets('welcome robot $v ($lang)', (t) async {
        t.view.physicalSize = const Size(1080, 2280);
        t.view.devicePixelRatio = 2.625;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: Locale(lang),
          supportedLocales: supportedLocales,
          localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
          theme: AppTheme.light(Locale(lang)),
          home: Scaffold(backgroundColor: BrandColors.navy, body: Center(child: LaunchAnimation(variant: v))),
        ));
        final total = WelcomeRobot.durationOf(v).inMilliseconds;
        for (var ms = 0; ms <= total + 200; ms += 100) {
          await t.pump(const Duration(milliseconds: 100));
          expect(t.takeException(), isNull, reason: '$v at ${ms}ms');
        }
        expect(find.textContaining(lang == 'ar' ? 'أهلاً بيك' : 'Welcome to'), findsOneWidget);
      });
    }
  }

  test('robot pose ends where it should', () {
    final peek = robotPose('peek', 10);
    expect(peek.rot, 23);
    final call = robotPose('call', 10);
    expect(call.x, -6);
  });
}
