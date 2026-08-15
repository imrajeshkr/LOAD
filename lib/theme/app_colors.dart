import 'package:flutter/material.dart';

/// LOAD v2 palette — dark, from `design_handoff_load_app` tokens.
///
/// Old v1 token names are kept as aliases mapped to their nearest v2 value so
/// not-yet-rewritten screens keep compiling during the rebuild. New screens
/// use the v2 names.
class AppColors {
  AppColors._();

  // ── v2 tokens ──────────────────────────────────────────────────────────
  static const page = Color(0xFF100E0D); // app background, inside the device
  static const pageOuter = Color(0xFF0A0908); // preview only
  static const surface = Color(0xFF1B1817); // cards, panels, inputs, nav
  static const surfaceSunken = Color(0xFF100E0D); // wells inside a card
  static const surfaceRaised = Color(0xFF161413); // bottom sheet
  static const border = Color(0xFF2A2624); // default hairline / card border
  static const borderStrong = Color(0xFF3A3532); // focused field, sheet handle
  static const borderFaint = Color(0xFF221F1D); // dim, not-yet-reached rows

  static const accent = Color(0xFFC8F751); // primary action, positive, active
  static const accentBright = Color(0xFFDCFF7A); // link hover only
  static const accentMid = Color(0xFF9BC93F); // second bar in a ranking
  static const accentDeep = Color(0xFF7FA83A); // third bar; effective-zone label
  static const warn = Color(0xFFFF8A5B); // injury, stall, destructive, shortfall

  static const textPrimary = Color(0xFFF5EFEA); // headings, values
  static const textSecondary = Color(0xFFBDB2AB); // body inside a highlight card
  static const textMuted = Color(0xFF8C817A); // labels, captions
  static const textFaint = Color(0xFF6E655F); // inactive tab icon, disabled
  static const textDim = Color(0xFF5C5450); // rarely — never must-read
  static const inactiveFill = Color(0xFF4E4744); // chart dots, dim glyphs

  static const onAccent = Color(0xFF100E0D); // text/icon on the lime accent

  // ── v1 aliases (mapped to v2; remove as screens are rewritten) ───────────
  static const background = page;
  static const inputFill = surfaceSunken;
  static const divider = border;
  static const chipFill = surfaceSunken;
  static const peach = surface;
  static const positive = accent;
  static const positiveSoft = Color(0xFF243015);
  static const warning = warn;
  static const note = warn;
  static const error = warn;
  static const textBody = textSecondary;
  static const inactive = textFaint;
  static const track = border;
}
