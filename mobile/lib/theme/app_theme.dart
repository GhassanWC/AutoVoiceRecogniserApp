import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Calm, minimal, travel-friendly look. Cairo covers both Latin and Arabic
/// glyphs well; other scripts fall back to system fonts automatically.
class AppTheme {
  static const _seed = Color(0xFF0F766E); // calm deep teal

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      textTheme: GoogleFonts.cairoTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        titleTextStyle: GoogleFonts.cairo(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: GoogleFonts.cairo(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

/// Distinct-but-soft colors so speakers are easy to tell apart. Color is
/// never the only cue — the speaker label is always shown as text too.
Color speakerColor(BuildContext context, String? speakerId) {
  final scheme = Theme.of(context).colorScheme;
  if (speakerId == null) return scheme.outline;
  const palette = [
    Color(0xFF0E7490), // cyan 700
    Color(0xFFB45309), // amber 700
    Color(0xFF7C3AED), // violet 600
    Color(0xFF15803D), // green 700
    Color(0xFFBE185D), // pink 700
    Color(0xFF4338CA), // indigo 700
    Color(0xFF9A3412), // orange 800
    Color(0xFF0F766E), // teal 700
  ];
  final digits = RegExp(r'\d+').firstMatch(speakerId)?.group(0);
  final index = (int.tryParse(digits ?? '') ?? speakerId.hashCode.abs()) - 1;
  return palette[index % palette.length];
}
