import 'package:flutter/material.dart';

import 'theme.dart';

/// The Aegis identity mark. Used where the product signs its name — the lock
/// screen, onboarding, the app bar — and never as a security indicator.
class ShieldMark extends StatelessWidget {
  final double size;
  const ShieldMark({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    // Rendered a touch larger than the nominal size, since the asset carries
    // transparent margin of its own.
    return Image.asset(
      'assets/logo/shield.png',
      width: size * 1.18,
      height: size * 1.18,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// The "AEGIS" wordmark.
class AegisWordmark extends StatelessWidget {
  final double height;
  const AegisWordmark({super.key, this.height = 34});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/logo/wordmark.png',
      height: height,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// The primary action button: one solid accent fill, no gradient.
///
/// Supports the full set of states the design system requires — default,
/// pressed, focused, disabled and loading — because a button that only has a
/// default state is where interfaces start to feel cheap. Focus is drawn as a
/// visible ring so the control is usable from a keyboard.
class PrimaryButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// Shows a spinner and blocks input. Use for actions that take long enough to
  /// notice, so the user isn't left wondering whether the tap registered.
  final bool loading;

  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
  });

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    // Disabled is expressed as a muted surface, not as a faded copy of the
    // enabled state — translucent text fails contrast.
    final fill = enabled ? AegisColor.accent : AegisColor.surfaceElevated;
    final fg = enabled ? AegisColor.textOnAccent : AegisColor.textMuted;

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: AegisMotion.of(context, AegisMotion.fast),
            curve: AegisMotion.enter,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _pressed ? AegisColor.accentMuted : fill,
              borderRadius: BorderRadius.circular(AegisRadius.sm),
              border: Border.all(
                color: _focused ? AegisColor.textPrimary : Colors.transparent,
                width: 2,
              ),
            ),
            child: widget.loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(fg),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, color: fg, size: 18),
                        const SizedBox(width: AegisSpace.s2),
                      ],
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: fg,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A destructive button that only fires after being held down for ~1.5s, so a
/// panic wipe can't happen on an accidental tap. The fill animates as you hold;
/// releasing early cancels.
class HoldToWipeButton extends StatefulWidget {
  final bool enabled;
  final Future<void> Function() onWipe;
  final String idleLabel;
  const HoldToWipeButton({
    super.key,
    required this.enabled,
    required this.onWipe,
    this.idleLabel = 'Hold to wipe',
  });

  @override
  State<HoldToWipeButton> createState() => _HoldToWipeButtonState();
}

class _HoldToWipeButtonState extends State<HoldToWipeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..addStatusListener((s) {
      if (s == AnimationStatus.completed) _fire();
    });
  bool _fired = false;

  Future<void> _fire() async {
    if (_fired) return;
    _fired = true;
    await widget.onWipe();
  }

  void _start() {
    if (!widget.enabled) return;
    _fired = false;
    _ctrl.forward(from: 0);
  }

  void _cancel() {
    if (!_ctrl.isCompleted) _ctrl.reset();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _start(),
      onTapUp: (_) => _cancel(),
      onTapCancel: _cancel,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final t = _ctrl.value;
          return Container(
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AegisTheme.danger),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Fill grows left→right as the hold progresses.
                FractionallySizedBox(
                  widthFactor: t,
                  heightFactor: 1,
                  alignment: Alignment.centerLeft,
                  child: Container(color: AegisTheme.danger.withValues(alpha: 0.25)),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.local_fire_department_rounded,
                        size: 18, color: AegisTheme.danger),
                    const SizedBox(width: 8),
                    Text(
                      t > 0 && t < 1 ? 'Keep holding…' : widget.idleLabel,
                      style: const TextStyle(
                        color: AegisTheme.danger,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A round avatar showing the first letter of [name] over a soft gradient,
/// tinted deterministically from the name so contacts are distinguishable.
class ContactAvatar extends StatelessWidget {
  final String name;
  final double size;
  const ContactAvatar({super.key, required this.name, this.size = 46});

  @override
  Widget build(BuildContext context) {
    final letter = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final hue = (name.hashCode % 360).abs().toDouble();
    final c1 = HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor();
    final c2 = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.55, 0.42).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c1, c2],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Shorten an Aegis ID for display: `aegis:AB12…9Z`.
String shortId(String aegisId) {
  final body = aegisId.startsWith('aegis:') ? aegisId.substring(6) : aegisId;
  if (body.length <= 12) return aegisId;
  return 'aegis:${body.substring(0, 6)}…${body.substring(body.length - 4)}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// A 24-hour clock, `14:07`.
String formatClock(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// A day label for a chat separator: `Today`, `Yesterday`, `12 Jul`, or
/// `12 Jul 2024` for other years.
String formatDayLabel(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(d.year, d.month, d.day))
      .inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  final base = '${d.day} ${_months[d.month - 1]}';
  return d.year == now.year ? base : '$base ${d.year}';
}

/// A compact stamp for a chat-list row: the clock if today, else the day.
String formatListTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  final now = DateTime.now();
  final today = d.year == now.year && d.month == now.month && d.day == now.day;
  return today ? formatClock(ms) : formatDayLabel(ms);
}

/// Whether two timestamps fall on different calendar days (a day separator goes
/// between them in a chat).
bool differentDay(int aMs, int bMs) {
  final a = DateTime.fromMillisecondsSinceEpoch(aMs).toLocal();
  final b = DateTime.fromMillisecondsSinceEpoch(bMs).toLocal();
  return a.year != b.year || a.month != b.month || a.day != b.day;
}
