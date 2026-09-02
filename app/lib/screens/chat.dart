import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../attachments.dart';
import '../bubbles.dart';
import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';
import '../voice.dart';
import '../widgets.dart';

/// One conversation. Shows the history and a composer; sending goes straight
/// into the Rust engine (which establishes the session on the first message).
class ChatScreen extends StatefulWidget {
  final AegisEngineController engine;
  final Contact contact;
  const ChatScreen({super.key, required this.engine, required this.contact});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  // Everything `build` needs from the engine is cached here.
  //
  // This matters for more than copying cost. Bridge reads are synchronous and
  // take the engine's lock, and a poll holds that lock for its whole network
  // round-trip. A `build` that called across the bridge would therefore block
  // the UI thread for as long as the relay took to answer — every three
  // seconds, and much longer when the network is slow. Reading once per actual
  // change keeps the UI thread off that lock.
  List<ChatMessage> _history = const [];
  bool _locked = false;
  bool _hasPassword = false;
  int _disappearingSecs = 0;

  /// Whether the user has scrolled far enough up that new messages would land
  /// off-screen — drives the jump-to-latest button.
  bool _showJumpToEnd = false;

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_onEngine);
    _scroll.addListener(_onScroll);
    _refresh();
    // Opening the chat marks its received messages read (sends read receipts).
    widget.engine.markRead(widget.contact.aegisId);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // Same threshold `_scrollToEnd` uses to decide whether to follow new
    // content, so the button appears exactly when auto-follow stops.
    final show = pos.maxScrollExtent - pos.pixels > 240;
    if (show != _showJumpToEnd) setState(() => _showJumpToEnd = show);
  }

  /// Pull everything the screen renders across the bridge once, into local
  /// state. Called on open and whenever the engine reports a change.
  void _refresh() {
    final id = widget.contact.aegisId;
    _locked = widget.engine.chatLocked(id);
    _hasPassword = widget.engine.chatHasPassword(id);
    _disappearingSecs = widget.engine.disappearingSecs(id);
    _history = _locked ? const [] : widget.engine.history(id);
  }

  void _onEngine() {
    if (!mounted) return;
    setState(_refresh);
    _scrollToEnd();
    // New mail may have arrived while we're looking — receipt it as read.
    widget.engine.markRead(widget.contact.aegisId);
  }

  @override
  void dispose() {
    widget.engine.removeListener(_onEngine);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      // Don't yank the view down if the user has scrolled up to read history;
      // only follow new content when already near the bottom (or on send).
      final nearBottom = pos.maxScrollExtent - pos.pixels < 240;
      if (force || nearBottom || pos.pixels == 0) {
        _scroll.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  static String _fmtTimer(int secs) {
    if (secs == 0) return 'Off';
    if (secs < 3600) return '${secs ~/ 60} min';
    if (secs < 86400) return '${secs ~/ 3600} hour${secs == 3600 ? '' : 's'}';
    if (secs < 604800) return '${secs ~/ 86400} day${secs == 86400 ? '' : 's'}';
    return '${secs ~/ 604800} week${secs == 604800 ? '' : 's'}';
  }

  Future<void> _showDisappearing() async {
    const options = [0, 300, 3600, 86400, 604800]; // off · 5m · 1h · 1d · 1w
    final current = widget.engine.disappearingSecs(widget.contact.aegisId);
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AegisTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Disappearing messages',
                  style: TextStyle(
                      color: AegisTheme.textHi,
                      fontSize: 17,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'New messages vanish from both devices after the timer. Applies '
                  'to this conversation.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
                ),
              ),
            ),
            for (final o in options)
              ListTile(
                title: Text(o == 0 ? 'Off' : _fmtTimer(o),
                    style: const TextStyle(color: AegisTheme.textHi)),
                trailing: o == current
                    ? const Icon(Icons.check_rounded, color: AegisTheme.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    widget.engine.setDisappearing(widget.contact.aegisId, choice);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(choice == 0
          ? 'Disappearing messages off'
          : 'Messages disappear after ${_fmtTimer(choice)}'),
    ));
  }

  void _showSafetyNumber() {
    String number;
    try {
      number = widget.engine.safetyNumber(widget.contact.aegisId);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not compute: $e')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: Row(
          children: const [
            Icon(Icons.verified_user_rounded, color: AegisTheme.accent, size: 20),
            SizedBox(width: 8),
            Text('Safety number',
                style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              number,
              style: const TextStyle(
                color: AegisTheme.textHi,
                fontFamily: 'monospace',
                fontSize: 18,
                letterSpacing: 1.5,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Compare these digits with ${widget.contact.name} over a channel '
              'you trust (in person, a call). If they match, no one is in the '
              'middle of your conversation.',
              style: const TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done', style: TextStyle(color: AegisTheme.accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _chatPasswordAction() async {
    final id = widget.contact.aegisId;
    if (widget.engine.chatHasPassword(id)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          backgroundColor: AegisTheme.surface,
          title: const Text('Remove chat password?',
              style: TextStyle(color: AegisTheme.textHi)),
          content: const Text(
            'This conversation will no longer ask for its own password.',
            style: TextStyle(color: AegisTheme.textLo),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel',
                    style: TextStyle(color: AegisTheme.textLo))),
            TextButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Remove',
                    style: TextStyle(color: AegisTheme.danger))),
          ],
        ),
      );
      if (ok == true) await widget.engine.removeChatPassword(id);
      return;
    }
    final controller = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Set chat password',
            style: TextStyle(color: AegisTheme.textHi)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              style: const TextStyle(color: AegisTheme.textHi),
              decoration: const InputDecoration(hintText: 'Password'),
            ),
            const SizedBox(height: 10),
            const Text(
              'This chat’s history is sealed under this password. It will ask '
              'for it after the app restarts. There is no recovery if you '
              'forget it.',
              style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Cancel',
                  style: TextStyle(color: AegisTheme.textLo))),
          TextButton(
              onPressed: () => Navigator.pop(d, controller.text),
              child: const Text('Set',
                  style: TextStyle(color: AegisTheme.accent))),
        ],
      ),
    );
    controller.dispose();
    if (pw != null && pw.trim().isNotEmpty) {
      await widget.engine.setChatPassword(id, pw.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Chat locked — it will ask for this password on restart'),
        ));
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    HapticFeedback.lightImpact();
    try {
      // Always stores the message locally (even if the network send fails, it's
      // kept and retried), so it never vanishes from the chat.
      await widget.engine.send(aegisId: widget.contact.aegisId, text: text);
      _scrollToEnd(force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    }
  }

  /// Send an attachment, reporting failures rather than dropping them quietly.
  /// Large files are chunked by the engine, so this can take a moment.
  Future<void> _sendAttachment({
    required int kind,
    required String name,
    required String mime,
    required Uint8List bytes,
    int durationMs = 0,
  }) async {
    try {
      await widget.engine.sendAttachment(
        aegisId: widget.contact.aegisId,
        kind: kind,
        fileName: name,
        mime: mime,
        bytes: bytes,
        durationMs: durationMs,
      );
      _scrollToEnd(force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send: $e')),
        );
      }
    }
  }

  /// The "+" sheet: photo, camera, or any file.
  Future<void> _showAttachSheet() async {
    // Shape, colour and drag handle all come from the theme's bottomSheetTheme.
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _attachTile(sheet, 'gallery', Icons.image_rounded, 'Photo',
                'Send a picture from your gallery'),
            _attachTile(sheet, 'camera', Icons.photo_camera_rounded, 'Camera',
                'Take a photo now'),
            _attachTile(sheet, 'file', Icons.attach_file_rounded, 'File',
                'Send any document, encrypted end-to-end'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'gallery':
      case 'camera':
        await _pickImage(choice == 'camera');
      case 'file':
        await _pickFile();
    }
  }

  Widget _attachTile(
    BuildContext sheet,
    String value,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AegisTheme.accent.withOpacity(0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: AegisTheme.accent, size: 20),
      ),
      title: Text(title,
          style: const TextStyle(
              color: AegisTheme.textHi, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: AegisTheme.textLo, fontSize: 12)),
      onTap: () => Navigator.pop(sheet, value),
    );
  }

  Future<void> _pickImage(bool camera) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        // Downscale: a modern phone photo is many megabytes, and every chunk is
        // its own packet through the mixnet.
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _sendAttachment(
        kind: MsgKind.image,
        name: picked.name,
        mime: picked.mimeType ?? 'image/jpeg',
        bytes: bytes,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not attach: $e')));
      }
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      final files = result?.files;
      if (files == null || files.isEmpty) return;
      final file = files.first;
      final bytes = file.bytes;
      if (bytes == null) return;
      await _sendAttachment(
        kind: MsgKind.file,
        name: file.name,
        mime: '',
        bytes: bytes,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not attach: $e')));
      }
    }
  }

  bool get _isBlocked => widget.engine
      .contacts()
      .firstWhere((c) => c.aegisId == widget.contact.aegisId,
          orElse: () => widget.contact)
      .blocked;

  @override
  Widget build(BuildContext context) {
    // Both come from the cache refreshed on engine changes — see `_refresh`.
    final locked = _locked;
    final history = _history;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            ContactAvatar(name: widget.contact.name, size: 36),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.contact.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AegisTheme.textHi,
                  ),
                ),
                Text(
                  shortId(widget.contact.aegisId),
                  style: const TextStyle(fontSize: 12, color: AegisTheme.textLo),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Disappearing messages',
            icon: Icon(
              _disappearingSecs > 0
                  ? Icons.timer_rounded
                  : Icons.timer_off_outlined,
              color: _disappearingSecs > 0
                  ? AegisTheme.accent
                  : AegisTheme.textHi,
            ),
            onPressed: _showDisappearing,
          ),
          IconButton(
            tooltip: 'Verify safety number',
            icon: const Icon(Icons.verified_user_rounded, color: AegisTheme.textHi),
            onPressed: _showSafetyNumber,
          ),
          if (!locked)
            IconButton(
              tooltip: 'Chat password',
              icon: Icon(
                _hasPassword
                    ? Icons.lock_rounded
                    : Icons.lock_open_rounded,
                color: _hasPassword
                    ? AegisTheme.accent
                    : AegisTheme.textHi,
              ),
              onPressed: _chatPasswordAction,
            ),
        ],
      ),
      body: locked
          ? _ChatLock(engine: widget.engine, contact: widget.contact)
          : Column(
        children: [
          if (_isBlocked)
            Container(
              width: double.infinity,
              color: AegisTheme.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.block_rounded, size: 14, color: AegisTheme.danger),
                  SizedBox(width: 6),
                  Text('Blocked — their messages are dropped',
                      style: TextStyle(color: AegisTheme.danger, fontSize: 12)),
                ],
              ),
            ),
          if (_disappearingSecs > 0)
            Container(
              width: double.infinity,
              color: AegisTheme.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.timer_rounded, size: 14, color: AegisTheme.accent),
                  const SizedBox(width: 6),
                  Text(
                    'Messages disappear after '
                    '${_fmtTimer(_disappearingSecs)}',
                    style: const TextStyle(color: AegisTheme.accent, fontSize: 12),
                  ),
                ],
              ),
            ),
          Expanded(
            child: history.isEmpty
                ? const _ChatEmpty()
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                        itemCount: history.length,
                        // Keep a screen of messages laid out either side of the
                        // viewport so a fast flick doesn't build rows mid-scroll.
                        cacheExtent: 600,
                        // Nothing in a bubble holds scroll state worth keeping, so
                        // don't pay to keep off-screen rows alive.
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: true,
                        itemBuilder: (context, i) {
                          final msg = history[i];
                          final showDay = i == 0 ||
                              differentDay(history[i - 1].timestampMs.toInt(),
                                  msg.timestampMs.toInt());
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showDay)
                                _DaySeparator(ms: msg.timestampMs.toInt()),
                              _BubbleEntrance(
                                // Keyed by message id so the animation runs once,
                                // when the message first appears — not again on
                                // every rebuild or receipt tick.
                                key: ValueKey(msg.id),
                                child: _Bubble(
                                  message: msg,
                                  engine: widget.engine,
                                  aegisId: widget.contact.aegisId,
                                  // An attachment retry needs its bytes back from
                                  // storage, a different path than text.
                                  onRetry: () => msg.hasAttachment
                                      ? widget.engine.resendAttachment(
                                          widget.contact.aegisId, msg)
                                      : widget.engine.resend(
                                          aegisId: widget.contact.aegisId,
                                          id: msg.id,
                                        ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      // Scrolled up far enough that new messages land
                      // off-screen: offer a way straight back to the latest.
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: _JumpToLatest(
                          visible: _showJumpToEnd,
                          onTap: () => _scrollToEnd(force: true),
                        ),
                      ),
                    ],
                  ),
          ),
          _Composer(
            controller: _input,
            onSend: _send,
            onAttach: _showAttachSheet,
            onVoice: (bytes, durationMs) => _sendAttachment(
              kind: MsgKind.voice,
              name: 'voice-message.m4a',
              mime: 'audio/mp4',
              bytes: bytes,
              durationMs: durationMs,
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final AegisEngineController engine;
  final String aegisId;
  final VoidCallback? onRetry;
  const _Bubble({
    required this.message,
    required this.engine,
    required this.aegisId,
    this.onRetry,
  });

  void _copy(BuildContext context) {
    HapticFeedback.mediumImpact();
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message copied')),
    );
  }

  /// Long-press action sheet: a reaction row on top, then copy, and — for our
  /// own messages — edit and delete-for-everyone; delete-for-me is always
  /// available.
  Future<void> _showActions(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final mine = message.fromMe;
    final isText = message.kind == MsgKind.text;
    // Our current reaction, so tapping it again in the bar clears it.
    String? current;
    for (final r in message.reactions) {
      if (r.fromMe) current = r.emoji;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReactionBar(
              current: current,
              onPick: (emoji) {
                Navigator.pop(sheet);
                // Picking the one already set toggles it off.
                engine.react(
                  aegisId,
                  message.id,
                  emoji == current ? '' : emoji,
                );
              },
            ),
            const Divider(height: 1, color: AegisTheme.surfaceHi),
            if (isText)
              ListTile(
                leading:
                    const Icon(Icons.copy_rounded, color: AegisTheme.textHi),
                title: const Text('Copy',
                    style: TextStyle(color: AegisTheme.textHi)),
                onTap: () {
                  Navigator.pop(sheet);
                  _copy(context);
                },
              ),
            if (mine && isText)
              ListTile(
                leading:
                    const Icon(Icons.edit_rounded, color: AegisTheme.textHi),
                title: const Text('Edit',
                    style: TextStyle(color: AegisTheme.textHi)),
                onTap: () {
                  Navigator.pop(sheet);
                  _edit(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: AegisTheme.textHi),
              title: const Text('Delete for me',
                  style: TextStyle(color: AegisTheme.textHi)),
              onTap: () {
                Navigator.pop(sheet);
                engine.deleteMessage(aegisId, message.id, forBoth: false);
              },
            ),
            if (mine)
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded,
                    color: AegisTheme.danger),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: AegisTheme.danger)),
                onTap: () {
                  Navigator.pop(sheet);
                  engine.deleteMessage(aegisId, message.id, forBoth: true);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final controller = TextEditingController(text: message.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Edit message',
            style: TextStyle(color: AegisTheme.textHi)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          style: const TextStyle(color: AegisTheme.textHi),
          decoration: const InputDecoration(hintText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel',
                style: TextStyle(color: AegisTheme.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: const Text('Save',
                style: TextStyle(color: AegisTheme.accent)),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newText?.trim();
    if (trimmed != null && trimmed.isNotEmpty && trimmed != message.text) {
      await engine.editMessage(aegisId, message.id, trimmed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mine = message.fromMe;
    final failed = mine && message.status == 3;
    final onBubble = mine ? const Color(0xFF06110F) : AegisTheme.textHi;
    final isImage = message.kind == MsgKind.image && message.complete;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => _showActions(context),
            onTap: failed ? onRetry : null,
            // Double-tap to like, the gesture everyone already expects.
            onDoubleTap: () {
              HapticFeedback.mediumImpact();
              final liked = message.reactions.any((r) => r.fromMe);
              engine.react(aegisId, message.id, liked ? '' : '❤️');
            },
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.76,
              ),
              margin: const EdgeInsets.symmetric(vertical: 4),
              // An image fills its bubble; everything else keeps the inset.
              padding: isImage
                  ? const EdgeInsets.all(4)
                  : const EdgeInsets.fromLTRB(14, 9, 14, 7),
              decoration: BoxDecoration(
                gradient: mine ? AegisTheme.shield : null,
                color: mine ? null : AegisTheme.surfaceHi,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(mine ? 18 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 18),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.hasAttachment)
                    AttachmentContent(
                      message: message,
                      engine: engine,
                      aegisId: aegisId,
                      mine: mine,
                    ),
                  // Text, or an attachment's caption when it has one.
                  if (message.text.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        top: message.hasAttachment ? 6 : 0,
                        left: isImage ? 8 : 0,
                        right: isImage ? 8 : 0,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          message.text,
                          style: TextStyle(
                              color: onBubble, fontSize: 15, height: 1.3),
                        ),
                      ),
                    ),
                  const SizedBox(height: 2),
                  Padding(
                    padding: EdgeInsets.only(right: isImage ? 6 : 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (failed) ...[
                          const Icon(Icons.error_outline_rounded,
                              size: 12, color: AegisTheme.danger),
                          const SizedBox(width: 3),
                          const Text(
                            'Not sent · tap to retry',
                            style: TextStyle(
                              color: AegisTheme.danger,
                              fontSize: 10,
                              height: 1.0,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (message.edited) ...[
                          Text(
                            'edited · ',
                            style: TextStyle(
                              color: mine
                                  ? const Color(0x9906110F)
                                  : AegisTheme.textLo,
                              fontSize: 10,
                              height: 1.0,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                        Text(
                          formatClock(message.timestampMs.toInt()),
                          style: TextStyle(
                            // Dimmed: dark-on-gradient for mine, muted grey
                            // for theirs.
                            color: mine
                                ? const Color(0x9906110F)
                                : AegisTheme.textLo,
                            fontSize: 10,
                            height: 1.0,
                          ),
                        ),
                        if (mine && !failed) ...[
                          const SizedBox(width: 4),
                          _StatusTick(status: message.status),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          ReactionChips(
            message: message,
            engine: engine,
            aegisId: aegisId,
            mine: mine,
          ),
        ],
      ),
    );
  }
}

/// The "jump to latest" button, shown only while the user is scrolled up.
/// It fades and scales rather than popping in, so it never yanks attention
/// away from the message being read.
class _JumpToLatest extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  const _JumpToLatest({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AegisMotion.fast,
        curve: AegisMotion.enter,
        child: AnimatedScale(
          scale: visible ? 1 : 0.8,
          duration: AegisMotion.fast,
          curve: AegisMotion.enter,
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AegisTheme.surfaceHi,
                shape: BoxShape.circle,
                border: Border.all(color: AegisTheme.accent.withOpacity(0.35)),
                boxShadow: const [
                  BoxShadow(color: Color(0x55000000), blurRadius: 10),
                ],
              ),
              child: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AegisTheme.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades and lifts a bubble into place the first time it is built, so an
/// arriving message settles in instead of snapping into the list.
///
/// The animation is deliberately tied to the widget's lifetime (via a keyed
/// element in the list) rather than to a "is new" flag — scrolling an old
/// message back into view rebuilds it, and re-animating then would look wrong.
/// Because the list is keyed by message id, an element is created once per
/// message, so this plays exactly once.
class _BubbleEntrance extends StatefulWidget {
  final Widget child;
  const _BubbleEntrance({super.key, required this.child});

  @override
  State<_BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<_BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AegisMotion.medium,
  )..forward();

  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: AegisMotion.enter);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(_fade),
        child: widget.child,
      ),
    );
  }
}

/// The delivery indicator on one of our own bubbles:
/// `✓` sent · `✓✓` delivered · bright `✓✓` read.
class _StatusTick extends StatelessWidget {
  final int status;
  const _StatusTick({required this.status});

  @override
  Widget build(BuildContext context) {
    final delivered = status >= 1;
    final read = status >= 2;
    return Icon(
      delivered ? Icons.done_all_rounded : Icons.check_rounded,
      size: 13,
      // On the gradient bubble: dark-dim until read, then bright white.
      color: read ? Colors.white : const Color(0x9906110F),
    );
  }
}

/// A centered day marker (`Today`, `12 Jul`) between messages from different
/// days.
class _DaySeparator extends StatelessWidget {
  final int ms;
  const _DaySeparator({required this.ms});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: AegisTheme.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          formatDayLabel(ms),
          style: const TextStyle(
            color: AegisTheme.textLo,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The message composer: attach, type, and hold the mic to record a voice note.
///
/// The send button becomes a mic when there is nothing typed, so one control
/// covers both — press-and-hold records, release sends, and sliding away
/// cancels.
class _Composer extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final Future<void> Function(Uint8List bytes, int durationMs) onVoice;
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttach,
    required this.onVoice,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final VoiceRecorder _recorder = VoiceRecorder();
  bool _recording = false;
  bool _cancelling = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    HapticFeedback.mediumImpact();
    final ok = await _recorder.start();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone permission is needed for voice messages'),
        ),
      );
      return;
    }
    setState(() {
      _recording = true;
      _cancelling = false;
    });
  }

  Future<void> _finishRecording() async {
    if (!_recording) return;
    final cancelled = _cancelling;
    setState(() {
      _recording = false;
      _cancelling = false;
    });
    if (cancelled) {
      HapticFeedback.heavyImpact();
      await _recorder.cancel();
      return;
    }
    HapticFeedback.mediumImpact();
    final result = await _recorder.stop();
    if (result == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hold to record a voice message')),
      );
      return;
    }
    await widget.onVoice(result.bytes, result.durationMs);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          children: [
            if (!_recording) ...[
              _CircleButton(
                icon: Icons.add_rounded,
                onTap: widget.onAttach,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  style: const TextStyle(color: AegisTheme.textHi),
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => widget.onSend(),
                  decoration: const InputDecoration(
                    hintText: 'Encrypted message…',
                  ),
                ),
              ),
            ] else
              Expanded(
                child: _RecordingBar(
                  recorder: _recorder,
                  cancelling: _cancelling,
                ),
              ),
            const SizedBox(width: 8),
            // One button, two jobs: tap to send typed text, hold to record.
            GestureDetector(
              onTap: _hasText ? widget.onSend : null,
              onLongPressStart: _hasText ? null : (_) => _startRecording(),
              onLongPressEnd: _hasText ? null : (_) => _finishRecording(),
              // Dragging away from the button while holding cancels, so a
              // recording started by accident is easy to abandon.
              onLongPressMoveUpdate: _hasText
                  ? null
                  : (d) {
                      final cancel = d.localOffsetFromOrigin.dx < -60;
                      if (cancel != _cancelling) {
                        setState(() => _cancelling = cancel);
                        HapticFeedback.selectionClick();
                      }
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                width: _recording ? 58 : 48,
                height: _recording ? 58 : 48,
                decoration: BoxDecoration(
                  gradient: _cancelling ? null : AegisTheme.shield,
                  color: _cancelling ? AegisTheme.danger : null,
                  shape: BoxShape.circle,
                  boxShadow: _recording
                      ? [
                          BoxShadow(
                            color: (_cancelling
                                    ? AegisTheme.danger
                                    : AegisTheme.accent)
                                .withOpacity(0.45),
                            blurRadius: 18,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  _recording
                      ? (_cancelling ? Icons.delete_rounded : Icons.mic_rounded)
                      : (_hasText
                          ? Icons.arrow_upward_rounded
                          : Icons.mic_rounded),
                  color: _cancelling ? Colors.white : const Color(0xFF06110F),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round secondary button in the composer row.
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 42,
        height: 42,
        decoration: const BoxDecoration(
          color: AegisTheme.surfaceHi,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: AegisTheme.textHi, size: 22),
      ),
    );
  }
}

/// Replaces the text field while recording: elapsed time, a live waveform, and
/// the slide-to-cancel hint.
class _RecordingBar extends StatelessWidget {
  final VoiceRecorder recorder;
  final bool cancelling;
  const _RecordingBar({required this.recorder, required this.cancelling});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AegisTheme.surfaceHi,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          // A pulsing dot, so it's obvious recording is live.
          const _RecordingDot(),
          const SizedBox(width: 10),
          ValueListenableBuilder<Duration>(
            valueListenable: recorder.elapsed,
            builder: (context, d, _) => Text(
              formatDuration(d),
              style: const TextStyle(
                color: AegisTheme.textHi,
                fontSize: 13,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: cancelling
                ? const Text(
                    'Release to cancel',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: AegisTheme.danger,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : ValueListenableBuilder<List<double>>(
                    valueListenable: recorder.waveform,
                    builder: (context, levels, _) => SizedBox(
                      height: 22,
                      child: CustomPaint(
                        painter: _LiveWavePainter(levels: levels),
                      ),
                    ),
                  ),
          ),
          if (!cancelling) ...[
            const SizedBox(width: 8),
            const Icon(Icons.keyboard_arrow_left_rounded,
                size: 16, color: AegisTheme.textLo),
            const Text(
              'slide to cancel',
              style: TextStyle(color: AegisTheme.textLo, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

/// The blinking "recording" indicator.
class _RecordingDot extends StatefulWidget {
  const _RecordingDot();

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 9,
        height: 9,
        decoration: const BoxDecoration(
          color: AegisTheme.danger,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// The live input level while recording, newest bars on the right.
class _LiveWavePainter extends CustomPainter {
  final List<double> levels;
  const _LiveWavePainter({required this.levels});

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    const slot = 4.0;
    final count = (size.width / slot).floor().clamp(1, levels.length);
    final shown = levels.sublist(levels.length - count);
    final paint = Paint()
      ..color = AegisTheme.accent
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;
    for (var i = 0; i < shown.length; i++) {
      // Right-align so the waveform scrolls leftwards as it grows.
      final x = size.width - (shown.length - i) * slot;
      final h = (size.height * shown[i]).clamp(2.0, size.height);
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveWavePainter old) => old.levels != levels;
}

class _ChatEmpty extends StatelessWidget {
  const _ChatEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.lock_rounded, size: 40, color: AegisTheme.surfaceHi),
          SizedBox(height: 12),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              'Messages are end-to-end encrypted with post-quantum '
              'cryptography. Not even the relay can read them.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AegisTheme.textLo, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// The unlock view shown in place of a locked conversation: enter the per-chat
/// password to reveal it. On success the engine notifies and the parent chat
/// screen rebuilds unlocked.
class _ChatLock extends StatefulWidget {
  final AegisEngineController engine;
  final Contact contact;
  const _ChatLock({required this.engine, required this.contact});

  @override
  State<_ChatLock> createState() => _ChatLockState();
}

class _ChatLockState extends State<_ChatLock> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_pw.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.engine.unlockChat(widget.contact.aegisId, _pw.text);
      // Success: the engine notifies and the parent rebuilds unlocked.
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Wrong password.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock_rounded, size: 56, color: AegisTheme.accent),
            const SizedBox(height: 16),
            const Text(
              'This chat is locked',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AegisTheme.textHi,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enter this conversation’s password to open it. Its history stays '
              'sealed until you do.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AegisTheme.textLo, height: 1.4),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _pw,
              autofocus: true,
              obscureText: true,
              enabled: !_busy,
              style: const TextStyle(color: AegisTheme.textHi),
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _unlock(),
              decoration: InputDecoration(
                hintText: 'Password',
                prefixIcon:
                    const Icon(Icons.lock_rounded, color: AegisTheme.textLo),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 14),
            GradientButton(
              label: _busy ? 'Unlocking…' : 'Unlock',
              icon: Icons.lock_open_rounded,
              onPressed: _busy ? null : _unlock,
            ),
          ],
        ),
      ),
    );
  }
}
