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
  /// Working sets already logged in today's session (any status) for this
  /// lift — drives the plan chip's progress fill when a session is resumed.
  final int doneSets;

  /// Why today's suggested weight is what it is, in the user's language.
  /// Null when nothing interesting happened (weight simply held).
  final String? coachNote;

  /// The suggested weight is a step back after a stall. Never labelled as
  /// such to the user — [coachNote] carries the reason instead.
  final bool isDeload;

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
    this.doneSets = 0,
    this.coachNote,
    this.isDeload = false,
  });

  bool get isBodyweight => loadType == 'bodyweight_reps';

  /// Step used by the ± chips: catalog/derived value, else 2.5, else n/a.
  double get step => weightStep ?? 2.5;

  /// 0..1, clamped — how far into this lift today's session already is.
  double get progress => setsTarget <= 0 ? 0 : (doneSets / setsTarget).clamp(0.0, 1.0);
  bool get inProgress => doneSets > 0 && doneSets < setsTarget;
  bool get isDone => setsTarget > 0 && doneSets >= setsTarget;

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
      doneSets: (j['done_sets'] as num?)?.toInt() ?? 0,
      coachNote: j['coach_note'] as String?,
      isDeload: (j['is_deload'] as bool?) ?? false,
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

  TrainScreenV2 copyWith({List<WeekDayV2>? week}) => TrainScreenV2(
        today: today,
        isRest: isRest,
        label: label,
        sessionId: sessionId,
        sessionStatus: sessionStatus,
        startedAt: startedAt,
        paused: paused,
        exercises: exercises,
        week: week ?? this.week,
        upcoming: upcoming,
      );

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
  /// The scheduled day's label ("Push day"), null on rest days. Only present
  /// once the `train_screen` RPC returns it — older deployments give null,
  /// which the calendar just renders as an untagged day.
  final String? label;
  /// The scheduled program day's id, null on rest days. Used by the swap RPC.
  final String? programDayId;
  /// The day's lift list, for the in-place preview. Provisional loads; empty on
  /// rest days and on older deployments that don't return it.
  final List<UpcomingExerciseV2> exercises;
  const WeekDayV2({
    required this.date,
    required this.dow,
    required this.planned,
    required this.trained,
    required this.isToday,
    this.label,
    this.programDayId,
    this.exercises = const [],
  });

  /// No session scheduled on this day.
  bool get isRest => label == null || label!.isEmpty;

  factory WeekDayV2.fromJson(Map<String, dynamic> j) => WeekDayV2(
        date: DateTime.parse(j['date'] as String),
        dow: (j['dow'] as num).toInt(),
        planned: j['planned'] as bool? ?? false,
        trained: j['trained'] as bool? ?? false,
        isToday: j['is_today'] as bool? ?? false,
        label: j['label'] as String?,
        programDayId: j['program_day_id'] as String?,
        exercises: ((j['exercises'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(UpcomingExerciseV2.fromJson)
            .toList(),
      );

  WeekDayV2 copyWith({
    String? label,
    String? programDayId,
    List<UpcomingExerciseV2>? exercises,
  }) =>
      WeekDayV2(
        date: date,
        dow: dow,
        planned: planned,
        trained: trained,
        isToday: isToday,
        label: label ?? this.label,
        programDayId: programDayId ?? this.programDayId,
        exercises: exercises ?? this.exercises,
      );
}

/// One lift in an upcoming day's preview sheet — provisional until logged.
class UpcomingExerciseV2 {
  final String name;
  final String loadType;
  final int setsTarget;
  final int repLow;
  final int repHigh;
  final double? targetWeightKg;
  const UpcomingExerciseV2({
    required this.name,
    required this.loadType,
    required this.setsTarget,
    required this.repLow,
    required this.repHigh,
    required this.targetWeightKg,
  });
  bool get isBodyweight => loadType == 'bodyweight_reps';
  String get prescription {
    final range = repLow == repHigh ? '$repLow' : '$repLow–$repHigh';
    return '$setsTarget sets · $range reps';
  }
  factory UpcomingExerciseV2.fromJson(Map<String, dynamic> j) => UpcomingExerciseV2(
        name: j['name'] as String? ?? 'Exercise',
        loadType: j['load_type'] as String? ?? 'weight_reps',
        setsTarget: (j['sets_target'] as num?)?.toInt() ?? 3,
        repLow: (j['rep_low'] as num?)?.toInt() ?? 8,
        repHigh: (j['rep_high'] as num?)?.toInt() ?? 12,
        targetWeightKg: (j['target_weight_kg'] as num?)?.toDouble(),
      );
}

class UpcomingV2 {
  final DateTime on;
  final String label;
  final int liftCount;
  final List<UpcomingExerciseV2> exercises;
  const UpcomingV2({
    required this.on,
    required this.label,
    required this.liftCount,
    this.exercises = const [],
  });
  factory UpcomingV2.fromJson(Map<String, dynamic> j) => UpcomingV2(
        on: DateTime.parse(j['on'] as String),
        label: j['label'] as String? ?? 'Session',
        liftCount: (j['lift_count'] as num?)?.toInt() ?? 0,
        exercises: ((j['exercises'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(UpcomingExerciseV2.fromJson)
            .toList(),
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

  static EffortV2? fromDb(String? v) {
    for (final e in EffortV2.values) {
      if (e.dbValue == v) return e;
    }
    return null;
  }
}

/// How a lift was entered (session_exercises.entry_mode).
enum EntryModeV2 { live, bulk, deferred }

extension EntryModeV2Parse on EntryModeV2 {
  static EntryModeV2? fromDb(String? v) {
    for (final e in EntryModeV2.values) {
      if (e.name == v) return e;
    }
    return null;
  }
}

/// One exercise's already-logged progress in an in-progress session, read
/// back when resuming so "Continue session" doesn't start from a blank slate.
class ResumedLiftV2 {
  final int ordinal;
  final EntryModeV2? entryMode;
  final EffortV2? effort;
  final bool unconfirmed;
  final List<(double?, int)> sets; // working, completed sets, in order
  const ResumedLiftV2({
    required this.ordinal,
    required this.entryMode,
    required this.effort,
    required this.unconfirmed,
    required this.sets,
  });
}

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

// ─────────────────────────────────────────────────────────────────────────
// Progress tab
// ─────────────────────────────────────────────────────────────────────────

/// Raw counts from progress_gates(); the client owns the thresholds.
class ProgressGatesV2 {
  final int sessionsTotal;
  final int weeksOfHistory;
  final int maxLiftSessions;
  final int rirAnsweredSets;
  final int weighIns;
  final int proteinDays;
  final int photoCount;

  const ProgressGatesV2({
    required this.sessionsTotal,
    required this.weeksOfHistory,
    required this.maxLiftSessions,
    required this.rirAnsweredSets,
    required this.weighIns,
    required this.proteinDays,
    required this.photoCount,
  });

  // Design thresholds.
  bool get hasStrength => maxLiftSessions >= 3;
  bool get hasEffort => rirAnsweredSets >= 8;
  bool get hasMuscle => weeksOfHistory >= 1;
  bool get hasBody => weighIns >= 7;
  bool get hasConsistency => weeksOfHistory >= 3;

  factory ProgressGatesV2.fromJson(Map<String, dynamic> j) => ProgressGatesV2(
        sessionsTotal: (j['sessions_total'] as num?)?.toInt() ?? 0,
        weeksOfHistory: (j['weeks_of_history'] as num?)?.toInt() ?? 0,
        maxLiftSessions: (j['max_lift_sessions'] as num?)?.toInt() ?? 0,
        rirAnsweredSets: (j['rir_answered_sets'] as num?)?.toInt() ?? 0,
        weighIns: (j['weigh_ins'] as num?)?.toInt() ?? 0,
        proteinDays: (j['protein_days'] as num?)?.toInt() ?? 0,
        photoCount: (j['photo_count'] as num?)?.toInt() ?? 0,
      );
}

/// One row of lift_status(): feeds both the strength tiles and the stall panel.
class LiftStatusV2 {
  final String exerciseId;
  final String name;
  final int sessionsCounted;
  final double? latestTopKg;
  final double? latestE1rmKg;
  final int streakSessions;
  final int streakTopHits;
  final double netChangeKg;
  final String status; // insufficient | stalled | progressing | no_change
  final List<double> e1rmSeries; // oldest-first, for the sparkline
  /// Dated e1rm points (oldest-first), so a tile can slice to its own window
  /// client-side without another round-trip. Parsed from the same series.
  final List<(DateTime, double)> e1rmPoints;
  /// Dated top-set points, for the top-weight readout per window.
  final List<(DateTime, double)> topPoints;

  const LiftStatusV2({
    required this.exerciseId,
    required this.name,
    required this.sessionsCounted,
    required this.latestTopKg,
    required this.latestE1rmKg,
    required this.streakSessions,
    required this.streakTopHits,
    required this.netChangeKg,
    required this.status,
    required this.e1rmSeries,
    this.e1rmPoints = const [],
    this.topPoints = const [],
  });

  bool get stalled => status == 'stalled';

  factory LiftStatusV2.fromJson(Map<String, dynamic> j) {
    final rawSeries = (j['series'] as List?) ?? const [];
    final maps = rawSeries.whereType<Map>().toList();
    DateTime? on(Map p) {
      final v = p['on'];
      return v is String ? DateTime.tryParse(v) : null;
    }
    return LiftStatusV2(
      exerciseId: j['exercise_id'] as String,
      name: j['exercise_name'] as String? ?? '',
      sessionsCounted: (j['sessions_counted'] as num?)?.toInt() ?? 0,
      latestTopKg: (j['latest_top_kg'] as num?)?.toDouble(),
      latestE1rmKg: (j['latest_e1rm_kg'] as num?)?.toDouble(),
      streakSessions: (j['streak_sessions'] as num?)?.toInt() ?? 0,
      streakTopHits: (j['streak_top_hits'] as num?)?.toInt() ?? 0,
      netChangeKg: (j['net_change_kg'] as num?)?.toDouble() ?? 0,
      status: j['status'] as String? ?? 'insufficient',
      e1rmSeries: maps.map((p) => (p['e1rm'] as num?)?.toDouble() ?? 0).toList(),
      e1rmPoints: [
        for (final p in maps)
          if (on(p) != null) (on(p)!, (p['e1rm'] as num?)?.toDouble() ?? 0)
      ],
      topPoints: [
        for (final p in maps)
          if (on(p) != null) (on(p)!, (p['top_kg'] as num?)?.toDouble() ?? 0)
      ],
    );
  }
}

class ConsistencyWeekV2 {
  final DateTime weekStart;
  final int sessionCount;
  final int pausedDays;
  final int target;
  const ConsistencyWeekV2({
    required this.weekStart,
    required this.sessionCount,
    required this.pausedDays,
    required this.target,
  });
  bool get fullyPaused => pausedDays >= 7;
  factory ConsistencyWeekV2.fromJson(Map<String, dynamic> j) => ConsistencyWeekV2(
        weekStart: DateTime.parse(j['week_start'] as String),
        sessionCount: (j['session_count'] as num?)?.toInt() ?? 0,
        pausedDays: (j['paused_days'] as num?)?.toInt() ?? 0,
        target: (j['target'] as num?)?.toInt() ?? 3,
      );
}

class PhotoV2 {
  final DateTime takenOn;
  final String storagePath;
  final double? weightKg;
  const PhotoV2({required this.takenOn, required this.storagePath, required this.weightKg});
  factory PhotoV2.fromJson(Map<String, dynamic> j) => PhotoV2(
        takenOn: DateTime.parse(j['taken_on'] as String),
        storagePath: j['storage_path'] as String? ?? '',
        weightKg: (j['weight_kg'] as num?)?.toDouble(),
      );
}

class PhotoPairV2 {
  final int total;
  final PhotoV2? first;
  final PhotoV2? latest;
  const PhotoPairV2({required this.total, required this.first, required this.latest});
  factory PhotoPairV2.fromJson(Map<String, dynamic> j) => PhotoPairV2(
        total: (j['total'] as num?)?.toInt() ?? 0,
        first: j['first'] == null
            ? null
            : PhotoV2.fromJson((j['first'] as Map).cast<String, dynamic>()),
        latest: j['latest'] == null
            ? null
            : PhotoV2.fromJson((j['latest'] as Map).cast<String, dynamic>()),
      );
}

/// Bodyweight trend derived client-side from the weigh-in series.
class BodyTrendV2 {
  final double? sevenDayAvg;
  final double? kgPerWeek; // negative = losing
  final double? targetKg;
  final List<(DateTime, double)> points; // oldest-first daily weigh-ins

  const BodyTrendV2({
    required this.sevenDayAvg,
    required this.kgPerWeek,
    required this.targetKg,
    required this.points,
  });
}

/// Protein adherence over the trailing week.
class ProteinWeekV2 {
  final int hitDays;
  final int loggedDays;
  final int? targetG;
  final double averageG;
  const ProteinWeekV2({
    required this.hitDays,
    required this.loggedDays,
    required this.targetG,
    required this.averageG,
  });
}

// ─────────────────────────────────────────────────────────────────────────
// Profile tab
// ─────────────────────────────────────────────────────────────────────────

/// The `training_goal` enum ↔ the design's five goal chips. The DB enum has no
/// dedicated "rehab" value, so the last chip maps onto `recomposition`.
enum GoalV2 {
  buildMuscle('build_muscle', 'Build muscle'),
  loseFat('lose_fat', 'Lose fat'),
  strength('strength', 'Get stronger'),
  generalHealth('general_health', 'Stay consistent'),
  recomposition('recomposition', 'Rehab / return');

  final String db;
  final String label;
  const GoalV2(this.db, this.label);

  static GoalV2? fromDb(String v) {
    for (final g in GoalV2.values) {
      if (g.db == v) return g;
    }
    return null;
  }
}

/// Instant preferences — `user_preferences`. Every field writes the moment it
/// is tapped; this holds the local mirror so the switch/segment reflects it.
class PreferencesV2 {
  final bool metric; // units: metric ↔ kg, imperial ↔ lb
  final int defaultRestSeconds;
  final String effortPrompt; // first_set | every_set | never
  final bool autoStartRest;
  final bool keepScreenAwake;
  final bool restEndSound;
  final bool notifyMorning;
  final bool notifyDebrief;
  final bool notifyMissed;
  final bool notifyWeekly;

  const PreferencesV2({
    required this.metric,
    required this.defaultRestSeconds,
    required this.effortPrompt,
    required this.autoStartRest,
    required this.keepScreenAwake,
    required this.restEndSound,
    required this.notifyMorning,
    required this.notifyDebrief,
    required this.notifyMissed,
    required this.notifyWeekly,
  });

  PreferencesV2 copyWith({
    bool? metric,
    int? defaultRestSeconds,
    String? effortPrompt,
    bool? autoStartRest,
    bool? keepScreenAwake,
    bool? restEndSound,
    bool? notifyMorning,
    bool? notifyDebrief,
    bool? notifyMissed,
    bool? notifyWeekly,
  }) =>
      PreferencesV2(
        metric: metric ?? this.metric,
        defaultRestSeconds: defaultRestSeconds ?? this.defaultRestSeconds,
        effortPrompt: effortPrompt ?? this.effortPrompt,
        autoStartRest: autoStartRest ?? this.autoStartRest,
        keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
        restEndSound: restEndSound ?? this.restEndSound,
        notifyMorning: notifyMorning ?? this.notifyMorning,
        notifyDebrief: notifyDebrief ?? this.notifyDebrief,
        notifyMissed: notifyMissed ?? this.notifyMissed,
        notifyWeekly: notifyWeekly ?? this.notifyWeekly,
      );

  factory PreferencesV2.fromJson(Map<String, dynamic> j) => PreferencesV2(
        metric: (j['units'] as String? ?? 'metric') == 'metric',
        defaultRestSeconds: (j['default_rest_seconds'] as num?)?.toInt() ?? 90,
        effortPrompt: j['effort_prompt'] as String? ?? 'first_set',
        autoStartRest: j['auto_start_rest'] as bool? ?? true,
        keepScreenAwake: j['keep_screen_awake'] as bool? ?? true,
        restEndSound: j['rest_end_sound'] as bool? ?? true,
        notifyMorning: j['notify_morning_note'] as bool? ?? true,
        notifyDebrief: j['notify_session_debrief'] as bool? ?? true,
        notifyMissed: j['notify_missed_session'] as bool? ?? true,
        notifyWeekly: j['notify_weekly_review'] as bool? ?? true,
      );
}

/// One "Working around" entry — `user_constraints` joined to `joints`.
class ConstraintV2 {
  final String id;
  final String label;
  final String? side; // left | right | bilateral | null
  final String? jointId;
  final String? jointName;

  const ConstraintV2({
    required this.id,
    required this.label,
    this.side,
    this.jointId,
    this.jointName,
  });

  /// "Left shoulder" — side-prefixed joint, falling back to the free-text label.
  String get display {
    if (jointName == null) return label;
    final s = switch (side) {
      'left' => 'Left ',
      'right' => 'Right ',
      'bilateral' => 'Both ',
      _ => '',
    };
    return '$s${jointName!.toLowerCase()}'.trim().replaceFirstMapped(
        RegExp(r'^\w'), (m) => m.group(0)!.toUpperCase());
  }

  factory ConstraintV2.fromJson(Map<String, dynamic> j) {
    final joint = (j['joints'] as Map?)?.cast<String, dynamic>();
    return ConstraintV2(
      id: j['id'] as String,
      label: j['label'] as String? ?? '',
      side: j['side'] as String?,
      jointId: j['joint_id'] as String?,
      jointName: joint?['name'] as String?,
    );
  }
}

/// Everything the Profile tab renders, from one load.
class ProfileDataV2 {
  final String? displayName;
  final String? email;
  final String? avatarUrl;
  final int sessionsTotal;
  final int weeksTraining;
  final bool paused;
  final List<GoalV2> goals;
  final bool goalIsCoachChoice;
  final double? targetWeightKg;
  final String? targetDirection; // lose | maintain | gain | declined
  final List<int> trainingWeekdays; // ISO 1=Mon..7=Sun
  /// Chosen split: push_pull_legs | upper_lower | full_body | no_preference.
  final String splitPreference;
  final String? experience;   // beginner | intermediate | advanced
  final String? environment;  // commercial_gym | home_gym | bodyweight_only

  /// False when [experience]/[environment] came from a default or backfill
  /// rather than from the lifter. Profile asks once while this is false —
  /// the values drive catalog filtering and the whole progression scheme,
  /// so a wrong guess is not cosmetic.
  final bool intakeConfirmed;
  /// Weekday (ISO 1=Mon..7=Sun) → the session label the plan puts there
  /// ("Push day", "Upper body", …). Empty on rest weekdays / older payloads.
  final Map<int, String> weekdaySlots;
  final double barWeightKg;
  final List<double> plateSizes;
  final double? latestWeightKg;
  final List<ConstraintV2> constraints;
  final PreferencesV2 prefs;

  const ProfileDataV2({
    required this.displayName,
    required this.email,
    this.intakeConfirmed = true,
    this.avatarUrl,
    required this.sessionsTotal,
    required this.weeksTraining,
    required this.paused,
    required this.goals,
    required this.goalIsCoachChoice,
    required this.targetWeightKg,
    required this.targetDirection,
    required this.trainingWeekdays,
    this.splitPreference = 'no_preference',
    this.experience,
    this.environment,
    this.weekdaySlots = const {},
    required this.barWeightKg,
    required this.plateSizes,
    required this.latestWeightKg,
    required this.constraints,
    required this.prefs,
  });

  double get sessionsPerWeek =>
      weeksTraining == 0 ? 0 : sessionsTotal / weeksTraining;

  /// "AK" from the display name; "—" when there's no name yet.
  String get initials {
    final name = displayName?.trim() ?? '';
    if (name.isEmpty) return '—';
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Onboarding
// ─────────────────────────────────────────────────────────────────────────

/// A body-map joint with its silhouette coordinates, from `joints` (v2_0002).
class JointV2 {
  final String id;
  final String slug;
  final String name;
  final String mapView; // front | back | both
  final double mapX; // 0..1, lateral joints store the right side
  final double mapY; // 0..1
  final bool isLateral;

  const JointV2({
    required this.id,
    required this.slug,
    required this.name,
    required this.mapView,
    required this.mapX,
    required this.mapY,
    required this.isLateral,
  });

  factory JointV2.fromJson(Map<String, dynamic> j) => JointV2(
        id: j['id'] as String,
        slug: j['slug'] as String,
        name: j['name'] as String? ?? '',
        mapView: j['map_view'] as String? ?? 'front',
        mapX: (j['map_x'] as num?)?.toDouble() ?? 0.5,
        mapY: (j['map_y'] as num?)?.toDouble() ?? 0.5,
        isLateral: j['is_lateral'] as bool? ?? false,
      );
}

/// One flagged niggle chosen on the body map: a joint + which side.
class OnboardingFlag {
  final String jointId;
  final String jointName;
  final String side; // left | right | bilateral

  const OnboardingFlag({
    required this.jointId,
    required this.jointName,
    required this.side,
  });

  /// "Left shoulder" / "Neck".
  String get label {
    final prefix = switch (side) {
      'left' => 'Left ',
      'right' => 'Right ',
      _ => '',
    };
    return '$prefix${jointName.toLowerCase()}'
        .replaceFirstMapped(RegExp(r'^\w'), (m) => m.group(0)!.toUpperCase());
  }

  String get key => '$jointId|$side';
}

/// Everything the intake collects, submitted in one call at "Build my week".
class OnboardingDraft {
  final List<GoalV2> goals; // empty + coachChoice = "you choose"
  final bool coachChoice;
  final bool metric; // units toggle
  final double bodyweightKg;
  final String targetDirection; // lose | maintain | gain | declined
  final double? targetWeightKg;
  final List<int> weekdaysIso; // 1..7
  final String splitPreference; // full_body | upper_lower | push_pull_legs
  /// beginner | intermediate | advanced — gates exercise difficulty, volume
  /// ceiling, start loads and progression rate.
  final String experience;
  /// commercial_gym | home_gym | bodyweight_only — gates which equipment the
  /// generator may select.
  final String environment;
  final double barWeightKg;
  final bool hasBenched;
  final double? benchStartKg; // calibrated total, null when never benched
  final List<OnboardingFlag> flags;
  final String otherPain;

  const OnboardingDraft({
    required this.goals,
    required this.coachChoice,
    required this.metric,
    required this.bodyweightKg,
    required this.targetDirection,
    required this.targetWeightKg,
    required this.weekdaysIso,
    required this.splitPreference,
    required this.experience,
    required this.environment,
    required this.barWeightKg,
    required this.hasBenched,
    required this.benchStartKg,
    required this.flags,
    required this.otherPain,
  });

  /// The single `training_profiles.goal` (NOT NULL): the lead pick, or general
  /// strength when the user asked the coach to choose.
  GoalV2 get leadGoal => goals.isEmpty ? GoalV2.strength : goals.first;
}

// ─────────────────────────────────────────────────────────────────────────
// Trainer tab
// ─────────────────────────────────────────────────────────────────────────

/// One stat tile inside a coach message card (`card.stats`).
class CoachStatV2 {
  final String value;
  final String label;
  const CoachStatV2({required this.value, required this.label});
  factory CoachStatV2.fromJson(Map<String, dynamic> j) => CoachStatV2(
        value: '${j['value'] ?? ''}',
        label: j['label'] as String? ?? '',
      );
}

/// Structured content snapshotted onto a message (`coach_messages.card`):
/// stat tiles and/or an inline load sparkline.
class CoachCardV2 {
  final List<CoachStatV2> stats;
  final List<double> chartPoints;
  final String? chartStart;
  final String? chartEnd;

  const CoachCardV2({
    required this.stats,
    required this.chartPoints,
    required this.chartStart,
    required this.chartEnd,
  });

  bool get hasStats => stats.isNotEmpty;
  bool get hasChart => chartPoints.length >= 2;

  static CoachCardV2? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final chart = (j['chart'] as Map?)?.cast<String, dynamic>();
    final card = CoachCardV2(
      stats: ((j['stats'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(CoachStatV2.fromJson)
          .toList(),
      chartPoints: ((chart?['points'] as List?) ?? const [])
          .map((p) => (p as num).toDouble())
          .toList(),
      chartStart: chart?['caption_start'] as String?,
      chartEnd: chart?['caption_end'] as String?,
    );
    return (card.hasStats || card.hasChart) ? card : null;
  }
}

/// A pending (or resolved) decision attached to a coach message — the "Go to
/// 45 kg" / "Hold" buttons ride on `coach_proposals`.
class CoachProposalV2 {
  final String id;
  final String kind; // log_sets | adjust_program
  final String status; // pending | accepted | rejected
  final List<String> actionLabels; // [accept, reject] if the payload named them

  const CoachProposalV2({
    required this.id,
    required this.kind,
    required this.status,
    required this.actionLabels,
  });

  bool get pending => status == 'pending';

  factory CoachProposalV2.fromJson(Map<String, dynamic> j) {
    final payload = (j['payload'] as Map?)?.cast<String, dynamic>();
    final labels = ((payload?['actions'] as List?) ?? const []).cast<String>();
    return CoachProposalV2(
      id: j['id'] as String,
      kind: j['kind'] as String? ?? 'adjust_program',
      status: j['status'] as String? ?? 'pending',
      actionLabels: labels,
    );
  }
}

/// One message in the trainer thread — user or assistant, with its receipts,
/// card, category, and read/ack/pin state.
class CoachMessageV2 {
  final String id;
  final bool isUser;
  final String content;
  final DateTime createdAt;
  final String category; // morning_note | session_debrief | decision | ...
  final bool needsAttention;
  final DateTime? readAt;
  final DateTime? acknowledgedAt;
  final DateTime? pinnedUntil;
  final CoachCardV2? card;
  final List<ReceiptV2> receipts;
  final CoachProposalV2? proposal;

  const CoachMessageV2({
    required this.id,
    required this.isUser,
    required this.content,
    required this.createdAt,
    required this.category,
    required this.needsAttention,
    required this.readAt,
    required this.acknowledgedAt,
    required this.pinnedUntil,
    required this.card,
    required this.receipts,
    required this.proposal,
  });

  bool get acknowledged => acknowledgedAt != null;

  /// Pinned and still current (`pinned_until >= today`).
  bool pinnedActiveOn(DateTime today) =>
      pinnedUntil != null &&
      !pinnedUntil!.isBefore(DateTime(today.year, today.month, today.day));

  CoachMessageV2 copyWith({DateTime? acknowledgedAt, CoachProposalV2? proposal}) =>
      CoachMessageV2(
        id: id,
        isUser: isUser,
        content: content,
        createdAt: createdAt,
        category: category,
        needsAttention: needsAttention,
        readAt: readAt,
        acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
        pinnedUntil: pinnedUntil,
        card: card,
        receipts: receipts,
        proposal: proposal ?? this.proposal,
      );

  factory CoachMessageV2.fromJson(Map<String, dynamic> j) {
    final receipts = ((j['receipts'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .toList()
      ..sort((a, b) =>
          ((a['position'] as num?) ?? 0).compareTo((b['position'] as num?) ?? 0));
    final proposals = ((j['proposals'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(CoachProposalV2.fromJson)
        .toList();
    // Prefer a still-pending proposal; else the most recent resolved one.
    CoachProposalV2? proposal;
    for (final p in proposals) {
      if (p.pending) {
        proposal = p;
        break;
      }
    }
    proposal ??= proposals.isEmpty ? null : proposals.first;

    DateTime? ts(String key) =>
        j[key] == null ? null : DateTime.parse(j[key] as String).toLocal();

    return CoachMessageV2(
      id: j['id'] as String,
      isUser: (j['role'] as String?) == 'user',
      content: j['content'] as String? ?? '',
      createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      category: j['category'] as String? ?? 'reply',
      needsAttention: j['needs_attention'] as bool? ?? false,
      readAt: ts('read_at'),
      acknowledgedAt: ts('acknowledged_at'),
      pinnedUntil:
          j['pinned_until'] == null ? null : DateTime.parse(j['pinned_until'] as String),
      card: CoachCardV2.fromJson((j['card'] as Map?)?.cast<String, dynamic>()),
      receipts: receipts.map(ReceiptV2.fromJson).toList(),
      proposal: proposal,
    );
  }
}
