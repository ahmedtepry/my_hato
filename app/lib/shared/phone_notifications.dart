import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System notifications on the phone (status bar + sound) for new in-app notifications:
/// order / repair updates for customers, and new orders / repairs / cancellations / reviews /
/// low stock for staff. Shown while the app is running (open or recently in the background).
class PhoneNotifications {
  PhoneNotifications._();
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static void Function(String link)? onOpen;

  static const _channel = AndroidNotificationDetails(
    'myhato_updates',
    'My Hatō updates',
    channelDescription: 'Orders, repairs and store alerts',
    importance: Importance.high,
    priority: Priority.high,
    icon: '@mipmap/ic_launcher',
    color: Color(0xFF0B2D5B),
  );

  static Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) {
          final link = r.payload;
          if (link != null && link.isNotEmpty) onOpen?.call(link);
        },
      );
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  static Future<void> show({required String id, required String title, required String body, String? link}) async {
    if (!_ready) return;
    try {
      await _plugin.show(id.hashCode & 0x7fffffff, title, body, const NotificationDetails(android: _channel), payload: link);
    } catch (_) {}
  }
}
