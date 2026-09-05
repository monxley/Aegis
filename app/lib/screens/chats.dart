import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/states.dart';
import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';
import '../updater.dart';
import '../widgets.dart';
import 'add_contact.dart';
import 'chat.dart';
import 'identity.dart';
import 'nodes.dart';
import 'notes.dart';
import 'search.dart';
import 'settings.dart';

/// The home screen: the list of conversations. Rebuilds whenever the engine
/// signals new state (a sent or polled message, a new contact).
class ChatsScreen extends StatefulWidget {
  final AegisEngineController engine;
  const ChatsScreen({super.key, required this.engine});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  AegisEngineController get engine => widget.engine;
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
      appBar: AppBar(
        title: Row(
          children: [
            const ShieldMark(size: 30),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 2),
                  child: AegisWordmark(height: 18),
                ),
                _ConnectionStatus(engine: engine),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search_rounded, color: AegisTheme.textHi),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchScreen(engine: engine),
              ),
            ),
          ),
          IconButton(
            tooltip: 'My identity',
            icon: const Icon(Icons.badge_rounded, color: AegisTheme.textHi),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => IdentityScreen(engine: engine),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Network nodes',
            icon: const Icon(Icons.hub_rounded, color: AegisTheme.textHi),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => NodesScreen(engine: engine),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_rounded, color: AegisTheme.textHi),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(engine: engine),
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
          return Column(
            children: [
              if (integrity != null &&
                  integrity.flagged &&
                  !_securityDismissed)
                _SecurityBanner(
                  reason: integrity.reason,
                  onDismiss: () => setState(() => _securityDismissed = true),
                ),
              if (update != null) _UpdateBanner(engine: engine, update: update),
              _NotesTile(engine: engine),
              const Divider(height: 1, indent: 82, color: AegisColor.border),
              Expanded(
                child: contacts.isEmpty
                    ? const _EmptyState()
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: contacts.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 1,
                          indent: 82,
                          color: AegisColor.border,
                        ),
                        itemBuilder: (context, i) =>
                            _ContactTile(engine: engine, contact: contacts[i]),
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AegisTheme.accent,
        foregroundColor: AegisColor.textOnAccent,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AddContactScreen(engine: engine)),
        ),
        child: const Icon(Icons.person_add_alt_1_rounded),
      ),
    );
  }
}

/// A small dot + label under the "Aegis" title showing how this device is
/// connected: cyan for the anonymous mixnet, amber for a plain relay, grey when
/// offline. Rebuilds with the engine so toggling node mode updates it live.
class _ConnectionStatus extends StatelessWidget {
  final AegisEngineController engine;
  const _ConnectionStatus({required this.engine});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: engine,
      builder: (context, _) {
        final label = engine.connectionLabel;
        final color = label.startsWith('Mixnet')
            ? AegisTheme.accent
            : label.startsWith('Relay')
                ? AegisColor.warning
                : AegisTheme.textLo;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(color: AegisTheme.textLo, fontSize: 11),
            ),
          ],
        );
      },
    );
  }
}

/// The always-present "Notes" entry at the top of the list: a private,
/// local-only, encrypted self-chat.
class _NotesTile extends StatelessWidget {
  final AegisEngineController engine;
  const _NotesTile({required this.engine});

