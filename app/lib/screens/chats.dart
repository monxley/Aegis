import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/responsive.dart';
import '../design/states.dart';
import '../engine.dart';
import '../src/rust/api/shoal.dart';
import '../theme.dart';
import '../updater.dart';
import '../widgets.dart';
import 'add_contact.dart';
import 'chat.dart';
import 'identity.dart';
import 'nodes.dart';
import 'notes.dart';
import 'search.dart';

/// The home screen: the list of conversations. Rebuilds whenever the engine
/// signals new state (a sent or polled message, a new contact).
class ChatsScreen extends StatefulWidget {
  final ShoalEngineController engine;
  const ChatsScreen({super.key, required this.engine});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  ShoalEngineController get engine => widget.engine;
  bool _updateDialogShown = false;
  bool _securityDismissed = false;

  @override
  void initState() {
    super.initState();
    engine.addListener(_maybeShowUpdate);
    _maybeShowUpdate();
  }

  @override
  void dispose() {
    engine.removeListener(_maybeShowUpdate);
    super.dispose();
  }

  /// Show the update dialog once per session, the first time a newer release is
  /// detected (the check runs asynchronously at launch).
  void _maybeShowUpdate() {
    if (_updateDialogShown || engine.availableUpdate == null) return;
    _updateDialogShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showUpdateDialog(context, engine, engine.availableUpdate!);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Transparent so HomeShell's scale field shows through; the
      // field is drawn once, behind all three tabs, rather than by
      // each of them.
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Row(
          children: [
            const ShoalMark(size: 30),
            const SizedBox(width: ShoalSpace.s2),
            // Expanded, not a bare Column: a Row hands its non-flex children
            // unbounded width, and the status line below flexes its label so a
            // long transport name ellipsizes instead of overflowing. Flex
            // inside unbounded constraints is an assertion, not a layout.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 2),
                    child: ShoalWordmark(height: 18),
                  ),
                  _ConnectionStatus(engine: engine),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search_rounded, color: ShoalColor.textPrimary),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchScreen(engine: engine),
              ),
            ),
          ),
          IconButton(
            tooltip: 'My identity',
            icon: const Icon(Icons.badge_rounded, color: ShoalColor.textPrimary),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => IdentityScreen(engine: engine),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Network nodes',
            icon: const Icon(Icons.hub_rounded, color: ShoalColor.textPrimary),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => NodesScreen(engine: engine),
              ),
            ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: engine,
        builder: (context, _) {
          final update = engine.availableUpdate;
          final integrity = engine.deviceIntegrity;
          final contacts = engine.contacts();
          return ReadingColumn(
            child: Column(
              children: [
                if (integrity != null &&
                    integrity.flagged &&
                    !_securityDismissed)
                  _SecurityBanner(
                    reason: integrity.reason,
                    onDismiss: () => setState(() => _securityDismissed = true),
                  ),
                if (update != null)
                  _UpdateBanner(engine: engine, update: update),
                _NotesTile(engine: engine),
                const Divider(height: 1, indent: 72, color: ShoalColor.border),
                Expanded(
                  child: contacts.isEmpty
                      ? const _EmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: contacts.length,
                          separatorBuilder: (_, __) => const Divider(
                            height: 1,
                            indent: 72,
                            color: ShoalColor.border,
                          ),
                          itemBuilder: (context, i) =>
                              _ContactTile(engine: engine, contact: contacts[i]),
                        ),
                ),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: ShoalColor.accent,
        foregroundColor: ShoalColor.textOnAccent,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AddContactScreen(engine: engine)),
        ),
        child: const Icon(Icons.person_add_alt_1_rounded),
      ),
    );
  }
}

/// The line under the wordmark: which transport this device is using, and
/// whether it is actually working.
///
/// These are two different facts and the old version showed only the first, so
/// the header could read "Mixnet · anonymous send + receive" while nothing had
/// reached a node in ten minutes. The transport chooses the icon (mixnet, plain
/// relay, or no network at all); reachability — the only connectivity evidence
/// the app really has — chooses the colour *and* a word, so it survives
/// greyscale and colour-blindness.
class _ConnectionStatus extends StatefulWidget {
  final ShoalEngineController engine;
  const _ConnectionStatus({required this.engine});

