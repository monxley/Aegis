import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/responsive.dart';
import '../engine.dart';
import '../src/rust/api/shoal.dart';
import '../theme.dart';
import '../widgets.dart';
import 'add_contact.dart';
import 'chat.dart';

/// The people you can talk to, as a directory rather than as a timeline.
///
/// In Shoal a contact *is* a conversation — there is no separate address book —
/// so this and the chat list draw on the same `engine.contacts()`. They are not
/// the same view of it, and that difference is the point of having both:
///
///   Chats     ordered by what happened last, showing the last message.
///             The question is "what is going on".
///   Contacts  ordered alphabetically, showing who someone *is* — their Shoal
///             ID, whether they are blocked. The question is "who do I have",
///             which a busy timeline answers badly.
///
/// Anyone you have ever added is here, including people you have never
/// exchanged a message with, who never appear near the top of a chat list.
class ContactsScreen extends StatefulWidget {
  final ShoalEngineController engine;
  const ContactsScreen({super.key, required this.engine});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _filter = TextEditingController();
  bool _searching = false;

  ShoalEngineController get engine => widget.engine;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// Alphabetical, case- and accent-insensitive enough for a contact list, with
  /// everything that does not start with a letter gathered under '#' at the end
  /// — the usual convention, and it keeps emoji and digits out of the A row.
  List<(String, List<Contact>)> _grouped(List<Contact> all) {
    final query = _filter.text.trim().toLowerCase();
    final visible = query.isEmpty
        ? all
        : all
            .where((c) =>
                c.name.toLowerCase().contains(query) ||
                c.shoalId.toLowerCase().contains(query))
            .toList();

    final sorted = [...visible]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final groups = <String, List<Contact>>{};
    for (final c in sorted) {
      final first = c.name.trim();
      final letter = first.isEmpty ? '#' : first[0].toUpperCase();
      final key = RegExp(r'\p{L}', unicode: true).hasMatch(letter) ? letter : '#';
      groups.putIfAbsent(key, () => []).add(c);
    }

    final keys = groups.keys.toList()..sort();
    // '#' sorts before letters by code point; it belongs last.
    keys.sort((a, b) {
      if (a == '#') return 1;
      if (b == '#') return -1;
      return a.compareTo(b);
    });
    return [for (final k in keys) (k, groups[k]!)];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Transparent so HomeShell's scale field shows through; the
      // field is drawn once, behind all three tabs, rather than by
      // each of them.
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _filter,
                autofocus: true,
                style: ShoalType.body,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search contacts',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: ShoalColor.textMuted),
                ),
              )
            : const Text('Contacts'),
        actions: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded,
                color: ShoalColor.textPrimary),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _filter.clear();
            }),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: engine,
        builder: (context, _) {
          final all = engine.contacts();
          if (all.isEmpty) return const _NoContactsYet();
          final groups = _grouped(all);
          if (groups.isEmpty) {
            return Center(
              child: Text('Nobody matches “${_filter.text.trim()}”.',
                  style: ShoalType.secondary),
            );
          }
          return ReadingColumn(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: groups.length,
              itemBuilder: (context, gi) {
                final (letter, people) = groups[gi];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          ShoalSpace.s4, ShoalSpace.s4, ShoalSpace.s4, ShoalSpace.s1),
                      child: Text(letter,
                          style: ShoalType.meta.copyWith(
                              color: ShoalColor.accent,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2)),
                    ),
                    for (final c in people)
                      _ContactRow(engine: engine, contact: c),
                  ],
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: ShoalColor.accent,
        foregroundColor: ShoalColor.textOnAccent,
        tooltip: 'Add contact',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AddContactScreen(engine: engine)),
        ),
        child: const Icon(Icons.person_add_alt_1_rounded),
      ),
    );
  }
}

