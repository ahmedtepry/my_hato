import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appearance.dart';
import 'config.dart';
import 'l10n.dart';
import 'supabase_providers.dart';
import 'theme.dart';

/// Colour themes of the Windows team app. 'default' keeps the store's own colours.
class TeamThemeDef {
  const TeamThemeDef(this.id, this.ar, this.en, this.accent);
  final String id, ar, en;
  final int accent; // RGB of the main colour
}

const teamThemes = <TeamThemeDef>[
  TeamThemeDef('default', 'الأزرق الأساسي', 'Classic blue', 0x00A3FF),
  TeamThemeDef('terracotta', 'طوبي وكريمي', 'Terracotta', 0xC76545),
  TeamThemeDef('forest', 'أخضر غابي', 'Forest green', 0x8DA879),
  TeamThemeDef('mustard', 'ذهبي خردلي', 'Mustard gold', 0xD3A23A),
  TeamThemeDef('plum', 'برقوقي', 'Plum', 0xA36B95),
  TeamThemeDef('burnt', 'برتقالي محروق', 'Burnt orange', 0xD6783E),
  TeamThemeDef('olive', 'أخضر مريمي', 'Sage green', 0x9CA879),
  TeamThemeDef('cocoa', 'كاكاو نحاسي', 'Cocoa copper', 0xB88A55),
  TeamThemeDef('coral', 'مرجاني', 'Coral', 0xDE7464),
  TeamThemeDef('leaf', 'أخضر ورقي', 'Leaf green', 0x78A17E),
  TeamThemeDef('bronze', 'برونزي', 'Bronze', 0xBC852E),
];

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// What decides the colours: this device's own pick, unless the owner pushed a theme to everybody after it.
class TeamTheme {
  static String id = 'default';

  static TeamThemeDef? def(String id) {
    for (final t in teamThemes) {
      if (t.id == id) return t;
    }
    return null;
  }

  static String effective(SharedPreferences p) {
    final dev = p.getString('tt_device_id');
    final devAt = p.getInt('tt_device_at') ?? 0;
    final glob = p.getString('tt_global_id') ?? 'default';
    final globV = p.getInt('tt_global_v') ?? 0;
    if (dev != null && def(dev) != null && devAt >= globV) return dev;
    return def(glob) != null ? glob : 'default';
  }

  /// The five app colours of a theme (accent = its main colour, the dark and the light colours are made from it).
  static Map<String, String> palette(String themeId, Map<String, String> storePalette) {
    final d = def(themeId);
    if (d == null || d.id == 'default') return storePalette;
    final accent = Color(0xFF000000 | d.accent);
    final hue = HSLColor.fromColor(accent).hue;
    return {
      'primary': _hex(HSLColor.fromAHSL(1, hue, 0.36, 0.17).toColor()),
      'accent': _hex(accent),
      'background': _hex(HSLColor.fromAHSL(1, hue, 0.30, 0.965).toColor()),
      'success': AppPalette.defaults['success']!,
      'danger': AppPalette.defaults['danger']!,
    };
  }
}

class TeamThemeController extends Notifier<String> {
  Timer? _timer;

  SharedPreferences get _p => ref.read(sharedPrefsProvider);

  @override
  String build() {
    ref.onDispose(() => _timer?.cancel());
    final id = TeamTheme.effective(_p);
    if (AppConfig.teamOnly) {
      Future.microtask(_pull);
      _timer = Timer.periodic(const Duration(seconds: 20), (_) => _pull());
    }
    return id;
  }

  /// What the owner set for everybody. Silent when offline.
  Future<void> _pull() async {
    try {
      if (ref.read(supabaseProvider).auth.currentUser == null) return;
      final r = await ref.read(supabaseProvider).rpc('team_theme_get');
      if (r is! Map) return;
      await _p.setString('tt_global_id', '${r['theme'] ?? 'default'}');
      await _p.setInt('tt_global_v', ((r['v'] as num?) ?? 0).toInt());
      _use(TeamTheme.effective(_p));
    } catch (_) {}
  }

  void _use(String id) {
    if (id == state && TeamTheme.id == id) return;
    TeamTheme.id = id;
    AppPalette.apply(TeamTheme.palette(id, ref.read(appearanceProvider).palette));
    state = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        WidgetsBinding.instance.reassembleApplication(); // repaint everything, even widgets built once with const colours
      } catch (_) {}
    });
  }

  /// Only this device. Nobody else sees it.
  Future<void> pickForDevice(String id) async {
    await _p.setString('tt_device_id', id);
    await _p.setInt('tt_device_at', DateTime.now().millisecondsSinceEpoch);
    _use(TeamTheme.effective(_p));
  }

  /// Everybody (owner only: the database refuses anyone else).
  Future<void> pickForEveryone(String id) async {
    final r = await ref.read(supabaseProvider).rpc('owner_set_team_theme', params: {'p_theme': id});
    if (r is Map) {
      await _p.setString('tt_global_id', '${r['theme']}');
      await _p.setInt('tt_global_v', ((r['v'] as num?) ?? 0).toInt());
    }
    await _p.setString('tt_device_id', id);
    await _p.setInt('tt_device_at', DateTime.now().millisecondsSinceEpoch);
    _use(TeamTheme.effective(_p));
  }
}

