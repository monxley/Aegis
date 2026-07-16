import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../share.dart';
import '../theme.dart';
import '../widgets.dart';
import 'identity.dart';

/// Settings: your profile (share code), connection status, and the opt-in
/// "become a node" toggle.
class SettingsScreen extends StatefulWidget {
  final AegisEngineController engine;
  const SettingsScreen({super.key, required this.engine});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  Future<void> _toggleNode(bool on) async {
    setState(() => _busy = true);
    await widget.engine.setNodeEnabled(on);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          _card(
            icon: Icons.badge_rounded,
            title: 'Your profile',
            child: _ProfileCard(engine: e),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.hub_rounded,
            title: 'Connection',
            child: Text(
              e.connectionLabel,
              style: const TextStyle(color: AegisTheme.textLo),
            ),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.dns_rounded,
            title: 'Run a node',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Help carry the network. Your device relays others’ '
                  'onion traffic — it never sees who or what. Best on an '
                  'always-on machine; on a phone, use Wi-Fi + power.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Node mode',
                        style: TextStyle(color: AegisTheme.textHi, fontSize: 15)),
                    Switch(
                      value: e.nodeEnabled,
                      onChanged: _busy ? null : _toggleNode,
                      activeColor: AegisTheme.accent,
                    ),
                  ],
                ),
                if (e.nodeEnabled && e.node != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Running · id ${e.node!.nodeId.substring(0, 8)}…  ·  ${e.node!.address}',
                    style: const TextStyle(
                      color: AegisTheme.accent,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                if (e.nodeEnabled && e.anonReceive) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Running · receiving anonymously through the mixnet',
                    style: TextStyle(color: AegisTheme.accent, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'All cryptography runs on this device. Aegis never sees your '
              'messages, keys, or contacts.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AegisTheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShaderMask(
                shaderCallback: (r) => AegisTheme.shield.createShader(r),
                child: Icon(icon, size: 20, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Text(title,
                  style: const TextStyle(
                    color: AegisTheme.textHi,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// The profile card body: this device's Aegis ID and a one-tap copy of the full
/// share code (ID + prekey bundle) to send a friend, who pastes it in Add
/// contact. No QR — the post-quantum bundle is too large for one.
class _ProfileCard extends StatelessWidget {
  final AegisEngineController engine;
  const _ProfileCard({required this.engine});

  @override
  Widget build(BuildContext context) {
    final aegisId = engine.myAegisId;
    final code = ShareCode(aegisId, engine.myBundle).encode();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Your Aegis ID',
            style: TextStyle(color: AegisTheme.textLo, fontSize: 12)),
        const SizedBox(height: 4),
        SelectableText(
          shortId(aegisId),
          style: const TextStyle(
            color: AegisTheme.textHi,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 14),
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
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.tag_rounded, size: 18),
                label: const Text('Copy ID only'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AegisTheme.textHi,
                  side: const BorderSide(color: AegisTheme.surfaceHi),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: aegisId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Aegis ID copied')),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.open_in_full_rounded, size: 18),
                label: const Text('Full code'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AegisTheme.textHi,
                  side: const BorderSide(color: AegisTheme.surfaceHi),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => IdentityScreen(engine: engine),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Send your share code to a friend over any channel. They paste it in '
          '“Add contact” to message you. Your keys never leave this device.',
          style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
        ),
      ],
    );
  }
}
