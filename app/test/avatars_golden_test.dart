import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/shared/avatars.dart';

/// Renders all avatars into one image (CI publishes it for design review) and checks they paint.
void main() {
  testWidgets('avatars render', (t) async {
    await t.binding.setSurfaceSize(const Size(880, 880));
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
              for (final row in [for (var i = 0; i < avatarIds.length; i += 4) avatarIds.sublist(i, i + 4)])
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
