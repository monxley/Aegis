import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';
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

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_onEngine);
    // Opening the chat marks its received messages read (sends read receipts).
    widget.engine.markRead(widget.contact.aegisId);
  }

  void _onEngine() {
    if (mounted) {
      setState(() {});
      _scrollToEnd();
      // New mail may have arrived while we're looking — receipt it as read.
      widget.engine.markRead(widget.contact.aegisId);
    }
  }

  @override
  void dispose() {
    widget.engine.removeListener(_onEngine);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
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

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    HapticFeedback.lightImpact();
    try {
      // Always stores the message locally (even if the network send fails, it's
      // kept and retried), so it never vanishes from the chat.
      await widget.engine.send(aegisId: widget.contact.aegisId, text: text);
      _scrollToEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.engine.history(widget.contact.aegisId);
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
              widget.engine.disappearingSecs(widget.contact.aegisId) > 0
                  ? Icons.timer_rounded
                  : Icons.timer_off_outlined,
              color: widget.engine.disappearingSecs(widget.contact.aegisId) > 0
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
        ],
      ),
      body: Column(
        children: [
          if (widget.engine.disappearingSecs(widget.contact.aegisId) > 0)
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
                    '${_fmtTimer(widget.engine.disappearingSecs(widget.contact.aegisId))}',
                    style: const TextStyle(color: AegisTheme.accent, fontSize: 12),
                  ),
                ],
              ),
            ),
          Expanded(
            child: history.isEmpty
                ? const _ChatEmpty()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                    itemCount: history.length,
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
                          _Bubble(
                            message: msg,
                            onRetry: () => widget.engine.resend(
                                aegisId: widget.contact.aegisId, id: msg.id),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          _Composer(controller: _input, onSend: _send),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onRetry;
  const _Bubble({required this.message, this.onRetry});

  void _copy(BuildContext context) {
    HapticFeedback.mediumImpact();
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = message.fromMe;
    final failed = mine && message.status == 3;
    final onBubble = mine ? const Color(0xFF06110F) : AegisTheme.textHi;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _copy(context),
        onTap: failed ? onRetry : null,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.76,
          ),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
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
              Text(
                message.text,
                style: TextStyle(color: onBubble, fontSize: 15, height: 1.3),
              ),
              const SizedBox(height: 2),
              Row(
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
                  Text(
                    formatClock(message.timestampMs.toInt()),
                    style: TextStyle(
                      // Dimmed: dark-on-gradient for mine, muted grey for theirs.
                      color: mine ? const Color(0x9906110F) : AegisTheme.textLo,
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
            ],
          ),
        ),
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

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  const _Composer({required this.controller, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                style: const TextStyle(color: AegisTheme.textHi),
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Encrypted message…',
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onSend,
              child: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  gradient: AegisTheme.shield,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_upward_rounded,
                  color: Color(0xFF06110F),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
