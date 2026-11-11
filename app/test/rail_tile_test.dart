import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/shared/rail_tile.dart';

void main() {
  testWidgets('every rail tile has the same size, dot and count show on the corner', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          RailTile(icon: const Icon(Icons.home, size: 32), label: 'رجوع', tooltip: 't', onTap: () {}),
          RailTile(icon: const Icon(Icons.smart_toy, size: 32), label: 'المساعد', tooltip: 't', onTap: () {}, dot: Colors.green),
          RailTile(icon: const Icon(Icons.chat, size: 32), label: 'رسايل', tooltip: 't', onTap: () {}, count: '3'),
          const RailSep(),
        ]),
      ),
    ));
    final sizes = [for (final e in tester.widgetList<SizedBox>(find.byType(SizedBox)).where((b) => b.width == RailTile.width)) Size(e.width!, e.height!)];
    expect(sizes.length, 3);
    expect(sizes.toSet().length, 1);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('المساعد'), findsOneWidget);
  });
}
