import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../share.dart';
import '../theme.dart';
import '../widgets.dart';
import 'identity.dart';
import 'onboarding.dart';

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
            icon: Icons.lock_rounded,
            title: 'App password',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.hasPassword
                      ? 'On. Your identity key is encrypted on this device and '
                          'the app asks for the password on launch.'
                      : 'Encrypt your identity on this device with a password. '
                          'Without it the key can’t be decrypted, so nothing — '
                          'not even a bypass of this screen — can reach it.',
                  style: const TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: Icon(e.hasPassword
                            ? Icons.password_rounded
                            : Icons.lock_outline_rounded),
                        label: Text(e.hasPassword ? 'Change' : 'Set password'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AegisTheme.textHi,
                          side: const BorderSide(color: AegisTheme.surfaceHi),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _busy ? null : _setOrChangePassword,
                      ),
                    ),
                    if (e.hasPassword) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.lock_open_rounded),
                          label: const Text('Remove'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AegisTheme.danger,
                            side: const BorderSide(color: AegisTheme.danger),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: _busy ? null : _removePassword,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
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
          const SizedBox(height: 14),
          _card(
            icon: Icons.restart_alt_rounded,
            title: 'Reset identity',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Forget this identity and start fresh: a new key, and all '
                  'contacts and history erased. Use this if you want a clean '
                  'account. This cannot be undone.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_forever_rounded, size: 18),
                  label: const Text('Reset identity'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AegisTheme.danger,
                    side: const BorderSide(color: AegisTheme.danger),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: const Size.fromHeight(0),
                  ),
                  onPressed: _busy ? null : _confirmReset,
                ),
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

  Future<void> _setOrChangePassword() async {
    final pw = await _promptNewPassword();
    if (pw == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.engine.setAppPassword(pw);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('App password set')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _removePassword() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Remove password?',
            style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
        content: const Text(
          'The app will no longer ask for a password, and your identity key '
          'will be stored unencrypted on this device.',
          style: TextStyle(color: AegisTheme.textLo, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: AegisTheme.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: AegisTheme.danger)),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.engine.removeAppPassword();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Prompt for a new password twice; returns it if the two match and it's long
  /// enough, else null (cancelled/invalid).
  Future<String?> _promptNewPassword() {
    final a = TextEditingController();
    final b = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            backgroundColor: AegisTheme.surface,
            title: Text(
              widget.engine.hasPassword ? 'Change password' : 'Set password',
              style: const TextStyle(color: AegisTheme.textHi, fontSize: 18),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: a,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(color: AegisTheme.textHi),
                  decoration: const InputDecoration(hintText: 'New password'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: b,
                  obscureText: true,
                  style: const TextStyle(color: AegisTheme.textHi),
                  decoration: InputDecoration(hintText: 'Repeat', errorText: err),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel', style: TextStyle(color: AegisTheme.textLo)),
              ),
              TextButton(
                onPressed: () {
                  if (a.text.length < 4) {
                    setD(() => err = 'At least 4 characters');
                    return;
                  }
                  if (a.text != b.text) {
                    setD(() => err = 'Passwords do not match');
                    return;
                  }
                  Navigator.pop(ctx, a.text);
                },
                child: const Text('Save', style: TextStyle(color: AegisTheme.accent)),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmReset() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Reset identity?',
            style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
        content: const Text(
          'Your key, contacts, and message history on this device will be '
          'erased and a new identity created. This cannot be undone.',
          style: TextStyle(color: AegisTheme.textLo, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: AegisTheme.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset', style: TextStyle(color: AegisTheme.danger)),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await widget.engine.resetIdentity();
    if (!mounted) return;
    // Drop every screen and land on onboarding to mint a fresh identity.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => OnboardingScreen(engine: widget.engine)),
      (route) => false,
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
