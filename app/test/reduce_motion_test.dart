import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/core/l10n.dart' show sharedPrefsProvider;
import 'package:myhato/core/reduce_motion.dart';
import 'package:myhato/core/theme.dart';
import 'package:myhato/shared/motion.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => ReduceMotion.on = false);

  test('fast mode is remembered and toggles the global flag', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(p)]);
    addTearDown(c.dispose);
    expect(c.read(reduceMotionProvider), false);
    await c.read(reduceMotionProvider.notifier).toggle();
    expect(c.read(reduceMotionProvider), true);
    expect(ReduceMotion.on, true);
    expect(p.getBool('reduce_motion'), true);
  });

  test('fast mode removes page transitions from the theme', () {
    ReduceMotion.on = true;
    final t = AppTheme.light(const Locale('ar'));
    expect(t.pageTransitionsTheme.builders[TargetPlatform.windows].runtimeType.toString(), '_NoTransitionsBuilder');
  });

  testWidgets('fast mode: page switch is instant and count-up shows the final number', (tester) async {
    ReduceMotion.on = true;
    await tester.pumpWidget(const MaterialApp(home: Column(children: [
      SizedBox(height: 40, child: SoftPageSwitch(index: 1, children: [Text('a'), Text('b')])),
      CountUpText('1,250 EGP'),
    ])));
    expect(find.text('b'), findsOneWidget);
    expect(find.text('1,250 EGP'), findsOneWidget);
  });
}
