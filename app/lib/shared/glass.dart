import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/l10n.dart';
import '../core/supabase_providers.dart';
import '../core/theme.dart';
import 'states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

// ============================================================================================ which look is on
/// A glass colour mood: backdrop gradient, three glows and the accent used on highlights.
class GlassPalette {
  const GlassPalette(this.id, this.ar, this.en, this.bg, this.glows, this.accent);
  final String id, ar, en;
  final List<Color> bg, glows;
  final Color accent;
}

const glassPalettes = <GlassPalette>[
  GlassPalette('midnight', 'منتصف الليل', 'Midnight', [Color(0xFF0B2347), Color(0xFF061833), Color(0xFF030B1C)], [Color(0x990A7CFF), Color(0x667B6CFF), Color(0x4000D1C1)], Color(0xFF00A3FF)),
  GlassPalette('aurora', 'الشفق', 'Aurora', [Color(0xFF0A2F2C), Color(0xFF06201F), Color(0xFF03100F)], [Color(0x9900D68F), Color(0x664F7CFF), Color(0x40B36BFF)], Color(0xFF2DE2A6)),
  GlassPalette('ember', 'الجمر', 'Ember', [Color(0xFF2A0F14), Color(0xFF1C0A10), Color(0xFF0D0508)], [Color(0x99FF6A1A), Color(0x66E5336B), Color(0x40FFB020)], Color(0xFFFF8A3D)),
  GlassPalette('neon', 'نيون', 'Neon', [Color(0xFF0A0614), Color(0xFF07040F), Color(0xFF030208)], [Color(0x99FF2BD6), Color(0x6600E5FF), Color(0x407B2CFF)], Color(0xFF00E5FF)),
  GlassPalette('royal', 'ملكي', 'Royal', [Color(0xFF1B1038), Color(0xFF120A28), Color(0xFF08041A)], [Color(0x998B5CFF), Color(0x66FFC857), Color(0x40FF5C8A)], Color(0xFFFFC857)),
];

const _looks = ['classic', 'midnight', 'aurora', 'ember', 'neon', 'royal'];
String _normLook(Object? v) => v == 'glass' ? 'midnight' : (_looks.contains(v) ? '$v' : '');

/// What the owner set for everyone: look = classic / midnight / aurora / ember / neon / royal, locked = members cannot switch. Null when nothing was set.
final consoleLookServerProvider = FutureProvider<({String look, bool locked})?>((ref) async {
  try {
    final rows = await ref.read(supabaseProvider).from('application_settings').select('value').eq('key', 'console_look').limit(1);
    final v = rows.isEmpty ? null : rows.first['value'];
    if (v is Map && _normLook(v['look']).isNotEmpty) return (look: _normLook(v['look']), locked: v['locked'] == true);
  } catch (_) {}
  return null;
});

/// This computer's own choice, remembered per device. Null = follow the default.
final consoleDeviceLookProvider = StateProvider<String?>((ref) {
  try {
    final v = _normLook(ref.read(sharedPrefsProvider).getString('console_look'));
    return v.isEmpty ? null : v;
  } catch (_) {
    return null;
  }
});

/// The look in force: a locked owner choice wins over the device choice; the default is midnight glass.
final consoleLookProvider = Provider<String>((ref) {
  final server = ref.watch(consoleLookServerProvider).valueOrNull;
  if (server != null && server.locked) return server.look;
  return ref.watch(consoleDeviceLookProvider) ?? server?.look ?? 'midnight';
});

/// True when the Windows console should use a glass look (anything but classic).
final glassLookProvider = Provider<bool>((ref) => ref.watch(consoleLookProvider) != 'classic');

final glassPaletteProvider = Provider<GlassPalette>((ref) {
  final id = ref.watch(consoleLookProvider);
  return glassPalettes.firstWhere((p) => p.id == id, orElse: () => glassPalettes.first);
});

void setDeviceLook(WidgetRef ref, String look) {
  ref.read(consoleDeviceLookProvider.notifier).state = look;
  try {
    ref.read(sharedPrefsProvider).setString('console_look', look);
  } catch (_) {}
}

// ============================================================================================ visuals
const glassText = Colors.white;
const glassMuted = Color(0x99FFFFFF);
const glassLine = Color(0x1FFFFFFF);

/// Midnight gradient with three soft glows. Painted once (RepaintBoundary), so it costs nothing while the page animates.
class GlassBackdrop extends ConsumerWidget {
  const GlassBackdrop({super.key, required this.child});
  final Widget child;

