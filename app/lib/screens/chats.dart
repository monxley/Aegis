import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';
import '../widgets.dart';
import 'add_contact.dart';
import 'chat.dart';
import 'identity.dart';
import 'nodes.dart';
import 'settings.dart';

/// The home screen: the list of conversations. Rebuilds whenever the engine
/// signals new state (a sent or polled message, a new contact).
class ChatsScreen extends StatelessWidget {
  final AegisEngineController engine;
  const ChatsScreen({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const ShieldMark(size: 26),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Aegis'),
                _ConnectionStatus(engine: engine),
              ],
            ),
          ],
        ),
        actions: [
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
          final contacts = engine.contacts();
          if (contacts.isEmpty) return const _EmptyState();
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: contacts.length,
            separatorBuilder: (_, __) => const Divider(
              height: 1,
              indent: 82,
              color: Color(0xFF1B1E29),
            ),
            itemBuilder: (context, i) =>
                _ContactTile(engine: engine, contact: contacts[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AegisTheme.accent,
        foregroundColor: const Color(0xFF06110F),
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
                ? const Color(0xFFFFC24B)
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

class _ContactTile extends StatelessWidget {
  final AegisEngineController engine;
  final Contact contact;
  const _ContactTile({required this.engine, required this.contact});

  @override
  Widget build(BuildContext context) {
    final history = engine.history(contact.aegisId);
    final last = history.isNotEmpty ? history.last : null;
    final preview = last == null
        ? 'Say hello — end-to-end encrypted.'
        : '${last.fromMe ? 'You: ' : ''}${last.text}';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      leading: ContactAvatar(name: contact.name),
      title: Row(
        children: [
          Flexible(
            child: Text(
              contact.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AegisTheme.textHi,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
          if (contact.pinned) ...[
            const SizedBox(width: 6),
            const Icon(Icons.push_pin_rounded, size: 13, color: AegisTheme.accent),
          ],
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
          : Text(
              formatListTime(last.timestampMs.toInt()),
              style: const TextStyle(color: AegisTheme.textLo, fontSize: 12),
            ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(engine: engine, contact: contact),
        ),
      ),
      onLongPress: () => _showActions(context),
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
            const Divider(height: 1, color: Color(0xFF1B1E29)),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.forum_rounded, size: 56, color: AegisTheme.surfaceHi),
            SizedBox(height: 16),
            Text(
              'No conversations yet',
              style: TextStyle(
                color: AegisTheme.textHi,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap + to add a contact by their Aegis code, '
              'then start an encrypted chat.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AegisTheme.textLo, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
