import 'dart:io';

import 'package:flutter/services.dart';

/// Toggles Android's `FLAG_SECURE` at runtime via a platform channel handled in
/// `MainActivity` (injected by `deploy/build-apk.sh`). When on, the OS blocks
/// screenshots and screen recording and blanks the app-switcher card.
///
/// Secure by default — `MainActivity.onCreate` sets the flag before Dart runs,
/// so screenshots are blocked from the first frame even if this is never called.
/// A no-op off Android (the flag is Android-only).
class ScreenSecurity {
  static const MethodChannel _ch = MethodChannel('aegis/screen_security');

  /// Turn the screenshot/recording block on or off. Best-effort: swallows any
  /// channel error (e.g. an old APK without the native handler).
  static Future<void> setSecure(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('setSecure', on);
    } catch (_) {
      // No native handler (older build) — the onCreate default still applies.
    }
  }
}