  Widget _glow(Color c, double size, {double? top, double? bottom, double? left, double? right}) => Positioned(
        top: top,
        bottom: bottom,
        left: left,
        right: right,
        child: IgnorePointer(
          child: Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [c, c.withValues(alpha: 0)]))),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = ref.watch(glassPaletteProvider);
    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: pal.bg)),
            child: Stack(children: [
              _glow(pal.glows[0], 900, top: -380, right: 120),
              _glow(pal.glows[1], 800, bottom: -420, left: 80),
              _glow(pal.glows[2], 520, top: 300, right: -240),
            ]),
          ),
        ),
      ),
      Positioned.fill(child: child),
    ]);
  }
}

/// A glass card: a faint white gradient + a bright hairline over the glowing backdrop. [blur] > 0 adds a real backdrop blur, which is heavy on
/// ordinary laptops, so it is off by default (the backdrop is a smooth gradient, the look is almost the same).
class GlassBox extends StatelessWidget {
  const GlassBox({super.key, required this.child, this.padding = const EdgeInsets.all(20), this.radius = 22, this.blur = 0, this.margin, this.tint});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius, blur;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [(tint ?? Colors.white).withValues(alpha: 0.12), (tint ?? Colors.white).withValues(alpha: 0.04)]),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: child,
    );
    final framed = blur <= 0 ? ClipRRect(borderRadius: r, clipBehavior: Clip.hardEdge, child: body) : ClipRRect(borderRadius: r, clipBehavior: Clip.hardEdge, child: BackdropFilter(filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: body));
    return margin == null ? framed : Padding(padding: margin!, child: framed);
  }
}

/// Wraps an ordinary (light) page so it sits on the glass background as one big frosted sheet and stays fully readable.
/// Every console page in the glass look: no white sheet, the page floats on the dark glass with a dark theme
/// (translucent cards, white text, dark dialogs), so it is lighter to draw and matches the sidebar.
class GlassPage extends StatelessWidget {
  const GlassPage({super.key, required this.child});
  final Widget child;

  static ThemeData dark(ThemeData b) {
    const surface = Color(0xFF0E1A2E);
    final scheme = ColorScheme.fromSeed(seedColor: BrandColors.electric, brightness: Brightness.dark).copyWith(
      primary: BrandColors.electric,
      onPrimary: Colors.white,
      surface: surface,
      onSurface: Colors.white,
      onSurfaceVariant: Colors.white70,
      surfaceContainerLowest: surface,
      surfaceContainerLow: const Color(0xFF12213A),
      surfaceContainer: const Color(0xFF14233D),
      surfaceContainerHigh: const Color(0xFF172A47),
      surfaceContainerHighest: const Color(0xFF1B2F50),
      outline: Colors.white24,
      outlineVariant: Colors.white12,
    );
    return b.copyWith(
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: surface,
      textTheme: b.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
      primaryTextTheme: b.primaryTextTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
      iconTheme: const IconThemeData(color: Colors.white70),
      dividerColor: Colors.white12,
      cardTheme: CardThemeData(color: Colors.white.withValues(alpha: .07), elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Colors.white12))),
      listTileTheme: const ListTileThemeData(textColor: Colors.white, iconColor: Colors.white70, subtitleTextStyle: TextStyle(color: Colors.white60, fontSize: 13)),
      dialogTheme: DialogThemeData(backgroundColor: const Color(0xFF111F38), surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: .08),
        hintStyle: const TextStyle(color: Colors.white54),
        labelStyle: const TextStyle(color: Colors.white70),
        prefixIconColor: Colors.white60,
        suffixIconColor: Colors.white60,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.white12)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.white12)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: BrandColors.electric, width: 1.6)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size.fromHeight(52), side: const BorderSide(color: Colors.white24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Colors.white)),
      chipTheme: b.chipTheme.copyWith(backgroundColor: Colors.white.withValues(alpha: .08), selectedColor: BrandColors.electric.withValues(alpha: .55), labelStyle: const TextStyle(color: Colors.white), side: BorderSide.none, checkmarkColor: Colors.white),
      popupMenuTheme: const PopupMenuThemeData(color: Color(0xFF14233D)),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, foregroundColor: Colors.white, surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800), iconTheme: IconThemeData(color: Colors.white), actionsIconTheme: IconThemeData(color: Colors.white)),
      tabBarTheme: TabBarThemeData(labelColor: Colors.white, unselectedLabelColor: Colors.white60, indicatorColor: BrandColors.electric, dividerColor: Colors.white12),
      floatingActionButtonTheme: FloatingActionButtonThemeData(backgroundColor: BrandColors.electric, foregroundColor: Colors.white),
      switchTheme: b.switchTheme,
      dataTableTheme: const DataTableThemeData(headingTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w800), dataTextStyle: TextStyle(color: Colors.white)),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
        child: Theme(data: dark(Theme.of(context)), child: Material(color: Colors.transparent, child: child)),
      );
}

