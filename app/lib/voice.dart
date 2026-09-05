import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'attachments.dart';

/// Records a voice note to a temporary Opus file and reports live amplitude so
/// the UI can draw a waveform while the user holds the button.
///
/// The recording only ever exists as a temp file for the moments between
/// stopping and handing the bytes to the engine, which seals them; [dispose]
/// and [cancel] both remove it.
class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  final ValueNotifier<List<double>> waveform = ValueNotifier(const []);
  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  Timer? _ticker;
  String? _path;
  DateTime? _startedAt;

  /// Whether a recording is currently running.
  bool get recording => _startedAt != null;

  /// Whether the OS will let us record (permission granted / hardware present).
  Future<bool> hasPermission() async {
    try {
      return await _rec.hasPermission();
    } catch (e) {
      debugPrint('mic permission check failed: $e');
      return false;
    }
  }

  /// Begin recording. Returns false if permission was refused or the recorder
  /// could not start, so the caller can show a hint instead of a dead UI.
  Future<bool> start() async {
    if (recording) return true;
    if (!await hasPermission()) return false;
    try {
      final dir = await Directory.systemTemp.createTemp('aegis-voice');
      final path = '${dir.path}/note.m4a';
      await _rec.start(
        // AAC in an m4a container: hardware-encoded on both platforms and
        // playable everywhere, so a note recorded on Android opens on iOS.
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      _path = path;
      _startedAt = DateTime.now();
      waveform.value = const [];
      elapsed.value = Duration.zero;
      _ticker = Timer.periodic(const Duration(milliseconds: 90), (_) => _tick());
      return true;
    } catch (e) {
      debugPrint('recording failed to start: $e');
      await _cleanup();
      return false;
    }
  }

  /// Sample the input level and advance the elapsed clock.
  Future<void> _tick() async {
    final startedAt = _startedAt;
    if (startedAt == null) return;
    elapsed.value = DateTime.now().difference(startedAt);
    try {
      final amp = await _rec.getAmplitude();
      // `current` is dBFS: roughly -60 (silence) to 0 (peak). Map it onto 0..1
      // with a floor, so quiet speech still shows movement.
      final db = amp.current.isFinite ? amp.current : -60.0;
      final level = ((db + 50) / 50).clamp(0.05, 1.0).toDouble();
      final next = [...waveform.value, level];
      // Keep only what the bar can show, so the list can't grow without bound.
      waveform.value = next.length > 64 ? next.sublist(next.length - 64) : next;
    } catch (_) {
      // Amplitude is a nicety — a failure here must not break recording.
    }
  }

  /// Stop and return the recorded bytes plus their duration, or null if the
  /// recording was too short to be meaningful (a tap rather than a hold).
  Future<({Uint8List bytes, int durationMs})?> stop() async {
    if (!recording) return null;
    final startedAt = _startedAt!;
    _ticker?.cancel();
    _ticker = null;
    _startedAt = null;
    try {
      final path = await _rec.stop() ?? _path;
      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      if (path == null || ms < 500) {
        await _cleanup();
        return null;
      }
      final file = File(path);
      if (!await file.exists()) {
        await _cleanup();
        return null;
      }
      final bytes = await file.readAsBytes();
      await _cleanup();
      return (bytes: bytes, durationMs: ms);
    } catch (e) {
      debugPrint('recording failed to stop: $e');
      await _cleanup();
      return null;
    }
  }

  /// Abandon the recording and delete the temp file.
  Future<void> cancel() async {
    _ticker?.cancel();
    _ticker = null;
    _startedAt = null;
    try {
      if (await _rec.isRecording()) await _rec.stop();
    } catch (_) {}
    await _cleanup();
  }

  Future<void> _cleanup() async {
    final path = _path;
    _path = null;
    waveform.value = const [];
    elapsed.value = Duration.zero;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      final dir = file.parent;
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await cancel();
    await _rec.dispose();
    waveform.dispose();
    elapsed.dispose();
  }
}

/// Plays back one voice note at a time across the whole app, so starting a
/// second note stops the first instead of talking over it.
class VoicePlayer {
  VoicePlayer._();
  static final VoicePlayer instance = VoicePlayer._();

  final AudioPlayer _player = AudioPlayer();

  /// Which message is playing, so every bubble can reflect it.
  final ValueNotifier<BigInt?> playing = ValueNotifier(null);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> total = ValueNotifier(Duration.zero);

  bool _wired = false;
  File? _scratch;

  void _wire() {
    if (_wired) return;
    _wired = true;
    _player.onPositionChanged.listen((p) => position.value = p);
    _player.onDurationChanged.listen((d) => total.value = d);
    _player.onPlayerComplete.listen((_) => _finish());
  }

  /// Play [bytes] (already decrypted) for message [id]. Tapping the note that
  /// is already playing stops it.
  Future<void> toggle(BigInt id, Uint8List bytes, String suggestedName) async {
    _wire();
    if (playing.value == id) {
      await stop();
      return;
    }
    await stop();
    try {
      // audioplayers needs a source it can seek; a scratch file is the reliable
      // path across both platforms. It is removed as soon as playback ends.
      final file = await AttachmentStore.scratchFile(
        suggestedName.isEmpty ? 'voice-$id.m4a' : suggestedName,
        bytes,
      );
      _scratch = file;
      playing.value = id;
      position.value = Duration.zero;
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      debugPrint('voice playback failed: $e');
      await _finish();
    }
  }

  Future<void> stop() async {
    if (playing.value == null) return;
    try {
      await _player.stop();
    } catch (_) {}
    await _finish();
  }

  Future<void> _finish() async {
    playing.value = null;
    position.value = Duration.zero;
    total.value = Duration.zero;
    final scratch = _scratch;
    _scratch = null;
    if (scratch == null) return;
    try {
      if (await scratch.exists()) await scratch.delete();
    } catch (_) {}
  }
}

/// A deterministic pseudo-waveform for a received note.
///
/// The audio is encrypted at rest and only decoded on play, so drawing a real
/// waveform would mean decrypting every note just to render the list. Instead
/// the bars are derived from the message id: stable for a given note (it looks
/// the same every time you open the chat) and visually varied between notes.
List<double> waveformFor(BigInt id, {int bars = 27}) {
  final rng = math.Random(id.hashCode);
  return List<double>.generate(
    bars,
    // Bias towards the middle of the range so no note looks flat or clipped.
    (_) => 0.28 + rng.nextDouble() * 0.72,
  );
}
