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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              const Text('Name', style: TextStyle(color: AegisTheme.textLo)),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                style: const TextStyle(color: AegisTheme.textHi),
                decoration: const InputDecoration(hintText: 'e.g. Alice'),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Aegis code',
                      style: TextStyle(color: AegisTheme.textLo)),
                  TextButton.icon(
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: const Text('Paste'),
                    style: TextButton.styleFrom(
                      foregroundColor: AegisTheme.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _code,
                style: const TextStyle(
                  color: AegisTheme.textHi,
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
                  style: const TextStyle(color: AegisTheme.danger),
                ),
              ],
              const Spacer(),
              GradientButton(
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