  @override
  Widget build(BuildContext context) {
    final notes = engine.notes();
    final last = notes.isNotEmpty ? notes.last : null;
    final preview =
        last?.text ?? 'Private, encrypted — only on this device.';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      leading: Container(
        width: 46,
        height: 46,
        decoration: const BoxDecoration(
          color: AegisColor.accent,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.bookmark_rounded, color: AegisColor.textOnAccent),
      ),
      title: const Row(
        children: [
          Text('Notes',
              style: TextStyle(
                  color: AegisTheme.textHi,
                  fontWeight: FontWeight.w600,
                  fontSize: 16)),
          SizedBox(width: 6),
          Icon(Icons.lock_rounded, size: 13, color: AegisTheme.accent),
        ],
      ),
      subtitle: Text(
        preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AegisTheme.textLo,
          fontStyle: last == null ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      trailing: last == null
          ? null
          : Text(formatListTime(last.timestampMs.toInt()),
              style: const TextStyle(color: AegisTheme.textLo, fontSize: 12)),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => NotesScreen(engine: engine)),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final AegisEngineController engine;
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
              horizontal: AegisSpace.s4, vertical: AegisSpace.s3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ContactAvatar(name: contact.name),
              const SizedBox(width: AegisSpace.s3),
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
                            style: AegisType.heading,
                          ),
                        ),
                        if (contact.pinned) ...[
                          const SizedBox(width: AegisSpace.s1),
                          const Icon(Icons.push_pin_rounded,
                              size: 12, color: AegisColor.textMuted),
                        ],
                        if (contact.blocked) ...[
                          const SizedBox(width: AegisSpace.s1),
                          const Icon(Icons.block_rounded,
                              size: 12, color: AegisColor.danger),
                        ],
                        const Spacer(),
                        if (hasLast)
                          Text(formatListTime(contact.lastTs.toInt()),
                              style: AegisType.meta),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AegisType.secondary.copyWith(
                        // An unstarted conversation reads as a prompt, not as a
                        // message someone actually sent.
                        color: hasLast
                            ? AegisColor.textSecondary
                            : AegisColor.textMuted,
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
      backgroundColor: AegisTheme.surface,
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
                        color: AegisTheme.textHi,
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
              onTap: () => engine.setPinned(contact.aegisId, !contact.pinned),
            ),
            _action(
              sheetCtx,
              icon: Icons.arrow_upward_rounded,
              label: 'Move up',
              onTap: () => engine.moveChat(contact.aegisId, up: true),
            ),
            _action(
              sheetCtx,
              icon: Icons.arrow_downward_rounded,
              label: 'Move down',
              onTap: () => engine.moveChat(contact.aegisId, up: false),
            ),
            _action(
              sheetCtx,
              icon: contact.blocked
                  ? Icons.check_circle_outline_rounded
                  : Icons.block_rounded,
              label: contact.blocked ? 'Unblock' : 'Block',
              danger: !contact.blocked,
              onTap: () => engine.setBlocked(contact.aegisId, !contact.blocked),
            ),
            const Divider(height: 1, color: AegisColor.border),
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
    final color = danger ? AegisTheme.danger : AegisTheme.textHi;
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
      backgroundColor: AegisTheme.surface,
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
                  color: AegisTheme.textHi,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'This cannot be undone.',
                style: TextStyle(color: AegisTheme.textLo, fontSize: 13),
              ),
            ),
            _action(
              sheetCtx,
              icon: Icons.person_remove_rounded,
              label: 'Delete for me',
              danger: true,
              onTap: () => engine.deleteChat(contact.aegisId),
            ),
            _action(
              sheetCtx,
              icon: Icons.delete_forever_rounded,
              label: 'Delete for everyone',
              danger: true,
              onTap: () => engine.deleteChatForBoth(contact.aegisId),
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
      message: 'Add someone by their Aegis code to start an encrypted '
          'conversation. There are no phone numbers or usernames to look up.',
    );
  }
}

/// A persistent strip at the top of the chat list when a newer release exists.
/// Tapping it opens the update dialog. Amber, because ignoring it can break
/// A dismissible warning shown when the app looks like it's running on a rooted
/// device or an emulator — a device-hardening hint (§1.4), not a guarantee.
class _SecurityBanner extends StatelessWidget {
  final String reason;
  final VoidCallback onDismiss;
  const _SecurityBanner({required this.reason, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AegisTheme.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.gpp_maybe_rounded,
                color: AegisTheme.danger, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$reason On a compromised device your keys and messages can be '
                'read while unlocked — treat this device as untrusted.',
                style: const TextStyle(
                    color: AegisTheme.danger, fontSize: 12.5, height: 1.3),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close_rounded,
                  color: AegisTheme.danger, size: 18),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

/// messaging.
class _UpdateBanner extends StatelessWidget {
  final AegisEngineController engine;
  final UpdateInfo update;
  const _UpdateBanner({required this.engine, required this.update});

  @override
  Widget build(BuildContext context) {
    const amber = AegisColor.warning;
    return Material(
      color: amber.withValues(alpha: 0.12),
      child: InkWell(
        onTap: () => showUpdateDialog(context, engine, update),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.system_update_rounded, color: amber, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Update available (${update.version}). Older versions may '
                  'stop working — tap to update.',
                  style: const TextStyle(color: amber, fontSize: 12.5, height: 1.3),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: amber, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// The update dialog: what's new, and why updating matters. Deliberately warns
/// that an out-of-date client can stop working when the protocol/network moves.
Future<void> showUpdateDialog(
  BuildContext context,
  AegisEngineController engine,
  UpdateInfo update,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AegisTheme.surface,
      title: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: AegisTheme.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Update ${update.version}',
              style: const TextStyle(color: AegisTheme.textHi, fontSize: 18),
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
              'A newer version of Aegis is available. Please update: the '
              'protocol and network can change between versions, and an '
              'out-of-date app may fail to send or receive — or stop working '
              'entirely.',
              style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.45),
            ),
            if (update.notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text("What's new",
                  style: TextStyle(
                      color: AegisTheme.textHi,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
              const SizedBox(height: 6),
              Text(
                update.notes,
                style: const TextStyle(
                    color: AegisTheme.textLo, fontSize: 12.5, height: 1.4),
              ),
            ],
            if (!update.hasApk) ...[
              const SizedBox(height: 12),
              const Text(
                'Opens the release page — download the APK there and install it.',
                style: TextStyle(color: AegisTheme.textLo, fontSize: 11, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Later', style: TextStyle(color: AegisTheme.textLo)),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AegisTheme.accent,
            foregroundColor: AegisColor.textOnAccent,
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
