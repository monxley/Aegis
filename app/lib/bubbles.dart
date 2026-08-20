import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import 'attachments.dart';
import 'engine.dart';
import 'src/rust/api/aegis.dart';
import 'theme.dart';
import 'voice.dart';

/// The emoji offered in the quick reaction bar. Deliberately short — one row,
/// no picker to hunt through.
const kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

/// The reaction chips shown under a bubble. Ours is highlighted, and tapping it
/// clears it.
class ReactionChips extends StatelessWidget {
  final ChatMessage message;
  final AegisEngineController engine;
  final String aegisId;
  final bool mine;
  const ReactionChips({
    super.key,
    required this.message,
    required this.engine,
    required this.aegisId,
    required this.mine,
  });

  @override
  Widget build(BuildContext context) {
    if (message.reactions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(
        top: 4,
        left: mine ? 0 : 8,
        right: mine ? 8 : 0,
      ),
      child: Wrap(
        spacing: 4,
        children: [
          for (final r in message.reactions)
            GestureDetector(
              onTap: r.fromMe
                  // Tapping our own reaction takes it back.
                  ? () {
                      HapticFeedback.selectionClick();
                      engine.react(aegisId, message.id, '');
                    }
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: r.fromMe
                      ? AegisTheme.accent.withValues(alpha: 0.18)
                      : AegisTheme.surfaceHi,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: r.fromMe
                        ? AegisTheme.accent.withValues(alpha: 0.55)
                        : Colors.transparent,
                  ),
                ),
                child: Text(r.emoji, style: const TextStyle(fontSize: 13)),
              ),
            ),
        ],
      ),
    );
  }
}

/// The horizontal emoji strip shown above the long-press action sheet.
class ReactionBar extends StatelessWidget {
  final ValueChanged<String> onPick;
  final String? current;
  const ReactionBar({super.key, required this.onPick, this.current});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final e in kQuickReactions)
            _ReactionButton(
              emoji: e,
              selected: current == e,
              onTap: () => onPick(e),
            ),
        ],
      ),
    );
  }
}

/// One emoji in the reaction bar, with a little press-scale so the row feels
/// responsive rather than static.
class _ReactionButton extends StatefulWidget {
  final String emoji;
  final bool selected;
  final VoidCallback onTap;
  const _ReactionButton({
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ReactionButton> createState() => _ReactionButtonState();
}

class _ReactionButtonState extends State<_ReactionButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.82 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.selected
                ? AegisTheme.accent.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}

/// The body of a non-text bubble: a voice note, an image, or a file row.
class AttachmentContent extends StatelessWidget {
  final ChatMessage message;
  final AegisEngineController engine;
  final String aegisId;
  final bool mine;
  const AttachmentContent({
    super.key,
    required this.message,
    required this.engine,
    required this.aegisId,
    required this.mine,
  });

