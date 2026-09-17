import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../share.dart';
import '../theme.dart';
import '../widgets.dart';

/// "My identity": show this device's Shoal ID and the share code others paste
/// to add you. The share code carries the ID plus the prekey bundle.
class IdentityScreen extends StatelessWidget {
  final ShoalEngineController engine;
  const IdentityScreen({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    final shoalId = engine.myShoalId;
    final code = ShareCode(shoalId, engine.myBundle).encode();

    return Scaffold(
      appBar: AppBar(title: const Text('My identity')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const Center(child: ShoalMark(size: 72)),
              const SizedBox(height: 20),
              const Center(
                child: Text(
                  'Your Shoal ID',
                  style: TextStyle(color: ShoalColor.textSecondary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  shortId(shoalId),
                  style: const TextStyle(
                    color: ShoalColor.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Share code',
                style: TextStyle(color: ShoalColor.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: ShoalColor.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SelectableText(
                  code,
                  style: const TextStyle(
                    color: ShoalColor.textPrimary,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
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
                style: TextStyle(color: ShoalColor.textSecondary, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
