import 'package:flutter/material.dart';

import '../engine.dart';
import '../theme.dart';
import '../widgets.dart';

/// Route all traffic through a SOCKS5 proxy or Tor. Tor is a SOCKS5 proxy
/// (Orbot on Android), so both share one mechanism; the user picks off, Tor, or
/// a custom SOCKS5 endpoint.
class ProxyScreen extends StatefulWidget {
  final AegisEngineController engine;
  const ProxyScreen({super.key, required this.engine});

  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  late String _mode = widget.engine.proxyMode;
  late final _host = TextEditingController(text: widget.engine.proxyHost);
  late final _user = TextEditingController(text: widget.engine.proxyUser);
  late final _pass = TextEditingController(text: widget.engine.proxyPass);
  late bool _torFirst = widget.engine.proxyTorFirst;
  bool _busy = false;
  String? _error;

  bool get _needsSocks => _mode == 'socks5' || _mode == 'chain';

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  static bool _validHostPort(String s) {
    final i = s.lastIndexOf(':');
    if (i <= 0 || i == s.length - 1) return false;
    final port = int.tryParse(s.substring(i + 1));
    return port != null && port > 0 && port <= 65535;
  }

  Future<void> _save() async {
    if (_needsSocks && !_validHostPort(_host.text.trim())) {
      setState(() => _error = 'Enter the proxy as host:port, e.g. 127.0.0.1:1080');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.engine.updateProxy(
      _mode,
      host: _host.text.trim(),
      user: _user.text,
      pass: _pass.text,
      torFirst: _torFirst,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_mode == 'off' ? 'Proxy off' : 'Proxy saved')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Proxy / Tor')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          const Text(
            'Send all Aegis traffic through a proxy — the mixnet and the mailbox '
            'both honour it. Tor routes over the Tor network (via Orbot); SOCKS5 '
            'uses any proxy you run. If the proxy isn’t reachable, the app can’t '
            'connect until it is.',
            style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 16),
          _option('off', 'Off', 'Connect directly (no proxy).'),
          _option('tor', 'Tor', 'Route over Tor via Orbot on '
              '$_torHint. Install and start Orbot first.'),
          _option('socks5', 'SOCKS5 proxy', 'Route through a SOCKS5 proxy you '
              'specify below.'),
          _option('chain', 'SOCKS5 → Tor (chain)', 'Two hops: your SOCKS5 proxy '
              'and Tor, chained. Order is configurable below.'),
          if (_needsSocks) ...[
            const SizedBox(height: 12),
            _field(_host, 'SOCKS5 host:port', 'e.g. 127.0.0.1:1080',
                error: _error),
            const SizedBox(height: 10),
            _field(_user, 'Username (optional)', ''),
            const SizedBox(height: 10),
            _field(_pass, 'Password (optional)', '', obscure: true),
          ],
          if (_mode == 'chain') ...[
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _torFirst,
              onChanged: _busy ? null : (v) => setState(() => _torFirst = v),
              activeColor: AegisTheme.accent,
              title: Text(
                _torFirst ? 'Order: app → Tor → SOCKS5' : 'Order: app → SOCKS5 → Tor',
                style: const TextStyle(color: AegisTheme.textHi, fontSize: 14),
              ),
              subtitle: const Text(
                'If Tor is Orbot on this phone, put Tor first — a remote SOCKS5 '
                'can’t reach your local Tor.',
                style: TextStyle(color: AegisTheme.textLo, fontSize: 11.5, height: 1.35),
              ),
            ),
          ],
          const SizedBox(height: 22),
          GradientButton(
            label: _busy ? 'Applying…' : 'Save & reconnect',
            icon: Icons.check_rounded,
            onPressed: _busy ? null : _save,
          ),
        ],
      ),
    );
  }

  static const String _torHint = '127.0.0.1:9050';

  Widget _option(String value, String title, String subtitle) {
    final selected = _mode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _busy ? null : () => setState(() => _mode = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AegisTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AegisTheme.accent : AegisTheme.surfaceHi,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: selected ? AegisTheme.accent : AegisTheme.textLo,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: AegisTheme.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AegisTheme.textLo, fontSize: 12.5, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint,
      {bool obscure = false, String? error}) {
    return TextField(
      controller: c,
      enabled: !_busy,
      obscureText: obscure,
      style: const TextStyle(color: AegisTheme.textHi, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: error,
        isDense: true,
      ),
    );
  }
}
