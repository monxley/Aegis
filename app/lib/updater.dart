import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/rust/api/aegis.dart';

/// A newer release found on GitHub.
class UpdateInfo {
  /// The release tag, e.g. `v0.1.1`.
  final String version;

  /// Where to get it: the `.apk` asset if the release has one, else the release
  /// page.
  final String url;

  /// The release notes (markdown, as written on GitHub).
  final String notes;

  /// Whether [url] points straight at an APK (vs. the release page).
  final bool hasApk;

  const UpdateInfo({
    required this.version,
    required this.url,
    required this.notes,
    required this.hasApk,
  });
}

/// Checks the project's GitHub releases for a newer build. Aegis is sideloaded
/// (no Play Store), and its protocol/node can change in ways that break older
/// clients — so an available update is surfaced prominently, not silently.
class Updater {
  /// `owner/repo` on GitHub.
  static const String repo = 'monxley/Aegis';

  /// The running build's version (`versionName`), e.g. `0.1.0`.
  static Future<String> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  /// Query the latest release; return [UpdateInfo] if it's newer than the
  /// running build, else null. Never throws — any error (offline, rate-limited,
  /// no releases yet) just yields null.
  static Future<UpdateInfo?> check() async {
    try {
      final current = await currentVersion();
      final json = await _fetchLatest();
      if (json == null) return null;
      final tag = (json['tag_name'] as String?)?.trim() ?? '';
      if (tag.isEmpty) return null;
      // Version precedence is decided by the Rust core (unit-tested there).
      if (!isNewerVersion(current: current, latest: tag)) return null;

      final assets = (json['assets'] as List?) ?? const [];
      String? apk;
      for (final a in assets) {
        final name = (a is Map ? a['name'] as String? : null) ?? '';
        if (name.toLowerCase().endsWith('.apk')) {
          apk = a['browser_download_url'] as String?;
          break;
        }
      }
      final page = (json['html_url'] as String?) ??
          'https://github.com/$repo/releases/latest';
      return UpdateInfo(
        version: tag,
        url: apk ?? page,
        notes: (json['body'] as String?)?.trim() ?? '',
        hasApk: apk != null,
      );
    } catch (e) {
      debugPrint('update check failed: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _fetchLatest() async {
    final client = HttpClient();
    try {
      final uri =
          Uri.parse('https://api.github.com/repos/$repo/releases/latest');
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'Aegis-Updater');
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } finally {
      client.close();
    }
  }

  /// Open the download URL in the browser (which fetches the APK; the user then
  /// installs it). Returns whether the launch succeeded.
  static Future<bool> openDownload(UpdateInfo u) async {
    try {
      return await launchUrl(Uri.parse(u.url),
          mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('launch failed: $e');
      return false;
    }
  }
}
