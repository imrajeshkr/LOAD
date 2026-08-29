import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/v2_models.dart';
import 'haptics.dart';
import 'planned_sets.dart';
import 'supabase_service.dart';
import 'supabase_service_v2.dart';

enum FlowScreen { lift, review, done }

/// A lift's state on the live rail / board — no lift is "next", each just
/// shows where it stands.
enum LiftState { untouched, inProgress, done, deferred, skipped }

/// One logged set, in progress or committed.
class SetRow {
  double? kg; // null for bodyweight
  int reps;
  SetRow(this.kg, this.reps);
}

/// Owns the in-session state machine for one workout. Created when a session
/// starts, disposed when the finish screen is left. Nothing here mirrors
/// server-derived plan data — the plan is read once into [exercises].
class SessionController extends ChangeNotifier {
  final _svc = SupabaseService.instance;

  final String sessionId;
  final String label;
  final List<PlanExerciseV2> exercises;

  /// 'first_set' | 'every_set' | 'never' — from user_preferences.effort_prompt,
  /// read once at session start (Profile's "Ask how the set felt" toggle).
  final String effortPrompt;

  SessionController({
    required this.sessionId,
    required this.label,
    required this.exercises,
    this.effortPrompt = 'first_set',
    DateTime? startedAt,
    Map<int, ResumedLiftV2> resume = const {},
  }) : _startedAt = startedAt ?? DateTime.now() {
    _sets = List.generate(exercises.length, (_) => <SetRow>[]);
    _entry = List.filled(exercises.length, null);
    _effort = List.filled(exercises.length, null);
    _extra = List.filled(exercises.length, 0);
    _unconfirmed = List.filled(exercises.length, false);
    _order = List.generate(exercises.length, (i) => i);
    _skipped = List.filled(exercises.length, false);
    _planned = List<PlannedSets?>.filled(exercises.length, null);

    // Rehydrate from what's already logged, so "Continue session" actually
    // continues — otherwise every resume silently started blank at lift one.
    var firstIncomplete = 0;
    var foundIncomplete = false;
    for (var i = 0; i < exercises.length; i++) {
      final r = resume[exercises[i].ordinal];
      if (r != null && r.sets.isNotEmpty) {
        _sets[i] = r.sets.map((s) => SetRow(s.$1, s.$2)).toList();
        _entry[i] = r.entryMode;
        _effort[i] = r.effort;
        _unconfirmed[i] = r.unconfirmed;
      }
      if (!foundIncomplete && _sets[i].length < exercises[i].setsTarget) {
        firstIncomplete = i;
        foundIncomplete = true;
      }
    }
    idx = foundIncomplete ? firstIncomplete : 0;

    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
  }

  // ── state ──────────────────────────────────────────────────────────────
  FlowScreen screen = FlowScreen.lift;
  int idx = 0;
  final DateTime _startedAt;

  late List<List<SetRow>> _sets;
  late List<EntryModeV2?> _entry;
  late List<EffortV2?> _effort;
  late List<int> _extra; // delta on planned set count
  late List<bool> _unconfirmed;

  /// One editable row set per exercise, seeded on first view.
  late List<PlannedSets?> _planned;

  /// Display order over [exercises] — the free-order board reorders this, not
  /// the underlying lists. Identity until the lifter drags.
  late List<int> _order;
  bool _orderDirty = false; // reordered this session, not yet "made the plan"

  /// Lifts the lifter skipped today — dropped from the session, not counted as
  /// missed, restorable from the board.
  late List<bool> _skipped;

  bool cuesOpen = true;
  bool askFeel = false;

  // staged (uncommitted) values for the next live set; null = use computed
  double? _stagedKg;
  int? _stagedReps;

  String? situation;

  Timer? _elapsedTimer;
  Timer? _restTimer;
  int? _restRemaining;
  int _restTotal = 0;

  // ── derived ──────────────────────────────────────────────────────────────
  PlanExerciseV2 get ex => exercises[idx];
  List<SetRow> get sets => _sets[idx];
  EntryModeV2? get entry => _entry[idx];
  EffortV2? get effort => _effort[idx];

