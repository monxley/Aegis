import 'dart:io';

/// Best-effort, on-device **root / emulator detection**.
///
/// This uses file-path heuristics only (no native plugin), so it is easily
/// bypassed by a determined attacker — it catches casual cases (a rooted phone,
/// a stock emulator) and *warns* the user. It is a hardening hint, **not** a
/// security guarantee: on a truly compromised device nothing the app checks can
/// be trusted (§1.4).
class DeviceIntegrity {
  final bool rooted;
  final bool emulator;
  const DeviceIntegrity({required this.rooted, required this.emulator});

  /// Whether anything worth warning about was detected.
  bool get flagged => rooted || emulator;

  static const _rootPaths = [
    '/system/bin/su',
    '/system/xbin/su',
    '/sbin/su',
    '/su/bin/su',
    '/data/local/su',
    '/data/local/bin/su',
    '/data/local/xbin/su',
    '/system/bin/.ext/.su',
    '/system/xbin/busybox',
    '/system/app/Superuser.apk',
    '/system/usr/we-need-root/su-backup',
    // Magisk markers.
    '/sbin/.magisk',
    '/cache/.disable_magisk',
    '/init.magisk.rc',
  ];

  static const _emulatorPaths = [
    '/dev/socket/qemud',
    '/dev/qemu_pipe',
    '/system/lib/libc_malloc_debug_qemu.so',
    '/sys/qemu_trace',
    '/system/bin/qemu-props',
    '/dev/socket/genyd',
    '/dev/socket/baseband_genyd',
  ];

  /// Run the checks. Only meaningful on Android; elsewhere reports clean.
  static Future<DeviceIntegrity> check() async {
    if (!Platform.isAndroid) {
      return const DeviceIntegrity(rooted: false, emulator: false);
    }
    return DeviceIntegrity(
      rooted: _anyExists(_rootPaths),
      emulator: _anyExists(_emulatorPaths),
    );
  }

  static bool _anyExists(List<String> paths) {
    for (final p in paths) {
      try {
        if (File(p).existsSync()) return true;
      } catch (_) {
        // Unreadable path — ignore and keep checking.
      }
    }
    return false;
  }

  /// A short, human-readable reason for the warning.
  String get reason {
    if (rooted && emulator) return 'This device looks rooted and like an emulator.';
    if (rooted) return 'This device looks rooted.';
    return 'Aegis looks like it’s running on an emulator.';
  }
}
