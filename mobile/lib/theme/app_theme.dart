import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// One premium midnight identity. [light] and [dark] intentionally return the
/// same theme: the design language is deep navy + electric blue/violet, and a
/// washed-out light variant would break it. Cairo covers Latin AND Arabic
/// glyphs beautifully; other scripts fall back to system fonts automatically.
class AppTheme {
  static ThemeData light() => midnight();
  static ThemeData dark() => midnight();

  static ThemeData midnight() {
    const scheme = ColorScheme.dark(
      primary: AppColors.primaryBlue,
      onPrimary: Colors.white,
      secondary: AppColors.electricCyan,
      onSecondary: Color(0xFF03142F),
      tertiary: AppColors.violet,
      onTertiary: Colors.white,
      surface: AppColors.bg1,
      onSurface: AppColors.textPrimary,
      surfaceContainerHighest: AppColors.bg2,
      error: AppColors.danger,
      onError: Color(0xFF230A12),
      errorContainer: Color(0xFF3A1220),
      onErrorContainer: Color(0xFFFFC2CC),
      outline: AppColors.textSecondary,
      outlineVariant: AppColors.textTertiary,
    );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.bg0,
    );

    final text = GoogleFonts.cairoTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );

    return base.copyWith(
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        headlineSmall: text.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.4),
        labelSmall: text.labelSmall?.copyWith(letterSpacing: 0.2),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.cairo(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.glassFill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.glassBorder),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          backgroundColor: AppColors.primaryBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: GoogleFonts.cairo(fontSize: 17, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          foregroundColor: AppColors.textPrimary,
          side: BorderSide(color: AppColors.glassBorderStrong),
          backgroundColor: AppColors.glassFill,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: GoogleFonts.cairo(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.electricCyan,
          textStyle: GoogleFonts.cairo(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.glassFill,
        hintStyle: GoogleFonts.cairo(color: AppColors.textTertiary),
        labelStyle: GoogleFonts.cairo(color: AppColors.textSecondary),
        prefixIconColor: AppColors.textSecondary,
        suffixIconColor: AppColors.textSecondary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: AppColors.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: AppColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.primaryBlue, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.6),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.sheet,
        modalBackgroundColor: AppColors.sheet,
        showDragHandle: true,
        dragHandleColor: AppColors.textTertiary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.sheet,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: GoogleFonts.cairo(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
        contentTextStyle: GoogleFonts.cairo(
          fontSize: 15,
          color: AppColors.textSecondary,
          height: 1.5,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.sheet,
        contentTextStyle: GoogleFonts.cairo(color: AppColors.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.glassBorder),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : AppColors.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.primaryBlue
                : AppColors.glassFillStrong),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.transparent
                : AppColors.glassBorderStrong),
      ),
      dividerTheme: DividerThemeData(color: AppColors.glassBorder, thickness: 1),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: AppColors.electricCyan),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.glassFill,
        side: BorderSide(color: AppColors.glassBorder),
        labelStyle: GoogleFonts.cairo(color: AppColors.textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

/// Distinct-but-soft speaker accents tuned for the midnight background.
/// Color is never the only cue — the speaker label is always shown as text.
Color speakerColor(BuildContext context, String? speakerId) {
  if (speakerId == null) return AppColors.textSecondary;
  const palette = [
    AppColors.electricCyan,
    Color(0xFFFFB86B), // warm amber
    AppColors.violetBright,
    AppColors.success,
    Color(0xFFFF8FB2), // soft pink
    Color(0xFF7EA6FF), // periwinkle
    Color(0xFFFFA07A), // salmon
    Color(0xFF6BE3D0), // aqua
  ];
  final digits = RegExp(r'\d+').firstMatch(speakerId)?.group(0);
  final index = (int.tryParse(digits ?? '') ?? speakerId.hashCode.abs()) - 1;
  return palette[index % palette.length];
}
