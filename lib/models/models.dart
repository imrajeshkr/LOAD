import 'units.dart';

/// Maps between the human-readable option strings the onboarding and settings
/// screens are built from, and the Postgres enum values the v2 schema stores.
///
/// The UI is the source of truth for the labels — these tables exist so that
/// the screens can keep using them verbatim while the database gets proper
/// enums. Keep them in sync with the option lists in
/// `lib/screens/onboarding/onboarding_flow.dart` and
/// `lib/screens/settings/settings_screen.dart`.
class _Enum {
  const _Enum._();

  static const goal = {
    'Build muscle': 'build_muscle',
    'Lose fat': 'lose_fat',
    'Recomposition': 'recomposition',
    'General health': 'general_health',
    'Strength': 'strength',
  };

  static const experience = {
    'Beginner': 'beginner',
    'Intermediate': 'intermediate',
    'Advanced': 'advanced',
  };

  static const environment = {
    'Full gym': 'commercial_gym',
    'Dumbbells': 'home_gym',
    'Bodyweight': 'bodyweight_only',
  };

  static const split = {
    'Push / Pull / Legs': 'push_pull_legs',
    'Upper / Lower': 'upper_lower',
    'Full body': 'full_body',
    'No preference': 'no_preference',
  };

  /// db value -> display label. Unknown values fall through to null so a
  /// schema addition shows as "unset" rather than as a raw enum string.
  static String? label(Map<String, String> table, String? dbValue) {
    if (dbValue == null) return null;
    for (final e in table.entries) {
      if (e.value == dbValue) return e.key;
    }
    return null;
  }
}

class Profile {
  /// Human-readable labels, exactly as chosen in the UI option lists.
  String? goal;
  String? experience;
  int daysPerWeek;
  String? environment;
  String? splitPref;

  /// Free text, round-tripped through `user_constraints.label`.
  String injuries;

  /// Stored in kilograms regardless of display preference.
  double? currentWeightKg;
  double? targetWeightKg;

  UnitSystem units;

  Profile({
    this.goal,
    this.experience,
    this.daysPerWeek = 4,
    this.environment,
    this.splitPref,
    this.injuries = '',
    this.currentWeightKg,
    this.targetWeightKg,
    this.units = UnitSystem.metric,
  });

  /// Assembles a profile from the three tables it now lives across:
  /// [preferences] (`user_preferences`), [training] (the current
  /// `training_profiles` row, i.e. `valid_to is null`), plus the derived
  /// bodyweight and injury text.
  factory Profile.fromRows({
    Map<String, dynamic>? preferences,
    Map<String, dynamic>? training,
    double? currentWeightKg,
    String injuries = '',
  }) => Profile(
    goal: _Enum.label(_Enum.goal, training?['goal'] as String?),
    experience: _Enum.label(
      _Enum.experience,
      training?['experience'] as String?,
    ),
    daysPerWeek: (training?['days_per_week'] as int?) ?? 4,
    environment: _Enum.label(
      _Enum.environment,
      training?['environment'] as String?,
    ),
    splitPref: _Enum.label(
      _Enum.split,
      training?['split_preference'] as String?,
    ),
    injuries: injuries,
    currentWeightKg: currentWeightKg,
    targetWeightKg: (training?['target_weight_kg'] as num?)?.toDouble(),
    units: UnitSystem.fromId(preferences?['units'] as String?),
  );

  // ── enum values for the write side ───────────────────────────────────
  String? get goalValue => goal == null ? null : _Enum.goal[goal];
  String? get experienceValue =>
      experience == null ? null : _Enum.experience[experience];
  String? get environmentValue =>
      environment == null ? null : _Enum.environment[environment];
  String get splitPrefValue =>
      (splitPref == null ? null : _Enum.split[splitPref]) ?? 'no_preference';

