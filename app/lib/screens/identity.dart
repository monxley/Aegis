import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../share.dart';
import '../theme.dart';
import '../widgets.dart';

/// "My identity": show this device's Aegis ID and the share code others paste
/// to add you. The share code carries the ID plus the prekey bundle.
class IdentityScreen extends StatelessWidget {
  final AegisEngineController engine;
  const IdentityScreen({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    final aegisId = engine.myAegisId;
    final code = ShareCode(aegisId, engine.myBundle).encode();

    return Scaffold(
      appBar: AppBar(title: const Text('My identity')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const Center(child: ShieldMark(size: 72)),
              const SizedBox(height: 20),
              const Center(
                child: Text(
                  'Your Aegis ID',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 13),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  shortId(aegisId),
                  style: const TextStyle(
                    color: AegisTheme.textHi,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Share code',
                style: TextStyle(color: AegisTheme.textLo, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AegisTheme.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SelectableText(
                  code,
                  style: const TextStyle(
                    color: AegisTheme.textHi,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GradientButton(
                label: 'Copy share code',
                icon: Icons.copy_rounded,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Share code copied')),
                  );
                },
              ),
              const Spacer(),
              const Text(
                'Send this code to someone over any channel. They paste it to '
                'add you; from then on, only your two devices can read the '
                'conversation.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
