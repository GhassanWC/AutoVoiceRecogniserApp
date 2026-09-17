import 'package:flutter/material.dart';

/// The Sayvo design language: deep midnight navy, electric
/// blue→violet gradients, glass surfaces. One identity — the app is
/// deliberately dark-first; there is no separate light theme.
abstract final class AppColors {
  // ── Midnight backgrounds ────────────────────────────────────────────────
  static const Color bg0 = Color(0xFF03142F);
  static const Color bg1 = Color(0xFF061C42);
  static const Color bg2 = Color(0xFF082757);

  /// Opaque surface for sheets/dialogs (glass over-draw is unreadable there).
  static const Color sheet = Color(0xFF0A2350);

  // ── Brand accents ───────────────────────────────────────────────────────
  static const Color primaryBlue = Color(0xFF2979FF);
  static const Color electricCyan = Color(0xFF21C8FF);
  static const Color violet = Color(0xFF7755FF);
  static const Color violetBright = Color(0xFF914CFF);

  // ── Text ────────────────────────────────────────────────────────────────
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFA8B8D8);
  static const Color textTertiary = Color(0xFF7D90B8);

  // ── Feedback ────────────────────────────────────────────────────────────
  static const Color danger = Color(0xFFFF6B81);
  static const Color success = Color(0xFF3DDC97);

  // ── Glass ───────────────────────────────────────────────────────────────
  static Color glassFill = Colors.white.withValues(alpha: 0.07);
  static Color glassFillStrong = Colors.white.withValues(alpha: 0.11);
  static Color glassBorder = Colors.white.withValues(alpha: 0.12);
  static Color glassBorderStrong = Colors.white.withValues(alpha: 0.22);

  // ── Gradients ───────────────────────────────────────────────────────────
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryBlue, violet],
  );

  static const LinearGradient orbGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [electricCyan, primaryBlue, violetBright],
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bg2, bg1, bg0],
  );
}
