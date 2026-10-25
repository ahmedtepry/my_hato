import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'l10n.dart';
import 'supabase_providers.dart';
import 'theme.dart';

const launchAnimations = ['classic', 'zoom', 'slide'];
const appIcons = ['default', 'a', 'b', 'c'];

/// What the owner chose in the console: five colours, the opening animation and the launcher icon.
class Appearance {
  const Appearance({this.palette = AppPalette.defaults, this.animation = 'classic', this.icon = 'default'});
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
    );
  }
}

/// Paints the saved colours before the first frame, so the app never flashes the old ones.
void applySavedPalette(SharedPreferences prefs) => AppPalette.apply(Appearance.fromPrefs(prefs).palette);

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
      final rows = await ref.read(supabaseProvider).from('application_settings').select('key, value').inFilter('key', ['theme_palette', 'launch_animation', 'app_icon']);
      final m = {for (final r in rows) r['key'] as String: r['value']};
      final pal = m['theme_palette'];
      final anim = m['launch_animation'];
      final icon = m['app_icon'];
      _apply(Appearance(
        palette: pal is Map ? {for (final e in pal.entries) '${e.key}': '${e.value}'} : state.palette,
        animation: launchAnimations.contains(anim) ? anim as String : state.animation,
        icon: appIcons.contains(icon) ? icon as String : state.icon,
      ));
    } catch (_) {}
  }

  Future<void> _apply(Appearance a) async {
    final prefs = ref.read(sharedPrefsProvider);
    final paletteChanged = AppPalette.apply(a.palette);
    await prefs.setString('appearance_palette', jsonEncode(a.palette));
    await prefs.setString('appearance_animation', a.animation);
    await prefs.setString('appearance_icon', a.icon);
    state = a;
    if (paletteChanged) {
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
