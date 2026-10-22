import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand palette — taken from the My Hatō brand board.
class BrandColors {
  static const navy = Color(0xFF0B2D5B);
  static const navyDeep = Color(0xFF071C3A);
  static const electric = Color(0xFF00A3FF);
  static const offWhite = Color(0xFFF8F9FA);
  static const white = Color(0xFFFFFFFF);
  static const gray = Color(0xFF667085);
  static const border = Color(0xFFE4E7EC);
  static const error = Color(0xFFD92D20);
  static const success = Color(0xFF12B76A);
  static const warning = Color(0xFFF79009);
}

class AppTheme {
  static ThemeData light(Locale locale) {
    final base = ThemeData(
      useMaterial3: true,
      // Fixed slide transition on every platform. Android's default (predictive-back / fade-forward)
      // can leave a page frozen half-faded when a back swipe is cancelled.
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
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
      // soft "sparkle" touch ripple and a quick, gentle highlight on every tappable surface
      splashFactory: InkSparkle.splashFactory,
      highlightColor: BrandColors.electric.withValues(alpha: 0.04),
    );
    // Readex Pro: one modern rounded family for Arabic and English
    final text = GoogleFonts.readexProTextTheme(base.textTheme);
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
