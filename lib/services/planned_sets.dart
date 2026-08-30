/// The rows a lifter sees for one exercise before any of them are logged.
///
/// Exists because the session used to keep a single staged weight/reps pair,
/// which can only ever describe the NEXT set. The screen now shows every set
/// prefilled and individually adjustable, so each row needs its own value.
///
/// Deliberately free of Flutter and Supabase so it can be tested on its own.
class PlannedSets {
  final List<double> _kg;
  final List<int> _reps;

  PlannedSets.seed({required int count, required double kg, required int reps})
      : _kg = List<double>.filled(count, kg, growable: true),
        _reps = List<int>.filled(count, reps, growable: true);

  int get length => _kg.length;

  (double, int) at(int n) => (_kg[n], _reps[n]);

  /// Nudge one row. Weight floors at 0 (an empty bar is a real answer) and
  /// reps floor at 1 (a logged set with zero reps is not a set).
  void adjust(int n, {double dKg = 0, int dReps = 0}) {
    if (n < 0 || n >= _kg.length) return;
    // Snapped to a quarter kilo. Half-kilo steps accumulate binary error —
    // twenty additions of 0.5 lands on 22.500000000000004, which formats fine
    // today and compares wrong forever.
    _kg[n] = _snap((_kg[n] + dKg).clamp(0, 999).toDouble());
    _reps[n] = (_reps[n] + dReps).clamp(1, 100);
  }

  static double _snap(double kg) => (kg * 4).round() / 4;

  /// Extend to [count] rows, carrying the last row's values forward — a lifter
  /// adding a fourth set almost always wants what they just did.
  void grow(int count) {
    while (_kg.length < count) {
      _kg.add(_kg.isEmpty ? 0 : _kg.last);
      _reps.add(_reps.isEmpty ? 1 : _reps.last);
    }
  }
}
