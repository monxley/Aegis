import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Brand assets.
///
/// The mark — a shoal of fish, one of them picked out in amber — is the
/// product's *identity mark*. It appears where a product signs its name: the
/// lock screen, onboarding, the app bar, and nowhere else. It is deliberately
/// not used as a security indicator: a padlock stamped next to every message
/// is decoration, and decoration that claims to mean "safe" is worse than no
/// indicator at all. Security state is communicated by [SecurityIndicator] and
/// by message state, in words.
class Brand {
  const Brand._();

  static const markHero = 'assets/brand/mark_hero.png';
  static const markLayered = 'assets/brand/mark_layered.png';
  static const markSilver = 'assets/brand/mark_silver.png';
  static const markMono = 'assets/brand/mark_mono.png';
  static const lock = 'assets/brand/lock.png';
  static const chevrons = 'assets/brand/chevrons.png';
  static const broadcast = 'assets/brand/broadcast.png';
  static const wordmark = 'assets/brand/wordmark.png';
  /// The wordmark in brand ink, for light grounds and print.
  static const wordmarkDark = 'assets/brand/wordmark_dark.png';
  static const lockupVertical = 'assets/brand/lockup_vertical.png';
  static const lockupHorizontal = 'assets/brand/lockup_horizontal.png';
  /// A seamless tile of the mark's own lattice. See [ScaleField].
  static const scales = 'assets/brand/scales.png';
  /// One cell of that lattice, white, for the amber flare to tint.
  static const scaleCell = 'assets/brand/scale_cell.png';
}

/// How alive the scale field looks.
///
/// Mirrors [ShoalEngineController.relayReachable] exactly, including its null:
/// "still connecting" is a real third state and must not be drawn as either of
/// the other two.
enum ScalePulse {
  /// Connected. The field breathes and a cell lights amber now and then.
  alive,

  /// Still finding a node. Visible, but nothing moves.
  waiting,

  /// No node. Dimmer still, and completely static.
  dark;

  static ScalePulse of(bool? reachable) => switch (reachable) {
        true => ScalePulse.alive,
        false => ScalePulse.dark,
        null => ScalePulse.waiting,
      };
}

/// The mark's lattice, tiled behind a screen that carries the brand.
///
/// Same shape as the logo, continued past its diamond: the tile is one fish of
/// the mark, repeated on a half-drop.
///
/// It also carries one piece of real information. The field is lit only while a
/// node is actually reachable, so "the app is connected" is something you can
/// see without reading anything. That makes it an indicator, not decoration, so
/// it is held to an indicator's rules: it never claims connected while
/// [ScalePulse.waiting], and it says nothing whatsoever about whether a message
/// was encrypted or delivered — those live in words, in the security sheet and
/// in message state.
///
/// Deliberately faint, and fading downwards, so it never competes with content.
/// It belongs on screens where the product signs its name and on the main
/// surfaces; never behind a conversation, where texture under someone's words
/// is just noise.
class ScaleField extends StatefulWidget {
  final Widget child;

  /// Opacity of the resting tile.
  final double opacity;

  /// Drawn size of one tile, in logical pixels.
  final double tile;

  /// Where the downward fade reaches nothing. 1 means "over the whole height".
  final double fadeTo;

  /// Connection state. Defaults to [ScalePulse.alive] for the screens that are
  /// shown before there is an engine to ask (splash, onboarding).
  final ScalePulse pulse;

  const ScaleField({
    super.key,
    required this.child,
    this.opacity = 0.055,
    this.tile = 92,
    this.fadeTo = 0.85,
    this.pulse = ScalePulse.alive,
  });

  @override
  State<ScaleField> createState() => _ScaleFieldState();
}