/// One person. Shows who they are rather than what they last said: the name,
/// and a shortened Shoal ID, which is the only thing that actually identifies
/// them — names are local labels you chose and can be changed by you alone.
class _ContactRow extends StatelessWidget {
  final ShoalEngineController engine;
  final Contact contact;
  const _ContactRow({required this.engine, required this.contact});

  /// Enough of the ID to compare at a glance, from both ends: a middle-ellipsis
  /// keeps the prefix *and* the suffix, which is what makes two similar IDs
  /// distinguishable. A plain truncation hides exactly the half an impostor
  /// would change.
  static String shortId(String id) =>
      id.length <= 20 ? id : '${id.substring(0, 10)}…${id.substring(id.length - 8)}';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${contact.name}. Shoal ID ${shortId(contact.shoalId)}',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(engine: engine, contact: contact),
          ),
        ),
        onLongPress: () => _actions(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: ShoalSpace.s4, vertical: ShoalSpace.s3),
          child: Row(
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
                          child: Text(contact.name,
                              overflow: TextOverflow.ellipsis,
                              style: ShoalType.heading),
                        ),
                        if (contact.blocked) ...[
                          const SizedBox(width: ShoalSpace.s1),
                          const Icon(Icons.block_rounded,
                              size: 12, color: ShoalColor.danger),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      shortId(contact.shoalId),
                      style: ShoalType.meta.copyWith(
                          fontFamily: 'monospace',
                          color: ShoalColor.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: ShoalColor.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  void _actions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShoalColor.surface,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded,
                  color: ShoalColor.textPrimary),
              title: const Text('Message'),
              onTap: () {
                Navigator.of(sheet).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatScreen(engine: engine, contact: contact),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded,
                  color: ShoalColor.textPrimary),
              title: const Text('Copy Shoal ID'),
              onTap: () async {
                Navigator.of(sheet).pop();
                await Clipboard.setData(
                    ClipboardData(text: contact.shoalId));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Shoal ID copied')),
                  );
                }
              },
            ),
            // The safety number is the only check that catches a
            // machine-in-the-middle, and it only works if it is compared over
            // some other channel. Putting it one long-press from the contact is
            // the difference between a feature that exists and one that is used.
            ListTile(
              leading: const Icon(Icons.verified_user_outlined,
                  color: ShoalColor.textPrimary),
              title: const Text('Safety number'),
              subtitle: const Text('Compare in person or over another channel',
                  style: TextStyle(color: ShoalColor.textMuted, fontSize: 12)),
              onTap: () {
                Navigator.of(sheet).pop();
                _showSafetyNumber(context);
              },
            ),
            ListTile(
              leading: Icon(
                  contact.blocked
                      ? Icons.lock_open_rounded
                      : Icons.block_rounded,
                  color: ShoalColor.danger),
              title: Text(contact.blocked ? 'Unblock' : 'Block'),
              onTap: () {
                engine.setBlocked(contact.shoalId, !contact.blocked);
                Navigator.of(sheet).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSafetyNumber(BuildContext context) {
    final number = engine.safetyNumber(contact.shoalId);
    showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: ShoalColor.surface,
        title: Text('Safety number with ${contact.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              number,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: ShoalSpace.s3),
            const Text(
              'If this matches on both devices, nobody is sitting between you. '
              'Compare it in person or over a channel you already trust — '
              'reading it out over this chat proves nothing, because that is '
              'the channel in question.',
              style: TextStyle(
                  color: ShoalColor.textSecondary, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _NoContactsYet extends StatelessWidget {
  const _NoContactsYet();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(ShoalSpace.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline_rounded,
                size: 48, color: ShoalColor.textMuted),
            SizedBox(height: ShoalSpace.s4),
            Text('No contacts yet',
                style: ShoalType.heading, textAlign: TextAlign.center),
            SizedBox(height: ShoalSpace.s2),
            Text(
              'Add someone by their Shoal ID, or share yours so they can add '
              'you. There is no directory to search and no phone number to '
              'look up — that is the point.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: ShoalColor.textSecondary, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
