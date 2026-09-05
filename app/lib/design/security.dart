import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// How a conversation's cryptographic identity currently stands.
enum VerificationState {
  /// Safety numbers have been compared out of band and matched.
  verified,

  /// Encrypted, but the peer's identity has not been checked by a human.
  /// This is the honest default — encryption alone does not tell you *who* is
  /// on the other end.
  unverified,

  /// The peer's identity key is not the one previously seen. Either they
  /// reinstalled, or someone is in the middle. Never quietly accepted.
  changed,
}

/// Whether the app can currently reach the network.
enum ConnectionState { connected, connecting, offline }

/// The algorithms this build actually uses.
///
/// Kept as data, in one place, so the interface can never drift into claiming
/// something the protocol does not do. Every entry here corresponds to an
/// implementation in `crates/aegis-crypto` — nothing aspirational.
class ProtocolFacts {
  const ProtocolFacts._();

  static const List<({String role, String algorithm, String note})> primitives =
      [
    (
      role: 'Key establishment',
      algorithm: 'X25519 + ML-KEM-768',
      note:
          'Hybrid: a classical and a post-quantum exchange are combined, so the '
              'session stays private if either one is broken.',
    ),
    (
      role: 'Authentication',
      algorithm: 'ML-DSA-65',
      note: 'Signs the prekey bundle that starts a conversation.',
    ),
    (
      role: 'Message encryption',
      algorithm: 'ChaCha20-Poly1305',
      note: 'Encrypts and authenticates each message.',
    ),
    (
      role: 'Key derivation',
      algorithm: 'HKDF-SHA256',
      note: 'Derives per-message keys from the shared secret.',
    ),
    (
      role: 'Forward secrecy',
      algorithm: 'Double Ratchet',
      note:
          'Keys advance with every message, and re-key post-quantum as the '
              'conversation continues.',
    ),
    (
      role: 'Metadata',
      algorithm: 'Sphinx onion routing',
      note:
          'Messages travel through mix nodes, so no single node sees both ends.',
    ),
  ];

  /// The one caveat that belongs next to any security claim in this build.
  static const String maturity =
      'Aegis is alpha software and has not had an external security audit. '
      'The protocol and its implementation may contain flaws.';
}

/// A compact, inline statement of a conversation's security state.
///
/// Deliberately quiet. A padlock stamped on every screen becomes wallpaper —
/// users stop reading it, which makes it worse than nothing. This says one
/// short true thing, and opens the details when tapped.
class SecurityIndicator extends StatelessWidget {
  final VerificationState verification;
  final VoidCallback? onTap;

