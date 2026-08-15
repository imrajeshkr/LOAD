import 'package:flutter/services.dart';

/// Thin wrapper over Flutter's built-in haptics/system sound — no extra
/// package needed. Kept to a small, deliberate set of moments (navigation,
/// a logged action, success, error) rather than on every tap, per the
/// house decision: haptics only, no custom sound effects.
class Haptics {
  Haptics._();

  /// Switching tabs, picking an option in a segmented control or list.
  static void selection() => HapticFeedback.selectionClick();

  /// A set logged, a toggle flipped, a quick-add applied — small positive
  /// acknowledgement that something just happened.
  static void tap() => HapticFeedback.lightImpact();

  /// A session finished, a decision resolved, a plan rewritten — a bigger
  /// moment worth a stronger buzz.
  static void success() => HapticFeedback.mediumImpact();

  /// A save/send failed. Deliberately heavier than [tap] so it reads as
  /// distinct from a normal confirmation, not just "a bit more of the same".
  static void error() => HapticFeedback.heavyImpact();

  /// The device's own alert sound — used only for a coach note arriving
  /// while the app is open (the one thing worth an audible ping, per the
  /// house decision: in-app sound only, nothing implemented via a real
  /// push notification).
  static void alert() => SystemSound.play(SystemSoundType.alert);
}