class _ScaleFieldState extends State<ScaleField>
    with TickerProviderStateMixin {
  /// Aspect of the tile asset (320x268), so the lattice maths below is in one
  /// place rather than spread through magic numbers.
  static const double _tileAspect = 268 / 320;
  static const double _cellW = 268 / 320;
  static const double _cellH = 120 / 320;

  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );
  late final AnimationController _flare = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  final Random _rng = Random();
  Timer? _flareTimer;
  Offset? _flareAt;

  /// The field's own size, captured in build. A flare is placed on a lattice
  /// cell, and the lattice has no bounds of its own, so without this the cell
  /// is picked from an arbitrary range and most flares land off-screen where
  /// nobody sees them.
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ScaleField old) {
    super.didUpdateWidget(old);
    if (old.pulse != widget.pulse) _sync();
  }

  /// Start or stop everything that moves, from one place.
  void _sync() {
    final live = widget.pulse == ScalePulse.alive;
    if (live) {
      if (!_wave.isAnimating) _wave.repeat();
      _armFlare();
    } else {
      _wave.stop();
      _flare.stop();
      _flareTimer?.cancel();
      _flareTimer = null;
      _flareAt = null;
    }
  }

  void _armFlare() {
    _flareTimer?.cancel();
    // Irregular on purpose: a fish lighting up on a metronome reads as a
    // progress indicator, which it is not.
    final wait = 5000 + _rng.nextInt(9000);
    _flareTimer = Timer(Duration(milliseconds: wait), () {
      if (!mounted || widget.pulse != ScalePulse.alive) return;
      final at = _pickCell();
      if (at == null) {
        _armFlare();   // no size yet; try again rather than flare nowhere
        return;
      }
      setState(() => _flareAt = at);
      _flare.forward(from: 0).whenComplete(() {
        if (mounted) _armFlare();
      });
    });
  }

  /// A random cell centre of the half-drop lattice, in fractions of the tile.
  ///
  /// The tile carries two fish: one centred at (0.5, 0.25) and one at
  /// (0.0, 0.75). Picking a real lattice position is what makes the flare look
  /// like one of the scales lighting up rather than a dot floating over them.
  Offset? _pickCell() {
    if (_size.isEmpty) return null;
    final tileH = widget.tile * _tileAspect;
    final cols = (_size.width / widget.tile).ceil();
    // Only the part of the field that has not faded out: a flare below that is
    // invisible, and an indicator you cannot see is not one.
    final usable = _size.height * widget.fadeTo * 0.8;
    final rows = (usable / tileH).ceil();
    if (cols < 1 || rows < 1) return null;
    final i = _rng.nextInt(cols).toDouble();
    final j = _rng.nextInt(rows).toDouble();
    return _rng.nextBool()
        ? Offset(i + 1, j + 0.75)   // row B sits on the tile boundary
        : Offset(i + 0.5, j + 0.25);
  }

  @override
  void dispose() {
    _flareTimer?.cancel();
    _wave.dispose();
    _flare.dispose();
    super.dispose();
  }

  /// Three stops that are always strictly increasing and inside 0..1.
  ///
  /// A LinearGradient rejects stops out of order, and clamping a travelling
  /// band naively collapses all three at the ends of the sweep.
  static List<double> _band(double t, double half) {
    var a = (t - half).clamp(0.0, 1.0);
    var b = t.clamp(0.0, 1.0);
    var c = (t + half).clamp(0.0, 1.0);
    const eps = 1e-4;
    b = max(b, a + eps);
    c = max(c, b + eps);
    if (c > 1.0) {
      c = 1.0;
      b = min(b, c - eps);
      a = min(a, b - eps);
    }
    return [a, b, c];
  }

  Widget _tiled(double opacity) => Opacity(
        opacity: opacity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              // `scale` turns the 320px asset into `tile` logical pixels, so
              // changing the tile size never needs the PNG regenerated.
              image: ExactAssetImage(Brand.scales, scale: 320 / widget.tile),
              repeat: ImageRepeat.repeat,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final reduced = ShoalMotion.reduced(context);
    final live = widget.pulse == ScalePulse.alive && !reduced;

    // Reduced motion is only known here, not in initState, so the controllers
    // are stopped on the first build rather than left ticking for a viewer who
    // asked for stillness. ProgressLine does the same.
    if (reduced) {
      if (_wave.isAnimating) _wave.stop();
      _flareTimer?.cancel();
      _flareTimer = null;
    }

    // Unreachable is dimmer than connecting, which is dimmer than connected.
    final base = switch (widget.pulse) {
      ScalePulse.alive => widget.opacity,
      ScalePulse.waiting => widget.opacity * 0.75,
      ScalePulse.dark => widget.opacity * 0.45,
    };

    final tileH = widget.tile * _tileAspect;

    return LayoutBuilder(builder: (context, constraints) {
      _size = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [Colors.white, Colors.transparent],
                stops: [0.0, widget.fadeTo],
              ).createShader(rect),
              child: Stack(
                children: [
                  Positioned.fill(child: _tiled(base)),
                  if (live)
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _wave,
                        builder: (context, child) => ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (rect) {
                            final s = _band(_wave.value, 0.3);
                            return LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: const [
                                Colors.transparent,
                                Colors.white,
                                Colors.transparent,
                              ],
                              stops: s,
                            ).createShader(rect);
                          },
                          child: child,
                        ),
                        // Built once: the sweep only changes the mask.
                        child: _tiled(base * 1.9),
                      ),
                    ),
                  if (live && _flareAt != null)
                    Positioned(
                      left: (_flareAt!.dx - _cellW / 2) * widget.tile,
                      top: _flareAt!.dy * tileH - (_cellH * widget.tile) / 2,
                      width: _cellW * widget.tile,
                      height: _cellH * widget.tile,
                      child: FadeTransition(
                        opacity: _flare.drive(
                          TweenSequence<double>([
                            TweenSequenceItem(
                              tween: Tween(begin: 0.0, end: 1.0)
                                  .chain(CurveTween(curve: Curves.easeOut)),
                              weight: 35,
                            ),
                            TweenSequenceItem(
                              tween: Tween(begin: 1.0, end: 0.0)
                                  .chain(CurveTween(curve: Curves.easeIn)),
                              weight: 65,
                            ),
                          ]),
                        ),
                        child: const _AmberCell(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // The field repaints every frame while the sweep runs; the content
        // above it does not need to.
        RepaintBoundary(child: widget.child),
        ],
      );
    });
  }
}

