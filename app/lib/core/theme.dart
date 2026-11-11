import 'dart:math' as math;
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'reduce_motion.dart';

/// The colours the owner can change from the console (primary, accent, background, success, danger).
/// [LiveColor] reads these at paint time, so a change shows everywhere without touching the 400+ places that use [BrandColors].
class AppPalette {
  static const defaults = <String, String>{
    'primary': '#0B2D5B',
    'accent': '#00A3FF',
    'background': '#F8F9FA',
    'success': '#12B76A',
    'danger': '#D92D20',
  };
  // slots: 0 navy, 1 navyDeep (derived from primary), 2 electric, 3 offWhite, 4 success, 5 error
  static List<int> argb = [0xFF0B2D5B, 0xFF071C3A, 0xFF00A3FF, 0xFFF8F9FA, 0xFF12B76A, 0xFFD92D20];

  static int? _parse(Object? v) {
    if (v is! String || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(v)) return null;
    return 0xFF000000 | int.parse(v.substring(1), radix: 16);
  }

  /// Applies a palette map; unknown or invalid entries keep the default. Returns true when something changed.
  static bool apply(Map<String, dynamic>? json) {
    int pick(String k) => _parse(json?[k]) ?? _parse(defaults[k])!;
    final primary = pick('primary');
    // Contrast guard: whatever colours are picked, text stays readable and buttons stay visible.
    // background: always a light surface; primary (text, icons): dark enough to read on it (4.5:1);
    // accent / success / danger (filled buttons with white text, badges): at least 2.5:1 against white.
    final bg = _lift(pick('background'), 0.90);
    final ink = _darkenUntil(primary, (c) => _contrast(c, bg) >= 4.5);
    final hslInk = HSLColor.fromColor(Color(ink));
    final deepInk = hslInk.withLightness((hslInk.lightness * 0.5).clamp(0.0, 1.0)).toColor().toARGB32();
    int onWhite(int c) => _darkenUntil(c, (x) => _contrast(x, 0xFFFFFFFF) >= 2.5);
    final next = [ink, deepInk, onWhite(pick('accent')), bg, onWhite(pick('success')), onWhite(pick('danger'))];
    var changed = false;
    for (var i = 0; i < next.length; i++) {
      if (argb[i] != next[i]) changed = true;
    }
    argb = next;
    return changed;
  }

  static double _lum(int c) {
    double ch(int v) {
      final x = v / 255.0;
      return x <= 0.03928 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * ch((c >> 16) & 0xFF) + 0.7152 * ch((c >> 8) & 0xFF) + 0.0722 * ch(c & 0xFF);
  }

  static double _contrast(int a, int b) {
    final x = _lum(a), y = _lum(b);
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
  }

  /// Darkens [c] step by step (same hue) until [ok] holds.
  static int _darkenUntil(int c, bool Function(int) ok) {
    var h = HSLColor.fromColor(Color(c));
    var v = c;
    for (var i = 0; i < 40 && !ok(v); i++) {
      h = h.withLightness((h.lightness - 0.025).clamp(0.0, 1.0));
      v = h.toColor().toARGB32();
    }
    return v;
  }

  /// Raises the lightness of [c] to at least [min] (same hue): the page background is always light.
  static int _lift(int c, double min) {
    final h = HSLColor.fromColor(Color(c));
    return h.lightness >= min ? c : h.withLightness(min).toColor().toARGB32();
  }
}

class LiveColor extends Color {
  const LiveColor(this.slot) : super(0xFF000000);
  final int slot;
  int get _v => AppPalette.argb[slot];
  @override
  double get a => ((_v >> 24) & 0xFF) / 255.0;
  @override
  double get r => ((_v >> 16) & 0xFF) / 255.0;
  @override
  double get g => ((_v >> 8) & 0xFF) / 255.0;
  @override
  double get b => (_v & 0xFF) / 255.0;
  @override
  int toARGB32() => _v;
}

/// Brand palette — taken from the My Hatō brand board. navy / electric / offWhite / success / error follow the owner's palette.
class BrandColors {
  static const Color navy = LiveColor(0);
  static const Color navyDeep = LiveColor(1);
  static const Color electric = LiveColor(2);
  static const Color offWhite = LiveColor(3);
  static const white = Color(0xFFFFFFFF);
  static const gray = Color(0xFF667085);
  static const border = Color(0xFFE4E7EC);
  static const Color error = LiveColor(5);
  static const Color success = LiveColor(4);
  static const warning = Color(0xFFF79009);
}

class AppTheme {
  static ThemeData light(Locale locale) {
    final base = ThemeData(
      useMaterial3: true,
      // Fixed slide transition on every platform. Android's default (predictive-back / fade-forward)
      // can leave a page frozen half-faded when a back swipe is cancelled.
      pageTransitionsTheme: ReduceMotion.on
          ? PageTransitionsTheme(builders: {for (final p in TargetPlatform.values) p: const _NoTransitionsBuilder()})
          : const PageTransitionsTheme(builders: {
              TargetPlatform.android: CupertinoPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            }),
      colorScheme: ColorScheme.fromSeed(
        seedColor: BrandColors.navy,
        primary: BrandColors.navy,
        secondary: BrandColors.electric,
        surface: BrandColors.white,
        error: BrandColors.error,
      ),
      scaffoldBackgroundColor: BrandColors.offWhite,
      // light ripple (InkSparkle needs a shader warm-up that stutters on some Android phones)
      splashFactory: ReduceMotion.on ? NoSplash.splashFactory : InkRipple.splashFactory,
      highlightColor: BrandColors.electric.withValues(alpha: 0.04),
    );
    // Tajawal for Arabic, Poppins for English — bundled in the APK (assets/google_fonts), no download wait
    final text = locale.languageCode == 'ar'
        ? GoogleFonts.tajawalTextTheme(base.textTheme)
        : GoogleFonts.poppinsTextTheme(base.textTheme);
    return base.copyWith(
      textTheme: text.apply(bodyColor: BrandColors.navy, displayColor: BrandColors.navy),
      appBarTheme: AppBarTheme(
        backgroundColor: BrandColors.offWhite,
        foregroundColor: BrandColors.navy,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: BrandColors.navy),
      ),
      cardTheme: CardThemeData(
        color: BrandColors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: BrandColors.electric,
          foregroundColor: BrandColors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BrandColors.navy,
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: BrandColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BrandColors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: BrandColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: BrandColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: BrandColors.electric, width: 1.6)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: BrandColors.white,
        indicatorColor: BrandColors.electric.withOpacity(0.14),
        labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: const BorderSide(color: BrandColors.border),
      ),
    );
  }
}

/// Fast mode: a page appears at once, with no transition.
class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) => child;
}

/// A card / panel surface: white on the light pages, translucent glass on the dark (glass) pages, so no white sheet shows there.
Color panelColor(BuildContext context, [Color light = Colors.white]) =>
    Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.07) : light;

/// The thin border that goes with [panelColor].
Color panelLine(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Colors.white12 : BrandColors.border;

/// Text / icon colour that reads on the current page: the brand's dark ink on light pages, white on the dark (glass) pages.
Color inkColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Colors.white : BrandColors.navy;
