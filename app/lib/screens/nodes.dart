import 'package:flutter/material.dart';

import '../engine.dart';
import '../src/rust/api/aegis.dart';
import '../theme.dart';

/// The network view: every node this client has learned from the gossiped
/// directory — everyone's nodes, as they propagate. Star the ones you prefer
/// (used to steer routing once custom-node mode is enabled).
class NodesScreen extends StatelessWidget {
  final AegisEngineController engine;
  const NodesScreen({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network nodes')),
      body: AnimatedBuilder(
        animation: engine,
        builder: (context, _) {
          final nodes = engine.networkNodes();
          if (nodes.isEmpty) return const _NoNodes();
          final providers = nodes.where((n) => n.isProvider).length;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Row(
                  children: [
                    Text('${nodes.length} node${nodes.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                            color: AegisTheme.textHi,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Text('· $providers provider${providers == 1 ? '' : 's'}',
                        style: const TextStyle(color: AegisTheme.textLo, fontSize: 13)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  itemCount: nodes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _NodeTile(engine: engine, node: nodes[i]),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Text(
                  'Nodes carry onion traffic; providers also hold a blind '
                  'mailbox. Starring marks preferred nodes — routing through '
                  'only your chosen nodes arrives with custom-node mode.',
                  style: TextStyle(color: AegisTheme.textLo, fontSize: 11, height: 1.4),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  final AegisEngineController engine;
  final NodeSummary node;
  const _NodeTile({required this.engine, required this.node});

  @override
  Widget build(BuildContext context) {
    final fav = engine.favoriteNodes.contains(node.id);
    final shortId = node.id.length > 12
        ? '${node.id.substring(0, 8)}…${node.id.substring(node.id.length - 4)}'
        : node.id;
    return Container(
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
                  node.isProvider
                      ? 'provider · ${node.mixAddr}'
                      : 'forwarder · ${node.mixAddr}',
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