  /// The `training_profiles` payload. Null when the required enum columns
  /// aren't all answered yet — the table declares them NOT NULL.
  Map<String, dynamic>? toTrainingProfileMap() {
    final g = goalValue, e = experienceValue, env = environmentValue;
    if (g == null || e == null || env == null) return null;
    return {
      'goal': g,
      'experience': e,
      'environment': env,
      'split_preference': splitPrefValue,
      'days_per_week': daysPerWeek,
      'target_weight_kg': targetWeightKg,
    };
  }

  bool get isComplete =>
      goal != null &&
      experience != null &&
      environment != null &&
      splitPref != null;

  /// Daily protein target in grams — 1.8 g per kg of bodyweight, a common
  /// recommendation for people training for muscle. Falls back to a flat
  /// target until a weigh-in exists.
  int get proteinTargetG {
    final kg = currentWeightKg;
    if (kg == null || kg <= 0) return 120;
    return (kg * 1.8).round();
  }
}

/// How far through an exercise's prescription the lifter is today.
enum SetProgress { none, partial, complete }

/// How a completed-session breakdown row compares to last time.
enum DeltaTone { positive, neutral, warning }

/// A block of actual work on one exercise — used for both what was done last
/// time (`last`) and what has been logged today (`today`).
///
/// This is the thing the Today card was missing: a result, not a prescription.
class ExerciseEffort {
  /// The sets as performed, in order. Weights are kilograms.
  final List<LoggedSet> sets;

  /// Tonnage, i.e. Σ weight × reps, in kilograms. Zero for bodyweight work.
  final double volumeKg;

  /// Σ reps — the honest measure when the load isn't a number.
  final int totalReps;

  /// The day the work was done. Null for the in-progress `today` block.
  final DateTime? date;

  const ExerciseEffort({
    required this.sets,
    this.volumeKg = 0,
    this.totalReps = 0,
    this.date,
  });

  bool get isEmpty => sets.isEmpty;

  /// `sets` arrives as an array of `[weight_kg, reps]` pairs.
  static ExerciseEffort? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final raw = (json['sets'] as List?) ?? const [];
    final sets = <LoggedSet>[];
    for (final pair in raw) {
      if (pair is! List || pair.length < 2) continue;
      sets.add(
        LoggedSet(
          weightKg: (pair[0] as num?)?.toDouble() ?? 0,
          reps: (pair[1] as num?)?.toInt() ?? 0,
        ),
      );
    }
    if (sets.isEmpty) return null;

    final date = json['date'] as String?;
    return ExerciseEffort(
      sets: sets,
      volumeKg: (json['volume_kg'] as num?)?.toDouble() ?? 0,
      totalReps:
          (json['total_reps'] as num?)?.toInt() ??
          sets.fold(0, (n, s) => n + s.reps),
      date: date == null ? null : DateTime.parse(date),
    );
  }
}

class ExerciseSpec {
  /// `exercises.id` — the catalog row this slot prescribes.
  final String id;
  final String name;
  final int setsTarget;
  final int reps;

  /// Working weight in kilograms.
  final double weightKg;

  /// `exercises.load_type` — one of weight_reps, bodyweight_reps,
  /// weighted_bodyweight, assisted_bodyweight, time, distance.
  final String loadType;

  /// Prescribed rep range. [reps] stays the top of the range for callers that
  /// only want one number.
  final int repLow;
  final int repHigh;

  final int restSeconds;

  /// What to start the steppers on: what they actually lifted last time,
  /// never a pre-progressed number.
  final double prefillKg;
  final int prefillReps;

  /// Joint slugs this movement loads, from `exercise_joints`.
  final List<String> joints;

  /// Form cues from `exercise_cues`, in `position` order.
  final List<String> cues;

  /// The last completed effort on this movement, if there is one.
  final ExerciseEffort? last;

  /// What has been logged today — through any path, including chat.
  final ExerciseEffort? today;

  /// Object path within the public `exercise-media` bucket, e.g.
  /// "exercise-guide-web/bench-press.webp". Null means no demo asset yet.
  final String? demoPath;

