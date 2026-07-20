import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Asset paths for the Aegis brand art (see `pubspec.yaml` → `assets/brand/`).
class Brand {
  Brand._();
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

/// A plain square brand image (transparent PNG), sized to [size].
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
      filterQuality: FilterQuality.medium,
    );
  }
}

/// The vertical lockup (shield + AEGIS + "NOTHING TO INTERCEPT.").
class AegisLockupVertical extends StatelessWidget {
  final double width;
  const AegisLockupVertical({super.key, this.width = 200});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      Brand.lockupVertical,
      width: width,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// A soft, slowly-drifting aurora of the two brand colours behind the content.
/// Purely decorative and cheap: two radial blooms that orbit a little. Give it
/// as the bottom layer of a `Stack`.
class AuroraBackground extends StatefulWidget {
  final Widget child;
  const AuroraBackground({super.key, required this.child});

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AegisTheme.bg),
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => CustomPaint(painter: _AuroraPainter(_ctrl.value)),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  _AuroraPainter(this.t);

  void _bloom(Canvas c, Offset center, double radius, Color color) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withOpacity(0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    c.drawCircle(center, radius, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final a = 2 * math.pi * t;
    _bloom(
      canvas,
      Offset(w * (0.24 + 0.06 * math.sin(a)), h * (0.26 + 0.05 * math.cos(a))),
      w * 0.62,
      AegisTheme.accent.withOpacity(0.16),
    );
    _bloom(
      canvas,
      Offset(w * (0.82 + 0.05 * math.cos(a * 0.8)),
          h * (0.72 + 0.06 * math.sin(a * 1.2))),
      w * 0.66,
      AegisTheme.accent2.withOpacity(0.16),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t;
}

/// A slim indeterminate progress bar with a brand-gradient highlight sliding
/// across it. Use where the work has no measurable progress (boot, discovery).
class ShimmerBar extends StatefulWidget {
  final double width;
  const ShimmerBar({super.key, this.width = 150});

  @override
  State<ShimmerBar> createState() => _ShimmerBarState();
}

class _ShimmerBarState extends State<ShimmerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => CustomPaint(painter: _ShimmerPainter(_ctrl.value)),
        ),
      ),
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  final double t;
  _ShimmerPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AegisTheme.surfaceHi);
    final hl = size.width * 0.42;
    final x = -hl + (size.width + hl) * t;
    final rect = Rect.fromLTWH(x, 0, hl, size.height);
    final shader = const LinearGradient(
      colors: [
        Color(0x0035E0D0),
        AegisTheme.accent,
        AegisTheme.accent2,
        Color(0x007C5CFF),
      ],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => old.t != t;
}

/// The visual heart of the unlock flow: a gradient progress ring wrapped around
/// the lock glyph, which cross-fades to the open shield when [progress] reaches
/// 1. Drive [progress] (0..1) from the caller as the key derivation runs; set
/// [error] to flush the ring red.
class UnlockOrb extends StatelessWidget {
  final double progress;
  final bool error;
  final double size;
  const UnlockOrb({
    super.key,
    required this.progress,
    this.error = false,
    this.size = 148,
  });

  @override
  Widget build(BuildContext context) {
    final unlocked = progress >= 0.999 && !error;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _RingPainter(progress: progress, error: error),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: Tween(begin: 0.7, end: 1.0).animate(
                CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
              ),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: BrandGlyph(
              unlocked ? Brand.shieldHero : Brand.lock,
              key: ValueKey(unlocked),
              size: size * 0.52,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final bool error;
  _RingPainter({required this.progress, required this.error});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 6.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = AegisTheme.surfaceHi;
    canvas.drawCircle(center, radius, track);

    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: 3 * math.pi / 2,
        colors: error
            ? const [AegisTheme.danger, AegisTheme.danger]
            : const [AegisTheme.accent, AegisTheme.accent2, AegisTheme.accent],
      ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.error != error;
}
