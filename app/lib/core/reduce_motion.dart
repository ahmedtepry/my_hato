import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n.dart' show sharedPrefsProvider;

/// "Fast mode" for old computers: switches off page transitions, entrance animations, looping animations,
/// the opening animation and the blurred dialog backdrop. Remembered per device; a button in the console toggles it.
class ReduceMotion {
  /// Read by widgets that animate (a plain static so they need no provider).
  static bool on = false;

  /// Fires when fast mode is switched, so running loops (pulses, blinks, scanners) stop or start at once.
  static final ValueNotifier<bool> changes = ValueNotifier<bool>(false);

  /// The duration to give an animated widget: none at all in fast mode.
  static Duration d(Duration normal) => on ? Duration.zero : normal;

  static void _set(bool v) {
    on = v;
    changes.value = v;
  }

  /// Rebuilds every widget on screen, so the ones that read [on] in build switch straight away (no restart needed).
  static void rebuildAll() {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(mark);
  }
}

class ReduceMotionController extends Notifier<bool> {
  static const _key = 'reduce_motion';
  @override
  bool build() {
    var v = false;
    try {
      v = ref.read(sharedPrefsProvider).getBool(_key) ?? false;
    } catch (_) {}
    ReduceMotion._set(v);
    return v;
  }

  Future<void> toggle() async {
    state = !state;
    ReduceMotion._set(state);
    WidgetsBinding.instance.addPostFrameCallback((_) => ReduceMotion.rebuildAll());
    WidgetsBinding.instance.scheduleFrame();
    try {
      await ref.read(sharedPrefsProvider).setBool(_key, state);
    } catch (_) {}
  }
}

final reduceMotionProvider = NotifierProvider<ReduceMotionController, bool>(ReduceMotionController.new);