  const ExerciseSpec({
    required this.id,
    required this.name,
    required this.setsTarget,
    required this.reps,
    required this.weightKg,
    this.loadType = 'weight_reps',
    int? repLow,
    int? repHigh,
    this.restSeconds = 90,
    double? prefillKg,
    int? prefillReps,
    this.joints = const [],
    this.cues = const [],
    this.last,
    this.today,
    this.demoPath,
  }) : repLow = repLow ?? reps,
       repHigh = repHigh ?? reps,
       prefillKg = prefillKg ?? weightKg,
       prefillReps = prefillReps ?? reps;

  ExerciseSpec copyWith({
    int? setsTarget,
    int? reps,
    double? weightKg,
    ExerciseEffort? last,
    ExerciseEffort? today,
  }) => ExerciseSpec(
    id: id,
    name: name,
    setsTarget: setsTarget ?? this.setsTarget,
    reps: reps ?? this.reps,
    weightKg: weightKg ?? this.weightKg,
    loadType: loadType,
    repLow: repLow,
    repHigh: repHigh,
    restSeconds: restSeconds,
    prefillKg: prefillKg,
    prefillReps: prefillReps,
    joints: joints,
    cues: cues,
    last: last ?? this.last,
    today: today ?? this.today,
    demoPath: demoPath,
  );

  /// One item from `today_plan(uuid)`'s `exercises` array.
  factory ExerciseSpec.fromJson(Map<String, dynamic> json) {
    final repHigh = json['rep_high'] as int?;
    final repLow = json['rep_low'] as int?;
    return ExerciseSpec(
      id: json['exercise_id'] as String,
      name: json['name'] as String,
      setsTarget: (json['sets_target'] as int?) ?? 3,
      // Double progression aims at the top of the prescribed range.
      reps: repHigh ?? repLow ?? 10,
      // The prescription's own target isn't returned separately any more —
      // prefill (what was actually lifted) is the number the UI shows.
      weightKg: (json['prefill_kg'] as num?)?.toDouble() ?? 0,
      loadType: (json['load_type'] as String?) ?? 'weight_reps',
      repLow: repLow,
      repHigh: repHigh,
      restSeconds: (json['rest_seconds'] as int?) ?? 90,
      prefillKg: (json['prefill_kg'] as num?)?.toDouble(),
      prefillReps: json['prefill_reps'] as int?,
      joints: ((json['joints'] as List?) ?? const []).cast<String>(),
      cues: ((json['cues'] as List?) ?? const []).cast<String>(),
      last: ExerciseEffort.fromJson(json['last'] as Map<String, dynamic>?),
      today: ExerciseEffort.fromJson(json['today'] as Map<String, dynamic>?),
      demoPath: json['demo_path'] as String?,
    );
  }

  /// The load isn't a number the lifter chose — reps are the result.
  bool get isBodyweight =>
      loadType == 'bodyweight_reps' || loadType == 'assisted_bodyweight';

  String get setsLabel => '$setsTarget × $reps';

  /// "4 sets · 8–10 reps" — the prescription, said properly.
  String get prescriptionLabel {
    final range = repLow == repHigh ? '$repLow' : '$repLow–$repHigh';
    return '$setsTarget sets · $range reps';
  }

  int get setsLoggedToday => today?.sets.length ?? 0;

  SetProgress get progress {
    final n = setsLoggedToday;
    if (n == 0) return SetProgress.none;
    return n >= setsTarget ? SetProgress.complete : SetProgress.partial;
  }
}

class LoggedSet {
  /// Weight in kilograms.
  final double weightKg;
  final int reps;
  LoggedSet({required this.weightKg, required this.reps});
}

/// One real `session_sets` row, with its id — unlike [LoggedSet], which is
/// just the `[weight, reps]` pair `today_plan` aggregates, this is enough to
/// edit or delete the specific set it came from.
class LoggedSetRow {
  final String id;
  final int setNumber;
  final double weightKg;
  final int reps;
  const LoggedSetRow({
    required this.id,
    required this.setNumber,
    required this.weightKg,
    required this.reps,
  });
}

class WeightEntry {
  /// Bodyweight in kilograms, as measured.
  final double weightKg;

