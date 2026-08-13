// LOAD v2 domain models. Named `*V2` where a v1 name already exists, so both
// can coexist during the rebuild.

/// One exercise as prescribed for today, from `train_screen()`.
class PlanExerciseV2 {
  final String exerciseId;
  final String name;
  final String loadType; // weight_reps | bodyweight_reps | ...
  final int ordinal;
  final int setsTarget;
  final int repLow;
  final int repHigh;
  final int restSeconds;
  final String? demoPath;
  final double? weightStep; // null = bodyweight (no weight control)
  final double prefillKg; // last-session last set, else plan target
  final int prefillReps;
  final List<(double, int)> lastSets; // last completed session, for "last time"
  final List<String> cues;
  final List<String> joints;

  const PlanExerciseV2({
    required this.exerciseId,
    required this.name,
    required this.loadType,
    required this.ordinal,
    required this.setsTarget,
    required this.repLow,
    required this.repHigh,
    required this.restSeconds,
    required this.demoPath,
    required this.weightStep,
    required this.prefillKg,
    required this.prefillReps,
    required this.lastSets,
    required this.cues,
    required this.joints,
  });

  bool get isBodyweight => loadType == 'bodyweight_reps';

  /// Step used by the ± chips: catalog/derived value, else 2.5, else n/a.
  double get step => weightStep ?? 2.5;

  String get prescription {
    final range = repLow == repHigh ? '$repLow' : '$repLow–$repHigh';
    return '$setsTarget × $range';
  }

  /// "40 kg × 8" from the most recent prior session.
  String get lastTimeLabel {
    if (lastSets.isEmpty) return '—';
    final s = lastSets.last;
    if (isBodyweight) return '${s.$2} reps';
    return '${_n(s.$1)} kg × ${s.$2}';
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  factory PlanExerciseV2.fromJson(Map<String, dynamic> j) {
    final rawLast = (j['last_sets'] as List?) ?? const [];
    return PlanExerciseV2(
      exerciseId: j['exercise_id'] as String,
      name: j['name'] as String,
      loadType: (j['load_type'] as String?) ?? 'weight_reps',
      ordinal: (j['ordinal'] as num?)?.toInt() ?? 0,
      setsTarget: (j['sets_target'] as num?)?.toInt() ?? 3,
      repLow: (j['rep_low'] as num?)?.toInt() ?? 8,
      repHigh: (j['rep_high'] as num?)?.toInt() ?? 12,
      restSeconds: (j['rest_seconds'] as num?)?.toInt() ?? 90,
      demoPath: j['demo_path'] as String?,
      weightStep: (j['weight_step'] as num?)?.toDouble(),
      prefillKg: (j['prefill_kg'] as num?)?.toDouble() ?? 0,
      prefillReps: (j['prefill_reps'] as num?)?.toInt() ?? 10,
      lastSets: rawLast
          .whereType<List>()
          .where((p) => p.length >= 2)
          .map((p) => ((p[0] as num?)?.toDouble() ?? 0, (p[1] as num?)?.toInt() ?? 0))
          .toList(),
      cues: ((j['cues'] as List?) ?? const []).cast<String>(),
      joints: ((j['joints'] as List?) ?? const []).cast<String>(),
    );
  }
}

/// The whole Train-tab / today payload from `train_screen()`.
class TrainScreenV2 {
  final DateTime today;
  final bool isRest;
  final String? label;
  final String? sessionId;
  final String? sessionStatus; // in_progress | completed | null
  final DateTime? startedAt;
  final bool paused;
  final List<PlanExerciseV2> exercises;
  final List<WeekDayV2> week;
  final List<UpcomingV2> upcoming;

  const TrainScreenV2({
    required this.today,
    required this.isRest,
    required this.label,
    required this.sessionId,
    required this.sessionStatus,
    required this.startedAt,
    required this.paused,
    required this.exercises,
    required this.week,
    required this.upcoming,
  });

  factory TrainScreenV2.fromJson(Map<String, dynamic> j) => TrainScreenV2(
        today: DateTime.parse(j['today'] as String),
        isRest: j['is_rest'] as bool? ?? false,
        label: j['label'] as String?,
        sessionId: j['session_id'] as String?,
        sessionStatus: j['session_status'] as String?,
        startedAt: j['started_at'] == null ? null : DateTime.parse(j['started_at'] as String),
        paused: j['paused'] as bool? ?? false,
        exercises: ((j['exercises'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(PlanExerciseV2.fromJson)
            .toList(),
        week: ((j['week'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(WeekDayV2.fromJson)
            .toList(),
        upcoming: ((j['upcoming'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(UpcomingV2.fromJson)
            .toList(),
      );
}

class WeekDayV2 {
  final DateTime date;
  final int dow; // 1=Mon..7=Sun
  final bool planned;
  final bool trained;
  final bool isToday;
  const WeekDayV2({
    required this.date,
    required this.dow,
    required this.planned,
    required this.trained,
    required this.isToday,
  });
  factory WeekDayV2.fromJson(Map<String, dynamic> j) => WeekDayV2(
        date: DateTime.parse(j['date'] as String),
        dow: (j['dow'] as num).toInt(),
        planned: j['planned'] as bool? ?? false,
        trained: j['trained'] as bool? ?? false,
        isToday: j['is_today'] as bool? ?? false,
      );
}

class UpcomingV2 {
  final DateTime on;
  final String label;
  final int liftCount;
  const UpcomingV2({required this.on, required this.label, required this.liftCount});
  factory UpcomingV2.fromJson(Map<String, dynamic> j) => UpcomingV2(
        on: DateTime.parse(j['on'] as String),
        label: j['label'] as String? ?? 'Session',
        liftCount: (j['lift_count'] as num?)?.toInt() ?? 0,
      );
}

/// "Could you have done another rep?" — the per-lift effort answer.
/// RIR mapping (D1): easy→3, right→1, all→0.
enum EffortV2 {
  easy('easy', 3),
  right('right', 1),
  all('all', 0);

  final String dbValue;
  final int rir;
  const EffortV2(this.dbValue, this.rir);
}

/// How a lift was entered (session_exercises.entry_mode).
enum EntryModeV2 { live, bulk, deferred }
