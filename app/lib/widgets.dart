import 'package:flutter/material.dart';

import 'theme.dart';

/// The Aegis shield mark: a rounded shield filled with the cyan→violet
/// gradient. Scales with [size].
class ShieldMark extends StatelessWidget {
  final double size;
  const ShieldMark({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (r) => AegisTheme.shield.createShader(r),
      child: Icon(Icons.shield_rounded, size: size, color: Colors.white),
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
