import 'package:flutter/material.dart';

import 'design/tokens.dart';

export 'design/tokens.dart';

/// The Shoal theme, assembled from the design tokens.
///
/// The visual language is deliberately quiet: an ink ground, one restrained
/// accent, hairline borders, and typography doing the structural work. There
/// are no gradients, no glows and no ambient animation — the product should
/// read as a precision instrument, and security should be communicated by
/// state and copy rather than by decoration.
class ShoalTheme {
  const ShoalTheme._();

  // There used to be a block of colour aliases here (`ShoalTheme.textHi` and
  // friends) forwarding to the tokens. It meant the app had two names for every
  // colour and 300-odd call sites split between them, which is exactly how a
  // design system stops governing the code it is supposed to govern. The
  // aliases are gone: `ShoalColor` is the only vocabulary, and this file
  // re-exports it so importing the theme is enough.

  /// The shape every bottom sheet uses.
  static const RoundedRectangleBorder sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(ShoalRadius.lg)),
  );

  /// A hairline, used instead of heavy dividers and shadows.
  static const BorderSide hairline =
      BorderSide(color: ShoalColor.border, width: 1);

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: ShoalColor.accent,
      onPrimary: ShoalColor.textOnAccent,
      surface: ShoalColor.surface,
      onSurface: ShoalColor.textPrimary,
      error: ShoalColor.danger,
      outline: ShoalColor.border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: ShoalColor.background,
      fontFamily: 'sans-serif',
      // A quiet, fast page transition. Route changes should feel like the
      // interface responding, not like a scene change.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ShoalPageTransitionsBuilder(),
          TargetPlatform.iOS: ShoalPageTransitionsBuilder(),
          TargetPlatform.linux: ShoalPageTransitionsBuilder(),
          TargetPlatform.macOS: ShoalPageTransitionsBuilder(),
          TargetPlatform.windows: ShoalPageTransitionsBuilder(),
          TargetPlatform.fuchsia: ShoalPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: ShoalColor.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: ShoalType.title,
        iconTheme: IconThemeData(color: ShoalColor.textSecondary, size: 20),
      ),
      // Cards are defined by a hairline, not a shadow.
      cardTheme: CardThemeData(
        color: ShoalColor.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShoalRadius.md),
          side: hairline,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ShoalColor.surface,
        hintStyle: const TextStyle(color: ShoalColor.textMuted, fontSize: 15),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: ShoalSpace.s4,
          vertical: ShoalSpace.s3,
        ),
        border: _inputBorder(ShoalColor.border),
        enabledBorder: _inputBorder(ShoalColor.border),
        focusedBorder: _inputBorder(ShoalColor.accent),
        errorBorder: _inputBorder(ShoalColor.danger),
        focusedErrorBorder: _inputBorder(ShoalColor.danger),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ShoalColor.surfaceElevated,
        contentTextStyle: ShoalType.secondary
            .copyWith(color: ShoalColor.textPrimary, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShoalRadius.sm),
          side: hairline,
        ),
        insetPadding: const EdgeInsets.all(ShoalSpace.s4),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: ShoalColor.surface,
        modalBackgroundColor: ShoalColor.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: ShoalColor.scrim,
        shape: sheetShape,
        showDragHandle: true,
        dragHandleColor: ShoalColor.borderStrong,
        dragHandleSize: Size(32, 3),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: ShoalColor.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: ShoalType.heading,
        contentTextStyle: ShoalType.secondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShoalRadius.lg),
          side: hairline,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: ShoalColor.textSecondary,
        textColor: ShoalColor.textPrimary,
        minVerticalPadding: ShoalSpace.s3,
      ),
      dividerTheme: const DividerThemeData(
        color: ShoalColor.border,
        thickness: 1,
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? ShoalColor.textOnAccent
                : ShoalColor.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? ShoalColor.accent
                : ShoalColor.surfaceElevated),
        trackOutlineColor:
            const WidgetStatePropertyAll(ShoalColor.borderStrong),
      ),
      // A quiet highlight rather than Material's expanding ink, which fights
      // the flat surfaces.
      splashFactory: NoSplash.splashFactory,
      highlightColor: ShoalColor.surfaceElevated,
      // Focus must be visible for keyboard users; this is not optional.
      focusColor: ShoalColor.accent,
      textTheme: const TextTheme(
        titleLarge: ShoalType.title,
        titleMedium: ShoalType.heading,
        bodyLarge: ShoalType.body,
        bodyMedium: ShoalType.secondary,
        labelSmall: ShoalType.meta,
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(ShoalRadius.sm),
        borderSide: BorderSide(color: color, width: 1),
      );
}

/// A short fade with a small rise. Enough to show that a new surface arrived,
/// short enough never to sit between the user and their next action. Collapses
/// to an instant cut when the platform asks for reduced motion.
class ShoalPageTransitionsBuilder extends PageTransitionsBuilder {
  const ShoalPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (ShoalMotion.reduced(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: ShoalMotion.enter,
      reverseCurve: ShoalMotion.exit,
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
class ShoalScrollBehavior extends MaterialScrollBehavior {
  const ShoalScrollBehavior();

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
