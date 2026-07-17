import 'dart:io';

import 'package:flutter/services.dart';

/// Starts/stops the Android foreground service (handled in `MainActivity`,
/// injected by `deploy/build-apk.sh`). The service keeps the app process alive
/// with a quiet ongoing notification so the poll timer keeps receiving messages
/// while the app is in the background — 24/7 delivery, and the mailbox is drained
/// promptly instead of piling up on the node.
///
/// A no-op off Android; best-effort (swallows channel errors on an old APK).
class BackgroundService {
  static const MethodChannel _ch = MethodChannel('aegis/background');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
