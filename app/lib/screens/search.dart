import 'package:flutter/material.dart';

import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';
import '../widgets.dart';
import 'chat.dart';

/// Local, on-device search across contacts and message history. Everything is
/// already decrypted in memory, so the search never touches the network — it
/// just scans what this device holds.
class SearchScreen extends StatefulWidget {
  final AegisEngineController engine;
  const SearchScreen({super.key, required this.engine});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// One matching message: which contact it belongs to and the message itself.
class _MessageHit {
  final Contact contact;
  final ChatMessage message;
  _MessageHit(this.contact, this.message);
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Contacts whose name or Aegis ID contains the query.
  List<Contact> _contactHits(String q) {
    return widget.engine
        .contacts()
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.aegisId.toLowerCase().contains(q))
        .toList();
  }

  /// Messages (across all conversations) whose text contains the query, newest
  /// first.
  List<_MessageHit> _messageHits(String q) {
    final hits = <_MessageHit>[];
    for (final c in widget.engine.contacts()) {
      for (final m in widget.engine.history(c.aegisId)) {
        if (m.text.toLowerCase().contains(q)) {
          hits.add(_MessageHit(c, m));
        }
      }
    }
    hits.sort((a, b) => b.message.timestampMs.compareTo(a.message.timestampMs));
    return hits;
  }

  void _open(Contact c) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(engine: widget.engine, contact: c),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final contactHits = q.isEmpty ? const <Contact>[] : _contactHits(q);
    final messageHits = q.isEmpty ? const <_MessageHit>[] : _messageHits(q);
    final empty = q.isNotEmpty && contactHits.isEmpty && messageHits.isEmpty;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          style: const TextStyle(color: AegisTheme.textHi, fontSize: 16),
          textInputAction: TextInputAction.search,
          onChanged: (v) => setState(() => _query = v),
          decoration: const InputDecoration(
            hintText: 'Search messages and contacts',
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded, color: AegisTheme.textLo),
              onPressed: () {
                _controller.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: q.isEmpty
          ? const _Hint()
          : empty
              ? _NoResults(query: _query)
              : ListView(
                  children: [
                    if (contactHits.isNotEmpty) ...[
                      const _SectionLabel('Contacts'),
                      ...contactHits.map((c) => ListTile(
                            leading: ContactAvatar(name: c.name),
                            title: Text(c.name,
                                style:
                                    const TextStyle(color: AegisTheme.textHi)),
                            subtitle: Text(shortId(c.aegisId),
                                style: const TextStyle(
                                    color: AegisTheme.textLo, fontSize: 12)),
                            onTap: () => _open(c),
                          )),
                    ],
                    if (messageHits.isNotEmpty) ...[
                      const _SectionLabel('Messages'),
                      ...messageHits.map((h) => ListTile(
                            leading: ContactAvatar(name: h.contact.name),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(h.contact.name,
                                      style: const TextStyle(
                                          color: AegisTheme.textHi,
                                          fontWeight: FontWeight.w600)),
                                ),
                                Text(
                                  formatListTime(h.message.timestampMs.toInt()),
                                  style: const TextStyle(
                                      color: AegisTheme.textLo, fontSize: 11),
                                ),
                              ],
                            ),
                            subtitle: _Snippet(text: h.message.text, query: q),
                            onTap: () => _open(h.contact),
                          )),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AegisTheme.accent,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

/// A one-line message preview with the matched substring highlighted.
class _Snippet extends StatelessWidget {
  final String text;
  final String query;
  const _Snippet({required this.text, required this.query});

  @override
  Widget build(BuildContext context) {
    final lower = text.toLowerCase();
    final i = lower.indexOf(query);
    const base = TextStyle(color: AegisTheme.textLo, fontSize: 13);
    if (i < 0 || query.isEmpty) {
      return Text(text,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: base);
    }
    // Keep a little context before the match so it's visible in one line.
    final start = i > 24 ? i - 20 : 0;
    final prefix = start > 0 ? '…' : '';
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: prefix + text.substring(start, i)),
          TextSpan(
            text: text.substring(i, i + query.length),
            style: const TextStyle(
                color: AegisTheme.accent, fontWeight: FontWeight.w700),
          ),
          TextSpan(text: text.substring(i + query.length)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          'Search your conversations and contacts. Everything stays on this '
          'device — nothing is sent anywhere.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AegisTheme.textLo, height: 1.4),
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  final String query;
  const _NoResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          'No matches for “$query”.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AegisTheme.textLo),
        ),
      ),
    );
  }
}
