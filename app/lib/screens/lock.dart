import 'package:flutter/material.dart';

import '../engine.dart';
import '../theme.dart';
import '../widgets.dart';

/// The app-lock screen: the seed on disk is encrypted, so nothing works until
/// the password decrypts it. There is no plaintext seed to fall back to, so this
/// cannot be skipped — bypassing the UI reaches an engine that was never built.
class LockScreen extends StatefulWidget {
  final AegisEngineController engine;
  final VoidCallback onUnlocked;
  const LockScreen({
    super.key,
    required this.engine,
    required this.onUnlocked,
  });

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_pw.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.engine.unlock(_pw.text);
      if (!mounted) return;
      widget.onUnlocked();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Wrong password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Center(child: ShieldMark(size: 72)),
              const SizedBox(height: 20),
              const Text(
                'Locked',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AegisTheme.textHi,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your identity is encrypted on this device. Enter your password '
                'to unlock it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _pw,
                autofocus: true,
                obscureText: true,
                enabled: !_busy,
                style: const TextStyle(color: AegisTheme.textHi),
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _unlock(),
                decoration: InputDecoration(
                  hintText: 'Password',
                  prefixIcon: const Icon(Icons.lock_rounded, color: AegisTheme.textLo),
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 16),
              GradientButton(
                label: _busy ? 'Unlocking…' : 'Unlock',
                icon: Icons.lock_open_rounded,
                onPressed: _busy ? null : _unlock,
              ),
              const Spacer(),
              const Text(
                'Forgot it? There is no recovery — the key never left this '
                'device. You can reinstall and start a new identity.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AegisTheme.textLo, fontSize: 11, height: 1.4),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
