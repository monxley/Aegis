import 'package:flutter/material.dart';

import '../engine.dart';
import '../theme.dart';
import '../widgets.dart';
import 'chats.dart';

/// First run: explain what Aegis is, optionally point at a relay, and mint an
/// identity. No email, no phone, no account — just a key pair.
class OnboardingScreen extends StatefulWidget {
  final AegisEngineController engine;
  const OnboardingScreen({super.key, required this.engine});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _relay = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _relay.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      await widget.engine.createIdentity(relayAddr: _relay.text.trim());
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
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: AegisTheme.textLo,
                ),
              ),
              const Spacer(),
              const Text(
                'Relay server (optional)',
                style: TextStyle(color: AegisTheme.textLo, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _relay,
                enabled: !_busy,
                style: const TextStyle(color: AegisTheme.textHi),
                decoration: const InputDecoration(
                  hintText: 'relay.example:5077  ·  leave blank for offline',
                  prefixIcon: Icon(Icons.dns_rounded, color: AegisTheme.textLo),
                ),
              ),
              const SizedBox(height: 20),
              GradientButton(
                label: _busy ? 'Creating…' : 'Create my identity',
                icon: Icons.bolt_rounded,
                onPressed: _busy ? null : _create,
              ),
              const SizedBox(height: 14),
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
