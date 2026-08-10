/// Unit handling.
///
/// Everything is stored in the database in **metric** (kg) regardless of what
/// the user sees, so history stays comparable if they switch preference later.
/// Conversion happens only at the display/input boundary.
///
/// Members live on the enum itself rather than in an extension so callers can
/// use them without importing this file directly.
enum UnitSystem {
  metric,
  imperial;

  static const double _lbPerKg = 2.2046226218;

  static UnitSystem fromId(String? id) => UnitSystem.values.firstWhere(
        (u) => u.name == id,
        orElse: () => UnitSystem.metric,
      );

  String get id => name;

  /// Short label for the weight unit, e.g. "kg" / "lb".
  String get weightLabel => this == UnitSystem.metric ? 'kg' : 'lb';

  /// Short label for body height, e.g. "cm" / "in".
  String get heightLabel => this == UnitSystem.metric ? 'cm' : 'in';

  String get title => this == UnitSystem.metric ? 'Metric' : 'Imperial';

  String get subtitle =>
      this == UnitSystem.metric ? 'kilograms, centimetres' : 'pounds, inches';

  /// Smallest sensible increment when stepping a barbell load.
  double get weightStep => this == UnitSystem.metric ? 2.5 : 5;

  /// kg (stored) -> value shown to the user.
  double fromKg(double kg) => this == UnitSystem.metric ? kg : kg * _lbPerKg;

  /// value entered by the user -> kg (stored).
  double toKg(double value) =>
      this == UnitSystem.metric ? value : value / _lbPerKg;

  /// Formats a stored kg value in the user's units, without the unit suffix.
  /// Trailing ".0" is dropped so loads read as "60" rather than "60.0".
  String formatWeight(double kg, {int decimals = 0}) {
    final v = fromKg(kg);
    if (decimals == 0) return v.round().toString();
    final s = v.toStringAsFixed(decimals);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// Formats a stored kg value including the unit suffix, e.g. "82 kg".
  String formatWeightWithUnit(double kg, {int decimals = 0}) =>
      '${formatWeight(kg, decimals: decimals)} $weightLabel';
}
