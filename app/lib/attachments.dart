import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'src/rust/api/aegis.dart';

/// On-device storage for attachment payloads (voice notes, images, files).
///
/// Attachment bytes deliberately live **outside** the app-state blob: that blob
/// is rewritten on every change, so folding megabytes of audio into it would
/// make every message expensive to save. Instead each attachment is one file in
/// the app's private directory.
///
/// Those files are **never written in the clear**. The engine hands the bytes
/// over already sealed under the master-seed-derived state key
/// ([`AegisEngine.takeAttachment`]) and opens them again for playback
/// ([`AegisEngine.openAttachment`]) — so a device backup, a file manager, or
/// another app that somehow reaches the directory finds only ciphertext.
class AttachmentStore {
  static Directory? _dir;

  /// The private directory attachments live in, created on first use.
  static Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/attachments');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _dir = dir;
  }

  /// Write an already-sealed attachment blob and return its path.
  static Future<String> save(BigInt id, Uint8List sealed) async {
    final dir = await _directory();
    final file = File('${dir.path}/$id.aeg');
    await file.writeAsBytes(sealed, flush: true);
    return file.path;
  }

  /// Read a sealed attachment back, or null if the file is gone (e.g. the user
  /// cleared app storage, or it was never persisted on this device).
  static Future<Uint8List?> readSealed(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('attachment read failed: $e');
      return null;
    }
  }

  /// Delete one attachment file — used when its message is deleted.
  static Future<void> remove(String path) async {
    if (path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('attachment delete failed: $e');
    }
  }

  /// Delete every stored attachment (panic wipe / reset identity).
  static Future<void> clear() async {
    try {
      final dir = await _directory();
      if (await dir.exists()) await dir.delete(recursive: true);
      _dir = null;
    } catch (e) {
      debugPrint('attachment wipe failed: $e');
    }
  }

  /// Write decrypted bytes to a scratch file so another app can open them
  /// (share sheet, "open with"). This is the one place plaintext touches the
  /// disk, and only for a file the user explicitly asked to open — the caller
  /// should clean it up with [clearScratch] when the chat closes.
  static Future<File> scratchFile(String name, Uint8List plain) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/aegis-open');
    if (!await dir.exists()) await dir.create(recursive: true);
    // Keep the extension (some apps dispatch on it) but not the user's path.
    final safe = name.isEmpty ? 'file' : name.split('/').last;
    final file = File('${dir.path}/$safe');
    await file.writeAsBytes(plain, flush: true);
    return file;
  }

  /// Remove the plaintext scratch directory used by [scratchFile].
  static Future<void> clearScratch() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/aegis-open');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('scratch wipe failed: $e');
    }
  }
}

/// What a [ChatMessage] carries. Mirrors the `kind` byte the engine sets.
class MsgKind {
  static const int text = 0;
  static const int file = 1;
  static const int voice = 2;
  static const int image = 3;
}

extension MessageAttachment on ChatMessage {
  /// Whether this message carries an attachment rather than plain text.
  bool get hasAttachment => kind != MsgKind.text;

  /// Whether every chunk has arrived (always true for text and for our own
  /// outgoing messages, which are complete by definition).
  bool get complete => kind == MsgKind.text || transferHave >= transferTotal;

  /// A short label for notifications and chat previews.
  String get attachmentLabel => switch (kind) {
        MsgKind.voice => 'Voice message',
        MsgKind.image => 'Photo',
        MsgKind.file => fileName.isEmpty ? 'File' : fileName,
        _ => text,
      };
}

/// A human-readable file size ("1.4 MB").
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value < 10 ? value.toStringAsFixed(1) : value.round()} ${units[unit]}';
}

/// A voice-note duration as `m:ss`.
String formatDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}
