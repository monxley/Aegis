import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Fingerprint / Face unlock, layered **over** the app password as a
/// convenience. When the user turns it on (from an unlocked session), the master
/// seed is copied into Keystore-backed secure storage; a successful biometric
/// check then releases it to boot the engine — without typing the password.
///
/// This is a deliberate convenience/security trade-off the user opts into: the
/// seed lives in the OS keystore (hardware-backed where available), not only in
/// the password vault. Biometrics unlock the **real** account; under coercion,
/// use the duress password instead (biometrics can be compelled).
///
/// All methods are Android/iOS-only and fail closed (return false / null) if the
/// platform, plugins, or enrolled biometrics are unavailable.
class Biometrics {
  static final LocalAuthentication _auth = LocalAuthentication();
  static const FlutterSecureStorage _store = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const String _seedKey = 'aegis.bio_seed';

  /// Whether the device can do biometric auth right now (hardware present and at
  /// least one fingerprint/face enrolled).
  static Future<bool> deviceSupported() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return false;
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      final kinds = await _auth.getAvailableBiometrics();
      return kinds.isNotEmpty;
    } catch (e) {
      debugPrint('biometric support check failed: $e');
      return false;
    }
  }

  /// Whether a biometric-unlock seed is currently stored (i.e. the feature is
  /// enabled on this device).
  static Future<bool> hasStoredSeed() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return false;
    try {
      return await _store.containsKey(key: _seedKey);
    } catch (_) {
      return false;
    }
  }

  /// Prompt for a biometric check. Returns true only on a successful match.
  static Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (e) {
      debugPrint('biometric auth failed: $e');
      return false;
    }
  }

  /// Store the master [seed] for biometric unlock (call after the user has
  /// authenticated with their password).
  static Future<void> storeSeed(Uint8List seed) async {
    await _store.write(key: _seedKey, value: base64Encode(seed));
  }

  /// Read back the stored seed, or null if none / unreadable. Gate this behind
  /// [authenticate].
  static Future<Uint8List?> readSeed() async {
    try {
      final v = await _store.read(key: _seedKey);
      if (v == null) return null;
      return Uint8List.fromList(base64Decode(v));
    } catch (e) {
      debugPrint('biometric seed read failed: $e');
      return null;
    }
  }

  /// Remove the stored seed (disable the feature, or on wipe/reset).
  static Future<void> clear() async {
    try {
      await _store.delete(key: _seedKey);
    } catch (_) {}
  }
}
