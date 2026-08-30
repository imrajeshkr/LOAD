import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_colors.dart';

/// Shape tokens from the v2 handoff.
class AppRadii {
  AppRadii._();
  static const double card = 18; // cards
  static const double cardLg = 20; // larger cards
  static const double inner = 14; // steppers, chips, thumbnails
  static const double sheet = 26; // bottom-sheet top corners
  static const double pill = 22; // buttons, nav bar
  static const double chip = 16;
  // v1 aliases
  static const double button = 22;
  static const double smallButton = 14;
  static const double input = 14;
}

class AppTheme {
  AppTheme._();

  static const String fontFamily = 'Space Grotesk';

  // Dark app → light status-bar glyphs.
  static const SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  );

  static ThemeData get theme {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.page,
      canvasColor: AppColors.page,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: AppColors.accent,
        onPrimary: AppColors.onAccent,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: AppColors.warn,
      ),
      textTheme: _textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceSunken,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: _inputBorder(AppColors.border),
        enabledBorder: _inputBorder(AppColors.border),
        focusedBorder: _inputBorder(AppColors.borderStrong, width: 1.5),
        errorBorder: _inputBorder(AppColors.warn),
        focusedErrorBorder: _inputBorder(AppColors.warn, width: 1.5),
        hintStyle: const TextStyle(
          color: AppColors.textFaint,
          fontWeight: FontWeight.w400,
          fontSize: 13,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.onAccent,
          disabledBackgroundColor: AppColors.border,
          disabledForegroundColor: AppColors.textFaint,
          padding: const EdgeInsets.symmetric(vertical: 17),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceRaised,
        contentTextStyle: const TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w500,
          fontSize: 13,
          color: AppColors.textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 10,
        // Flicked sideways, never down. A downward swipe at the bottom of an
        // iPhone is Reachability, so the system pulls the screen down out from
        // under the very gesture meant to dismiss the toast — the user's swipe
        // gets taken and the message stays.
        dismissDirection: DismissDirection.horizontal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.inner),
          // Without an edge these dissolve into a page of the same colour.
          side: const BorderSide(color: AppColors.borderStrong),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.input),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  // Space Grotesk 400/500/700. -0.01em ≈ -0.24 at 24px.
  static const TextTheme _textTheme = TextTheme(
    headlineMedium: TextStyle(
      fontFamily: fontFamily,
      fontWeight: FontWeight.w700,
      fontSize: 26,
      height: 1.12,
      letterSpacing: -0.26,
      color: AppColors.textPrimary,
    ),
    titleLarge: TextStyle(
      fontFamily: fontFamily,
      fontWeight: FontWeight.w700,
      fontSize: 22,
      height: 1.15,
      letterSpacing: -0.2,
      color: AppColors.textPrimary,
    ),
    titleMedium: TextStyle(
      fontFamily: fontFamily,
      fontWeight: FontWeight.w700,
      fontSize: 14,
      height: 1.2,
      color: AppColors.textPrimary,
    ),
    bodyLarge: TextStyle(
      fontFamily: fontFamily,
      fontWeight: FontWeight.w400,
      fontSize: 13,
      height: 1.55,
      color: AppColors.textSecondary,
    ),
    bodyMedium: TextStyle(
      fontFamily: fontFamily,
      fontWeight: FontWeight.w400,
      fontSize: 12.5,
      height: 1.5,
      color: AppColors.textMuted,
    ),
    bodySmall: TextStyle(
      fontFamily: fontFamily,
      fontWeight: FontWeight.w400,
      fontSize: 11,
      height: 1.45,
      color: AppColors.textMuted,
    ),
    labelSmall: TextStyle(
      fontFamily: fontFamily,
      fontWeight: FontWeight.w400,
      fontSize: 10,
      letterSpacing: 0.8,
      color: AppColors.textMuted,
    ),
  );

  // v1 alias — some not-yet-rewritten screens reference AppTheme.light.
  static ThemeData get light => theme;
}
