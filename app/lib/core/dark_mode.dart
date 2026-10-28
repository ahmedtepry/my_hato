import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n.dart' show sharedPrefsProvider;

/// Dark / light mode, remembered per device.
class DarkModeController extends Notifier<bool> {
  static const _key = 'dark_mode';
  @override
  bool build() {
    try {
      return ref.read(sharedPrefsProvider).getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> toggle() async {
    state = !state;
    try {
      await ref.read(sharedPrefsProvider).setBool(_key, state);
    } catch (_) {}
  }
}

final darkModeProvider = NotifierProvider<DarkModeController, bool>(DarkModeController.new);

// Inverts lightness and rotates the hue back, so blues stay blue and golds stay gold, then softens the extremes
// (white becomes a dark grey, black a soft white) so it is easy on the eyes.
const _a = 0.86, _b = 0.07;
const _h = <double>[
  -0.574, 1.430, 0.144, //
  0.426, 0.430, 0.144,
  0.426, 1.430, -0.856,
];
final ColorFilter darkFilter = ColorFilter.matrix(<double>[
  for (var r = 0; r < 3; r++) ...[-_a * _h[r * 3], -_a * _h[r * 3 + 1], -_a * _h[r * 3 + 2], 0, (_a + _b) * 255],
  0, 0, 0, 1, 0,
]);

/// Wraps [child] in the dark filter when [dark] is on.
Widget applyDarkMode(bool dark, Widget child) => dark ? ColorFiltered(colorFilter: darkFilter, child: child) : child;
