import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../models/units.dart';
import 'supabase_service.dart';

/// Central app state: profile + today's session + logs + chat.
class AppState extends ChangeNotifier {
  final _service = SupabaseService.instance;

  Profile profile = Profile();
  bool loading = true;

  List<ExerciseSpec> exercises = [];

  /// Swap suggestions for the loaded plan, keyed by the exercise name they
  /// replace. Sourced from `exercise_alternatives`, prefetched so the Swap
  /// button can stay synchronous.
  Map<String, ExerciseSpec> _alternatives = {};

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

  /// Progress-tab series.
  List<String> trackedExercises = [];
  String? selectedTrendExercise;
  List<StrengthPoint> strengthTrend = [];
  Set<DateTime> trainingDays = {};

  UnitSystem get units => profile.units;

  /// Set when the initial load partially failed, so the UI can say so instead
  /// of sitting on a spinner or silently showing empty charts.
  String? loadError;

  /// Runs [task], swallowing failures so one bad query can't wedge startup.
  Future<void> _guard(String what, Future<void> Function() task) async {
    try {
      await task();
    } catch (e) {
      debugPrint('LOAD: $what failed — $e');
      loadError = what;
    }
  }

  Future<void> loadInitial() async {
    loading = true;
    loadError = null;
    notifyListeners();

    await _guard('profile', () async {
      final p = await _service.fetchProfile();
      if (p != null) profile = p;
    });

    await _guard('plan', _loadTodayPlan);

    await Future.wait([
      _guard('weigh-ins', () async => weightLog = await _service.fetchWeightLog()),
      _guard('protein', () async => proteinLog = await _service.fetchProteinLog()),
      _guard('sessions', () async => sessionHistory = await _service.fetchSessionHistory()),
      _guard('chat', () async => chatMessages = await _service.fetchChatHistory()),
      _guard('exercises', () async => trackedExercises = await _service.fetchLoggedExerciseNames()),
      _guard('training days', () async => trainingDays = await _service.fetchTrainingDays()),
    ]);

    if (chatMessages.isEmpty) {
      chatMessages = [
        ChatMessage(
          sender: 'coach',
          body: "Morning. I'm your coach — ask me anything, or just tell me what "
              "you did after training and I'll log it for you.",
        ),
      ];
    }

    if (trackedExercises.isNotEmpty) {
      selectedTrendExercise = trackedExercises.first;
      await _guard('strength trend', () async {
        strengthTrend = await _service.fetchStrengthTrend(selectedTrendExercise!);
      });
    }

    loading = false;
    notifyListeners();
  }

  /// Loads today's prescription from the active program. A user who has
  /// completed onboarding but has no program yet gets one built for them from
  /// the catalog, once.
  Future<void> _loadTodayPlan() async {
    var plan = await _service.fetchTodayExercises();
    if (plan.isEmpty && profile.isComplete) {
      await _service.bootstrapProgram();
      plan = await _service.fetchTodayExercises();
    }
    exercises = plan;
    _alternatives = {};
    if (plan.isNotEmpty) {
      final byId = await _service.fetchAlternatives(plan.map((e) => e.id).toList());
      _alternatives = {
        for (final ex in plan)
          if (byId[ex.id] != null) ex.name: byId[ex.id]!,
      };
    }
  }

  Future<void> refreshProgress() async {
    await Future.wait([
      _service.fetchWeightLog().then((v) => weightLog = v),
      _service.fetchProteinLog().then((v) => proteinLog = v),
      _service.fetchSessionHistory().then((v) => sessionHistory = v),
      _service.fetchLoggedExerciseNames().then((v) => trackedExercises = v),
      _service.fetchTrainingDays().then((v) => trainingDays = v),
    ]);
    if (selectedTrendExercise != null) {
      strengthTrend = await _service.fetchStrengthTrend(selectedTrendExercise!);
    } else if (trackedExercises.isNotEmpty) {
      selectedTrendExercise = trackedExercises.first;
      strengthTrend = await _service.fetchStrengthTrend(selectedTrendExercise!);
    }
    notifyListeners();
  }

  Future<void> selectTrendExercise(String name) async {
    selectedTrendExercise = name;
    strengthTrend = [];
    notifyListeners();
    strengthTrend = await _service.fetchStrengthTrend(name);
    notifyListeners();
  }

