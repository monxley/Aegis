import 'package:flutter/material.dart';

import '../engine.dart';
import '../theme.dart';
import '../widgets.dart';
import 'chats.dart';

/// First run: explain what Aegis is and mint an identity. Defaults to the
/// anonymous mixnet (zero setup); an "Advanced" sheet allows a specific relay or
/// offline mode. No email, no phone, no account — just a key pair.
class OnboardingScreen extends StatefulWidget {
  final AegisEngineController engine;
  const OnboardingScreen({super.key, required this.engine});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start: $e')),
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

  Future<String?> _askNode() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Add a mixnet node',
            style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "No node is built in. Enter a node's mix address to join the "
              'network — you learn the rest automatically.',
              style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: AegisTheme.textHi),
              decoration: const InputDecoration(hintText: 'node.example:5078'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AegisTheme.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Join', style: TextStyle(color: AegisTheme.accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _advanced() async {
    final relay = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AegisTheme.surface,
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
                  color: AegisTheme.textHi,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 4),
            const Text(
              'Most people should use the anonymous mixnet. These are for '
              'running against your own server or trying it offline.',
              style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: relay,
              style: const TextStyle(color: AegisTheme.textHi),
              decoration: const InputDecoration(
                hintText: 'your relay  ·  relay.example:5077',
                prefixIcon: Icon(Icons.dns_rounded, color: AegisTheme.textLo),
              ),
            ),
            const SizedBox(height: 12),
            GradientButton(
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
                  style: TextStyle(color: AegisTheme.textLo)),
            ),
          ],
        ),
      ),
    );
  }

  /// Restore an existing identity from its 24-word recovery phrase.
  Future<void> _restore() async {
    final ctrl = TextEditingController();
    final phrase = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AegisTheme.surface,
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
                    color: AegisTheme.textHi,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Enter your 24 words in order, separated by spaces. This brings '
              'back your identity; past messages aren’t restored.',
              style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              style: const TextStyle(
                  color: AegisTheme.textHi, fontFamily: 'monospace', fontSize: 14),
              decoration: const InputDecoration(hintText: 'word1 word2 word3 …'),
            ),
            const SizedBox(height: 12),
            GradientButton(
              label: 'Restore',
              icon: Icons.restore_rounded,
              onPressed: () => Navigator.pop(ctx, ctrl.text),
            ),
          ],
        ),
      ),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not restore: $e')),
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
              const Center(child: ShieldMark(size: 88)),
              const SizedBox(height: 24),
              const Text(
                'Aegis',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                  color: AegisTheme.textHi,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'A message you cannot intercept —\nand if you do, cannot read.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, height: 1.4, color: AegisTheme.textLo),
              ),
              const Spacer(),
              GradientButton(
                label: _busy ? 'Creating…' : 'Create my identity',
                icon: Icons.bolt_rounded,
                onPressed: _busy ? null : _createNetwork,
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.hub_rounded, size: 14, color: AegisTheme.accent),
                  SizedBox(width: 6),
                  Text('Connects to the anonymous mixnet — no setup',
                      style: TextStyle(color: AegisTheme.textLo, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _restore,
                    child: const Text('I have a recovery phrase',
                        style: TextStyle(color: AegisTheme.accent)),
                  ),
                  const Text('·', style: TextStyle(color: AegisTheme.textLo)),
                  TextButton(
                    onPressed: _busy ? null : _advanced,
                    child: const Text('Advanced',
                        style: TextStyle(color: AegisTheme.textLo)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'No phone number, no email. Your identity is a key that never '
                'leaves this device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}
