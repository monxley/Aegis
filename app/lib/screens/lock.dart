import 'package:flutter/material.dart';

import '../brand.dart';
import '../engine.dart';
import '../theme.dart';
import '../widgets.dart';

/// The app-lock screen: the seed on disk is encrypted, so nothing works until
/// the password decrypts it. There is no plaintext seed to fall back to, so this
/// cannot be skipped — bypassing the UI reaches an engine that was never built.
///
/// Because the key derivation (PBKDF2, hundreds of thousands of rounds) takes a
/// beat, the unlock is shown as a live progress ring around the lock glyph that
/// fills as the key is derived and blooms into the open shield on success.
class LockScreen extends StatefulWidget {
  final AegisEngineController engine;
  final VoidCallback onUnlocked;
  final VoidCallback onWiped;
  const LockScreen({
    super.key,
    required this.engine,
    required this.onUnlocked,
    required this.onWiped,
  });

  @override
  State<LockScreen> createState() => _LockScreenState();
}

enum _Phase { idle, deriving }

class _LockScreenState extends State<LockScreen>
    with SingleTickerProviderStateMixin {
  final _pw = TextEditingController();
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  _Phase _phase = _Phase.idle;
  bool _bioEnabled = false;
  bool _error = false;
  String? _errorText;

  bool get _busy => _phase == _Phase.deriving;

  @override
  void initState() {
    super.initState();
    _initBiometrics();
  }

  Future<void> _initBiometrics() async {
    final on = await widget.engine.biometricEnabled();
    if (!mounted || !on) return;
    setState(() => _bioEnabled = true);
    // Offer it straight away so the common case is one tap on the prompt.
    _bioUnlock();
  }

  @override
  void dispose() {
    _pw.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// Run [work] under the progress animation: fill toward 90% while it runs,
  /// snap to 100% + hold on success, or flush red and rewind on failure. A
  /// password attempt surfaces the wrong-password / attempts-left message; a
  /// biometric attempt rewinds quietly (cancel isn't an error).
  Future<void> _runUnlock(
    Future<bool> Function() work, {
    required bool isPassword,
  }) async {
    setState(() {
      _phase = _Phase.deriving;
      _error = false;
      _errorText = null;
    });
    // Let the ring climb toward 0.9 while the key is derived (don't await).
    _progress.animateTo(0.9,
        duration: const Duration(milliseconds: 1300), curve: Curves.easeOut);
    try {
      final ok = await work();
      if (!mounted) return;
      if (ok) {
        await _progress.animateTo(1.0,
            duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
        await Future.delayed(const Duration(milliseconds: 240));
        if (!mounted) return;
        widget.onUnlocked();
        return;
      }
      // Biometric cancelled / not recognised — quietly rewind, no error text.
      await _progress.animateBack(0.0,
          duration: const Duration(milliseconds: 300));
      if (mounted) setState(() => _phase = _Phase.idle);
    } on AccountWipedException {
      if (mounted) widget.onWiped();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = isPassword);
      await _progress.animateBack(0.0,
          duration: const Duration(milliseconds: 360));
      if (!mounted) return;
      final left = widget.engine.attemptsRemaining;
      setState(() {
        _phase = _Phase.idle;
        _errorText = !isPassword
            ? null
            : left != null
                ? 'Wrong password — $left attempt${left == 1 ? '' : 's'} left before wipe.'
                : 'Wrong password.';
      });
    }
  }

  void _unlock() {
    if (_pw.text.isEmpty || _busy) return;
    final pw = _pw.text;
    _runUnlock(() async {
      await widget.engine.unlock(pw);
      return true; // unlock throws on a wrong password
    }, isPassword: true);
  }

  void _bioUnlock() {
    if (_busy) return;
    _runUnlock(() => widget.engine.unlockWithBiometric(), isPassword: false);
  }

  Future<void> _panicWipe() async {
    await widget.engine.panicWipe();
    if (!mounted) return;
    widget.onWiped();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AuroraBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Center(
                  child: AnimatedBuilder(
                    animation: _progress,
                    builder: (_, __) => UnlockOrb(
                      progress: _progress.value,
                      error: _error,
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  _busy ? 'Unlocking' : 'Locked',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AegisTheme.textHi,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _busy
                      ? 'Deriving your key on this device…'
                      : 'Your identity is encrypted on this device. Enter your '
                          'password to unlock it.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AegisTheme.textLo,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 26),
                // Inputs fade out while the key derives so the ring is the focus.
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _busy ? 0.35 : 1,
                  child: IgnorePointer(
                    ignoring: _busy,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
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
                            prefixIcon: const Icon(Icons.lock_rounded,
                                color: AegisTheme.textLo),
                            errorText: _errorText,
                          ),
                        ),
                        const SizedBox(height: 16),
                        GradientButton(
                          label: _busy ? 'Unlocking…' : 'Unlock',
                          icon: Icons.lock_open_rounded,
                          onPressed: _busy ? null : _unlock,
                        ),
                        if (_bioEnabled) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.fingerprint_rounded, size: 20),
                            label: const Text('Unlock with biometrics'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AegisTheme.textHi,
                              side: const BorderSide(color: AegisTheme.surfaceHi),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              minimumSize: const Size.fromHeight(0),
                            ),
                            onPressed: _busy ? null : _bioUnlock,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                const Text(
                  'Forgot it? There is no recovery — the key never left this '
                  'device. You can reinstall and start a new identity.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AegisTheme.textLo,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                HoldToWipeButton(
                  enabled: !_busy,
                  onWipe: _panicWipe,
                  idleLabel: 'Hold to wipe everything',
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
