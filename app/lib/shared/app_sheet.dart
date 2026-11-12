// Panels that slide up from the bottom on a phone open as a centred window on a computer: a bottom sheet on a wide
// Windows screen was cut off by the screen edge, so the last fields (and the save button) could not be reached.
// The window is never taller than 88% of the screen and its content scrolls inside it.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'motion.dart';

bool get _desktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// Same parameters as [showModalBottomSheet]; on a computer it shows a centred window instead.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool? showDragHandle,
  bool useSafeArea = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  Color? backgroundColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  double maxWidth = 640,
}) {
  if (!_desktop) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      backgroundColor: backgroundColor,
      shape: shape,
      constraints: constraints,
    );
  }
  return showSmoothDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: isDismissible,
    builder: (d) {
      final size = MediaQuery.sizeOf(d);
      return Dialog(
        backgroundColor: backgroundColor,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints?.maxWidth.isFinite == true ? constraints!.maxWidth : maxWidth, maxHeight: size.height * 0.88),
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            // the panels were written for a bottom sheet: they get the same "remove the keyboard inset" view here
            child: MediaQuery.removeViewInsets(context: d, removeBottom: true, child: Builder(builder: builder)),
          ),
        ),
      );
    },
  );
}
