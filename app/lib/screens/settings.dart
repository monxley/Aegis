import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../share.dart';
import '../theme.dart';
import '../updater.dart';
import '../widgets.dart';
import 'chats.dart';
import 'identity.dart';
import 'onboarding.dart';
import 'proxy.dart';

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
  bool _bioSupported = false;
  bool _bioEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadBiometrics();
  }

  String _version = '';

  Future<void> _loadBiometrics() async {
    final supported = await widget.engine.biometricDeviceSupported();
    final enabled = await widget.engine.biometricEnabled();
    final version = await Updater.currentVersion();
    if (!mounted) return;
    setState(() {
      _bioSupported = supported;
      _bioEnabled = enabled;
      _version = version;
    });
  }

  static const _disguises = [
    ('default', 'Aegis', Icons.shield_rounded),
    ('calculator', 'Calculator', Icons.calculate_rounded),
    ('notes', 'Notes', Icons.sticky_note_2_rounded),
    ('weather', 'Weather', Icons.wb_cloudy_rounded),
  ];

  static String _disguiseLabel(String id) =>
      _disguises.firstWhere((d) => d.$1 == id, orElse: () => _disguises.first).$2;
  static IconData _disguiseIcon(String id) =>
      _disguises.firstWhere((d) => d.$1 == id, orElse: () => _disguises.first).$3;

  Future<void> _showDisguisePicker() async {
    final current = widget.engine.disguise;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AegisTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Appearance on the home screen',
                    style: TextStyle(
                        color: AegisTheme.textHi,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Changes the launcher icon and name. Aegis still opens '
                  'normally — you just tap the decoy.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
                ),
              ),
            ),
            for (final d in _disguises)
              ListTile(
                leading: Icon(d.$3,
                    color: d.$1 == current ? AegisTheme.accent : AegisTheme.textHi),
                title: Text(d.$2, style: const TextStyle(color: AegisTheme.textHi)),
                trailing: d.$1 == current
                    ? const Icon(Icons.check_rounded, color: AegisTheme.accent)
                    : null,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _applyDisguise(d.$1, d.$2);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _applyDisguise(String id, String label) async {
    setState(() => _busy = true);
    await widget.engine.setDisguise(id);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(id == 'default'
            ? 'Showing as Aegis'
            : 'Now disguised as “$label” on the home screen'),
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    setState(() => _busy = true);
    await widget.engine.checkForUpdate();
    if (!mounted) return;
    setState(() => _busy = false);
    final update = widget.engine.availableUpdate;
    if (update != null) {
      await showUpdateDialog(context, widget.engine, update);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You’re on the latest version')),
      );
    }
  }

  Future<void> _toggleBiometric(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) {
        await widget.engine.enableBiometric();
      } else {
        await widget.engine.disableBiometric();
      }
      _bioEnabled = on;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Biometrics: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleNode(bool on) async {
    setState(() => _busy = true);
    try {
      await widget.engine.setNodeEnabled(on);
    } on NodeModeError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), duration: const Duration(seconds: 6)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Node error: $e')));
      }
    }
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
          // The real account's lock/duress settings are hidden in the decoy so
          // an attacker there can't change or discard the real vault.
          if (!e.isDecoy) ...[
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
          if (e.hasPassword) ...[
            const SizedBox(height: 14),
            _card(
              icon: Icons.theater_comedy_rounded,
              title: 'Duress password',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.hasDuress
                        ? 'On. Entering the duress password at the lock screen '
                            'opens an empty decoy account instead of this one. '
                            'Your real chats stay encrypted and hidden.'
                        : 'A second password for when you’re forced to unlock. It '
                            'opens a blank decoy account — no contacts, no '
                            'history — while your real account stays hidden. Make '
                            'it different from your real password.',
                    style: const TextStyle(
                        color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: Icon(e.hasDuress
                              ? Icons.password_rounded
                              : Icons.theater_comedy_outlined),
                          label: Text(e.hasDuress ? 'Change' : 'Set duress password'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AegisTheme.textHi,
                            side: const BorderSide(color: AegisTheme.surfaceHi),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: _busy ? null : _setOrChangeDuress,
                        ),
                      ),
                      if (e.hasDuress) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.close_rounded),
                            label: const Text('Remove'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AegisTheme.danger,
                              side: const BorderSide(color: AegisTheme.danger),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: _busy ? null : _removeDuress,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (e.hasPassword && _bioSupported) ...[
            const SizedBox(height: 14),
            _card(
              icon: Icons.fingerprint_rounded,
              title: 'Biometric unlock',
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Expanded(
                    child: Text(
                      'Unlock with your fingerprint or face instead of typing the '
                      'password. The key is held in the device keystore. Under '
                      'coercion, use the duress password instead.',
                      style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                    ),
                  ),
                  Switch(
                    value: _bioEnabled,
                    onChanged: _busy ? null : _toggleBiometric,
                    activeColor: AegisTheme.accent,
                  ),
                ],
              ),
            ),
          ],
          ],
          const SizedBox(height: 14),
          _card(
            icon: Icons.key_rounded,
            title: 'Recovery phrase',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '24 words that back up your identity. Write them down and keep '
                  'them offline — anyone who has them can restore your account, '
                  'and there is no other way to recover it.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.visibility_rounded, size: 18),
                  label: const Text('Reveal recovery phrase'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AegisTheme.textHi,
                    side: const BorderSide(color: AegisTheme.surfaceHi),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: const Size.fromHeight(0),
                  ),
                  onPressed: _showRecoveryPhrase,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.notifications_rounded,
            title: 'Notifications',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: Text(
                    'Alert me when a message arrives. The alert never shows the '
                    'message text — only that something came in.',
                    style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                  ),
                ),
                Switch(
                  value: e.notificationsEnabled,
                  onChanged: _busy
                      ? null
                      : (v) async {
                          setState(() => _busy = true);
                          await widget.engine.setNotificationsEnabled(v);
                          if (mounted) setState(() => _busy = false);
                        },
                  activeColor: AegisTheme.accent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.screenshot_monitor_rounded,
            title: 'Block screenshots',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: Text(
                    'Stop screenshots and screen recording, and hide the app in '
                    'the recent-apps switcher. On by default.',
                    style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                  ),
                ),
                Switch(
                  value: e.screenshotsBlocked,
                  onChanged: _busy
                      ? null
                      : (v) async {
                          setState(() => _busy = true);
                          await widget.engine.setScreenshotsBlocked(v);
                          if (mounted) setState(() => _busy = false);
                        },
                  activeColor: AegisTheme.accent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.sync_rounded,
            title: 'Background operation',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: Text(
                    'Keep receiving messages 24/7 while the app is in the '
                    'background, with a quiet ongoing notification. On by '
                    'default — turn off to save battery.',
                    style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                  ),
                ),
                Switch(
                  value: e.backgroundEnabled,
                  onChanged: _busy
                      ? null
                      : (v) async {
                          setState(() => _busy = true);
                          await widget.engine.setBackgroundEnabled(v);
                          if (mounted) setState(() => _busy = false);
                        },
                  activeColor: AegisTheme.accent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.vpn_lock_rounded,
            title: 'Proxy / Tor',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (e.proxyMode) {
                    'tor' => 'On · routing over Tor (Orbot).',
                    'socks5' => 'On · SOCKS5 ${e.proxyHost}.',
                    _ => 'Off · connecting directly. Route through Tor or a '
                        'SOCKS5 proxy to hide your IP from the nodes.',
                  },
                  style: const TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('Configure proxy'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AegisTheme.textHi,
                    side: const BorderSide(color: AegisTheme.surfaceHi),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: const Size.fromHeight(0),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProxyScreen(engine: widget.engine),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.masks_rounded,
            title: 'Disguise',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.disguise == 'default'
                      ? 'Show Aegis as itself on the home screen. Switch to a '
                          'decoy icon and name to blend in.'
                      : 'Disguised as “${_disguiseLabel(e.disguise)}”. The home-'
                          'screen icon and name are hidden.',
                  style: const TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: Icon(_disguiseIcon(e.disguise), size: 18),
                  label: Text('Appearance: ${_disguiseLabel(e.disguise)}'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AegisTheme.textHi,
                    side: const BorderSide(color: AegisTheme.surfaceHi),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: const Size.fromHeight(0),
                  ),
                  onPressed: _busy ? null : _showDisguisePicker,
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
                // Live sync/verify status.
                AnimatedBuilder(
                  animation: e,
                  builder: (_, __) {
                    final left = e.nodeSyncRemaining;
                    if (e.nodeEnabled && left != null) {
                      final mins = (left.inSeconds / 60).ceil();
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Synchronizing… ~$mins min left. Keep node mode on to '
                          'finish verifying; after that it turns on instantly.',
                          style: const TextStyle(
                              color: AegisTheme.accent2, fontSize: 12, height: 1.4),
                        ),
                      );
                    }
                    if (e.nodeVerified) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('Verified — node mode toggles instantly.',
                            style: TextStyle(color: AegisTheme.textLo, fontSize: 12)),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            icon: Icons.local_fire_department_rounded,
            title: 'Panic wipe',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Instantly erase everything on this device — key, contacts, '
                  'and history — and return to a blank slate. Hold the button to '
                  'fire. This cannot be undone.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                HoldToWipeButton(
                  enabled: !_busy,
                  onWipe: _panicWipe,
                ),
              ],
            ),
          ),
          if (!e.isDecoy) ...[
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
          ],
          const SizedBox(height: 14),
          _card(
            icon: Icons.system_update_rounded,
            title: 'App version',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _version.isEmpty ? 'Aegis' : 'Aegis $_version',
                  style: const TextStyle(color: AegisTheme.textHi, fontSize: 15),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Aegis is sideloaded, so it updates from GitHub releases. Keep '
                  'it current — an out-of-date app can stop sending or receiving '
                  'when the network changes.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Check for updates'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AegisTheme.textHi,
                    side: const BorderSide(color: AegisTheme.surfaceHi),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: const Size.fromHeight(0),
                  ),
                  onPressed: _busy ? null : _checkForUpdate,
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

  Future<void> _showRecoveryPhrase() async {
    final String phrase;
    try {
      phrase = widget.engine.recoveryPhrase();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Unavailable: $e')));
      }
      return;
    }
    final words = phrase.split(' ');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Recovery phrase',
            style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Write these 24 words down in order. Keep them offline; don’t '
                'screenshot or send them.',
                style: TextStyle(color: AegisTheme.textLo, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < words.length; i++)
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: AegisTheme.surfaceHi,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${i + 1}. ${words[i]}',
                          style: const TextStyle(
                              color: AegisTheme.textHi,
                              fontFamily: 'monospace',
                              fontSize: 13)),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: phrase));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Recovery phrase copied')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 18, color: AegisTheme.accent),
            label: const Text('Copy', style: TextStyle(color: AegisTheme.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done', style: TextStyle(color: AegisTheme.textLo)),
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

  Future<void> _setOrChangeDuress() async {
    final pw = await _promptNewPassword(
      title: widget.engine.hasDuress
          ? 'Change duress password'
          : 'Set duress password',
    );
    if (pw == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.engine.setDuressPassword(pw);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Duress password set')),
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

  Future<void> _removeDuress() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AegisTheme.surface,
        title: const Text('Remove duress password?',
            style: TextStyle(color: AegisTheme.textHi, fontSize: 18)),
        content: const Text(
          'The decoy account and its data will be discarded, and only your real '
          'password will unlock the app.',
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
      await widget.engine.removeDuressPassword();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _panicWipe() async {
    await widget.engine.panicWipe();
    if (!mounted) return;
    // Drop every screen and land on onboarding to mint a fresh identity.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => OnboardingScreen(engine: widget.engine)),
      (route) => false,
    );
  }

  /// Prompt for a new password twice; returns it if the two match and it's long
  /// enough, else null (cancelled/invalid). [title] labels the dialog.
  Future<String?> _promptNewPassword({String? title}) {
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
              title ??
                  (widget.engine.hasPassword ? 'Change password' : 'Set password'),
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