  /// 7-day trailing mean in kilograms, from `v_bodyweight_trend`. Day-to-day
  /// bodyweight swings on water and food alone, so this is the number worth
  /// showing. Falls back to [weightKg] when the view isn't the source.
  final double avgKg;

  final DateTime loggedAt;

  WeightEntry({required this.weightKg, required this.loggedAt, double? avgKg})
    : avgKg = avgKg ?? weightKg;
}

class ProteinEntry {
  final int grams;
  final DateTime loggedAt;
  ProteinEntry({required this.grams, required this.loggedAt});
}

class ChatMessage {
  final String sender; // 'user' | 'coach'
  final String body;
  ChatMessage({required this.sender, required this.body});
}

class PendingLogRow {
  final String exerciseName;
  final double weightKg;
  final int reps;
  final int sets;

  /// Set when the coach resolved the name server-side. Confirming then writes
  /// against this id rather than re-matching the display name, which can drift
  /// if the plan changes between the proposal and the tap.
  final String? exerciseId;

  PendingLogRow({
    required this.exerciseName,
    required this.weightKg,
    required this.reps,
    required this.sets,
    this.exerciseId,
  });
}

/// One reply from the coach, plus whatever it wants the lifter to confirm.
///
/// [proposalId] non-null means the proposal is a durable row in
/// `coach_proposals`, so confirming goes through the Edge Function and
/// survives the app being killed. Null means it came from the offline
/// fallback parser and is confirmed locally.
class CoachTurn {
  final String reply;
  final String? proposalId;
  final List<PendingLogRow> pending;

  CoachTurn({required this.reply, this.proposalId, this.pending = const []});
}

class SessionHistoryEntry {
  final String label;
  final DateTime date;
  final int setCount;
  final double volumeKg;
  SessionHistoryEntry({
    required this.label,
    required this.date,
    this.setCount = 0,
    this.volumeKg = 0,
  });
}

/// One point on a per-exercise strength trend.
class StrengthPoint {
  final DateTime date;
  final double topSetKg;
  StrengthPoint({required this.date, required this.topSetKg});
}

/// A session's aggregate numbers — either the one in progress (`session_now`,
/// which also carries `startedAt`/`elapsedMin`) or the last time this same
/// program day was trained (`session_last`, which carries `date` instead).
class SessionTotals {
  final int setCount;
  final double volumeKg;
  final int totalReps;
  final int? exerciseCount;
  final DateTime? startedAt;
  final int? elapsedMin;
  final DateTime? date;

  const SessionTotals({
    required this.setCount,
    required this.volumeKg,
    required this.totalReps,
    this.exerciseCount,
    this.startedAt,
    this.elapsedMin,
    this.date,
  });

  static SessionTotals? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    // Both session_now and session_last return a row of zeros/nulls when
    // there is nothing to aggregate yet — treat that as "nothing", not "0 kg".
    final setCount = (json['set_count'] as num?)?.toInt() ?? 0;
    if (setCount == 0) return null;
    return SessionTotals(
      setCount: setCount,
      volumeKg: (json['volume_kg'] as num?)?.toDouble() ?? 0,
      totalReps: (json['total_reps'] as num?)?.toInt() ?? 0,
      exerciseCount: (json['exercise_count'] as num?)?.toInt(),
      startedAt: json['started_at'] == null
          ? null
          : DateTime.parse(json['started_at'] as String),
      elapsedMin: (json['elapsed_min'] as num?)?.toInt(),
      date: json['date'] == null
          ? null
          : DateTime.parse(json['date'] as String),
    );
  }
}

/// The full result of `today_plan(uuid)` — the prescription plus what was
/// actually done, last time and today, for every exercise in the slot.
class TodayPlan {
  final bool hasPlan;
  final DateTime? localDate;
  final String? programDayId;

  /// "Push Day" — the stable identity used to compare against past sessions
  /// of the same day, and shown in the UI instead of a hardcoded string.
  final String? label;

  final String? sessionId;
  final String? sessionStatus;
  final List<ExerciseSpec> exercises;
  final SessionTotals? sessionNow;
  final SessionTotals? sessionLast;

