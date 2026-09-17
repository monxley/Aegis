import 'package:flutter/material.dart';

import '../design/states.dart';
import '../engine.dart';
import '../theme.dart';
import '../widgets.dart';
import 'chats.dart';

/// First run: explain what Shoal is and mint an identity. Defaults to the
/// anonymous mixnet (zero setup); an "Advanced" sheet allows a specific relay or
/// offline mode. No email, no phone, no account — just a key pair.
class OnboardingScreen extends StatefulWidget {
  final ShoalEngineController engine;
  const OnboardingScreen({super.key, required this.engine});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;

  // Owned by the State, not by the sheets and dialogs that use them.
  //
  // Disposing one where the sheet's future resolves would throw: TransitionRoute
  // completes that future when the *exit animation starts*, so the TextField is
  // still mounted and still reading its controller for several more frames.
  final _nodeCtrl = TextEditingController();
  final _relayCtrl = TextEditingController();
  final _phraseCtrl = TextEditingController();

  @override
  void dispose() {
    _nodeCtrl.dispose();
    _relayCtrl.dispose();
    _phraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _create(
    ConnMode mode, {
    String? relayAddr,
    List<String> bootstrap = const [],
  }) async {
    setState(() => _busy = true);
    try {
      await widget.engine
          .createIdentity(mode: mode, relayAddr: relayAddr, bootstrap: bootstrap);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatsScreen(engine: widget.engine)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showFailure(
        context,
        message: 'Could not create an identity. Nothing was saved — try again.',
        details: e,
      );
    }
  }

  /// Join the mixnet. If no bootstrap node is compiled in, ask for one.
  Future<void> _createNetwork() async {
    if (widget.engine.hasBootstrap) {
      await _create(ConnMode.network);
      return;
    }
    final node = await _askNode();
    if (node != null && node.isNotEmpty) {
      await _create(ConnMode.network, bootstrap: [node]);
    }
  }

  Future<String?> _askNode() {
    final ctrl = _nodeCtrl..clear();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ShoalColor.surface,
        title: const Text('Add a mixnet node',
            style: TextStyle(color: ShoalColor.textPrimary, fontSize: 18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "No node is built in. Enter a node's mix address to join the "
              'network — you learn the rest automatically.',
              style: ShoalType.secondary,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: ShoalColor.textPrimary),
              decoration: const InputDecoration(hintText: 'node.example:5078'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: ShoalColor.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Join', style: TextStyle(color: ShoalColor.accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _advanced() async {
    final relay = _relayCtrl..clear();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShoalColor.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Advanced',
                style: TextStyle(
                  color: ShoalColor.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 4),
            const Text(
              'Most people should use the anonymous mixnet. These are for '
              'running against your own server or trying it offline.',
              style: TextStyle(color: ShoalColor.textSecondary, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: relay,
              style: const TextStyle(color: ShoalColor.textPrimary),
              decoration: const InputDecoration(
                hintText: 'your relay  ·  relay.example:5077',
                prefixIcon: Icon(Icons.dns_rounded, color: ShoalColor.textSecondary),
              ),
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              label: 'Use this relay',
              icon: Icons.dns_rounded,
              onPressed: () {
                final addr = relay.text.trim();
                if (addr.isEmpty) return;
                Navigator.pop(ctx);
                _create(ConnMode.relay, relayAddr: addr);
              },
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _create(ConnMode.memory);
              },
              child: const Text('Try offline (in-memory, no delivery)',
                  style: TextStyle(color: ShoalColor.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }

  /// Restore an existing identity from its 24-word recovery phrase.
  Future<void> _restore() async {
    final ctrl = _phraseCtrl..clear();
    final phrase = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ShoalColor.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Restore from recovery phrase',
                style: TextStyle(
                    color: ShoalColor.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Enter your 24 words in order, separated by spaces. This brings '
              'back your identity; past messages aren’t restored.',
              style: TextStyle(color: ShoalColor.textSecondary, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              style: const TextStyle(
                  color: ShoalColor.textPrimary, fontFamily: 'monospace', fontSize: 14),
              decoration: const InputDecoration(hintText: 'word1 word2 word3 …'),
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              label: 'Restore',
              icon: Icons.restore_rounded,
              onPressed: () => Navigator.pop(ctx, ctrl.text),
            ),
          ],
        ),
      ),
    );
    // The 24 words are the identity: drop them from the field as soon as we
    // have the string, rather than leaving the seed phrase sitting in a live
    // controller for the rest of the session.
    ctrl.clear();
    if (phrase == null || phrase.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.engine.restoreFromMnemonic(phrase);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatsScreen(engine: widget.engine)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showFailure(
        context,
        message: 'Could not restore from that phrase. Check that all 24 words '
            'are present, in order, and spelled as written.',
        details: e,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Center(child: ShoalMark(size: 88)),
              const SizedBox(height: 24),
              const Text(
                'Shoal',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                  color: ShoalColor.textPrimary,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'A message you cannot intercept —\nand if you do, cannot read.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, height: 1.4, color: ShoalColor.textSecondary),
              ),
              const Spacer(),
              PrimaryButton(
                label: _busy ? 'Creating…' : 'Create my identity',
                icon: Icons.bolt_rounded,
                onPressed: _busy ? null : _createNetwork,
              ),
              const SizedBox(height: 10),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.hub_rounded, size: 14, color: ShoalColor.accent),
                  SizedBox(width: 6),
                  Text('Connects to the anonymous mixnet — no setup',
                      style: TextStyle(color: ShoalColor.textSecondary, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _restore,
                    child: const Text('I have a recovery phrase',
                        style: TextStyle(color: ShoalColor.accent)),
                  ),
                  const Text('·', style: TextStyle(color: ShoalColor.textSecondary)),
                  TextButton(
                    onPressed: _busy ? null : _advanced,
                    child: const Text('Advanced',
                        style: TextStyle(color: ShoalColor.textSecondary)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'No phone number, no email. Your identity is a key that never '
                'leaves this device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ShoalColor.textSecondary, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}
