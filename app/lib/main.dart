import 'package:flutter/material.dart';

import 'engine.dart';
import 'screens/chats.dart';
import 'screens/lock.dart';
import 'screens/onboarding.dart';
import 'theme.dart';
import 'widgets.dart';

void main() {
  // Render immediately, then boot the Rust engine in the background. Doing the
  // (potentially slow, possibly throwing) `boot()` before `runApp` would leave
  // the app frozen on the native splash if it hung or errored — instead we show
  // a splash we control and surface any startup failure on screen.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AegisApp(engine: AegisEngineController()));
}

class AegisApp extends StatelessWidget {
  final AegisEngineController engine;

  const AegisApp({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aegis',
      debugShowCheckedModeBanner: false,
      theme: AegisTheme.dark,
      home: _Bootstrap(engine: engine),
    );
  }
}

/// Runs [AegisEngineController.boot] and swaps in the right first screen. While
/// booting it shows the Aegis splash; if boot throws it shows the error (so a
/// failure to load the native library is readable, not a black screen).
class _Bootstrap extends StatefulWidget {
  final AegisEngineController engine;
  const _Bootstrap({required this.engine});

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

enum _Phase { booting, onboarding, chats, locked, error }

class _BootstrapState extends State<_Bootstrap> {
  _Phase _phase = _Phase.booting;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await widget.engine.init();
      final state = await widget.engine.accountState();
      if (!mounted) return;
      switch (state) {
        case AccountState.none:
          setState(() => _phase = _Phase.onboarding);
        case AccountState.plaintext:
          await widget.engine.bootPlaintext();
          if (!mounted) return;
          setState(() => _phase = _Phase.chats);
        case AccountState.locked:
          setState(() => _phase = _Phase.locked);
      }
    } catch (e, st) {
      debugPrint('boot failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = e;
        _phase = _Phase.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.booting:
        return const _Splash();
      case _Phase.error:
        return _StartupError(error: _error!, onRetry: _retry);
      case _Phase.locked:
        return LockScreen(
          engine: widget.engine,
          onUnlocked: () => setState(() => _phase = _Phase.chats),
          onWiped: () => setState(() => _phase = _Phase.onboarding),
        );
      case _Phase.onboarding:
        return OnboardingScreen(engine: widget.engine);
      case _Phase.chats:
        return ChatsScreen(engine: widget.engine);
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _phase = _Phase.booting;
    });
    _boot();
  }
}

/// The splash shown while the engine boots — the shield mark over the app
/// background, with a quiet progress hint.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            ShieldMark(size: 72),
            SizedBox(height: 24),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown if [AegisEngineController.boot] throws — most likely the Rust library
/// failed to load. Readable beats a frozen logo, and Retry re-runs boot.
class _StartupError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _StartupError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.error_outline,
                  color: AegisTheme.danger, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Aegis failed to start',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AegisTheme.textHi,
                    fontSize: 20,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AegisTheme.textLo, fontSize: 13),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