  /// When the in-progress session actually started, server-stamped —
  /// available even before the first set is logged, unlike [sessionNow],
  /// which is null until there's at least one set to aggregate. This is what
  /// makes the in-flow elapsed timer resume-safe: it reads a fact the server
  /// recorded once, not a client-side clock that resets on every reload.
  final DateTime? sessionStartedAt;

  const TodayPlan({
    required this.hasPlan,
    this.localDate,
    this.programDayId,
    this.label,
    this.sessionId,
    this.sessionStatus,
    this.exercises = const [],
    this.sessionNow,
    this.sessionLast,
    this.sessionStartedAt,
  });

  factory TodayPlan.fromJson(Map<String, dynamic> json) {
    final rawExercises = (json['exercises'] as List?) ?? const [];
    final rawNow = json['session_now'] as Map<String, dynamic>?;
    return TodayPlan(
      hasPlan: json['has_plan'] as bool? ?? false,
      localDate: json['local_date'] == null
          ? null
          : DateTime.parse(json['local_date'] as String),
      programDayId: json['program_day_id'] as String?,
      label: json['label'] as String?,
      sessionId: json['session_id'] as String?,
      sessionStatus: json['session_status'] as String?,
      exercises: rawExercises
          .cast<Map<String, dynamic>>()
          .map(ExerciseSpec.fromJson)
          .toList(),
      sessionNow: SessionTotals.fromJson(rawNow),
      sessionLast: SessionTotals.fromJson(
        json['session_last'] as Map<String, dynamic>?,
      ),
      sessionStartedAt: rawNow?['started_at'] == null
          ? null
          : DateTime.parse(rawNow!['started_at'] as String),
    );
  }

  static const empty = TodayPlan(hasPlan: false);
}

/// The goal-derived daily protein target from `protein_target_for(uuid)`.
class ProteinTarget {
  final int grams;
  final double? basisKg;
  final double? perKg;
  final String rationale;

  const ProteinTarget({
    required this.grams,
    this.basisKg,
    this.perKg,
    required this.rationale,
  });

  static const placeholder = ProteinTarget(
    grams: 120,
    rationale: 'A general placeholder until your first weigh-in.',
  );

  factory ProteinTarget.fromRow(Map<String, dynamic> row) => ProteinTarget(
    grams: (row['grams'] as num?)?.toInt() ?? 120,
    basisKg: (row['basis_kg'] as num?)?.toDouble(),
    perKg: (row['per_kg'] as num?)?.toDouble(),
    rationale: (row['rationale'] as String?) ?? '',
  );
}

/// The next scheduled day after today, for the "Up next" card shown once
/// today's session is complete — from `next_session_preview(uuid)`.
class NextSessionPreview {
  final bool hasNext;
  final String? label;
  final DateTime? scheduledFor;
  final List<ExerciseSpec> exercises;

  const NextSessionPreview({
    required this.hasNext,
    this.label,
    this.scheduledFor,
    this.exercises = const [],
  });

  static const none = NextSessionPreview(hasNext: false);

  factory NextSessionPreview.fromJson(Map<String, dynamic> json) {
    final rawExercises = (json['exercises'] as List?) ?? const [];
    return NextSessionPreview(
      hasNext: json['has_next'] as bool? ?? false,
      label: json['label'] as String?,
      scheduledFor: json['scheduled_for'] == null
          ? null
          : DateTime.parse(json['scheduled_for'] as String),
      exercises: rawExercises
          .cast<Map<String, dynamic>>()
          .map(ExerciseSpec.fromJson)
          .toList(),
    );
  }

  int get totalSets => exercises.fold(0, (sum, e) => sum + e.setsTarget);
}

/// Fallback shown when a catalog exercise has no `exercise_cues` rows.
const List<String> defaultCues = [
  'Move with control through the full range of motion.',
  'Keep the target muscle under tension throughout.',
  'Breathe out on the exertion phase of the lift.',
  'Stop a rep short of form breakdown.',
];
