import 'dart:io';

import 'package:flutter/services.dart';

/// Toggles the platform's screen-privacy protection at runtime via a channel
/// handled in the native host (both injected by the build scripts).
///
/// - **Android** (`MainActivity`, `deploy/build-apk.sh`): sets `FLAG_SECURE`, so
///   the OS blocks screenshots and screen recording and blanks the app-switcher
///   card. Secure by default — `onCreate` sets the flag before Dart runs, so
///   screenshots are blocked from the first frame even if this is never called.
/// - **iOS** (`AppDelegate`, `deploy/build-ios.sh`): iOS has **no** API to block
///   screenshots, so this instead covers the app-switcher snapshot with a blur
///   overlay when the app resigns active — the closest available protection.
///   (A taken screenshot can still be *detected* natively but not prevented.)
///
/// A no-op on desktop. Best-effort: swallows channel errors (e.g. an old build
/// without the native handler).
class ScreenSecurity {
  static const MethodChannel _ch = MethodChannel('aegis/screen_security');

  /// Turn the screen-privacy protection on or off.
  static Future<void> setSecure(bool on) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _ch.invokeMethod<void>('setSecure', on);
    } catch (_) {
      // No native handler (older build) — the platform default still applies.
    }
  }
}
