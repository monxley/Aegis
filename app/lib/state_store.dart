import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the encrypted app-state blob lives on disk.
///
/// It used to live in `SharedPreferences` as a base64 string. That is fine for
/// a setting and bad for a blob that grows with your entire message history:
/// on Android, prefs are a single XML file that is parsed **in full on the
/// first access** and rewritten **in full on every commit**, so a large state
/// meant a slow launch and a stutter on every save — and base64 inflated it by
/// a third on top.
///
/// So the blob is now its own file: written once, read once, no XML parsing,
/// no base64. Existing installs are migrated on first read and the old prefs
/// entry is removed.
///
/// The bytes are already encrypted by the engine (sealed under a key derived
/// from the master seed) before they reach this class — nothing here is ever
/// plaintext.
class StateStore {
  Directory? _dir;

  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/state');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// The file backing a given prefs key (the real and decoy states are
  /// separate keys, so they stay separate files).
  Future<File> _fileFor(String key) async {
    final dir = await _directory();
    // Keep the key readable but filesystem-safe.
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return File('${dir.path}/$safe.bin');
  }

  /// Write the blob durably. The write goes to a temp file first and is then
  /// renamed over the target: a crash mid-write leaves the previous good state
  /// intact instead of a truncated file the engine can't parse.
  Future<void> write(String key, Uint8List blob) async {
    final file = await _fileFor(key);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(blob, flush: true);
    await tmp.rename(file.path);
  }

  /// Read the blob, migrating from the old prefs entry if this is the first
  /// run after the change. Returns null when there is nothing stored.
  Future<Uint8List?> read(String key) async {
    try {
      final file = await _fileFor(key);
      if (await file.exists()) return await file.readAsBytes();
    } catch (e) {
      debugPrint('state read failed: $e');
    }
    return _migrateFromPrefs(key);
  }

  /// One-time move of a legacy base64 prefs blob into a file.
  Future<Uint8List?> _migrateFromPrefs(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(key);
      if (legacy == null || legacy.isEmpty) return null;
      final blob = Uint8List.fromList(base64Decode(legacy));
      await write(key, blob);
      // Only drop the old copy once the new one is safely written.
      await prefs.remove(key);
      debugPrint('migrated state to file storage (${blob.length} bytes)');
      return blob;
    } catch (e) {
      debugPrint('state migration failed: $e');
      return null;
    }
  }

  /// Delete a stored state (reset identity / panic wipe). Also clears any
  /// legacy prefs copy that migration has not reached yet.
  Future<void> remove(String key) async {
    try {
      final file = await _fileFor(key);
      if (await file.exists()) await file.delete();
      final tmp = File('${file.path}.tmp');
      if (await tmp.exists()) await tmp.delete();
    } catch (e) {
      debugPrint('state delete failed: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }
}
