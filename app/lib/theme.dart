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
      scaffoldBackgroundColor: bg,
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
      cardTheme: CardTheme(
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
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceHi,
        contentTextStyle: TextStyle(color: textHi),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
