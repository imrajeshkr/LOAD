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

// ─────────────────────────────────────────────────────────────────────────
// After-state: session_summary()
// ─────────────────────────────────────────────────────────────────────────

class SessionSummaryV2 {
  final String label;
  final DateTime performedOn;
  final String? situation;
  final int? durationMin;
  final int setCount;
  final double volumeKg;
  final int exerciseCount;
  final double? lastSameVolume; // previous same-label session volume, if any
  final List<SummaryExerciseV2> exercises;
  final List<MuscleChipV2> muscles;
  final List<TrendPointV2> trend;
  final List<PbV2> pbs;

  const SessionSummaryV2({
    required this.label,
    required this.performedOn,
    required this.situation,
    required this.durationMin,
    required this.setCount,
    required this.volumeKg,
    required this.exerciseCount,
    required this.lastSameVolume,
    required this.exercises,
    required this.muscles,
    required this.trend,
    required this.pbs,
  });

  /// Signed "+155 vs last push" delta, or null when there's no prior session.
  double? get vsLastDelta =>
      lastSameVolume == null ? null : volumeKg - lastSameVolume!;

  factory SessionSummaryV2.fromJson(Map<String, dynamic> j) {
    final totals = (j['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final last = (j['last_same'] as Map?)?.cast<String, dynamic>();
    return SessionSummaryV2(
      label: j['label'] as String? ?? 'Session',
      performedOn: DateTime.parse(j['performed_on'] as String),
      situation: j['situation'] as String?,
      durationMin: (j['duration_min'] as num?)?.toInt(),
      setCount: (totals['set_count'] as num?)?.toInt() ?? 0,
      volumeKg: (totals['volume_kg'] as num?)?.toDouble() ?? 0,
      exerciseCount: (totals['exercise_count'] as num?)?.toInt() ?? 0,
      lastSameVolume: (last?['volume_kg'] as num?)?.toDouble(),
      exercises: ((j['exercises'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(SummaryExerciseV2.fromJson)
          .toList(),
      muscles: ((j['muscles'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(MuscleChipV2.fromJson)
          .toList(),
      trend: ((j['trend'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(TrendPointV2.fromJson)
          .toList(),
      pbs: ((j['pbs'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(PbV2.fromJson)
          .toList(),
    );
  }
}

class SummaryExerciseV2 {
  final String name;
  final String loadType;
  final int ordinal;
  final double volumeKg;
  final int totalReps;
  final int setCount;
  final double? topKg;
  final List<(double?, int)> sets;

  const SummaryExerciseV2({
    required this.name,
    required this.loadType,
    required this.ordinal,
    required this.volumeKg,
    required this.totalReps,
    required this.setCount,
    required this.topKg,
    required this.sets,
  });

  bool get isBodyweight => loadType == 'bodyweight_reps';

  factory SummaryExerciseV2.fromJson(Map<String, dynamic> j) {
    final rawSets = (j['sets'] as List?) ?? const [];
    return SummaryExerciseV2(
      name: j['name'] as String,
      loadType: (j['load_type'] as String?) ?? 'weight_reps',
      ordinal: (j['ordinal'] as num?)?.toInt() ?? 0,
      volumeKg: (j['volume_kg'] as num?)?.toDouble() ?? 0,
      totalReps: (j['total_reps'] as num?)?.toInt() ?? 0,
      setCount: (j['set_count'] as num?)?.toInt() ?? 0,
      topKg: (j['top_kg'] as num?)?.toDouble(),
      sets: rawSets
          .whereType<List>()
          .where((p) => p.length >= 2)
          .map((p) => ((p[0] as num?)?.toDouble(), (p[1] as num?)?.toInt() ?? 0))
          .toList(),
    );
  }
}

class MuscleChipV2 {
  final String group;
  final int sets;
  const MuscleChipV2({required this.group, required this.sets});
  factory MuscleChipV2.fromJson(Map<String, dynamic> j) => MuscleChipV2(
        group: j['group'] as String? ?? '',
        sets: (j['sets'] as num?)?.toInt() ?? 0,
      );
}

class TrendPointV2 {
  final DateTime on;
  final double volumeKg;
  const TrendPointV2({required this.on, required this.volumeKg});
  factory TrendPointV2.fromJson(Map<String, dynamic> j) => TrendPointV2(
        on: DateTime.parse(j['on'] as String),
        volumeKg: (j['volume_kg'] as num?)?.toDouble() ?? 0,
      );
}

class PbV2 {
  final String name;
  final double? kg;
  final int reps;
  final int? prevReps;
  const PbV2({required this.name, required this.kg, required this.reps, required this.prevReps});
  factory PbV2.fromJson(Map<String, dynamic> j) => PbV2(
        name: j['name'] as String? ?? '',
        kg: (j['kg'] as num?)?.toDouble(),
        reps: (j['reps'] as num?)?.toInt() ?? 0,
        prevReps: (j['prev_reps'] as num?)?.toInt(),
      );
}

/// One row of `progression_suggestions()` — "next time these go up".
class ProgressionV2 {
  final String exerciseId;
  final String name;
  final double? currentKg;
  final double? suggestedKg;
  final double deltaKg;
  final String reason; // up | grind | unconfirmed | top_of_range | ...

  const ProgressionV2({
    required this.exerciseId,
    required this.name,
    required this.currentKg,
    required this.suggestedKg,
    required this.deltaKg,
    required this.reason,
  });

  bool get goesUp => deltaKg > 0;

  /// Human copy keyed off the reason enum from the RPC.
  String get reasonLabel => switch (reason) {
        'reps_in_reserve' => 'Had reps to spare',
        'top_of_range' => 'Hit the top of the range',
        'grind' => 'That was everything — hold',
        'unconfirmed' => 'Last time was auto-filled — hold',
        'building_reps' => 'Still building reps — hold',
        'no_history' => 'No history yet',
        _ => 'Hold',
      };

  factory ProgressionV2.fromJson(Map<String, dynamic> j) => ProgressionV2(
        exerciseId: j['exercise_id'] as String,
        name: j['name'] as String? ?? '',
        currentKg: (j['current_kg'] as num?)?.toDouble(),
        suggestedKg: (j['suggested_kg'] as num?)?.toDouble(),
        deltaKg: (j['delta_kg'] as num?)?.toDouble() ?? 0,
        reason: j['reason'] as String? ?? 'no_history',
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Before-state extras: morning note + body/fuel
// ─────────────────────────────────────────────────────────────────────────

class MorningNoteV2 {
  final String id;
  final String content;
  final DateTime createdAt;
  final bool pinned;
  final DateTime? readAt;
  final DateTime? acknowledgedAt;
  final List<ReceiptV2> receipts;

  const MorningNoteV2({
    required this.id,
    required this.content,
    required this.createdAt,
    required this.pinned,
    required this.readAt,
    required this.acknowledgedAt,
    required this.receipts,
  });

  factory MorningNoteV2.fromJson(Map<String, dynamic> j) => MorningNoteV2(
        id: j['id'] as String,
        content: j['content'] as String? ?? '',
        createdAt: DateTime.parse(j['created_at'] as String),
        pinned: j['pinned_until'] != null,
        readAt: j['read_at'] == null ? null : DateTime.parse(j['read_at'] as String),
        acknowledgedAt: j['acknowledged_at'] == null
            ? null
            : DateTime.parse(j['acknowledged_at'] as String),
        receipts: ((j['receipts'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ReceiptV2.fromJson)
            .toList(),
      );
}

class ReceiptV2 {
  final String icon;
  final String label;
  const ReceiptV2({required this.icon, required this.label});
  factory ReceiptV2.fromJson(Map<String, dynamic> j) => ReceiptV2(
        icon: j['icon'] as String? ?? 'check',
        label: j['label'] as String? ?? '',
      );
}

class BodyFuelV2 {
  final double? weightKg;
  final double proteinG;
  final int? proteinTargetG;

  const BodyFuelV2({
    required this.weightKg,
    required this.proteinG,
    required this.proteinTargetG,
  });

  int? get proteinShortfall => proteinTargetG == null
      ? null
      : (proteinTargetG! - proteinG).round().clamp(0, 1 << 30);
}
