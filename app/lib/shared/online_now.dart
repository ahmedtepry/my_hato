// "Online now": every open copy of the app joins one Realtime presence channel while it is in the
// foreground. Nothing is stored in the database and no personal data is sent: each copy only announces a
// random key and whether it belongs to the team. The owner's overview shows how many non-team copies are open.
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OnlineNow {
  OnlineNow._();

  /// Customers and guests with the app open right now (team members are not counted).
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  static SupabaseClient? _db;
  static RealtimeChannel? _ch;
  static bool? _staff;

  static void start(SupabaseClient db, {required bool staff}) {
    if (_ch != null && _staff == staff) return;
    stop();
    _db = db;
    _staff = staff;
    try {
      final key = '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 31)}';
      final ch = db.channel('online-now', opts: RealtimeChannelConfig(key: key));
      _ch = ch;
      ch.onPresenceSync((_) => _recount(ch)).subscribe((status, [error]) async {
        if (status == RealtimeSubscribeStatus.subscribed) {
          await ch.track({'staff': staff});
        }
      });
    } catch (_) {/* presence is best effort */}
  }

  static void _recount(RealtimeChannel ch) {
    try {
      var n = 0;
      for (final s in ch.presenceState()) {
        if (!s.presences.any((p) => p.payload['staff'] == true)) n++;
      }
      count.value = n;
    } catch (_) {}
  }

  static void stop() {
    final ch = _ch;
    final db = _db;
    _ch = null;
    _staff = null;
    count.value = 0;
    if (ch != null && db != null) {
      try {
        ch.untrack();
        db.removeChannel(ch);
      } catch (_) {}
    }
  }
}
