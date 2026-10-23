import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard against the "frozen, half-faded screen" bug: Hero widgets on product tiles break page
/// transitions when the same product is shown twice on one screen (duplicate hero tags).
void main() {
  test('no Hero widgets in the app code', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (!l.startsWith('//') && RegExp(r'\bHero\(').hasMatch(l)) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty, reason: 'Hero widgets found: $offenders');
  });
}
