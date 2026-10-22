import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/core/l10n.dart';
import 'package:myhato/shared/cancel_request.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: supportedLocales,
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
    );

void main() {
  testWidgets('cancel request: reason sent to the server, then the button is locked', (t) async {
    final sent = <String>[];
    await t.pumpWidget(_wrap(CancelRequestBlock(
      requests: const [],
      canRequest: true,
      repair: false,
      submit: (r) async => sent.add(r),
    )));

    await t.tap(find.byKey(const ValueKey('cancel-request-button')));
    await t.pumpAndSettle();
    // send stays disabled until a reason is picked
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('cancel-send'))).onPressed, isNull);
    await t.tap(find.text('لقيت سعر أحسن'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('cancel-send')));
    await t.pumpAndSettle();

    expect(sent, ['لقيت سعر أحسن']);
    expect(find.byKey(const ValueKey('cancel-request-button')), findsNothing);
    expect(find.byKey(const ValueKey('cancel-under-review')), findsOneWidget);
  });

  testWidgets('cancel request: server error stays in the sheet and nothing is locked', (t) async {
    await t.pumpWidget(_wrap(CancelRequestBlock(
      requests: const [],
      canRequest: true,
      repair: true,
      submit: (_) async => throw Exception('CANNOT_CANCEL'),
    )));
    await t.tap(find.byKey(const ValueKey('cancel-request-button')));
    await t.pumpAndSettle();
    await t.tap(find.text('التكلفة عالية'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('cancel-send')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('cancel-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel-under-review')), findsNothing);
  });

  testWidgets('open request from the server: no button, under review shown', (t) async {
    await t.pumpWidget(_wrap(const CancelRequestBlock(
      requests: [
        {'status': 'pending', 'reason': 'غيرت رأيي'}
      ],
      canRequest: true,
      repair: false,
      submit: _noop,
    )));
    expect(find.byKey(const ValueKey('cancel-request-button')), findsNothing);
    expect(find.textContaining('غيرت رأيي'), findsOneWidget);
  });
}

Future<void> _noop(String _) async {}
