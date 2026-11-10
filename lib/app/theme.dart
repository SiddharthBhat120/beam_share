import 'package:flutter/material.dart';

/// Brand colors and the light/dark themes.
///
/// One accent per direction makes the app easy to read at a glance:
/// indigo/violet = sending, teal/cyan = receiving.
class BeamColors {
  static const indigo = Color(0xFF5B5BF7);
  static const violet = Color(0xFF9B5CF6);
  static const teal = Color(0xFF14C8A8);
  static const cyan = Color(0xFF22B8F0);
  static const success = Color(0xFF22C55E);
  static const danger = Color(0xFFEF4444);

  static const sendGradient = LinearGradient(
    colors: [indigo, violet],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const receiveGradient = LinearGradient(
    colors: [teal, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: BeamColors.indigo,
    brightness: brightness,
  ).copyWith(
    primary: BeamColors.indigo,
    secondary: BeamColors.teal,
    surface: dark ? const Color(0xFF0F1020) : const Color(0xFFF7F7FC),
    surfaceContainerHighest: dark ? const Color(0xFF1C1E33) : const Color(0xFFE9E9F5),
    surfaceContainer: dark ? const Color(0xFF16182A) : Colors.white,
    error: BeamColors.danger,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.25 : 0.5)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
  );
}
