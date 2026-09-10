import 'package:record_platform_interface/record_platform_interface.dart';

/// A deliberately inert Linux backend for the `record` plugin.
///
/// The published `record_linux` 0.7.2 does not compile against *any* 1.x of
/// `record_platform_interface` that pub will resolve for `record: ^5.1.2` — it
/// is missing `startStream` and its `hasPermission` lost a named argument. That
/// would be only a Linux problem except that `record` imports its Linux backend
/// unconditionally, so the broken file is compiled into the **Android** kernel
/// snapshot too, and the release APK cannot be built at all.
///
/// Aegis does not record audio on Linux desktop, so a backend that refuses is
/// no loss. What it must not do is pretend: every call throws, rather than
/// silently returning an empty recording that the user would discover only
/// after trying to send it.
///
/// It implements the interface through [noSuchMethod] instead of listing the
/// members, which is what the analyzer itself suggests for exactly this case.
/// That is not laziness — it is the property that matters here. A stub that
/// enumerated `startStream`, `hasPermission` and the rest would break again the
/// next time the interface gains a member, which is precisely the failure being
/// worked around. This one cannot.
///
/// Delete this package the moment `record` ships a Linux implementation that
/// matches its own interface, and drop the `dependency_overrides` entry with it.
class RecordLinux extends RecordPlatform {
  /// Registered by Flutter's generated Dart plugin registrant on Linux.
  static void registerWith() {
    RecordPlatform.instance = RecordLinux();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
        'Recording audio is not supported on Linux in this build: the record '
        'plugin has no working Linux backend. Playback, files and images are '
        'unaffected.',
      );
}
