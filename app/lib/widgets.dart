import 'package:flutter/material.dart';

import 'theme.dart';

/// The Aegis shield mark: a rounded shield filled with the cyan→violet
/// gradient. Scales with [size].
class ShieldMark extends StatelessWidget {
  final double size;
  const ShieldMark({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    // The brand shield (metallic + cyan chevron, transparent background) — reads
    // on the dark UI. Rendered a touch larger than the nominal size since the
    // asset carries transparent margin.
    return Image.asset(
      'assets/logo/shield.png',
      width: size * 1.18,
      height: size * 1.18,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// The "AEGIS" wordmark (light gradient, transparent background).
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

/// A full-width pill button filled with the shield gradient.
class GradientButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Ink(
            decoration: BoxDecoration(
              gradient: AegisTheme.shield,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Container(
              height: 54,
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: const Color(0xFF06110F), size: 20),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFF06110F),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
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
                  child: Container(color: AegisTheme.danger.withOpacity(0.25)),
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
