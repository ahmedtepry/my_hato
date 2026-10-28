import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'l10n.dart';
import 'team_theme.dart';
import 'supabase_providers.dart';
import 'theme.dart';

const launchAnimations = ['classic', 'zoom', 'slide'];
const appIcons = ['default', 'a', 'b', 'c'];

/// The app's name, set by the owner. Read wherever the app writes its own name.
class AppName {
  static String ar = 'My Hatō';
  static String en = 'My Hatō';
  static String of(String languageCode) => languageCode == 'ar' ? ar : en;
}

/// The occasion running now (stamp on the logo), or empty. Read by the logo widgets.
class AppOccasion {
  static String key = '';
  static String stamp = '';
}

/// What the owner chose in the console: five colours, the opening animation and the launcher icon.
class Appearance {
  const Appearance({this.palette = AppPalette.defaults, this.animation = 'classic', this.icon = 'default', this.nameAr = 'My Hatō', this.nameEn = 'My Hatō', this.occasion = '', this.stamp = ''});
  final String occasion;
  final String stamp;
  final String nameAr;
  final String nameEn;
  final Map<String, String> palette;
  final String animation;
  final String icon;

  static Appearance fromPrefs(SharedPreferences p) {
    Map<String, String> pal = AppPalette.defaults;
    try {
      final raw = p.getString('appearance_palette');
      if (raw != null) pal = {for (final e in (jsonDecode(raw) as Map).entries) '${e.key}': '${e.value}'};
    } catch (_) {}
    final anim = p.getString('appearance_animation');
    final icon = p.getString('appearance_icon');
    return Appearance(
      palette: pal,
      animation: launchAnimations.contains(anim) ? anim! : 'classic',
      icon: appIcons.contains(icon) ? icon! : 'default',
      nameAr: _cleanName(p.getString('appearance_name_ar')),
      nameEn: _cleanName(p.getString('appearance_name_en')),
      occasion: p.getString('appearance_occasion') ?? '',
      stamp: p.getString('appearance_stamp') ?? '',
    );
  }
}

String _cleanName(String? v) => (v == null || v.trim().isEmpty) ? 'My Hatō' : v.trim();

/// Paints the saved colours before the first frame, so the app never flashes the old ones.
void applySavedPalette(SharedPreferences prefs) {
  final a = Appearance.fromPrefs(prefs);
  if (AppConfig.teamOnly) TeamTheme.id = TeamTheme.effective(prefs);
  AppPalette.apply(AppConfig.teamOnly ? TeamTheme.palette(TeamTheme.id, a.palette) : a.palette);
  AppName.ar = a.nameAr;
  AppName.en = a.nameEn;
  AppOccasion.key = a.occasion;
  AppOccasion.stamp = a.stamp;
}

class AppearanceController extends Notifier<Appearance> {
  static const _iconChannel = MethodChannel('myhato/icon');
  RealtimeChannel? _channel;

  @override
  Appearance build() {
    final saved = Appearance.fromPrefs(ref.read(sharedPrefsProvider));
    Future.microtask(_start);
    ref.onDispose(() => _channel?.unsubscribe());
    return saved;
  }

  Future<void> _start() async {
    await refresh();
    try {
      _channel = ref
          .read(supabaseProvider)
          .channel('appearance')
          .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'application_settings', callback: (_) => refresh())
          .subscribe();
    } catch (_) {}
  }

  /// Reads the owner's choices and applies them. Silent on failure: the app keeps the last known look.
  Future<void> refresh() async {
    try {
      final rows = await ref.read(supabaseProvider).from('application_settings').select('key, value').inFilter('key', ['theme_palette', 'launch_animation', 'app_icon', 'app_name', 'active_occasion']);
      final m = {for (final r in rows) r['key'] as String: r['value']};
      final pal = m['theme_palette'];
      final anim = m['launch_animation'];
      final icon = m['app_icon'];
      final name = m['app_name'];
      final occ = m['active_occasion'];
      final occKey = occ is Map && occ['key'] is String ? occ['key'] as String : '';
      final occStamp = occ is Map && occ['stamp'] is String ? occ['stamp'] as String : '';
      String pickName(String k, String keep) {
        final v = name is Map ? name[k] : null;
        return v is String && v.trim().isNotEmpty ? v.trim() : keep;
      }

      _apply(Appearance(
        palette: pal is Map ? {for (final e in pal.entries) '${e.key}': '${e.value}'} : state.palette,
        animation: launchAnimations.contains(anim) ? anim as String : state.animation,
        icon: appIcons.contains(icon) ? icon as String : state.icon,
        nameAr: pickName('ar', state.nameAr),
        nameEn: pickName('en', state.nameEn),
        occasion: m.containsKey('active_occasion') ? occKey : state.occasion,
        stamp: m.containsKey('active_occasion') ? occStamp : state.stamp,
      ));
    } catch (_) {}
  }

  Future<void> _apply(Appearance a) async {
    final prefs = ref.read(sharedPrefsProvider);
    final paletteChanged = AppPalette.apply(AppConfig.teamOnly ? TeamTheme.palette(TeamTheme.id, a.palette) : a.palette);
    final nameChanged = AppName.ar != a.nameAr || AppName.en != a.nameEn;
    AppName.ar = a.nameAr;
    AppName.en = a.nameEn;
    final occasionChanged = AppOccasion.key != a.occasion || AppOccasion.stamp != a.stamp;
    AppOccasion.key = a.occasion;
    AppOccasion.stamp = a.stamp;
    await prefs.setString('appearance_occasion', a.occasion);
    await prefs.setString('appearance_stamp', a.stamp);
    await prefs.setString('appearance_name_ar', a.nameAr);
    await prefs.setString('appearance_name_en', a.nameEn);
    await prefs.setString('appearance_palette', jsonEncode(a.palette));
    await prefs.setString('appearance_animation', a.animation);
    await prefs.setString('appearance_icon', a.icon);
    state = a;
    if (paletteChanged || nameChanged || occasionChanged) {
      // repaint everything, including widgets that were built once with const colours
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          WidgetsBinding.instance.reassembleApplication();
        } catch (_) {}
      });
    }
    if (prefs.getString('appearance_icon_applied') != a.icon) {
      try {
        final ok = await _iconChannel.invokeMethod<bool>('set', a.icon);
        if (ok == true) await prefs.setString('appearance_icon_applied', a.icon);
      } catch (_) {
        // not Android, or an old build without the icon switch: nothing to do
      }
    }
  }
}

final appearanceProvider = NotifierProvider<AppearanceController, Appearance>(AppearanceController.new);