  @override
  State<_ConnectionStatus> createState() => _ConnectionStatusState();
}

class _ConnectionStatusState extends State<_ConnectionStatus>
    with SingleTickerProviderStateMixin {
  /// Drives both the spin while connecting and the settle when it lands. One
  /// controller rather than two: they are never both wanted, and a single
  /// repeating clock cannot drift against itself.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  bool? _lastReachable;

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_onEngine);
    _sync();
  }

  @override
  void dispose() {
    widget.engine.removeListener(_onEngine);
    _pulse.dispose();
    super.dispose();
  }

  void _onEngine() {
    if (!mounted) return;
    final now = widget.engine.relayReachable;
    if (now != _lastReachable) {
      _lastReachable = now;
      _sync();
    }
  }

  /// While a check is in flight the icon turns continuously; the moment it
  /// resolves it stops and plays once, so "connected" is a thing you *see*
  /// happen rather than a label that was already there when you looked.
  void _sync() {
    final reachable = widget.engine.relayReachable;
    if (reachable == null) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Vestibular-safe: a spinner that never stops is the worst offender in a
    // status bar, so when the system asks for less motion it simply does not
    // move. Nothing is lost -- the word and the colour carry the same state.
    final still = MediaQuery.disableAnimationsOf(context);

    return AnimatedBuilder(
      animation: Listenable.merge([widget.engine, _pulse]),
      builder: (context, _) {
        final engine = widget.engine;
        final label = engine.connectionLabel;
        // In-memory mode never talks to a relay, so "unreachable" would be
        // meaningless there -- the label already says the app is offline.
        final networked = !label.startsWith('Offline');
        final (icon, tone, text) = switch ((networked, engine.relayReachable)) {
          (false, _) => (Icons.cloud_off_rounded, ShoalColor.textMuted, label),
          (true, null) => (
              Icons.sync_rounded,
              ShoalColor.textMuted,
              '$label · connecting',
            ),
          (true, false) => (
              Icons.cloud_off_rounded,
              ShoalColor.warning,
              '$label · no connection',
            ),
          (true, true) => (
              label.startsWith('Mixnet')
                  ? Icons.hub_rounded
                  : Icons.dns_rounded,
              label.startsWith('Mixnet')
                  ? ShoalColor.accent
                  // A plain relay works, but it sees more than a mix path does.
                  // Amber is the honest colour for "connected, less private".
                  : ShoalColor.warning,
              label,
            ),
        };

        final connecting = networked && engine.relayReachable == null;
        Widget mark = Icon(icon, size: 11, color: tone);

        if (!still) {
          if (connecting) {
            mark = RotationTransition(turns: _pulse, child: mark);
          } else if (networked) {
            // A single soft expansion on arrival. Curves.easeOut so it decays
            // rather than bouncing: this is a status line, not a notification.
            final t = Curves.easeOut.transform(_pulse.value);
            mark = Transform.scale(
              scale: 1 + 0.55 * (1 - t) * (_pulse.isAnimating ? 1 : 0),
              child: Opacity(opacity: 0.55 + 0.45 * t, child: mark),
            );
          }
        }

        return Semantics(
          button: true,
          label: 'Network: $text',
          excludeSemantics: true,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => NodesScreen(engine: engine)),
            ),
            borderRadius: BorderRadius.circular(ShoalRadius.xs),
            child: Padding(
              padding: const EdgeInsets.only(right: ShoalSpace.s1, top: 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  mark,
                  const SizedBox(width: ShoalSpace.s1),
                  Flexible(
                    // The label crossfades rather than snapping, so a transport
                    // change reads as one state becoming another.
                    child: AnimatedSwitcher(
                      duration: Duration(milliseconds: still ? 0 : 220),
                      child: Text(
                        text,
                        key: ValueKey(text),
                        overflow: TextOverflow.ellipsis,
                        style: ShoalType.meta.copyWith(color: tone),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The always-present "Notes" entry at the top of the list: a private,
/// local-only, encrypted self-chat.
class _NotesTile extends StatelessWidget {
  final ShoalEngineController engine;
  const _NotesTile({required this.engine});

  @override
  Widget build(BuildContext context) {
    final notes = engine.notes();
    final last = notes.isNotEmpty ? notes.last : null;
    final preview =
        last?.text ?? 'Private, encrypted — only on this device.';
    // Laid out like a contact row rather than with ListTile, so Notes sits on
    // the same grid as the conversations under it instead of nearly-but-not-
    // quite matching them.
    return Semantics(
      button: true,
      label: 'Notes. $preview',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NotesScreen(engine: engine)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: ShoalSpace.s4, vertical: ShoalSpace.s3),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: ShoalColor.accentMuted,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.bookmark_border_rounded,
                    size: 20, color: ShoalColor.accent),
              ),
              const SizedBox(width: ShoalSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text('Notes', style: ShoalType.heading),
                        const SizedBox(width: ShoalSpace.s1),
                        const Icon(Icons.lock_outline_rounded,
                            size: 12, color: ShoalColor.textMuted),
                        const Spacer(),
                        if (last != null)
                          Text(formatListTime(last.timestampMs.toInt()),
                              style: ShoalType.meta),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShoalType.secondary.copyWith(
                        color: last == null
                            ? ShoalColor.textMuted
                            : ShoalColor.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final ShoalEngineController engine;
  final Contact contact;
  const _ContactTile({required this.engine, required this.contact});

  @override
  Widget build(BuildContext context) {
    // Use the lightweight preview carried on the contact — no per-row history
    // clone (that was the chat list's main source of lag).
    final lastText = contact.lastText;
    final preview = lastText == null
        ? 'Say hello — end-to-end encrypted.'
        : '${contact.lastFromMe ? 'You: ' : ''}$lastText';
    final hasLast = lastText != null;

    // The row is laid out by hand rather than with ListTile: the name and the
    // timestamp sit on one baseline with the time right-aligned, which ListTile
    // cannot do, and the whole row keeps a predictable height so the list
    // scrolls without measuring text.
    return Semantics(
      button: true,
      label: '${contact.name}. $preview',
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(engine: engine, contact: contact),
          ),
        ),
        onLongPress: () => _showActions(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: ShoalSpace.s4, vertical: ShoalSpace.s3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ContactAvatar(name: contact.name),
              const SizedBox(width: ShoalSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            contact.name,
                            overflow: TextOverflow.ellipsis,
                            style: ShoalType.heading,
                          ),
                        ),
                        if (contact.pinned) ...[
                          const SizedBox(width: ShoalSpace.s1),
                          const Icon(Icons.push_pin_rounded,
                              size: 12, color: ShoalColor.textMuted),
                        ],
                        if (contact.blocked) ...[
                          const SizedBox(width: ShoalSpace.s1),
                          const Icon(Icons.block_rounded,
                              size: 12, color: ShoalColor.danger),
                        ],
                        const Spacer(),
                        if (hasLast)
                          Text(formatListTime(contact.lastTs.toInt()),
                              style: ShoalType.meta),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShoalType.secondary.copyWith(
                        // An unstarted conversation reads as a prompt, not as a
                        // message someone actually sent.
                        color: hasLast
                            ? ShoalColor.textSecondary
                            : ShoalColor.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShoalColor.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  ContactAvatar(name: contact.name, size: 34),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      contact.name,
                      style: const TextStyle(
                        color: ShoalColor.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _action(
              sheetCtx,
              icon: contact.pinned
                  ? Icons.push_pin_outlined
                  : Icons.push_pin_rounded,
              label: contact.pinned ? 'Unpin' : 'Pin to top',
              onTap: () => engine.setPinned(contact.shoalId, !contact.pinned),
            ),
            _action(
              sheetCtx,
              icon: Icons.arrow_upward_rounded,
              label: 'Move up',
              onTap: () => engine.moveChat(contact.shoalId, up: true),
            ),
            _action(
              sheetCtx,
              icon: Icons.arrow_downward_rounded,
              label: 'Move down',
              onTap: () => engine.moveChat(contact.shoalId, up: false),
            ),
            _action(
              sheetCtx,
              icon: contact.blocked
                  ? Icons.check_circle_outline_rounded
                  : Icons.block_rounded,
              label: contact.blocked ? 'Unblock' : 'Block',
              danger: !contact.blocked,
              onTap: () => engine.setBlocked(contact.shoalId, !contact.blocked),
            ),
            const Divider(height: 1, color: ShoalColor.border),
            _action(
              sheetCtx,
              icon: Icons.delete_outline_rounded,
              label: 'Delete chat…',
              danger: true,
              onTap: () => _confirmDelete(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _action(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? ShoalColor.danger : ShoalColor.textPrimary;
    return ListTile(
      leading: Icon(icon, color: color, size: 22),
      title: Text(label, style: TextStyle(color: color, fontSize: 15)),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }

  void _confirmDelete(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShoalColor.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                'Delete this chat?',
                style: TextStyle(
                  color: ShoalColor.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'This cannot be undone.',
                style: TextStyle(color: ShoalColor.textSecondary, fontSize: 13),
              ),
            ),
            _action(
              sheetCtx,
              icon: Icons.person_remove_rounded,
              label: 'Delete for me',
              danger: true,
              onTap: () => engine.deleteChat(contact.shoalId),
            ),
            _action(
              sheetCtx,
              icon: Icons.delete_forever_rounded,
              label: 'Delete for everyone',
              danger: true,
              onTap: () => engine.deleteChatForBoth(contact.shoalId),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.forum_outlined,
      title: 'No conversations yet',
      message: 'Add someone by their Shoal code to start an encrypted '
          'conversation. There are no phone numbers or usernames to look up.',
    );
  }
}

/// Shown when the app looks like it's running on a rooted device or an
/// emulator. A hardening *hint*, not a guarantee — root detection is defeatable
/// and the copy says only what the check actually establishes. Dismissible,
/// because the user may well know exactly why their device looks like that.
class _SecurityBanner extends StatelessWidget {
  final String reason;
  final VoidCallback onDismiss;
  const _SecurityBanner({required this.reason, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return NoticeBar(
      icon: Icons.gpp_maybe_rounded,
      label: 'Device check failed',
      detail: '$reason On a compromised device your keys and messages can be '
          'read while unlocked — treat this device as untrusted.',
      tone: ShoalColor.danger,
      emphasis: true,
      onDismiss: onDismiss,
    );
  }
}

/// A newer release exists. Worth a banner rather than only a dialog: the
/// protocol can move between versions, and a client that falls behind stops
/// being able to send or receive at all.
class _UpdateBanner extends StatelessWidget {
  final ShoalEngineController engine;
  final UpdateInfo update;
  const _UpdateBanner({required this.engine, required this.update});

  @override
  Widget build(BuildContext context) {
    return NoticeBar(
      icon: Icons.system_update_rounded,
      label: 'Update ${update.version}',
      detail: 'Older versions may stop working. Tap to update.',
      tone: ShoalColor.warning,
      emphasis: true,
      onTap: () => showUpdateDialog(context, engine, update),
    );
  }
}

/// The update dialog: what's new, and why updating matters. Deliberately warns
/// that an out-of-date client can stop working when the protocol/network moves.
Future<void> showUpdateDialog(
  BuildContext context,
  ShoalEngineController engine,
  UpdateInfo update,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: ShoalColor.surface,
      title: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: ShoalColor.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Update ${update.version}',
              style: const TextStyle(color: ShoalColor.textPrimary, fontSize: 18),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A newer version of Shoal is available. Please update: the '
              'protocol and network can change between versions, and an '
              'out-of-date app may fail to send or receive — or stop working '
              'entirely.',
              style: TextStyle(color: ShoalColor.textSecondary, fontSize: 13, height: 1.45),
            ),
            if (update.notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text("What's new",
                  style: TextStyle(
                      color: ShoalColor.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
              const SizedBox(height: 6),
              Text(
                update.notes,
                style: const TextStyle(
                    color: ShoalColor.textSecondary, fontSize: 12.5, height: 1.4),
              ),
            ],
            if (!update.hasApk) ...[
              const SizedBox(height: 12),
              const Text(
                'Opens the release page — download the APK there and install it.',
                style: TextStyle(color: ShoalColor.textSecondary, fontSize: 11, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Later', style: TextStyle(color: ShoalColor.textSecondary)),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: ShoalColor.accent,
            foregroundColor: ShoalColor.textOnAccent,
          ),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Download update'),
          onPressed: () async {
            final ok = await Updater.openDownload(update);
            if (ctx.mounted) Navigator.pop(ctx);
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Could not open the download link')),
              );
            }
          },
        ),
      ],
    ),
  );
}
