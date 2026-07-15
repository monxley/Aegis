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

  Future<void> _create(ConnMode mode, {String? relayAddr}) async {
    setState(() => _busy = true);
    try {
      await widget.engine.createIdentity(mode: mode, relayAddr: relayAddr);
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
                onPressed: _busy ? null : () => _create(ConnMode.network),
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
              TextButton(
                onPressed: _busy ? null : _advanced,
                child: const Text('Advanced',
                    style: TextStyle(color: AegisTheme.textLo)),
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
