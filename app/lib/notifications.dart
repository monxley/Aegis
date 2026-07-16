import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// A thin wrapper over local notifications. Aegis shows a notification when a
/// message arrives (if the user enabled it) but never puts the message text in
/// it — the body is generic, so nothing sensitive lands on the lock screen.
class Notifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static const _channelId = 'aegis.messages';
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      'Messages',
      channelDescription: 'New Aegis messages',
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  /// Initialize the plugin (idempotent). Safe to call on every launch.
  static Future<void> init() async {
    if (_inited) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    _inited = true;
  }

  /// Ask the OS for notification permission (Android 13+). Returns whether it's
  /// granted; older Androids grant at install and return true.
  static Future<bool> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final granted = await android.requestNotificationsPermission();
    return granted ?? true;
  }

  /// Show a message notification. [title] is the sender; the body is generic on
  /// purpose (no message content leaks to the lock screen).
  static Future<void> showMessage({required String title, int id = 0}) async {
    if (!_inited) await init();
    try {
      await _plugin.show(id, title, 'New encrypted message', _details);
    } catch (e) {
      debugPrint('notify failed: $e');
    }
  }
}
