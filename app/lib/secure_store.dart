import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keystore-backed storage for the master seed when there is **no app password**.
///
/// Previously an unprotected seed sat in `SharedPreferences` as plain hex, so a
/// file-stealer could read it. Here it lives in `flutter_secure_storage`, which
/// on Android is `EncryptedSharedPreferences` keyed by a hardware-backed
/// Keystore master key — the ciphertext on disk is useless without the device's
/// TEE. (With an app password the seed is instead sealed in the password vault,
/// which is stronger still.)
///
/// A no-op-ish fallback off Android/iOS. All methods fail closed.
class SecureStore {
  static const FlutterSecureStorage _store = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const String _seedKey = 'aegis.secure_seed';

  static bool get _supported => Platform.isAndroid || Platform.isIOS;

  /// Store the master seed (hex) in the keystore.
  static Future<void> writeSeed(String seedHex) async {
    if (!_supported) return;
    try {
      await _store.write(key: _seedKey, value: seedHex);
    } catch (e) {
      debugPrint('secure seed write failed: $e');
    }
  }

  /// Read the stored seed (hex), or null if none / unreadable / unsupported.
  static Future<String?> readSeed() async {
    if (!_supported) return null;
    try {
      return await _store.read(key: _seedKey);
    } catch (e) {
      debugPrint('secure seed read failed: $e');
      return null;
    }
  }

  /// Whether a keystore-held seed exists.
  static Future<bool> hasSeed() async {
    if (!_supported) return false;
    try {
      return await _store.containsKey(key: _seedKey);
    } catch (_) {
      return false;
    }
  }

  /// Erase the stored seed.
  static Future<void> clear() async {
    if (!_supported) return;
    try {
      await _store.delete(key: _seedKey);
    } catch (_) {}
  }
}
