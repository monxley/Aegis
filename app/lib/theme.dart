import 'package:flutter/material.dart';

/// The Aegis look: a deep, near-black canvas with a cyan→violet "shielded"
/// accent. Dark only — a privacy tool should feel like one.
class AegisTheme {
  static const Color bg = Color(0xFF0A0B10);
  static const Color surface = Color(0xFF12141C);
  static const Color surfaceHi = Color(0xFF1B1E29);
  static const Color accent = Color(0xFF35E0D0); // cyan
  static const Color accent2 = Color(0xFF7C5CFF); // violet
  static const Color textHi = Color(0xFFEAECF2);
  static const Color textLo = Color(0xFF8A90A6);
  static const Color danger = Color(0xFFFF5C7A);

  /// The cyan→violet gradient used for the shield mark, send button, and
  /// outgoing bubbles.
  static const LinearGradient shield = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accent2],
  );

  /// Rounded-corner scale, so sheets, cards and bubbles agree.
  static const double radiusSm = 12;
  static const double radiusMd = 18;
  static const double radiusLg = 24;

  /// The shape every bottom sheet uses.
  static const RoundedRectangleBorder sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLg)),
  );

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: accent,
      secondary: accent2,
      surface: surface,
      error: danger,
      onPrimary: Color(0xFF06110F),
      onSurface: textHi,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Transparent so the app-wide AuroraBackground (painted once at the root
      // in main.dart) shows through every screen; opaque bars/cards sit on top.
      scaffoldBackgroundColor: Colors.transparent,
      // A soft fade + rise on every route push/pop, on every platform.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AegisPageTransitionsBuilder(),
          TargetPlatform.iOS: AegisPageTransitionsBuilder(),
          TargetPlatform.linux: AegisPageTransitionsBuilder(),
          TargetPlatform.macOS: AegisPageTransitionsBuilder(),
          TargetPlatform.windows: AegisPageTransitionsBuilder(),
          TargetPlatform.fuchsia: AegisPageTransitionsBuilder(),
        },
      ),
      fontFamily: 'sans-serif',
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textHi,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHi,
        hintStyle: const TextStyle(color: textLo),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHi,
        contentTextStyle: const TextStyle(color: textHi),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      ),
      // Every sheet in the app gets the same rounded top and backdrop, instead
      // of each call site repeating (and drifting from) the shape.
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: sheetShape,
        showDragHandle: true,
        dragHandleColor: surfaceHi,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textHi,
        textColor: textHi,
      ),
      dividerTheme: const DividerThemeData(
        color: surfaceHi,
        thickness: 1,
        space: 1,
      ),
      // The default Material ink splash fights the dark, glassy surfaces; a
      // quiet highlight reads better and costs less to paint.
      splashFactory: InkSparkle.splashFactory,
    );
  }
}

/// Shared motion values, so animations across the app agree instead of each
/// widget inventing its own timing.
class AegisMotion {
  /// A press, a toggle, an icon swap.
  static const Duration fast = Duration(milliseconds: 160);
  /// A sheet, an expanding row, a bubble arriving.
  static const Duration medium = Duration(milliseconds: 260);
  /// A page or a large reveal.
  static const Duration slow = Duration(milliseconds: 380);

  /// Decelerating: things entering or settling.
  static const Curve enter = Curves.easeOutCubic;
  /// Accelerating: things leaving.
  static const Curve exit = Curves.easeInCubic;
  /// A little overshoot, for something that should feel physical.
  static const Curve spring = Curves.easeOutBack;
}

/// App-wide scroll feel: no Material glow (it clashes with the dark canvas),
/// and the same stretch behaviour on every platform so Android and iOS match.
class AegisScrollBehavior extends MaterialScrollBehavior {
  const AegisScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return StretchingOverscrollIndicator(
      axisDirection: details.direction,
      child: child,
    );
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}

/// The Aegis page transition: a fade with a small upward rise, used for every
/// route push/pop across platforms (wired in [AegisTheme.dark]).
class AegisPageTransitionsBuilder extends PageTransitionsBuilder {
  const AegisPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
