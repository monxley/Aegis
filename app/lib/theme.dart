import 'package:flutter/material.dart';

import 'design/tokens.dart';

export 'design/tokens.dart';

/// The Aegis theme, assembled from the design tokens.
///
/// The visual language is deliberately quiet: an ink ground, one restrained
/// accent, hairline borders, and typography doing the structural work. There
/// are no gradients, no glows and no ambient animation — the product should
/// read as a precision instrument, and security should be communicated by
/// state and copy rather than by decoration.
class AegisTheme {
  const AegisTheme._();

  // Semantic aliases onto the tokens, so screens read in product terms.
  static const Color bg = AegisColor.background;
  static const Color surface = AegisColor.surface;
  static const Color surfaceHi = AegisColor.surfaceElevated;
  static const Color accent = AegisColor.accent;
  static const Color textHi = AegisColor.textPrimary;
  static const Color textLo = AegisColor.textSecondary;
  static const Color textMuted = AegisColor.textMuted;
  static const Color border = AegisColor.border;
  static const Color danger = AegisColor.danger;
  static const Color warning = AegisColor.warning;
  static const Color success = AegisColor.success;

  /// The shape every bottom sheet uses.
  static const RoundedRectangleBorder sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(AegisRadius.lg)),
  );

  /// A hairline, used instead of heavy dividers and shadows.
  static const BorderSide hairline =
      BorderSide(color: AegisColor.border, width: 1);

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: AegisColor.accent,
      onPrimary: AegisColor.textOnAccent,
      surface: AegisColor.surface,
      onSurface: AegisColor.textPrimary,
      error: AegisColor.danger,
      outline: AegisColor.border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AegisColor.background,
      fontFamily: 'sans-serif',
      // A quiet, fast page transition. Route changes should feel like the
      // interface responding, not like a scene change.
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
      appBarTheme: const AppBarTheme(
        backgroundColor: AegisColor.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AegisType.title,
        iconTheme: IconThemeData(color: AegisColor.textSecondary, size: 20),
      ),
      // Cards are defined by a hairline, not a shadow.
      cardTheme: CardThemeData(
        color: AegisColor.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AegisRadius.md),
          side: hairline,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AegisColor.surface,
        hintStyle: const TextStyle(color: AegisColor.textMuted, fontSize: 15),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AegisSpace.s4,
          vertical: AegisSpace.s3,
        ),
        border: _inputBorder(AegisColor.border),
        enabledBorder: _inputBorder(AegisColor.border),
        focusedBorder: _inputBorder(AegisColor.accent),
        errorBorder: _inputBorder(AegisColor.danger),
        focusedErrorBorder: _inputBorder(AegisColor.danger),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AegisColor.surfaceElevated,
        contentTextStyle: AegisType.secondary
            .copyWith(color: AegisColor.textPrimary, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AegisRadius.sm),
          side: hairline,
        ),
        insetPadding: const EdgeInsets.all(AegisSpace.s4),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AegisColor.surface,
        modalBackgroundColor: AegisColor.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: AegisColor.scrim,
        shape: sheetShape,
        showDragHandle: true,
        dragHandleColor: AegisColor.borderStrong,
        dragHandleSize: Size(32, 3),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AegisColor.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: AegisType.heading,
        contentTextStyle: AegisType.secondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AegisRadius.lg),
          side: hairline,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AegisColor.textSecondary,
        textColor: AegisColor.textPrimary,
        minVerticalPadding: AegisSpace.s3,
      ),
      dividerTheme: const DividerThemeData(
        color: AegisColor.border,
        thickness: 1,
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AegisColor.textOnAccent
                : AegisColor.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AegisColor.accent
                : AegisColor.surfaceElevated),
        trackOutlineColor:
            const WidgetStatePropertyAll(AegisColor.borderStrong),
      ),
      // A quiet highlight rather than Material's expanding ink, which fights
      // the flat surfaces.
      splashFactory: NoSplash.splashFactory,
      highlightColor: AegisColor.surfaceElevated,
      // Focus must be visible for keyboard users; this is not optional.
      focusColor: AegisColor.accent,
      textTheme: const TextTheme(
        titleLarge: AegisType.title,
        titleMedium: AegisType.heading,
        bodyLarge: AegisType.body,
        bodyMedium: AegisType.secondary,
        labelSmall: AegisType.meta,
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AegisRadius.sm),
        borderSide: BorderSide(color: color, width: 1),
      );
}

/// A short fade with a small rise. Enough to show that a new surface arrived,
/// short enough never to sit between the user and their next action. Collapses
/// to an instant cut when the platform asks for reduced motion.
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
    if (AegisMotion.reduced(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: AegisMotion.enter,
      reverseCurve: AegisMotion.exit,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// One scroll feel across platforms, with Material's glow removed — it reads as
/// a stock Android app and clashes with the flat surfaces.
class AegisScrollBehavior extends MaterialScrollBehavior {
  const AegisScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