final teamThemeProvider = NotifierProvider<TeamThemeController, String>(TeamThemeController.new);

/// The colour button in the top corner of the console.
class TeamThemeButton extends ConsumerWidget {
  const TeamThemeButton({super.key, required this.isOwner});
  final bool isOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
        color: Colors.white,
        elevation: 2,
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: context.isAr ? 'ألوان البرنامج' : 'App colours',
          icon: const Icon(Icons.palette_outlined),
          color: BrandColors.electric,
          onPressed: () => showDialog<void>(context: context, builder: (_) => _ThemeDialog(isOwner: isOwner)),
        ),
      );
}

/// The colour choice as a page (inside Appearance): opens the same picker as the button in the corner.
class TeamThemeCard extends StatelessWidget {
  const TeamThemeCard({super.key, required this.isOwner});
  final bool isOwner;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.color_lens_outlined, size: 44, color: BrandColors.electric),
            const SizedBox(height: 10),
            Text(
                context.isAr
                    ? 'كل موظف يختار لون برنامجه على جهازه بس.${isOwner ? ' وإنت تقدر تطبّق لون على كل الفريق.' : ''}'
                    : 'Each member picks the colours on his own device.${isOwner ? ' You can also apply a colour to everyone.' : ''}',
                textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => showDialog<void>(context: context, builder: (_) => _ThemeDialog(isOwner: isOwner)),
              icon: const Icon(Icons.palette_outlined),
              label: Text(context.isAr ? 'اختيار الألوان' : 'Choose colours'),
            ),
          ]),
        ),
      );
}

class _ThemeDialog extends ConsumerStatefulWidget {
  const _ThemeDialog({required this.isOwner});
  final bool isOwner;
  @override
  ConsumerState<_ThemeDialog> createState() => _ThemeDialogState();
}

class _ThemeDialogState extends ConsumerState<_ThemeDialog> {
  bool _busy = false;

  Future<void> _everyone(String id) async {
    setState(() => _busy = true);
    try {
      await ref.read(teamThemeProvider.notifier).pickForEveryone(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.isAr ? 'اتطبّق على كل الموظفين ✅' : 'Applied to everyone ✅')));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.isAr ? 'معرفتش أطبّقها، جرّب تاني' : 'Could not apply it, try again')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(teamThemeProvider);
    final store = ref.watch(appearanceProvider).palette;
    final ar = context.isAr;
    return AlertDialog(
      title: Text(ar ? 'ألوان البرنامج' : 'App colours'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              ar ? 'اختار اللون اللي يريّحك. بيتغيّر على جهازك إنت بس ومش بيأثر على حد.' : 'Pick the colour you like. It changes only on your device and nobody else sees it.',
              style: const TextStyle(color: BrandColors.gray),
            ),
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final t in teamThemes)
                Builder(builder: (_) {
                  final pal = TeamTheme.palette(t.id, store);
                  Color c(String k) => Color(0xFF000000 | int.parse(pal[k]!.substring(1), radix: 16));
                  final on = t.id == cur;
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => ref.read(teamThemeProvider.notifier).pickForDevice(t.id),
                    child: Container(
                      width: 104,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: on ? c('accent') : const Color(0xFFE4E7EC), width: on ? 2.4 : 1),
                      ),
                      child: Column(children: [
                        SizedBox(
                          height: 38,
                          child: Row(children: [
                            Expanded(child: Container(decoration: BoxDecoration(color: c('primary'), borderRadius: const BorderRadiusDirectional.horizontal(start: Radius.circular(9))))),
                            Expanded(child: Container(color: c('accent'))),
                            Expanded(child: Container(decoration: BoxDecoration(color: c('background'), border: Border.all(color: const Color(0xFFE4E7EC)), borderRadius: const BorderRadiusDirectional.horizontal(end: Radius.circular(9))))),
                          ]),
                        ),
                        const SizedBox(height: 6),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          if (on) const Icon(Icons.check_circle_rounded, size: 15),
                          if (on) const SizedBox(width: 3),
                          Flexible(child: Text(ar ? t.ar : t.en, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                        ]),
                      ]),
                    ),
                  );
                }),
            ]),
            if (widget.isOwner) ...[
              const SizedBox(height: 18),
              const Divider(),
              Text(
                ar ? 'كمالك تقدر تطبّق اللون ده على كل الموظفين، وده مش متاح لحد غيرك.' : 'As the owner you can apply this colour to every employee. Nobody else can.',
                style: const TextStyle(color: BrandColors.gray, fontSize: 13),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : () => _everyone(cur),
                icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.groups_rounded),
                label: Text(ar ? 'طبّق اللون المختار على كل الموظفين' : 'Apply the chosen colour to everyone'),
              ),
            ],
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(ar ? 'تمام' : 'Done'))],
    );
  }
}