  Future<void> saveProfile() async {
    await _service.saveProfile(profile);
    // Goal, environment and split all feed plan generation, so a profile
    // change is also the moment a first plan can be built.
    if (exercises.isEmpty && profile.isComplete) {
      await _guard('plan', _loadTodayPlan);
    }
    notifyListeners();
  }

  Future<void> setUnits(UnitSystem u) async {
    profile.units = u;
    notifyListeners();
    await _service.saveProfile(profile);
  }

  // ── weigh-in / protein ───────────────────────────────────────────────
  Future<void> logWeight(double weightKg) async {
    await _service.logWeight(weightKg);
    weightLog = [...weightLog, WeightEntry(weightKg: weightKg, loggedAt: DateTime.now())];
    profile.currentWeightKg = weightKg;
    notifyListeners();
    await _service.saveProfile(profile);
  }

  Future<void> logProtein(int grams) async {
    await _service.logProtein(grams);
    proteinLog = [...proteinLog, ProteinEntry(grams: grams, loggedAt: DateTime.now())];
    notifyListeners();
  }

  int get proteinToday {
    final now = DateTime.now();
    var total = 0;
    for (final e in proteinLog) {
      if (e.loggedAt.year == now.year &&
          e.loggedAt.month == now.month &&
          e.loggedAt.day == now.day) {
        total += e.grams;
      }
    }
    return total;
  }

