import 'package:flutter/material.dart';

/// Warm, coach-like palette — ported directly from the design guide
/// (`.local/design-guides/Fitness Coach App (standalone).html`).
/// Source values were oklch; hex here is the converted sRGB equivalent.
class AppColors {
  AppColors._();

  /// Page background — warm cream. oklch(97% 0.012 50)
  static const Color background = Color(0xFFFCF3EE);

  /// Cards sit on the cream background as plain white.
  static const Color surface = Color(0xFFFFFFFF);

  /// Inputs / inset wells. oklch(95% 0.015 45)
  static const Color inputFill = Color(0xFFF8ECE6);

  /// Hairline dividers inside white cards. oklch(93% 0.02 45)
  static const Color divider = Color(0xFFF4E4DD);

  /// Soft peach used for nudges / welcome-back banners. oklch(93% 0.03 40)
  static const Color peach = Color(0xFFFBE2D9);

  /// Pill background behind small chips ("Guide"). oklch(94% 0.03 40)
  static const Color chipFill = Color(0xFFFEE5DC);

  /// Primary accent — warm brick red. oklch(55% 0.15 25)
  static const Color accent = Color(0xFFB94642);
  static const Color onAccent = Color(0xFFFFFFFF);

  /// Headings. oklch(26% 0.02 30)
  static const Color textPrimary = Color(0xFF2D211E);

  /// Body copy on cards. oklch(28% 0.02 30)
  static const Color textBody = Color(0xFF322523);

  /// Slightly lighter body text. oklch(35% 0.02 35)
  static const Color textMuted = Color(0xFF443734);

  /// Labels and captions. oklch(55% 0.02 40)
  static const Color textSecondary = Color(0xFF7C6E69);

  /// Disabled / faint. oklch(65% 0.02 45)
  static const Color textFaint = Color(0xFF9A8C85);

  /// Inactive tab glyphs. oklch(60% 0.02 45)
  static const Color inactive = Color(0xFF8B7D77);

  /// Injury conflict warning. oklch(55% 0.14 55)
  static const Color warning = Color(0xFFAD5600);

  /// Coach note about a prior session. oklch(50% 0.1 60)
  static const Color note = Color(0xFF8C541F);

  /// Positive / progress. Kept muted so it reads warm, not neon.
  static const Color positive = Color(0xFF006925);
  static const Color positiveSoft = Color(0xFFE3F0E4);

  static const Color error = Color(0xFFB3261E);

  /// Track colour behind progress bars. oklch(90% 0.02 45)
  static const Color track = Color(0xFFEADAD3);
}
