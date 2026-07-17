import 'dart:io';

import 'package:flutter/services.dart';

/// Swaps the app's launcher icon + name at runtime (handled in `MainActivity`,
/// injected by `deploy/build-apk.sh`) so Aegis can masquerade as an ordinary
/// utility. Values: `default` (Aegis), `calculator`, `notes`, `weather`.
///
/// A no-op off Android; best-effort (swallows channel errors on an old APK).
class Disguise {
  static const MethodChannel _ch = MethodChannel('aegis/disguise');

  static Future<void> apply(String which) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('setDisguise', which);
    } catch (_) {}
  }
}
