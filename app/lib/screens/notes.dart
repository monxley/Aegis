import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';
import '../widgets.dart';

/// The private "Notes" chat: messages to yourself. **Purely local** — nothing
/// is ever sent to a node or relay — and stored **encrypted at rest** (a
/// seed-derived key), so a stealer that grabs the app's files gets only
/// ciphertext.
class NotesScreen extends StatefulWidget {
  final AegisEngineController engine;
  const NotesScreen({super.key, required this.engine});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _pw = TextEditingController();
  bool _busy = false;
  String? _pwError;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_pw.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _pwError = null;
    });
    final ok = await widget.engine.unlockNotes(_pw.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pwError = ok ? null : 'Wrong password';
    });
    if (ok) _pw.clear();
  }

  Future<void> _panicWipe() async {
    await widget.engine.panicWipeNotes();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _setOrChangePassword() async {
    final pw = await _promptNewPassword();
    if (pw == null || !mounted) return;
    await widget.engine.setNotesPassword(pw);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notes password set')),
      );
    }
  }

  Future<void> _removePassword() async {
    await widget.engine.removeNotesPassword();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notes password removed')),
      );
    }
  }

  Future<String?> _promptNewPassword() {
    final a = TextEditingController();
    final b = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            backgroundColor: AegisTheme.surface,
            title: Text(
              widget.engine.notesHasPassword
                  ? 'Change notes password'
                  : 'Set notes password',
              style: const TextStyle(color: AegisTheme.textHi, fontSize: 18),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'A separate password just for your notes, on top of the '
                  'device key. You’ll need it to open Notes.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: a,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(color: AegisTheme.textHi),
                  decoration: const InputDecoration(hintText: 'New password'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: b,
                  obscureText: true,
                  style: const TextStyle(color: AegisTheme.textHi),
                  decoration: InputDecoration(hintText: 'Repeat', errorText: err),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel', style: TextStyle(color: AegisTheme.textLo)),
              ),
              TextButton(
                onPressed: () {
                  if (a.text.length < 4) {
                    setD(() => err = 'At least 4 characters');
                    return;
                  }
                  if (a.text != b.text) {
                    setD(() => err = 'Passwords do not match');
                    return;
                  }
                  Navigator.pop(ctx, a.text);
                },
                child: const Text('Save', style: TextStyle(color: AegisTheme.accent)),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    HapticFeedback.lightImpact();
    await widget.engine.addNote(text);
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text('Notes'),
            Text('Local · encrypted · never sent',
                style: TextStyle(color: AegisTheme.textLo, fontSize: 11)),
          ],
        ),
        actions: [
          AnimatedBuilder(
            animation: widget.engine,
            builder: (context, _) => PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: AegisTheme.textHi),
              color: AegisTheme.surface,
              onSelected: (v) {
                switch (v) {
                  case 'set':
                    _setOrChangePassword();
                  case 'remove':
                    _removePassword();
                  case 'panic':
                    _confirmPanic();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'set',
                  child: Text(
                    widget.engine.notesHasPassword
                        ? 'Change notes password'
                        : 'Set notes password',
                    style: const TextStyle(color: AegisTheme.textHi),
                  ),
                ),
                if (widget.engine.notesHasPassword && !widget.engine.notesLocked)
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove notes password',
                        style: TextStyle(color: AegisTheme.textHi)),
                  ),
                const PopupMenuItem(
                  value: 'panic',
                  child: Text('Wipe all notes',
                      style: TextStyle(color: AegisTheme.danger)),
                ),
              ],
            ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.engine,
        builder: (context, _) {
          if (widget.engine.notesLocked) return _lockView();
          return Column(
            children: [
              Expanded(
                child: Builder(builder: (context) {
                  final notes = widget.engine.notes();
                  if (notes.isEmpty) return const _NotesEmpty();
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                    itemCount: notes.length,
                    itemBuilder: (context, i) =>
                        _NoteBubble(engine: widget.engine, note: notes[i]),
                  );
                }),
              ),
              _Composer(controller: _input, onAdd: _add),
            ],
          );
        },
      ),
    );
  }

  Widget _lockView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_rounded, size: 56, color: AegisTheme.accent),
          const SizedBox(height: 16),
          const Text('Notes are locked',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AegisTheme.textHi,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text(
            'Enter your notes password. It’s separate from the app password and '
            'never leaves this device.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _pw,
            autofocus: true,
            obscureText: true,
            enabled: !_busy,
            style: const TextStyle(color: AegisTheme.textHi),
            onSubmitted: (_) => _unlock(),
            decoration: InputDecoration(
              hintText: 'Notes password',
              prefixIcon: const Icon(Icons.lock_rounded, color: AegisTheme.textLo),
              errorText: _pwError,
            ),
          ),
          const SizedBox(height: 16),
          GradientButton(
            label: _busy ? 'Unlocking…' : 'Unlock notes',
            icon: Icons.lock_open_rounded,
            onPressed: _busy ? null : _unlock,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmPanic() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Wipe all notes?',
            style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
        content: const Text(
          'Every note on this device is erased. This cannot be undone.',
          style: TextStyle(color: AegisTheme.textLo, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: AegisTheme.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Wipe', style: TextStyle(color: AegisTheme.danger)),
          ),
        ],
      ),
    );
    if (yes == true) await _panicWipe();
  }
}

class _NoteBubble extends StatelessWidget {
  final AegisEngineController engine;
  final Note note;
  const _NoteBubble({required this.engine, required this.note});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () => _actions(context),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
          decoration: BoxDecoration(
            gradient: AegisTheme.shield,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(note.text,
                  style: const TextStyle(
                      color: Color(0xFF06110F), fontSize: 15, height: 1.3)),
              const SizedBox(height: 2),
              Text(
                formatClock(note.timestampMs.toInt()),
                style: const TextStyle(color: Color(0x9906110F), fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _actions(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AegisTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded, color: AegisTheme.textHi),
              title: const Text('Copy', style: TextStyle(color: AegisTheme.textHi)),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: note.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded, color: AegisTheme.textHi),
              title: const Text('Edit', style: TextStyle(color: AegisTheme.textHi)),
              onTap: () {
                Navigator.pop(ctx);
                _edit(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AegisTheme.danger),
              title: const Text('Delete', style: TextStyle(color: AegisTheme.danger)),
              onTap: () {
                Navigator.pop(ctx);
                engine.deleteNote(note.id);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final ctrl = TextEditingController(text: note.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Edit note',
            style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: null,
          style: const TextStyle(color: AegisTheme.textHi),
          decoration: const InputDecoration(hintText: 'Note'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AegisTheme.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save', style: TextStyle(color: AegisTheme.accent)),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await engine.editNote(note.id, result);
    }
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onAdd;
  const _Composer({required this.controller, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(color: AegisTheme.textHi),
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Write a private note…',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: onAdd,
              child: Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                  gradient: AegisTheme.shield,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add_rounded, color: Color(0xFF06110F)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotesEmpty extends StatelessWidget {
  const _NotesEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 48, color: AegisTheme.surfaceHi),
            SizedBox(height: 14),
            Text('Your private notes',
                style: TextStyle(
                    color: AegisTheme.textHi,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text(
              'Only on this device, encrypted at rest — never sent to any node. '
              'A place for keys, addresses, reminders.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AegisTheme.textLo, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
