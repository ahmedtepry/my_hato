import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/shared/avatars.dart';

/// Renders all avatars into one image (CI publishes it for design review) and checks they paint.
void main() {
  testWidgets('avatars render', (t) async {
    await t.binding.setSurfaceSize(const Size(880, 460));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: RepaintBoundary(
          key: const ValueKey('grid'),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              for (final row in [avatarIds.sublist(0, 4), avatarIds.sublist(4)])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    for (final id in row) HatoAvatar(id: id, size: 180, animate: false),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    ));
    await expectLater(find.byKey(const ValueKey('grid')), matchesGoldenFile('goldens/avatars.png'));
  });
}
