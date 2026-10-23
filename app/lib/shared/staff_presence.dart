// Team presence: while a team member has the app open, a light heartbeat (every 45 s) tells the
// owner's Team board that they are online and where they are; going to background marks them away.
// Customers never send anything.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/supabase_providers.dart';
import '../features/admin/admin_repository.dart';
import 'online_now.dart';

class StaffPresence {
  StaffPresence._();

  /// What the member is looking at (console tab key, 'team', 'offers', or 'store').
  static String area = 'store';
  static const _version = String.fromEnvironment('APP_VERSION', defaultValue: '');
  static String get platform {
    try {
      return Platform.isAndroid ? 'Android' : (Platform.isIOS ? 'iPhone' : Platform.operatingSystem);
    } catch (_) {
      return 'web';
    }
  }
}

class StaffPresenceScope extends ConsumerStatefulWidget {
  const StaffPresenceScope({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<StaffPresenceScope> createState() => _StaffPresenceScopeState();
}

class _StaffPresenceScopeState extends ConsumerState<StaffPresenceScope> with WidgetsBindingObserver {
  Timer? _timer;
  bool _staff = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _beat(bool online) async {
    if (!_staff) return;
    try {
      await ref.read(supabaseProvider).rpc('staff_heartbeat', params: {
        'p_online': online,
        'p_area': StaffPresence.area,
        'p_platform': StaffPresence.platform,
        'p_version': StaffPresence._version.isEmpty ? null : StaffPresence._version,
      });
    } catch (_) {/* presence is best effort */}
  }

  void _setStaff(bool v) {
    if (v == _staff) return;
    _staff = v;
    _timer?.cancel();
    if (v) {
      _beat(true);
      _timer = Timer.periodic(const Duration(seconds: 45), (_) => _beat(true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // the "online now" count only includes copies of the app that are on screen
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      OnlineNow.start(ref.read(supabaseProvider), staff: _staff);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _foreground = false;
      OnlineNow.stop();
    }
    if (!_staff) return;
    if (state == AppLifecycleState.resumed) {
      _beat(true);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 45), (_) => _beat(true));
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _timer?.cancel();
      _beat(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roles = ref.watch(staffContextProvider).valueOrNull?.roles ?? const <String>{};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _setStaff(roles.isNotEmpty);
      if (_foreground) OnlineNow.start(ref.read(supabaseProvider), staff: _staff);
    });
    return widget.child;
  }
}

/// Call before signing a team member out so the board shows them offline at once.
Future<void> staffWentOffline(WidgetRef ref) async {
  try {
    await ref.read(supabaseProvider).rpc('staff_heartbeat', params: {'p_online': false});
  } catch (_) {}
}