  int get proteinStreak {
    if (proteinLog.isEmpty) return 0;
    final days = proteinLog
        .map((e) => DateTime(e.loggedAt.year, e.loggedAt.month, e.loggedAt.day))
        .toSet();
    var streak = 0;
    var cursor = DateTime.now();
    cursor = DateTime(cursor.year, cursor.month, cursor.day);
    // Today not being logged yet shouldn't break yesterday's streak.
    if (!days.contains(cursor)) cursor = cursor.subtract(const Duration(days: 1));
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Consecutive days with a completed session, counting back from today.
  int get trainingStreak {
    if (trainingDays.isEmpty) return 0;
    var streak = 0;
    var cursor = DateTime.now();
    cursor = DateTime(cursor.year, cursor.month, cursor.day);
    if (!trainingDays.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    while (trainingDays.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Sessions completed in the last 7 days.
  int get sessionsThisWeek {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    return trainingDays.where((d) => d.isAfter(cutoff)).length;
  }

  // ── session flow ─────────────────────────────────────────────────────
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

  double get sessionVolumeKg {
    var v = 0.0;
    for (final sets in loggedSets.values) {
      for (final s in sets) {
        v += s.weightKg * s.reps;
      }
    }
    return v;
  }

  int get sessionSetsLogged {
    var n = 0;
    for (final sets in loggedSets.values) {
      n += sets.length;
    }
    return n;
  }

  int get sessionSetsTarget =>
      exercises.fold(0, (sum, ex) => sum + ex.setsTarget);

  /// True once a plan has actually loaded. Everything on the Today screen
  /// indexes into [exercises], so there is nothing to start without one.
  bool get hasPlan => exercises.isNotEmpty;

  Future<void> startSession(String label) async {
    if (!hasPlan) return;
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
    if (!hasPlan) return;
    // Clamped: the plan can change under a pushed LogScreen (a swap, a
    // reload), and an out-of-range index there is a crash, not a glitch.
    currentExerciseIndex = index.clamp(0, exercises.length - 1);
    notifyListeners();
  }

  Future<void> logSet(int exerciseIndex, double weightKg, int reps) async {
    final list = loggedSets.putIfAbsent(exerciseIndex, () => []);
    list.add(LoggedSet(weightKg: weightKg, reps: reps));
    notifyListeners();
    if (currentSessionId != null) {
      await _service.logSet(
        currentSessionId!,
        exercises[exerciseIndex].id,
        exerciseIndex + 1,
        list.length,
        weightKg,
        reps,
      );
    }
  }

  void undoLastSet(int exerciseIndex) {
    final list = loggedSets[exerciseIndex];
    if (list == null || list.isEmpty) return;
    list.removeLast();
    notifyListeners();
  }

  /// PRs for the just-finished session, computed from what was actually
  /// logged versus the planned working weight.
  List<String> get sessionHighlights {
    final out = <String>[];
    for (var i = 0; i < exercises.length; i++) {
      final sets = loggedSets[i];
      if (sets == null || sets.isEmpty) continue;
      final top = sets.map((s) => s.weightKg).reduce((a, b) => a > b ? a : b);
      if (top > exercises[i].weightKg) {
        out.add('${exercises[i].name} — ${units.formatWeightWithUnit(top)}, '
            'up from ${units.formatWeightWithUnit(exercises[i].weightKg)}');
      }
    }
    return out;
  }

  Future<void> finishSession(String label) async {
    sessionComplete = true;
    notifyListeners();
    if (currentSessionId != null) {
      await _service.completeSession(
        currentSessionId!,
        notes: sessionNotes,
        rpe: sessionRpe,
        pain: sessionPain,
      );
      await refreshProgress();
    }
  }

  void swapExercise(String currentName) {
    final alt = _alternatives[currentName];
    if (alt == null) return;
    exercises = exercises.map((e) {
      if (e.name != currentName) return e;
      // The prescription slot survives the swap — only the movement changes.
      return alt.copyWith(
        setsTarget: e.setsTarget,
        reps: e.reps,
        weightKg: alt.weightKg > 0 ? alt.weightKg : e.weightKg,
      );
    }).toList();
    notifyListeners();
  }

  bool canSwap(String name) => _alternatives.containsKey(name);

  // ── chat ─────────────────────────────────────────────────────────────

  /// Non-null while a server-side proposal is awaiting confirmation. When it
  /// is null but [pendingLog] is not, the card came from the offline fallback
  /// and is confirmed locally instead.
  String? pendingProposalId;

  Future<void> sendChat(String text) async {
    if (text.trim().isEmpty) return;

    // Echo locally first so the bubble appears immediately; the Edge Function
    // persists both sides of the turn itself.
    chatMessages = [...chatMessages, ChatMessage(sender: 'user', body: text)];
    notifyListeners();

    try {
      final turn = await _service.coachTurn(text);
      pendingProposalId = turn.proposalId;
      pendingLog = turn.pending.isEmpty ? null : List.of(turn.pending);
      chatMessages = [...chatMessages, ChatMessage(sender: 'coach', body: turn.reply)];
    } catch (e) {
      // Offline, or the function is not deployed yet. Fall back to the local
      // parser so logging by chat keeps working, and persist both sides
      // ourselves since the function never ran.
      debugPrint('LOAD: coach unavailable — $e');
      await _service.saveChatMessage('user', text);

      final parsed = _parseSessionLog(text);
      final reply = parsed.isNotEmpty
          ? "Here's what I caught — check it over and confirm."
          : _coachReply(text);

      pendingProposalId = null;
      pendingLog = parsed.isEmpty ? null : parsed;
      await _service.saveChatMessage('coach', reply);
      chatMessages = [...chatMessages, ChatMessage(sender: 'coach', body: reply)];
    }
    notifyListeners();
  }

  String _coachReply(String text) {
    final lower = text.toLowerCase();
    final swapAsk = RegExp(r'swap|replace|instead|alternative').hasMatch(lower);

    ExerciseSpec? target;
    for (final ex in exercises) {
      if (lower.contains(ex.name.toLowerCase())) {
        target = ex;
        break;
      }
    }

    if (swapAsk && target != null && _alternatives.containsKey(target.name)) {
      final alt = _alternatives[target.name]!;
      swapExercise(target.name);
      return 'Swapped ${target.name} for ${alt.name} — same movement pattern, '
          "easier on the joints. It's on your Today screen now.";
    }
    if (RegExp(r'protein|eat|diet|food').hasMatch(lower)) {
      return "You're aiming for ${profile.proteinTargetG} g of protein a day. "
          "Today you've logged $proteinToday g — log the rest from the Today screen.";
    }
    if (RegExp(r'hurt|pain|sore|injur').hasMatch(lower)) {
      return "If it's sharp or joint-related, stop the movement and we'll swap it. "
          "If it's normal muscle soreness, we can drop the load ~10% today and "
          "build back up. I'm not a medical professional though — if it persists, "
          "please get it looked at.";
    }
    if (RegExp(r'tired|exhaust|no energy|deload').hasMatch(lower)) {
      return "Noted. Let's cut today's working sets by one each and hold the "
          "weight where it is — better to bank a light session than skip it.";
    }
    if (profile.goal != null) {
      return "Given your goal (${profile.goal!.toLowerCase()}), I'd hold this "
          "week's volume and reassess after your next session.";
    }
    return "Noted — I'll factor that into your next session.";
  }

  /// Parses phrases like "bench 80x8x4, ohp 40x10x3" into structured rows.
  /// Numbers are read in the user's display units and converted to kg.
  List<PendingLogRow> _parseSessionLog(String text) {
    final clauses = text.split(RegExp(r'[,;]| and ', caseSensitive: false));
    final rows = <PendingLogRow>[];
    final numPattern =
        RegExp(r'(\d+(?:\.\d+)?)\s*[x×]\s*(\d+)(?:\s*[x×]\s*(\d+))?', caseSensitive: false);

    for (final clause in clauses) {
      final match = numPattern.firstMatch(clause);
      if (match == null) continue;
      final lower = clause.toLowerCase();

      ExerciseSpec? ex;
      for (final e in exercises) {
        final firstWord = e.name.toLowerCase().split(' ').first;
        if (lower.contains(e.name.toLowerCase()) || lower.contains(firstWord)) {
          ex = e;
          break;
        }
      }
      // Common shorthand the exercise names don't cover.
      ex ??= _shorthandMatch(lower);
      if (ex == null) continue;

      final shown = double.tryParse(match.group(1)!) ?? 0;
      final reps = int.tryParse(match.group(2)!) ?? 0;
      final sets = match.group(3) != null ? (int.tryParse(match.group(3)!) ?? 1) : 1;
      if (reps <= 0 || sets <= 0) continue;

      rows.add(PendingLogRow(
        exerciseName: ex.name,
        weightKg: units.toKg(shown),
        reps: reps,
        sets: sets,
      ));
    }
    return rows;
  }

  ExerciseSpec? _shorthandMatch(String clause) {
    const shorthand = {
      'ohp': 'Overhead Press',
      'bp': 'Bench Press',
      'incline': 'Incline DB Press',
      'pushdown': 'Tricep Pushdown',
    };
    for (final entry in shorthand.entries) {
      if (clause.contains(entry.key)) {
        for (final e in exercises) {
          if (e.name == entry.value) return e;
        }
      }
    }
    return null;
  }

  Future<void> confirmPendingLog() async {
    final rows = pendingLog;
    if (rows == null) return;

    final proposalId = pendingProposalId;
    if (proposalId != null) {
      // Server-side proposal: the Edge Function writes the session and sets in
      // one deterministic pass, guarded so a double tap cannot double-log.
      try {
        await _service.confirmProposal(proposalId);
      } catch (e) {
        debugPrint('LOAD: confirm failed — $e');
        chatMessages = [
          ...chatMessages,
          ChatMessage(sender: 'coach', body: "That didn't save — try again in a moment."),
        ];
        notifyListeners();
        return;
      }
      pendingLog = null;
      pendingProposalId = null;
      // The sets are already committed server-side, so the refresh below is a
      // convenience, not part of the write. Both calls are guarded: an
      // unhandled failure here would skip the notifyListeners() at the end of
      // this method and leave the confirm card on screen for work that was
      // actually saved — which reads to the user as "confirm is broken".
      await _guard('plan', _loadTodayPlan);
      await _guard('progress', refreshProgress);
    } else {
      // Offline fallback: write it locally against the open session.
      currentSessionId ??= await _service.startSession('Logged from chat');
      for (final row in rows) {
        final idx = exercises.indexWhere((e) => e.name == row.exerciseName);
        if (idx == -1) continue;
        for (var n = 0; n < row.sets; n++) {
          await logSet(idx, row.weightKg, row.reps);
        }
      }
      pendingLog = null;
    }

    const reply = "Logged. Nice work — your Today screen is up to date.";
    await _service.saveChatMessage('coach', reply);
    chatMessages = [...chatMessages, ChatMessage(sender: 'coach', body: reply)];
    notifyListeners();
  }

  void removePendingRow(int index) {
    final rows = pendingLog;
    if (rows == null) return;
    rows.removeAt(index);
    if (rows.isEmpty) {
      pendingLog = null;
      _rejectPending();
    }
    notifyListeners();
  }

  void cancelPendingLog() {
    pendingLog = null;
    _rejectPending();
    notifyListeners();
  }

  /// Close the server-side proposal too, so it isn't left pending forever.
  void _rejectPending() {
    final id = pendingProposalId;
    pendingProposalId = null;
    if (id != null) {
      _service.rejectProposal(id).catchError((Object e) {
        debugPrint('LOAD: reject failed — $e');
      });
    }
  }
}
