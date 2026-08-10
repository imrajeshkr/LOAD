import 'package:flutter/foundation.dart';
import '../models/models.dart';
import 'supabase_service.dart';

const Map<String, ExerciseSpec> exerciseAlts = {
  'Bench Press': ExerciseSpec(name: 'Floor Press', setsTarget: 4, reps: 8, startingWeight: 115, joints: ['shoulder', 'elbow']),
  'Overhead Press': ExerciseSpec(name: 'Landmine Press', setsTarget: 3, reps: 10, startingWeight: 50, joints: ['shoulder']),
  'Incline DB Press': ExerciseSpec(name: 'Machine Chest Press', setsTarget: 3, reps: 12, startingWeight: 50, joints: ['shoulder']),
  'Tricep Pushdown': ExerciseSpec(name: 'Rope Face Pull', setsTarget: 3, reps: 15, startingWeight: 30, joints: ['shoulder']),
};

/// Central app state: profile + today's session + logs + chat.
/// Holds working state locally and persists the meaningful bits to Supabase.
class AppState extends ChangeNotifier {
  final _service = SupabaseService.instance;

  Profile profile = Profile();
  bool loading = true;

  List<ExerciseSpec> exercises = List.of(defaultExercises);
  final Map<int, List<LoggedSet>> loggedSets = {};
  int currentExerciseIndex = 0;
  String? currentSessionId;
  bool sessionComplete = false;

  String sessionNotes = '';
  int? sessionRpe;
  List<String> sessionPain = [];

  List<WeightEntry> weightLog = [];
  List<ProteinEntry> proteinLog = [];
  List<SessionHistoryEntry> sessionHistory = [];
  List<ChatMessage> chatMessages = [];
  List<PendingLogRow>? pendingLog;

  int? guideExerciseIndex;

  Future<void> loadInitial() async {
    loading = true;
    notifyListeners();
    final p = await _service.fetchProfile();
    if (p != null) profile = p;
    weightLog = await _service.fetchWeightLog();
    proteinLog = await _service.fetchProteinLog();
    sessionHistory = await _service.fetchSessionHistory();
    chatMessages = await _service.fetchChatHistory();
    if (chatMessages.isEmpty) {
      chatMessages.add(ChatMessage(
        sender: 'coach',
        body: "Morning. I'm your coach — ask me anything, or tell me what you did after you train and I'll log it.",
      ));
    }
    loading = false;
    notifyListeners();
  }

  Future<void> saveProfile() async {
    await _service.saveProfile(profile);
    notifyListeners();
  }

  // ── weigh-in / protein ──────────────────────────────────────────────
  Future<void> logWeight(double weight) async {
    await _service.logWeight(weight);
    weightLog = [...weightLog, WeightEntry(weight: weight, loggedAt: DateTime.now())];
    if (weightLog.length > 8) weightLog = weightLog.sublist(weightLog.length - 8);
    profile.currentWeight = weight;
    notifyListeners();
  }

  Future<void> logProtein(int grams) async {
    await _service.logProtein(grams);
    proteinLog = [...proteinLog, ProteinEntry(grams: grams, loggedAt: DateTime.now())];
    if (proteinLog.length > 7) proteinLog = proteinLog.sublist(proteinLog.length - 7);
    notifyListeners();
  }

