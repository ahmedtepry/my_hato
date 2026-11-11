import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n.dart' show sharedPrefsProvider;

/// "Fast mode" for old computers: switches off page transitions, entrance animations, looping animations,
/// the opening animation and the blurred dialog backdrop. Remembered per device; a button in the console toggles it.
class ReduceMotion {
  /// Read by widgets that animate (a plain static so they need no provider).
  static bool on = false;
}

class ReduceMotionController extends Notifier<bool> {
  static const _key = 'reduce_motion';
  @override
  bool build() {
    var v = false;
    try {
      v = ref.read(sharedPrefsProvider).getBool(_key) ?? false;
    } catch (_) {}
    ReduceMotion.on = v;
    return v;
  }

  Future<void> toggle() async {
    state = !state;
    ReduceMotion.on = state;
    try {
      await ref.read(sharedPrefsProvider).setBool(_key, state);
    } catch (_) {}
  }
}

final reduceMotionProvider = NotifierProvider<ReduceMotionController, bool>(ReduceMotionController.new);