  @override
  Widget build(BuildContext context) {
    // Still arriving: show progress instead of a broken-looking empty bubble.
    if (!message.complete) {
      return _TransferProgress(message: message, mine: mine);
    }
    switch (message.kind) {
      case MsgKind.voice:
        return VoiceNote(
          message: message,
          engine: engine,
          aegisId: aegisId,
          mine: mine,
        );
      case MsgKind.image:
        return _ImageAttachment(
          message: message,
          engine: engine,
          mine: mine,
        );
      default:
        return _FileAttachment(
          message: message,
          engine: engine,
          mine: mine,
        );
    }
  }
}

/// Progress while an attachment's chunks are still arriving.
class _TransferProgress extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  const _TransferProgress({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    final total = message.transferTotal;
    final have = message.transferHave;
    final fraction = total == 0 ? 0.0 : (have / total).clamp(0.0, 1.0);
    final fg = mine ? const Color(0xFF06110F) : AegisTheme.textHi;
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_iconFor(message.kind), size: 16, color: fg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Receiving…',
                  style: TextStyle(color: fg, fontSize: 13),
                ),
              ),
              Text(
                '${(fraction * 100).round()}%',
                style: TextStyle(
                  color: fg.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: fg.withValues(alpha: 0.18),
              valueColor: AlwaysStoppedAnimation(
                mine ? const Color(0xFF06110F) : AegisTheme.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _iconFor(int kind) => switch (kind) {
      MsgKind.voice => Icons.mic_rounded,
      MsgKind.image => Icons.image_rounded,
      _ => Icons.insert_drive_file_rounded,
    };

/// A voice note: play/pause, a waveform that fills as it plays, and the length.
class VoiceNote extends StatelessWidget {
  final ChatMessage message;
  final AegisEngineController engine;
  final String aegisId;
  final bool mine;
  const VoiceNote({
    super.key,
    required this.message,
    required this.engine,
    required this.aegisId,
    required this.mine,
  });

  Future<void> _toggle() async {
    final playing = VoicePlayer.instance.playing.value == message.id;
    if (playing) {
      await VoicePlayer.instance.stop();
      return;
    }
    final bytes = await engine.attachmentBytes(message);
    if (bytes == null) return;
    await VoicePlayer.instance.toggle(message.id, bytes, message.fileName);
  }

  @override
  Widget build(BuildContext context) {
    final fg = mine ? const Color(0xFF06110F) : AegisTheme.textHi;
    final bars = waveformFor(message.id);
    return ValueListenableBuilder<BigInt?>(
      valueListenable: VoicePlayer.instance.playing,
      builder: (context, playingId, _) {
        final playing = playingId == message.id;
        return ValueListenableBuilder<Duration>(
          valueListenable: VoicePlayer.instance.position,
          builder: (context, pos, _) {
            return ValueListenableBuilder<Duration>(
              valueListenable: VoicePlayer.instance.total,
              builder: (context, total, _) {
                // While playing, fill the waveform by elapsed fraction; the
                // recorded duration is the fallback before the player reports.
                final lengthMs = playing && total.inMilliseconds > 0
                    ? total.inMilliseconds
                    : message.durationMs;
                final progress = playing && lengthMs > 0
                    ? (pos.inMilliseconds / lengthMs).clamp(0.0, 1.0)
                    : 0.0;
                final shown = playing
                    ? Duration(
                        milliseconds:
                            (lengthMs - pos.inMilliseconds).clamp(0, lengthMs))
                    : Duration(milliseconds: message.durationMs);
                return SizedBox(
                  width: 208,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: _toggle,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: fg.withValues(alpha: 0.14),
                          ),
                          child: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: fg,
                            size: 22,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 26,
                          child: CustomPaint(
                            painter: _WaveformPainter(
                              bars: bars,
                              progress: progress,
                              color: fg.withValues(alpha: 0.35),
                              activeColor:
                                  mine ? const Color(0xFF06110F) : AegisTheme.accent,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatDuration(shown),
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.75),
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Waveform bars, filled up to [progress].
class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color color;
  final Color activeColor;
  const _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.color,
    required this.activeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final slot = size.width / bars.length;
    final w = (slot * 0.55).clamp(1.5, 3.0);
    final played = size.width * progress;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars.length; i++) {
      final x = slot * i + slot / 2;
      final h = (size.height * bars[i]).clamp(3.0, size.height);
      paint
        ..color = x <= played ? activeColor : color
        ..strokeWidth = w;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.activeColor != activeColor;
}

/// An image attachment, decrypted on demand and shown inline.
class _ImageAttachment extends StatefulWidget {
  final ChatMessage message;
  final AegisEngineController engine;
  final bool mine;
  const _ImageAttachment({
    required this.message,
    required this.engine,
    required this.mine,
  });

  @override
  State<_ImageAttachment> createState() => _ImageAttachmentState();
}

class _ImageAttachmentState extends State<_ImageAttachment> {
  Uint8List? _bytes;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.engine.attachmentBytes(widget.message);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _tried = true;
    });
  }

  void _openFull() {
    final bytes = _bytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, __, ___) => _ImageViewer(bytes: bytes),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(
        width: 200,
        height: 140,
        child: Center(
          child: _tried
              // The message survived but its file didn't (cleared storage, or
              // it arrived on another device).
              ? Icon(Icons.broken_image_rounded,
                  color: widget.mine
                      ? const Color(0x8806110F)
                      : AegisTheme.textLo)
              : const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
      );
    }
    return GestureDetector(
      onTap: _openFull,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Hero(
          tag: 'img-${widget.message.id}',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 300),
            child: Image.memory(bytes, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}

/// Full-screen image view with pinch-zoom.
class _ImageViewer extends StatelessWidget {
  final Uint8List bytes;
  const _ImageViewer({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: Image.memory(bytes),
          ),
        ),
      ),
    );
  }
}

/// A file attachment: name, size, and a tap to open it in another app.
class _FileAttachment extends StatefulWidget {
  final ChatMessage message;
  final AegisEngineController engine;
  final bool mine;
  const _FileAttachment({
    required this.message,
    required this.engine,
    required this.mine,
  });

  @override
  State<_FileAttachment> createState() => _FileAttachmentState();
}

class _FileAttachmentState extends State<_FileAttachment> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await widget.engine.attachmentBytes(widget.message);
      if (bytes == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('This file is no longer on this device')),
        );
        return;
      }
      // Opening hands plaintext to another app — unavoidable, and the only
      // moment the bytes exist unencrypted on disk.
      final file = await AttachmentStore.scratchFile(
        widget.message.fileName,
        bytes,
      );
      await OpenFilex.open(file.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open: $e')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.mine ? const Color(0xFF06110F) : AegisTheme.textHi;
    final name = widget.message.fileName.isEmpty
        ? 'File'
        : widget.message.fileName;
    return GestureDetector(
      onTap: _open,
      child: SizedBox(
        width: 210,
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fg.withValues(alpha: 0.14),
              ),
              child: _opening
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(fg),
                      ),
                    )
                  : Icon(Icons.insert_drive_file_rounded, size: 20, color: fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatBytes(widget.message.fileSize.toInt()),
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
