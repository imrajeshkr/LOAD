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

  /// Rows the lifter has changed by hand. Everything else is still a default,
  /// and defaults follow the row above them.
  final Set<int> _touched = {};

  PlannedSets.seed({required int count, required double kg, required int reps})
      : _kg = List<double>.filled(count, kg, growable: true),
        _reps = List<int>.filled(count, reps, growable: true);

  int get length => _kg.length;

  (double, int) at(int n) => (_kg[n], _reps[n]);

  /// Nudge one row, and carry it down.
  ///
  /// Setting the first set to 60 kg and then repeating that on rows two,
  /// three and four is the same number typed four times — nobody warms up to
  /// a working weight and then wants the rest of the sets left at the old
  /// one. So the rows below follow, but only while they are still defaults:
  /// a row the lifter has deliberately set keeps its value, because a heavy
  /// top set followed by lighter back-offs is a real thing to want and
  /// silently overwriting it would be worse than not helping at all.
  ///
  /// Weight floors at 0 (an empty bar is a real answer) and reps floor at 1
  /// (a logged set with zero reps is not a set).
  void adjust(int n, {double dKg = 0, int dReps = 0}) {
    if (n < 0 || n >= _kg.length) return;
    // Snapped to a half kilo — the finest thing anyone can actually load, and
    // the grid the whole app promises. A quarter-kilo grid was worse than
    // useless: it let 10.25 exist, which renders as "10.3" and reads as a
    // rounding bug. Snapping also absorbs binary drift, which matters because
    // twenty raw additions of 0.5 land on 22.500000000000004.
    _kg[n] = _snap((_kg[n] + dKg).clamp(0, 999).toDouble());
    _reps[n] = (_reps[n] + dReps).clamp(1, 100);
    _touched.add(n);
    for (var i = n + 1; i < _kg.length; i++) {
      if (_touched.contains(i)) continue;
      _kg[i] = _kg[n];
      _reps[i] = _reps[n];
    }
  }

  /// True when this row has been set by hand rather than inherited.
  bool isTouched(int n) => _touched.contains(n);

  static double _snap(double kg) => (kg * 2).round() / 2;

  /// Extend to [count] rows, carrying the last row's values forward — a lifter
  /// adding a fourth set almost always wants what they just did.
  void grow(int count) {
    while (_kg.length < count) {
      _kg.add(_kg.isEmpty ? 0 : _kg.last);
      _reps.add(_reps.isEmpty ? 1 : _reps.last);
    }
  }

  /// A set was logged, so the rows after it inherit what was actually done
  /// rather than what was planned before the lifter changed their mind on the
  /// platform. Untouched rows only, same rule as [adjust].
  void carryFrom(int n, double kg, int reps) {
    for (var i = n + 1; i < _kg.length; i++) {
      if (_touched.contains(i)) continue;
      _kg[i] = _snap(kg);
      _reps[i] = reps;
    }
  }
}
