import 'dart:io';

import 'package:flutter/material.dart';

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
          if (nodes.isEmpty) return const _NoNodes();
          final online = nodes.where((n) => _online[n.id] == true).toList();
          final offline = nodes.where((n) => _online[n.id] == false).toList();
          final unknown = nodes.where((n) => _online[n.id] == null).toList();
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
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
                  'onion traffic; providers also hold a blind mailbox. Starring '
                  'marks preferred nodes for custom-node routing (coming).',
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

class _NoNodes extends StatelessWidget {
  const _NoNodes();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_rounded, size: 48, color: AegisTheme.surfaceHi),
            SizedBox(height: 14),
            Text(
              'No nodes known yet',
              style: TextStyle(color: AegisTheme.textHi, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 6),
            Text(
              'The network view fills in as the gossiped directory reaches you. '
              'It’s empty in offline or plain-relay mode.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AegisTheme.textLo, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