/// One scale of the field, lit in the brand amber — the same "one fish that is
/// not the school" the logo is built on.
class _AmberCell extends StatelessWidget {
  const _AmberCell();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // A soft bloom under the shape, so the cell reads as lit rather than
        // merely recoloured.
        Positioned.fill(
          child: FractionallySizedBox(
            widthFactor: 1.8,
            heightFactor: 3.2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    ShoalColor.accent.withValues(alpha: 0.30),
                    ShoalColor.accent.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
        // The asset is white, so a single colour filter puts the flare's colour
        // in the theme instead of in the PNG.
        ColorFiltered(
          colorFilter: ColorFilter.mode(ShoalColor.accent, BlendMode.srcIn),
          child: Image.asset(
            Brand.scaleCell,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ],
    );
  }
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
class ShoalLockupVertical extends StatelessWidget {
  final double width;
  const ShoalLockupVertical({super.key, this.width = 200});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Shoal',
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
    final reduced = ShoalMotion.reduced(context);
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
            color: ShoalColor.border,
            borderRadius: BorderRadius.circular(ShoalRadius.xs),
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
          color: ShoalColor.accent,
          borderRadius: BorderRadius.circular(ShoalRadius.xs),
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
    final color = error ? ShoalColor.danger : ShoalColor.accent;
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
                backgroundColor: ShoalColor.border,
                valueColor: AlwaysStoppedAnimation(color),
                strokeCap: StrokeCap.round,
              ),
            ),
            Icon(
              error ? Icons.priority_high_rounded : Icons.lock_outline_rounded,
              size: size * 0.3,
              color: error ? ShoalColor.danger : ShoalColor.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
