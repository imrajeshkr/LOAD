class Profile {
  String? goal;
  String? experience;
  int daysPerWeek;
  String? environment;
  String? splitPref;
  String injuries;
  double? currentWeight;
  double? targetWeight;

  Profile({
    this.goal,
    this.experience,
    this.daysPerWeek = 4,
    this.environment,
    this.splitPref,
    this.injuries = '',
    this.currentWeight,
    this.targetWeight,
  });

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
        goal: m['goal'] as String?,
        experience: m['experience'] as String?,
        daysPerWeek: (m['days_per_week'] as int?) ?? 4,
        environment: m['environment'] as String?,
        splitPref: m['split_pref'] as String?,
        injuries: (m['injuries'] as String?) ?? '',
        currentWeight: (m['current_weight'] as num?)?.toDouble(),
        targetWeight: (m['target_weight'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toMap() => {
        'goal': goal,
        'experience': experience,
        'days_per_week': daysPerWeek,
        'environment': environment,
        'split_pref': splitPref,
        'injuries': injuries,
        'current_weight': currentWeight,
        'target_weight': targetWeight,
      };

  bool get isComplete => goal != null && experience != null && environment != null && splitPref != null;
}

class ExerciseSpec {
  final String name;
  final int setsTarget;
  final int reps;
  final double startingWeight;
  final List<String> joints;

  const ExerciseSpec({
    required this.name,
    required this.setsTarget,
    required this.reps,
    required this.startingWeight,
    this.joints = const [],
  });
}

class LoggedSet {
  final double weight;
  final int reps;
  LoggedSet({required this.weight, required this.reps});
}

class WeightEntry {
  final double weight;
  final DateTime loggedAt;
  WeightEntry({required this.weight, required this.loggedAt});
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
  final double weight;
  final int reps;
  final int sets;
  PendingLogRow({required this.exerciseName, required this.weight, required this.reps, required this.sets});
}

class SessionHistoryEntry {
  final String label;
  final String detail;
  final DateTime date;
  SessionHistoryEntry({required this.label, required this.detail, required this.date});
}

/// Default push-day plan used until real plan-generation exists.
const List<ExerciseSpec> defaultExercises = [
  ExerciseSpec(name: 'Bench Press', setsTarget: 4, reps: 8, startingWeight: 135, joints: ['shoulder', 'wrist', 'elbow']),
  ExerciseSpec(name: 'Overhead Press', setsTarget: 3, reps: 10, startingWeight: 65, joints: ['shoulder', 'elbow']),
  ExerciseSpec(name: 'Incline DB Press', setsTarget: 3, reps: 12, startingWeight: 40, joints: ['shoulder']),
  ExerciseSpec(name: 'Tricep Pushdown', setsTarget: 3, reps: 15, startingWeight: 35, joints: ['elbow']),
];

const Map<String, List<String>> formCues = {
  'Bench Press': [
    'Retract shoulder blades before unracking.',
    'Bar path touches mid-chest, elbows around 45°.',
    'Drive feet into the floor, keep hips on the bench.',
    'Full lockout without flaring the elbows.',
  ],
  'Overhead Press': [
    'Brace your core, ribs down before pressing.',
    'Bar starts at collarbone, path just in front of your face.',
    'Lock out overhead, biceps by your ears.',
    'Avoid excessive lower-back arch.',
  ],
  'Incline DB Press': [
    'Bench at 30-45°, dumbbells at chest level.',
    'Elbows around 45° from torso, not flared to 90°.',
    'Press up and slightly in, control the descent.',
    "Avoid bouncing the dumbbells off your chest.",
  ],
  'Tricep Pushdown': [
    'Elbows pinned to your sides throughout.',
    'Full extension without locking out aggressively.',
    "Control the eccentric, don't let the bar fly up.",
    'Keep torso upright, no leaning into it.',
  ],
};

const List<String> defaultCues = [
  'Move with control through the full range of motion.',
  'Keep the target muscle under tension throughout.',
  'Breathe out on the exertion phase of the lift.',
  'Stop a rep short of form breakdown.',
];
