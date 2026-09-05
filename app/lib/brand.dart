import 'package:flutter/material.dart';

import 'theme.dart';

/// Brand assets.
///
/// The shield is the product's *identity mark*. It appears where a product
/// signs its name — the lock screen, onboarding, the app bar — and nowhere
/// else. It is deliberately not used as a security indicator: a padlock or
/// shield stamped next to every message is decoration, and decoration that
/// claims to mean "safe" is worse than no indicator at all. Security state is
/// communicated by [SecurityIndicator] and by message state, in words.
class Brand {
  const Brand._();

  static const shieldHero = 'assets/brand/shield_hero.png';
  static const shieldLayered = 'assets/brand/shield_layered.png';
  static const shieldSilver = 'assets/brand/shield_silver.png';
  static const shieldMono = 'assets/brand/shield_mono.png';
  static const lock = 'assets/brand/lock.png';
  static const chevrons = 'assets/brand/chevrons.png';
  static const broadcast = 'assets/brand/broadcast.png';
  static const wordmark = 'assets/brand/wordmark.png';
  static const lockupVertical = 'assets/brand/lockup_vertical.png';
  static const lockupHorizontal = 'assets/brand/lockup_horizontal.png';
}

/// A brand image at a given size.
class BrandGlyph extends StatelessWidget {
  final String asset;
  final double size;
  const BrandGlyph(this.asset, {super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      // Decorative: the surrounding copy already carries the meaning, so a
      // screen reader should skip it rather than announce an image.
      excludeFromSemantics: true,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// The vertical mark + wordmark lockup, for the splash and onboarding.
class AegisLockupVertical extends StatelessWidget {
  final double width;
  const AegisLockupVertical({super.key, this.width = 200});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Aegis',
      child: Image.asset(
        Brand.lockupVertical,
        width: width,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

/// A thin indeterminate progress line.
///
/// Replaces the shimmering bar that used to sit on the splash: a looping
/// gradient sweep is decoration that says nothing about what the app is doing.
/// This is a plain, honest "working" indicator, and it stops moving entirely
/// under reduced motion rather than animating in place.
class ProgressLine extends StatefulWidget {
  final double width;
  const ProgressLine({super.key, this.width = 120});

  @override
  State<ProgressLine> createState() => _ProgressLineState();
}

class _ProgressLineState extends State<ProgressLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AegisMotion.reduced(context);
    if (reduced) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
    return SizedBox(
      width: widget.width,
      height: 2,
      child: Semantics(
        label: 'Working',
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AegisColor.border,
            borderRadius: BorderRadius.circular(AegisRadius.xs),
          ),
          child: reduced
              // Static two-thirds bar: still reads as "in progress" without
              // moving pixels for someone who asked us not to.
              ? FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: 0.66,
                  child: _bar(),
                )
              : AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    // A short segment travelling left to right.
                    final t = Curves.easeInOut.transform(_c.value);
                    return Align(
                      alignment: Alignment(-1 + 2 * t, 0),
                      child: FractionallySizedBox(
                        widthFactor: 0.4,
                        child: _bar(),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Widget _bar() => DecoratedBox(
        decoration: BoxDecoration(
          color: AegisColor.accent,
          borderRadius: BorderRadius.circular(AegisRadius.xs),
        ),
      );
}

/// The unlock indicator: a determinate ring showing key-derivation progress.
///
/// Unlocking genuinely takes time — the vault key is deliberately expensive to
/// derive — so this reports real progress rather than spinning. It replaces a
/// glowing orb, which implied something mystical was happening instead of
/// telling the user the app was working and roughly how far along it was.
class UnlockProgress extends StatelessWidget {
  /// 0..1 derivation progress.
  final double progress;
  final bool error;
  final double size;

  const UnlockProgress({
    super.key,
    required this.progress,
    this.error = false,
    this.size = 72,
  });

  @override
  Widget build(BuildContext context) {
    final color = error ? AegisColor.danger : AegisColor.accent;
    final pct = (progress.clamp(0.0, 1.0) * 100).round();
    return Semantics(
      label: error ? 'Unlock failed' : 'Unlocking, $pct percent',
      value: '$pct%',
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                // Indeterminate only before work starts; determinate after.
                value: progress <= 0 ? null : progress.clamp(0.0, 1.0),
                strokeWidth: 2,
                backgroundColor: AegisColor.border,
                valueColor: AlwaysStoppedAnimation(color),
                strokeCap: StrokeCap.round,
              ),
            ),
            Icon(
              error ? Icons.priority_high_rounded : Icons.lock_outline_rounded,
              size: size * 0.3,
              color: error ? AegisColor.danger : AegisColor.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