class GlassSheet extends StatelessWidget {
  const GlassSheet({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.hardEdge,
          child: ColoredBox(color: const Color(0xFFF4F7FB), child: child),
        ),
      );
}

// ============================================================================================ the switch (icon + dialog)
/// The small tile in the control column: opens a choice between the glass and the classic look.
/// Members who may not switch (the owner locked it) do not see it, unless they hold appearance.look.
class ConsoleLookTile extends ConsumerWidget {
  const ConsoleLookTile({super.key, required this.canSetForAll, required this.builder});
  final bool canSetForAll;

  /// Builds the tile with the shared control-column style of the host screen.
  final Widget Function(BuildContext context, VoidCallback onTap, IconData icon, String label, String tooltip) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(consoleLookServerProvider).valueOrNull;
    final locked = server?.locked ?? false;
    if (locked && !canSetForAll) return const SizedBox.shrink();
    final glass = ref.watch(glassLookProvider);
    return builder(
      context,
      () => showDialog<void>(context: context, builder: (_) => _LookDialog(canSetForAll: canSetForAll)),
      glass ? Icons.blur_on_rounded : Icons.view_quilt_outlined,
      _t(context, 'الشكل', 'Look'),
      _t(context, 'شكل الواجهة: زجاجي أو كلاسيك', 'Console look: glass or classic'),
    );
  }
}

class _LookDialog extends ConsumerStatefulWidget {
  const _LookDialog({required this.canSetForAll});
  final bool canSetForAll;
  @override
  ConsumerState<_LookDialog> createState() => _LookDialogState();
}

class _LookDialogState extends ConsumerState<_LookDialog> {
  bool _everyone = false, _lock = false, _busy = false;

  Future<void> _pick(String look) async {
    setDeviceLook(ref, look);
    if (widget.canSetForAll && _everyone) {
      setState(() => _busy = true);
      try {
        await ref.read(supabaseProvider).rpc('console_look_set', params: {'p_look': look, 'p_locked': _lock});
        ref.invalidate(consoleLookServerProvider);
        if (mounted) showSnack(context, _t(context, 'اتطبّق على كل الفريق', 'Applied to the whole team'));
      } catch (e) {
        if (mounted) showSnack(context, friendlyError(context, e), error: true);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Widget _card(String look, String title, List<Color> grad, bool on) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _busy ? null : () => _pick(look),
        child: Container(
          width: 132,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: on ? BrandColors.electric : BrandColors.border, width: on ? 2.4 : 1)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              height: 70,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: grad)),
              child: Center(
                child: Container(width: 54, height: 30, decoration: BoxDecoration(color: Colors.white.withValues(alpha: look == 'classic' ? 0.9 : 0.16), borderRadius: BorderRadius.circular(9), border: Border.all(color: Colors.white.withValues(alpha: 0.4)))),
              ),
            ),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(consoleLookProvider);
    return AlertDialog(
      title: Text(_t(context, 'شكل الواجهة', 'Console look')),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final p in glassPalettes) _card(p.id, _t(context, p.ar, p.en), [p.bg.first, p.glows[0].withValues(alpha: 1), p.glows[1].withValues(alpha: 1)], cur == p.id),
            _card('classic', _t(context, 'كلاسيك', 'Classic'), const [Color(0xFF98A2B3), Color(0xFFE4E7EC)], cur == 'classic'),
          ]),
          if (widget.canSetForAll) ...[
            const SizedBox(height: 14),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_t(context, 'طبّق اختياري على كل الفريق', 'Apply my choice to the whole team')),
              value: _everyone,
              onChanged: (v) => setState(() => _everyone = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_t(context, 'امنع الموظفين من التبديل', 'Stop members from switching')),
              value: _lock,
              onChanged: _everyone ? (v) => setState(() => _lock = v) : null,
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_t(context, 'الاختيار ده على جهازك بس.', 'This choice is for this computer only.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
            ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(_t(context, 'إغلاق', 'Close')))],
    );
  }
}