  const SecurityIndicator({
    super.key,
    required this.verification,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (verification) {
      VerificationState.verified => (
          'Verified',
          AegisColor.success,
          Icons.check_circle_outline_rounded,
        ),
      VerificationState.unverified => (
          'Encrypted · not verified',
          AegisColor.textMuted,
          Icons.lock_outline_rounded,
        ),
      VerificationState.changed => (
          'Identity changed',
          AegisColor.warning,
          Icons.error_outline_rounded,
        ),
    };

    return Semantics(
      button: onTap != null,
      label: 'Security: $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AegisRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AegisSpace.s1, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: AegisSpace.s1),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: AegisType.meta.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The security sheet for one conversation.
///
/// Progressive disclosure, as the product requires: the top answers "is this
/// private, and do I know who I'm talking to" in plain language. The
/// cryptographic detail is real and complete, but it is one tap away — an
/// ordinary user should never have to read an algorithm name to use the app,
/// and a researcher should never have to guess what the build does.
class SecurityDetailsSheet extends StatefulWidget {
  final String contactName;
  final VerificationState verification;

  /// The safety number, or null if it could not be computed.
  final String? safetyNumber;

  /// Called when the user confirms they have compared the number out of band.
  final VoidCallback? onMarkVerified;

  const SecurityDetailsSheet({
    super.key,
    required this.contactName,
    required this.verification,
    this.safetyNumber,
    this.onMarkVerified,
  });

  @override
  State<SecurityDetailsSheet> createState() => _SecurityDetailsSheetState();
}

class _SecurityDetailsSheetState extends State<SecurityDetailsSheet> {
  bool _technical = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AegisSpace.s5, AegisSpace.s2, AegisSpace.s5, AegisSpace.s6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Security', style: AegisType.title),
            const SizedBox(height: AegisSpace.s1),
            // The plain-language answer, first and without jargon.
            Text(
              switch (widget.verification) {
                VerificationState.verified =>
                  'Messages with ${widget.contactName} are end-to-end '
                      'encrypted, and you have verified their identity.',
                VerificationState.unverified =>
                  'Messages with ${widget.contactName} are end-to-end '
                      'encrypted. You have not yet verified that this is really '
                      'them.',
                VerificationState.changed =>
                  "${widget.contactName}'s identity key has changed. This "
                      'happens when someone reinstalls, but it can also mean '
                      'someone is intercepting. Verify before you continue.',
              },
              style: AegisType.secondary,
            ),
            const SizedBox(height: AegisSpace.s5),

            if (widget.safetyNumber != null) ...[
              const Text('SAFETY NUMBER', style: AegisType.label),
              const SizedBox(height: AegisSpace.s2),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AegisSpace.s3),
                decoration: BoxDecoration(
                  color: AegisColor.background,
                  borderRadius: BorderRadius.circular(AegisRadius.sm),
                  border: Border.all(color: AegisColor.border),
                ),
                // Mono, because this is exact data the user is asked to compare
                // digit by digit.
                child: SelectableText(
                  widget.safetyNumber!,
                  style: AegisType.code,
                ),
              ),
              const SizedBox(height: AegisSpace.s2),
              Text(
                'Compare these digits with ${widget.contactName} over a channel '
                'you already trust — in person, or a call you recognise. If '
                'they match, no one is in the middle.',
                style: AegisType.secondary.copyWith(fontSize: 12),
              ),
              if (widget.onMarkVerified != null) ...[
                const SizedBox(height: AegisSpace.s4),
                _SheetAction(
                  label: 'They match — mark verified',
                  icon: Icons.check_rounded,
                  onTap: () {
                    widget.onMarkVerified!();
                    Navigator.of(context).pop();
                  },
                ),
              ],
              const SizedBox(height: AegisSpace.s6),
            ],

            // Progressive disclosure: collapsed by default, complete when open.
            _TechnicalDisclosure(
              expanded: _technical,
              onToggle: () => setState(() => _technical = !_technical),
            ),

            const SizedBox(height: AegisSpace.s5),
            // The caveat sits with the claims, not buried in an about screen.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 14, color: AegisColor.textMuted),
                const SizedBox(width: AegisSpace.s2),
                Expanded(
                  child: Text(
                    ProtocolFacts.maturity,
                    style: AegisType.meta.copyWith(height: 1.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The expandable "how this works" section.
class _TechnicalDisclosure extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;

  const _TechnicalDisclosure({required this.expanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(AegisRadius.xs),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AegisSpace.s2),
              child: Row(
                children: [
                  const Text('How this is protected',
                      style: AegisType.heading),
                  const SizedBox(width: AegisSpace.s2),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: AegisMotion.of(context, AegisMotion.fast),
                    child: const Icon(Icons.expand_more_rounded,
                        size: 18, color: AegisColor.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AegisSpace.s2),
              for (final p in ProtocolFacts.primitives) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: AegisSpace.s4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.role.toUpperCase(), style: AegisType.label),
                      const SizedBox(height: 3),
                      SelectableText(p.algorithm, style: AegisType.code),
                      const SizedBox(height: 3),
                      Text(
                        p.note,
                        style: AegisType.secondary.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: AegisMotion.of(context, AegisMotion.medium),
          sizeCurve: AegisMotion.move,
        ),
      ],
    );
  }
}

/// A full-width secondary action inside a sheet.
class _SheetAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _SheetAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(AegisRadius.sm),
      child: Container(
        width: double.infinity,
        height: AegisLayout.minTouchTarget,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AegisRadius.sm),
          border: Border.all(color: AegisColor.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: AegisColor.accent),
            const SizedBox(width: AegisSpace.s2),
            Text(
              label,
              style: AegisType.secondary.copyWith(
                color: AegisColor.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The network state, shown only when it is not "connected".
///
/// A permanent "Connected" banner is noise; the useful signal is when something
/// is wrong. This states what is happening and what it means for the user's
/// messages, without inventing detail about why.
class ConnectionBanner extends StatelessWidget {
  final ConnectionState state;
  const ConnectionBanner({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state == ConnectionState.connected) return const SizedBox.shrink();
    final (label, detail, color) = switch (state) {
      ConnectionState.connecting => (
          'Connecting',
          'Messages you send will go out once the connection is up.',
          AegisColor.textMuted,
        ),
      ConnectionState.offline => (
          'Offline',
          'Messages are saved on this device and sent when you reconnect.',
          AegisColor.warning,
        ),
      ConnectionState.connected => ('', '', AegisColor.textMuted),
    };

    return Semantics(
      liveRegion: true,
      label: '$label. $detail',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AegisSpace.s4, vertical: AegisSpace.s2),
        decoration: const BoxDecoration(
          color: AegisColor.surface,
          border: Border(bottom: BorderSide(color: AegisColor.border)),
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AegisSpace.s2),
            Text(label,
                style: AegisType.meta.copyWith(
                    color: AegisColor.textSecondary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: AegisSpace.s2),
            Expanded(
              child: Text(
                detail,
                overflow: TextOverflow.ellipsis,
                style: AegisType.meta,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
