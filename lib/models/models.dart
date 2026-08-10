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
    'Commercial gym': 'commercial_gym',
    'Home gym': 'home_gym',
    'Bodyweight only': 'bodyweight_only',
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
  }) =>
      Profile(
        goal: _Enum.label(_Enum.goal, training?['goal'] as String?),
        experience: _Enum.label(_Enum.experience, training?['experience'] as String?),
        daysPerWeek: (training?['days_per_week'] as int?) ?? 4,
        environment: _Enum.label(_Enum.environment, training?['environment'] as String?),
        splitPref: _Enum.label(_Enum.split, training?['split_preference'] as String?),
        injuries: injuries,
        currentWeightKg: currentWeightKg,
        targetWeightKg: (training?['target_weight_kg'] as num?)?.toDouble(),
        units: UnitSystem.fromId(preferences?['units'] as String?),
      );

  // ── enum values for the write side ───────────────────────────────────
  String? get goalValue => goal == null ? null : _Enum.goal[goal];
  String? get experienceValue => experience == null ? null : _Enum.experience[experience];
  String? get environmentValue => environment == null ? null : _Enum.environment[environment];
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
      goal != null && experience != null && environment != null && splitPref != null;

  /// Daily protein target in grams — 1.8 g per kg of bodyweight, a common
  /// recommendation for people training for muscle. Falls back to a flat
  /// target until a weigh-in exists.
  int get proteinTargetG {
    final kg = currentWeightKg;
    if (kg == null || kg <= 0) return 120;
    return (kg * 1.8).round();
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

  /// Joint slugs this movement loads, from `exercise_joints`.
  final List<String> joints;

  /// Form cues from `exercise_cues`, in `position` order.
  final List<String> cues;

  const ExerciseSpec({
    required this.id,
    required this.name,
    required this.setsTarget,
    required this.reps,
    required this.weightKg,
    this.joints = const [],
    this.cues = const [],
  });

  ExerciseSpec copyWith({
    int? setsTarget,
    int? reps,
    double? weightKg,
  }) =>
      ExerciseSpec(
        id: id,
        name: name,
        setsTarget: setsTarget ?? this.setsTarget,
        reps: reps ?? this.reps,
        weightKg: weightKg ?? this.weightKg,
        joints: joints,
        cues: cues,
      );

  String get setsLabel => '$setsTarget × $reps';
}

class LoggedSet {
  /// Weight in kilograms.
  final double weightKg;
  final int reps;
  LoggedSet({required this.weightKg, required this.reps});
}

class WeightEntry {
  /// Bodyweight in kilograms.
  final double weightKg;
  final DateTime loggedAt;
  WeightEntry({required this.weightKg, required this.loggedAt});
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

/// Fallback shown when a catalog exercise has no `exercise_cues` rows.
const List<String> defaultCues = [
  'Move with control through the full range of motion.',
  'Keep the target muscle under tension throughout.',
  'Breathe out on the exertion phase of the lift.',
  'Stop a rep short of form breakdown.',
];
