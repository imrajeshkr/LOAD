import 'package:flutter/material.dart';

/// Warm, coach-like palette — deliberately not the default AI orange/cream.
/// Base is a warm near-black brown; accent is a muted brick-rose, not orange.
class AppColors {
  AppColors._();

  static const Color background = Color(0xFF1C1714);
  static const Color surface = Color(0xFF26201C);
  static const Color surfaceAlt = Color(0xFF2E2620);
  static const Color border = Color(0xFF3A322C);

  static const Color textPrimary = Color(0xFFF3ECE6);
  static const Color textSecondary = Color(0xFFB8A99C);
  static const Color textTertiary = Color(0xFF8A7B6E);

  /// Primary accent — muted brick-rose, used for CTAs and active state.
  static const Color accent = Color(0xFFC1544B);
  static const Color accentOn = Color(0xFFFBF3EF);

  /// Positive/progress state — warm muted sage, not neon green.
  static const Color positive = Color(0xFF8FA37A);
  static const Color positiveOn = Color(0xFF1B2216);

  /// Caution — injury/pain flags, muted warm gold rather than harsh amber.
  static const Color caution = Color(0xFFC99A4A);
  static const Color cautionBg = Color(0xFF352A1C);

  static const Color error = Color(0xFFCB6157);
}
