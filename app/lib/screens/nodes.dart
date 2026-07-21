import 'dart:io';

import 'package:flutter/material.dart';

import '../brand.dart';
import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';

/// The network view: every node this client has learned from the gossiped
/// directory — everyone's nodes, split into **online** (reachable right now) and
/// **offline**. Star the ones you prefer (used to steer routing once custom-node
/// mode is enabled).
class NodesScreen extends StatefulWidget {
  final AegisEngineController engine;
  const NodesScreen({super.key, required this.engine});

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  final Map<String, bool> _online = {}; // node id → reachable
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _probeAll();
  }

  Future<void> _probeAll() async {
    final nodes = widget.engine.networkNodes();
    if (nodes.isEmpty) return;
    setState(() => _probing = true);
    await Future.wait(nodes.map((n) async {
      _online[n.id] = await _probe(n.mixAddr);
    }));
    if (mounted) setState(() => _probing = false);
  }

  /// Try to open a TCP connection to `host:port`; reachable ⇒ online.
  static Future<bool> _probe(String mixAddr) async {
    try {
      final i = mixAddr.lastIndexOf(':');
      if (i < 0) return false;
      final host = mixAddr.substring(0, i).replaceAll('[', '').replaceAll(']', '');
      final port = int.parse(mixAddr.substring(i + 1));
      final s = await Socket.connect(host, port,
          timeout: const Duration(seconds: 3));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network nodes'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: _probing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, color: AegisTheme.textHi),
            onPressed: _probing ? null : _probeAll,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.engine,
        builder: (context, _) {
          final nodes = widget.engine.networkNodes();
          final online = nodes.where((n) => _online[n.id] == true).toList();
          final offline = nodes.where((n) => _online[n.id] == false).toList();
          final unknown = nodes.where((n) => _online[n.id] == null).toList();
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
              _MyNodesCard(engine: widget.engine),
              if (nodes.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(6, 28, 6, 12),
                  child: Column(
                    children: [
                      BrandGlyph(Brand.broadcast, size: 76),
                      SizedBox(height: 16),
                      Text(
                        'No gossiped nodes known yet',
                        style: TextStyle(
                          color: AegisTheme.textHi,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'The directory fills in as it reaches you; it’s empty in '
                        'offline or plain-relay mode.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AegisTheme.textLo,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              if (online.isNotEmpty) ...[
                _sectionHeader('Online', online.length, AegisTheme.accent),
                ...online.map((n) => _NodeTile(engine: widget.engine, node: n, online: true)),
              ],
              if (unknown.isNotEmpty) ...[
                _sectionHeader('Checking…', unknown.length, AegisTheme.textLo),
                ...unknown.map((n) => _NodeTile(engine: widget.engine, node: n, online: null)),
              ],
              if (offline.isNotEmpty) ...[
                _sectionHeader('Offline', offline.length, AegisTheme.textLo),
                ...offline.map((n) => _NodeTile(engine: widget.engine, node: n, online: false)),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(6, 12, 6, 16),
                child: Text(
                  'Online = reachable from this device right now. Nodes carry '
                  'onion traffic; providers also hold a blind mailbox.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 11, height: 1.4),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(String label, int count, Color dot) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text('$label · $count',
              style: const TextStyle(
                  color: AegisTheme.textHi,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  final AegisEngineController engine;
  final NodeSummary node;
  final bool? online; // null = still checking
  const _NodeTile({required this.engine, required this.node, required this.online});

  @override
  Widget build(BuildContext context) {
    final fav = engine.favoriteNodes.contains(node.id);
    final shortId = node.id.length > 12
        ? '${node.id.substring(0, 8)}…${node.id.substring(node.id.length - 4)}'
        : node.id;
    return Opacity(
      opacity: online == false ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AegisTheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(node.isProvider ? Icons.dns_rounded : Icons.swap_horiz_rounded,
                color: node.isProvider ? AegisTheme.accent : AegisTheme.textLo,
                size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(shortId,
                      style: const TextStyle(
                          color: AegisTheme.textHi,
                          fontFamily: 'monospace',
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    '${node.isProvider ? 'provider' : 'forwarder'} · ${node.mixAddr}',
                    style: const TextStyle(color: AegisTheme.textLo, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: fav ? 'Unstar' : 'Star',
              icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: fav ? AegisTheme.accent2 : AegisTheme.textLo),
              onPressed: () => engine.toggleFavoriteNode(node.id),
            ),
          ],
        ),
      ),
    );
  }
}

/// Add your own bootstrap nodes (host:port) and optionally route **only**
/// through them, so the app connects to the network through infrastructure you
/// control instead of the built-in nodes.
class _MyNodesCard extends StatefulWidget {
  final AegisEngineController engine;
  const _MyNodesCard({required this.engine});

  @override
  State<_MyNodesCard> createState() => _MyNodesCardState();
}

class _MyNodesCardState extends State<_MyNodesCard> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static bool _validHostPort(String s) {
    final i = s.lastIndexOf(':');
    if (i <= 0 || i == s.length - 1) return false;
    final port = int.tryParse(s.substring(i + 1));
    return port != null && port > 0 && port <= 65535;
  }

  Future<void> _add() async {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    if (!_validHostPort(v)) {
      setState(() => _error = 'Use host:port, e.g. 1.2.3.4:9000');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.engine.addMyNode(v);
    _ctrl.clear();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setOnly(bool on) async {
    setState(() => _busy = true);
    await widget.engine.setOwnNodesOnly(on);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    final nodes = e.myNodes;
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AegisTheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.dns_rounded, size: 20, color: AegisTheme.accent),
              SizedBox(width: 10),
              Text('My nodes',
                  style: TextStyle(
                      color: AegisTheme.textHi,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Add a node by host:port to bootstrap through it. Turn on “only my '
            'nodes” to route exclusively through the nodes you add.',
            style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  enabled: !_busy,
                  style: const TextStyle(color: AegisTheme.textHi, fontSize: 14),
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    hintText: 'host:port',
                    isDense: true,
                    errorText: _error,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add_circle_rounded, color: AegisTheme.accent),
                tooltip: 'Add node',
              ),
            ],
          ),
          if (nodes.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...nodes.map((n) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      const Icon(Icons.circle, size: 7, color: AegisTheme.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(n,
                            style: const TextStyle(
                                color: AegisTheme.textHi,
                                fontFamily: 'monospace',
                                fontSize: 13)),
                      ),
                      InkWell(
                        onTap: _busy ? null : () => widget.engine.removeMyNode(n),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              size: 18, color: AegisTheme.danger),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              const Expanded(
                child: Text('Connect only through my nodes',
                    style: TextStyle(color: AegisTheme.textHi, fontSize: 14)),
              ),
              Switch(
                value: e.ownNodesOnly,
                onChanged: (_busy || nodes.isEmpty) ? null : _setOnly,
                activeColor: AegisTheme.accent,
              ),
            ],
          ),
          if (e.ownNodesOnly && nodes.isNotEmpty)
            const Text(
              'Routing exclusively through your nodes. If they go offline, the '
              'app can’t connect until they’re back.',
              style: TextStyle(color: AegisTheme.accent2, fontSize: 11, height: 1.4),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Reconnecting…',
                      style: TextStyle(color: AegisTheme.textLo, fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