  int get proteinStreak {
    var streak = 0;
    for (var i = proteinLog.length - 1; i >= 0; i--) {
      if (proteinLog[i].grams > 0) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  // ── session flow ────────────────────────────────────────────────────
  bool get hasFlaggedInjury => profile.injuries.trim().isNotEmpty;

  bool exerciseFlagged(ExerciseSpec ex) {
    if (profile.injuries.trim().isEmpty) return false;
    final lower = profile.injuries.toLowerCase();
    return ex.joints.any((j) => lower.contains(j));
  }

  String? flagLabel(ExerciseSpec ex) {
    final lower = profile.injuries.toLowerCase();
    for (final j in ex.joints) {
      if (lower.contains(j)) return j;
    }
    return null;
  }

  int loggedCount(int index) => loggedSets[index]?.length ?? 0;
  bool exerciseDone(int index) => loggedCount(index) >= exercises[index].setsTarget;

  int get totalDone {
    var n = 0;
    for (var i = 0; i < exercises.length; i++) {
      if (exerciseDone(i)) n++;
    }
    return n;
  }

  Future<void> startSession(String label) async {
    currentSessionId = await _service.startSession(label);
    loggedSets.clear();
    currentExerciseIndex = 0;
    sessionComplete = false;
    sessionNotes = '';
    sessionRpe = null;
    sessionPain = [];
    notifyListeners();
  }

  void openExercise(int index) {
    currentExerciseIndex = index;
    notifyListeners();
  }

  Future<void> logSet(int exerciseIndex, double weight, int reps) async {
    final list = loggedSets.putIfAbsent(exerciseIndex, () => []);
    list.add(LoggedSet(weight: weight, reps: reps));
    if (currentSessionId != null) {
      await _service.logSet(currentSessionId!, exercises[exerciseIndex].name, list.length, weight, reps);
    }
    notifyListeners();
  }

  Future<void> finishSession(String label) async {
    sessionComplete = true;
    if (currentSessionId != null) {
      await _service.completeSession(currentSessionId!, notes: sessionNotes, rpe: sessionRpe, pain: sessionPain);
      sessionHistory = [
        SessionHistoryEntry(label: label, detail: '${loggedSets.length} exercises', date: DateTime.now()),
        ...sessionHistory,
      ];
    }
    notifyListeners();
  }

  void swapExercise(String currentName) {
    final alt = exerciseAlts[currentName];
    if (alt == null) return;
    exercises = exercises.map((e) => e.name == currentName ? alt : e).toList();
    notifyListeners();
  }

  void openGuide(int index) {
    guideExerciseIndex = index;
    notifyListeners();
  }

  void closeGuide() {
    guideExerciseIndex = null;
    notifyListeners();
  }

  // ── chat ─────────────────────────────────────────────────────────────
  Future<void> sendChat(String text) async {
    if (text.trim().isEmpty) return;
    await _service.saveChatMessage('user', text);
    chatMessages = [...chatMessages, ChatMessage(sender: 'user', body: text)];
    notifyListeners();

    final parsed = _parseSessionLog(text);
    if (parsed.isNotEmpty) {
      pendingLog = parsed;
      final reply = "Here's what I caught from today — check it below and confirm.";
      await _service.saveChatMessage('coach', reply);
      chatMessages = [...chatMessages, ChatMessage(sender: 'coach', body: reply)];
      notifyListeners();
      return;
    }

    final lower = text.toLowerCase();
    final swapMatch = RegExp(r'swap|replace|instead|change').hasMatch(lower);
    ExerciseSpec? target;
    for (final ex in exercises) {
      if (lower.contains(ex.name.toLowerCase())) {
        target = ex;
        break;
      }
    }

    String reply = "Noted — I'll factor that in for your next session.";
    if (swapMatch && target != null && exerciseAlts.containsKey(target.name)) {
      final alt = exerciseAlts[target.name]!;
      swapExercise(target.name);
      reply = "Swapped ${target.name} for ${alt.name} — same movement pattern, easier on your setup. You'll see it on Today now.";
    } else if (lower.contains('knee') || profile.injuries.toLowerCase().contains('knee')) {
      reply = "Since you flagged your knee, swap leg extensions for leg press with a partial range — same stimulus, less joint stress.";
    } else if (RegExp(r'tired|sore|pain').hasMatch(lower)) {
      reply = "If it's more than normal soreness, let's deload 10% today rather than push through it.";
    } else if (profile.goal != null) {
      reply = "Given your goal (${profile.goal}), I'd keep this week's volume as-is and reassess after your next session.";
    }

    await _service.saveChatMessage('coach', reply);
    chatMessages = [...chatMessages, ChatMessage(sender: 'coach', body: reply)];
    notifyListeners();
  }

  List<PendingLogRow> _parseSessionLog(String text) {
    final clauses = text.split(RegExp(r'[,;]| and ', caseSensitive: false));
    final rows = <PendingLogRow>[];
    final numPattern = RegExp(r'(\d+)\s*[x×]\s*(\d+)(?:\s*[x×]\s*(\d+))?', caseSensitive: false);
    for (final clause in clauses) {
      final match = numPattern.firstMatch(clause);
      if (match == null) continue;
      final lower = clause.toLowerCase();
      ExerciseSpec? ex;
      for (final e in exercises) {
        if (lower.contains(e.name.toLowerCase().split(' ').first.toLowerCase())) {
          ex = e;
          break;
        }
      }
      if (ex == null) continue;
      final weight = double.tryParse(match.group(1)!) ?? 0;
      final reps = int.tryParse(match.group(2)!) ?? 0;
      final sets = match.group(3) != null ? int.tryParse(match.group(3)!) ?? 1 : 1;
      rows.add(PendingLogRow(exerciseName: ex.name, weight: weight, reps: reps, sets: sets));
    }
    return rows;
  }

  Future<void> confirmPendingLog() async {
    if (pendingLog == null) return;
    for (final row in pendingLog!) {
      final idx = exercises.indexWhere((e) => e.name == row.exerciseName);
      if (idx == -1) continue;
      for (var n = 0; n < row.sets; n++) {
        await logSet(idx, row.weight, row.reps);
      }
    }
    pendingLog = null;
    const reply = "Logged. Nice work — Today's card is updated.";
    await _service.saveChatMessage('coach', reply);
    chatMessages = [...chatMessages, ChatMessage(sender: 'coach', body: reply)];
    notifyListeners();
  }

  void cancelPendingLog() {
    pendingLog = null;
    notifyListeners();
  }
}
