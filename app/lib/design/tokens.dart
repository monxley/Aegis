import 'package:flutter/widgets.dart';

/// Aegis design tokens.
///
/// One source of truth for colour, type, space, radius, elevation and motion.
/// Nothing in the app should hard-code a hex value, a padding number or an
/// animation duration — if a value is worth using twice it belongs here.
///
/// **Direction: editorial precision.** The interface is carried by typography,
/// alignment and hairlines rather than decoration. There are no gradients, no
/// glows and no ambient animation: a privacy tool should feel like a precision
/// instrument, not a light show. Security is communicated by state and copy,
/// not by painting the screen in "cybersecurity" colours.

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/// Semantic colour tokens.
///
/// The ground is a slightly cool ink rather than pure black: true black on OLED
/// makes hairlines and elevation impossible to read, and reads as "hacker
/// terminal". Surfaces step up in small, even increments so depth is legible
/// without shadows.
///
/// A single accent is used, sparingly, for *the* primary action and for
/// affirmative state. Meaning is never carried by hue alone — every coloured
/// state is paired with an icon or a label, so it survives colour-blindness and
/// greyscale.
class AegisColor {
  const AegisColor._();

  // Ground and surfaces.
  static const background = Color(0xFF0E1013);
  static const surface = Color(0xFF15181C);
  static const surfaceElevated = Color(0xFF1C2026);
  /// For the one surface that must read as "yours" — the outgoing message.
  static const surfaceAccent = Color(0xFF1B2A2E);

  // Text. Primary sits at ~14:1 on background; secondary ~7:1; muted ~4.6:1,
  // which keeps it above WCAG AA for the small sizes it is used at.
  static const textPrimary = Color(0xFFE8EAED);
  static const textSecondary = Color(0xFFA8AEB8);
  static const textMuted = Color(0xFF767D88);
  /// Text drawn on top of [accent].
  static const textOnAccent = Color(0xFF07100F);

  // Lines. Hairlines do the work that borders and shadows would elsewhere.
  static const border = Color(0xFF23272E);
  static const borderStrong = Color(0xFF313741);

  /// The single accent: a restrained teal. Not neon, not a gradient.
  static const accent = Color(0xFF4FD1C5);
  static const accentMuted = Color(0xFF2A4E4C);

  // Status. Used with an icon or label, never alone.
  static const danger = Color(0xFFE5686F);
  static const warning = Color(0xFFD9A34A);
  static const success = Color(0xFF5FBF8B);

  /// Scrims for modal surfaces.
  static const scrim = Color(0xB3000000);
}

// ---------------------------------------------------------------------------
// Space
// ---------------------------------------------------------------------------

/// A 4px-based spacing scale. Using a scale rather than arbitrary numbers is
/// what makes unrelated screens feel like one product.
class AegisSpace {
  const AegisSpace._();

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;
  static const double s12 = 48;
  static const double s16 = 64;
}

// ---------------------------------------------------------------------------
// Radius
// ---------------------------------------------------------------------------

/// Corner radii. Deliberately modest: oversized radii read as "friendly app
/// template" and undercut the precision this product is trying to convey.
class AegisRadius {
  const AegisRadius._();

  /// Chips, tags, small controls.
  static const double xs = 4;
  /// Inputs, buttons, message surfaces.
  static const double sm = 8;
  /// Cards and grouped rows.
  static const double md = 12;
  /// Sheets and dialogs.
  static const double lg = 16;
  /// Avatars and other genuinely circular elements.
  static const double full = 999;
}

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

/// Type scale.
///
/// Body sits at 15px: comfortable for long reading without the oversized
/// "screenshot typography" that wastes space on a phone. Sizes step in a
/// deliberate ratio and each has one job.
///
/// Cryptographic material — fingerprints, identity strings, algorithm names —
/// is the *only* thing set in mono. That makes "this is exact, verifiable data"
/// a visual signal rather than a decorative choice.
class AegisType {
  const AegisType._();

  static const String mono = 'monospace';

  /// Screen titles.
  static const title = TextStyle(
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: AegisColor.textPrimary,
  );

  /// Section headings and conversation names.
  static const heading = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: AegisColor.textPrimary,
  );

  /// Message text and primary reading copy.
  static const body = TextStyle(
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: AegisColor.textPrimary,
  );

  /// Supporting copy, previews, descriptions.
  static const secondary = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: AegisColor.textSecondary,
  );

  /// Metadata: timestamps, counts, state.
  ///
  /// Tabular figures so a ticking clock or a changing count does not shift the
  /// layout around it.
  static const meta = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: AegisColor.textMuted,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Small all-caps section labels. Letter-spaced because caps need it.
  static const label = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: AegisColor.textMuted,
  );

  /// Cryptographic material only.
  static const code = TextStyle(
    fontFamily: mono,
    fontSize: 13,
    height: 1.5,
    color: AegisColor.textPrimary,
    letterSpacing: 0.4,
  );
}

// ---------------------------------------------------------------------------
// Elevation
// ---------------------------------------------------------------------------

/// Elevation is expressed as a surface step plus a hairline; shadows are used
/// only where something genuinely floats above the page (sheets, menus), and
/// even then they stay soft and low-contrast.
class AegisElevation {
  const AegisElevation._();

  static const List<BoxShadow> none = [];

  /// Menus, popovers.
  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x40000000), blurRadius: 16, offset: Offset(0, 4)),
  ];

  /// Sheets and dialogs.
  static const List<BoxShadow> overlay = [
    BoxShadow(color: Color(0x59000000), blurRadius: 32, offset: Offset(0, 12)),
  ];
}

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

/// Motion tokens.
///
/// Animation exists to explain a state change or a spatial relationship. It is
/// fast enough to never sit between the user and their next action: nothing in
/// a common path exceeds [medium].
///
/// Every duration goes through [AegisMotion.of], which collapses motion to zero
/// when the platform reports "reduce motion". That is an accessibility
/// requirement, not a preference.
class AegisMotion {
  const AegisMotion._();

  /// Press feedback, icon swaps, hovers.
  static const Duration fast = Duration(milliseconds: 120);
  /// Expansion, sheets, list changes.
  static const Duration medium = Duration(milliseconds: 200);
  /// Page transitions and larger reveals.
  static const Duration slow = Duration(milliseconds: 280);

  /// Entering / settling.
  static const Curve enter = Curves.easeOutCubic;
  /// Leaving.
  static const Curve exit = Curves.easeInCubic;
  /// Moving between two on-screen positions.
  static const Curve move = Curves.easeInOutCubic;

  /// The duration to actually use, honouring the platform's reduced-motion
  /// setting. Prefer this over the raw constants at every call site.
  static Duration of(BuildContext context, Duration duration) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false
          ? Duration.zero
          : duration;

  /// Whether the user has asked for reduced motion, for the few places that
  /// need to drop an effect entirely rather than shorten it.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// Breakpoints and layout constants.
///
/// Mobile and desktop are laid out deliberately rather than by scaling one into
/// the other: below [wide] the app is a single column with one screen at a
/// time; at or above it, the conversation list and the open conversation sit
/// side by side.
class AegisLayout {
  const AegisLayout._();

  /// Phone → large phone / small tablet.
  static const double medium = 600;
  /// Where a two-pane layout starts to make sense.
  static const double wide = 900;
  /// Where a third (details) pane fits.
  static const double extraWide = 1240;

  /// Reading measure for message text. Long lines are hard to track; this caps
  /// them on wide displays instead of letting text run the full width.
  static const double maxMessageWidth = 560;

  /// The minimum size any interactive target may be.
  static const double minTouchTarget = 44;

  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wide;
}
