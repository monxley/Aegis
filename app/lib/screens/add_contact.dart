import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../share.dart';
import '../theme.dart';
import '../widgets.dart';

/// Add a contact by pasting their Aegis share code (`aegis:…#…`), which carries
/// both the Aegis ID and the prekey bundle.
class AddContactScreen extends StatefulWidget {
  final AegisEngineController engine;
  const AddContactScreen({super.key, required this.engine});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) _code.text = data!.text!.trim();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give this contact a name.');
      return;
    }
    try {
      final share = ShareCode.decode(_code.text);
      widget.engine.addContact(
        name: name,
        aegisId: share.aegisId,
        bundle: share.bundle,
      );
      Navigator.of(context).pop();
    } on FormatException {
      setState(() => _error = 'That is not a valid Aegis code.');
    } catch (e) {
      setState(() => _error = 'Could not add contact: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add contact')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ListView(
            children: [
              const SizedBox(height: 8),
              const _HowItWorks(),
              const SizedBox(height: 18),
              const Text('Name', style: TextStyle(color: AegisColor.textSecondary)),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                style: const TextStyle(color: AegisColor.textPrimary),
                decoration: const InputDecoration(hintText: 'e.g. Alice'),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Aegis code',
                      style: TextStyle(color: AegisColor.textSecondary)),
                  TextButton.icon(
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: const Text('Paste'),
                    style: TextButton.styleFrom(
                      foregroundColor: AegisColor.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _code,
                style: const TextStyle(
                  color: AegisColor.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'aegis:…#…',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: AegisColor.danger),
                ),
              ],
              const SizedBox(height: 28),
              PrimaryButton(
                label: 'Add contact',
                icon: Icons.check_rounded,
                onPressed: _save,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}


/// What a share code is, and why both people need one.
///
/// This screen used to show a field labelled "Aegis code" and a hint reading
/// `aegis:…#…`, which tells someone who already knows how it works exactly
/// nothing they did not know, and everyone else nothing at all.
///
/// The exchange is genuinely two-way and the code says so: `send()` looks the
/// recipient up among local contacts and fails with UnknownContact if they are
/// not there. So a one-way paste leaves one person able to write and the other
/// not — which looks like the app is broken, at the exact moment a new user is
/// deciding whether it works.
class _HowItWorks extends StatefulWidget {
  const _HowItWorks();

  @override
  State<_HowItWorks> createState() => _HowItWorksState();
}

class _HowItWorksState extends State<_HowItWorks> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AegisColor.surface,
        borderRadius: BorderRadius.circular(AegisRadius.md),
        border: Border.all(color: AegisColor.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AegisRadius.md),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz_rounded,
                      size: 18, color: AegisColor.accent),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('How adding someone works',
                        style: AegisType.heading),
                  ),
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 20, color: AegisColor.textMuted),
                ],
              ),
            ),
          ),
          if (_open)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Step(
                    n: '1',
                    title: 'Swap share codes — both ways',
                    body: 'You need their code and they need yours. Each of you '
                        'pastes the other’s here. With only one side done, only '
                        'one of you can write: sending needs the other person’s '
                        'keys, and they are in the code.',
                  ),
                  _Step(
                    n: '2',
                    title: 'Find yours in Identity',
                    body: 'Your code is on the Identity screen — the badge icon '
                        'on the chat list. Copy it and send it over any channel '
                        'you like.',
                  ),
                  _Step(
                    n: '3',
                    title: 'It is public — send it anywhere',
                    body: 'The code is your Aegis ID plus your public keys: the '
                        'X25519 handshake key, the ML-KEM prekey and the ML-DSA '
                        'signing key. Nothing in it can decrypt anything. It is '
                        'long because post-quantum keys are large — too large '
                        'for a QR code, which is why there isn’t one.',
                  ),
                  _Step(
                    n: '4',
                    title: 'Then check the safety number',
                    body: 'Whoever handed you the code could have handed you '
                        'their own. Long-press the contact, open the safety '
                        'number and compare it in person or over a channel you '
                        'already trust — not over this chat, which is the thing '
                        'being checked.',
                    last: true,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String n;
  final String title;
  final String body;
  final bool last;
  const _Step({
    required this.n,
    required this.title,
    required this.body,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AegisColor.accent.withValues(alpha: 0.5)),
            ),
            child: Text(n,
                style: const TextStyle(
                    color: AegisColor.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AegisColor.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(body,
                    style: const TextStyle(
                        color: AegisColor.textSecondary,
                        fontSize: 13,
                        height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