  int get elapsedMin => DateTime.now().difference(_startedAt).inMinutes;
  String get elapsedLabel {
    final s = DateTime.now().difference(_startedAt).inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  int target(int i) {
    final base = situation == 'time'
        ? (exercises[i].setsTarget < 2 ? exercises[i].setsTarget : 2)
        : exercises[i].setsTarget;
    return (base + _extra[i]).clamp(1, 30);
  }

  double planKg(int i) {
    final e = exercises[i];
    if (e.isBodyweight) return 0;
    if (situation != 'energy') return e.prefillKg;
    final step = e.step;
    return (((e.prefillKg * 0.9) / step).round() * step).toDouble();
  }

  /// Prefill for the next set: explicit edit wins, else previous set today,
  /// else the adaptive plan target computed server-side (weight via [planKg],
  /// reps via the double-progression prefill).
  (double, int) staged() {
    final e = ex;
    final done = _sets[idx];
    final last = done.isNotEmpty ? done.last : null;
    final w = _stagedKg ?? (last?.kg ?? planKg(idx));
    final r = _stagedReps ?? (last?.reps ?? e.prefillReps);
    return (w, r);
  }

  /// The editable rows for the current exercise, seeded on first access from
  /// the same prefill `staged()` used to compute for the next set alone.
  PlannedSets get planned {
    final existing = _planned[idx];
    if (existing != null) {
      existing.grow(target(idx));
      return existing;
    }
    final e = ex;
    final seeded = PlannedSets.seed(
      count: target(idx),
      kg: planKg(idx),
      reps: e.prefillReps,
    );
    _planned[idx] = seeded;
    return seeded;
  }

  void adjustPlanned(int n, {double dKg = 0, int dReps = 0}) {
    planned.adjust(n, dKg: dKg, dReps: dReps);
    notifyListeners();
  }

  bool get exDone => _sets[idx].length >= target(idx);
  bool get resting => _restRemaining != null;
  int get restRemaining => _restRemaining ?? 0;
  String get restClock =>
      '${restRemaining ~/ 60}:${(restRemaining % 60).toString().padLeft(2, '0')}';
  double get restPct => _restTotal == 0 ? 0 : (_restTotal - restRemaining) / _restTotal;

  int setsLogged(int i) => _sets[i].length;
  bool exerciseDeferred(int i) => _entry[i] == EntryModeV2.deferred;

  // ── free-order navigation ──────────────────────────────────────────────
  /// Exercise indices in the lifter's chosen display order.
  List<int> get order => List.unmodifiable(_order);
  bool get orderDirty => _orderDirty;

  /// Where a lift stands — drives the rail/board, no lift is "next".
  LiftState liftState(int i) {
    if (_skipped[i]) return LiftState.skipped;
    if (_entry[i] == EntryModeV2.deferred && _sets[i].isEmpty) return LiftState.deferred;
    if (_sets[i].isEmpty) return LiftState.untouched;
    if (_sets[i].length >= target(i)) return LiftState.done;
    return LiftState.inProgress;
  }

  bool isSkipped(int i) => _skipped[i];

  /// Drop a lift from today: not counted as missed, not auto-filled at the end.
  /// Any sets already logged are cleared from the record; restore brings it
  /// back. Then move on to the next open lift (or finish).
  Future<void> skipLift() async {
    Haptics.tap();
    final i = idx;
    _skipped[i] = true;
    _entry[i] = null;
    _effort[i] = null;
    _unconfirmed[i] = false;
    askFeel = false;
    _stopRest();
    if (_sets[i].isNotEmpty) {
      _sets[i] = [];
      await _persistExercise(); // clears any written sets for this lift
    }
    advance();
  }

  /// Un-skip a lift so it re-joins the session (from the board).
  void restoreLift(int i) {
    if (!_skipped[i]) return;
    _skipped[i] = false;
    notifyListeners();
  }

  bool _isOpenLift(int i) {
    final s = liftState(i);
    return s == LiftState.untouched || s == LiftState.inProgress;
  }

  /// Another lift still needs work — so the primary action reads "Next lift"
  /// rather than "Finish session".
  bool get hasOtherOpenLift => _order.any((j) => j != idx && _isOpenLift(j));

  /// Jump straight to any lift. Rest keeps running — the whole point is you can
  /// go train something else while you recover.
  void goTo(int exIdx) {
    if (exIdx < 0 || exIdx >= exercises.length) return;
    idx = exIdx;
    cuesOpen = _sets[idx].isEmpty;
    askFeel = false;
    _stagedKg = null;
    _stagedReps = null;
    notifyListeners();
  }

  /// Reorder the board (ReorderableList indices).
  void reorderLifts(int fromPos, int toPos) {
    if (toPos > fromPos) toPos -= 1;
    if (fromPos == toPos) return;
    final v = _order.removeAt(fromPos);
    _order.insert(toPos, v);
    _orderDirty = true;
    notifyListeners();
  }

  /// "Make it the plan" — persist the current order to future sessions of this
  /// program day. "Just today" simply leaves [_order] as the session order.
  Future<void> makeOrderThePlan() async {
    final ids = _order.map((i) => exercises[i].exerciseId).toList();
    _orderDirty = false;
    notifyListeners();
    try {
      await _svc.reorderMyDay(ids);
    } catch (_) {/* session order still holds; the plan just didn't persist */}
  }
  /// True once a deferred lift has been given real numbers in the review
  /// screen (tapped open, edited, saved) rather than left to auto-fill.
  bool exerciseConfirmed(int i) => !_unconfirmed[i] && _sets[i].isNotEmpty;

  int get totalSets => _sets.fold(0, (n, l) => n + l.length);
  double get totalVolume => _sets.fold(0.0, (v, l) =>
      v + l.fold(0.0, (s, r) => s + (r.kg ?? 0) * r.reps));

  bool get anyDeferred =>
      _entry.asMap().entries.any((e) => e.value == EntryModeV2.deferred && _unconfirmed[e.key]);

  // ── mutations ────────────────────────────────────────────────────────────
  void adjustStagedWeight(double delta) {
    final e = ex;
    final cur = _stagedKg ?? staged().$1;
    _stagedKg = (cur + delta).clamp(0, 999);
    e.isBodyweight; // no-op guard
    notifyListeners();
  }

  void adjustStagedReps(int delta) {
    final cur = _stagedReps ?? staged().$2;
    _stagedReps = (cur + delta).clamp(1, 99);
    notifyListeners();
  }

  void adjustSet(int setIdx, {double? dKg, int? dReps}) {
    final row = _sets[idx][setIdx];
    if (dKg != null && row.kg != null) row.kg = (row.kg! + dKg).clamp(0, 999);
    if (dReps != null) row.reps = (row.reps + dReps).clamp(1, 99);
    _persist();
    notifyListeners();
  }

  void toggleCues() {
    cuesOpen = !cuesOpen;
    notifyListeners();
  }

  void startLive() {
    _entry[idx] = EntryModeV2.live;
    notifyListeners();
  }

  /// Log the currently-staged set (live mode). Whether this prompts for
  /// effort depends on [effortPrompt]: once after the first set, after every
  /// set, or never (Profile's "Ask how the set felt").
  Future<void> logSet() async {
    final e = ex;
    final st = staged();
    _sets[idx].add(SetRow(e.isBodyweight ? null : st.$1, st.$2));
    _entry[idx] = EntryModeV2.live;
    _stagedKg = null;
    _stagedReps = null;
    cuesOpen = false;

    final n = _sets[idx].length;
    askFeel = switch (effortPrompt) {
      'never' => false,
      'every_set' => true,
      _ => n == 1 && _effort[idx] == null, // first_set (default)
    };

    Haptics.tap();
    await _persist();
    if (!askFeel && n < target(idx)) _startRest(e.restSeconds);
    notifyListeners();
  }

  void setEffort(EffortV2 v) {
    _effort[idx] = v;
    askFeel = false;
    // "easy" bumps next set's weight one step.
    if (v == EffortV2.easy && !ex.isBodyweight) {
      _stagedKg = staged().$1 + ex.step;
    }
    // "all" closes the lift here: shrink target to what was done.
    if (v == EffortV2.all) {
      _extra[idx] = _sets[idx].length - exercises[idx].setsTarget;
      _stopRest();
    } else if (_sets[idx].length < target(idx)) {
      _startRest(ex.restSeconds);
    }
    _persistExercise();
    notifyListeners();
  }

  /// "Done all sets" — fill remaining rows with the staged values.
  Future<void> fillRemaining() async {
    final e = ex;
    final st = staged();
    while (_sets[idx].length < target(idx)) {
      _sets[idx].add(SetRow(e.isBodyweight ? null : st.$1, st.$2));
    }
    _entry[idx] = EntryModeV2.bulk;
    _unconfirmed[idx] = false;
    askFeel = false;
    _stopRest();
    await _persist();
    notifyListeners();
  }

  void deferLift() {
    _entry[idx] = EntryModeV2.deferred;
    _unconfirmed[idx] = true;
    _stopRest();
    notifyListeners();
  }

  void addSet() {
    _extra[idx] += 1;
    _entry[idx] = EntryModeV2.live;
    notifyListeners();
  }

  void removeSet(int setIdx) {
    if (setIdx < _sets[idx].length) {
      _sets[idx].removeAt(setIdx);
      _persist();
    } else {
      _extra[idx] -= 1;
    }
    notifyListeners();
  }

  Future<void> setSituation(String? s) async {
    situation = s;
    _stagedKg = null;
    await _svc.setSituation(sessionId, s);
    notifyListeners();
  }

  /// "Next" is a convenience, not the only path: move to the next still-open
  /// lift in display order (wrapping past the current one), else finish. Rest
  /// stops here because the lifter deliberately moved on from this lift.
  void advance() {
    _stopRest();
    final pos = _order.indexOf(idx);
    for (var k = 1; k <= _order.length; k++) {
      final j = _order[(pos + k) % _order.length];
      if (j != idx && _isOpenLift(j)) {
        goTo(j);
        return;
      }
    }
    _finish();
  }

  void skipRest() {
    _stopRest();
    notifyListeners();
  }

  void addRest() {
    if (_restRemaining == null) return;
    _restRemaining = _restRemaining! + 30;
    _restTotal += 30;
    _svc.setRestTimer(sessionId, startedFromSeconds: _restTotal);
    notifyListeners();
  }

  void _startRest(int seconds) {
    _restTimer?.cancel();
    _restRemaining = seconds;
    _restTotal = seconds;
    _svc.setRestTimer(sessionId, startedFromSeconds: seconds);
    _restTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = (_restRemaining ?? 0) - 1;
      if (left <= 0) {
        _stopRest();
      } else {
        _restRemaining = left;
      }
      notifyListeners();
    });
  }

  void _stopRest() {
    _restTimer?.cancel();
    _restTimer = null;
    if (_restRemaining != null) {
      _restRemaining = null;
      _svc.setRestTimer(sessionId, startedFromSeconds: null);
    }
  }

  void _finish() {
    if (anyDeferred) {
      screen = FlowScreen.review;
    } else {
      _completeAndDone();
    }
    notifyListeners();
  }

  /// Confirm real numbers for a deferred lift, from the review screen's
  /// inline editor — replaces the plan's guessed prefill with what actually
  /// happened, and persists immediately so it survives leaving the screen.
  Future<void> saveDeferredLift(int i, List<(double?, int)> rows) async {
    Haptics.tap();
    _sets[i] = rows.map((r) => SetRow(r.$1, r.$2)).toList();
    _unconfirmed[i] = false;
    await _svc.saveLift(
      sessionId: sessionId,
      exerciseId: exercises[i].exerciseId,
      ordinal: exercises[i].ordinal,
      rows: rows,
      effort: _effort[i],
      entryMode: EntryModeV2.deferred,
      unconfirmed: false,
    );
    notifyListeners();
  }

  /// Called from the finish button when not deferring, and from review.
  Future<void> finishReview() async {
    // Auto-fill any deferred lift the user never touched, at the plan.
    for (var i = 0; i < exercises.length; i++) {
      if (_unconfirmed[i] && _sets[i].isEmpty) {
        final e = exercises[i];
        for (var n = 0; n < target(i); n++) {
          _sets[i].add(SetRow(e.isBodyweight ? null : planKg(i), e.repHigh));
        }
        await _svc.saveLift(
          sessionId: sessionId,
          exerciseId: e.exerciseId,
          ordinal: e.ordinal,
          rows: _sets[i].map((r) => (r.kg, r.reps)).toList(),
          effort: _effort[i],
          entryMode: EntryModeV2.deferred,
          unconfirmed: true,
        );
      }
      _unconfirmed[i] = false;
    }
    await _completeAndDone();
  }

  Future<void> _completeAndDone() async {
    Haptics.success();
    await _svc.finishSession(sessionId, situation: situation);
    screen = FlowScreen.done;
    notifyListeners();
  }

  // ── persistence ──────────────────────────────────────────────────────────
  Future<void> _persist() async {
    final e = ex;
    await _svc.saveLift(
      sessionId: sessionId,
      exerciseId: e.exerciseId,
      ordinal: e.ordinal,
      rows: _sets[idx].map((r) => (r.kg, r.reps)).toList(),
      effort: _effort[idx],
      entryMode: _entry[idx] ?? EntryModeV2.live,
      unconfirmed: _unconfirmed[idx],
    );
  }

  Future<void> _persistExercise() async => _persist();

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _restTimer?.cancel();
    super.dispose();
  }
}
