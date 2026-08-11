import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../models/units.dart';
import 'supabase_service.dart';

/// Central app state: profile + today's plan + logs + chat.
///
/// Today's plan (exercises, what's logged, session totals) comes from the
/// server's `today_plan` RPC on every load and after every write — there is
/// deliberately no local map of logged sets. Keeping one alongside the
/// server was the bug that made a bodyweight exercise read "0 kg · Done" and
/// made sets logged through chat invisible on the Today screen: two sources
/// of truth for the same fact, free to disagree.
class AppState extends ChangeNotifier {
  final _service = SupabaseService.instance;

  Profile profile = Profile();
  bool loading = true;

  // ── today's plan (server-derived; see today_plan(uuid)) ────────────────
  bool hasPlan = false;
  String? planLabel;
  DateTime? planDate;
  String? currentSessionId;
  String? sessionStatus;
  List<ExerciseSpec> exercises = [];
  SessionTotals? sessionNow;
  SessionTotals? sessionLast;

  /// Swap suggestions for the loaded plan, keyed by the exercise name they
  /// replace. Sourced from `exercise_alternatives`, prefetched so the Swap
  /// button can stay synchronous.
  Map<String, ExerciseSpec> _alternatives = {};

  int currentExerciseIndex = 0;
  bool sessionComplete = false;

  /// The real, editable rows for whichever exercise is open in the Log
  /// screen — distinct from `exercises[i].today`, which is only the
  /// aggregated `[weight, reps]` pairs `today_plan` returns.
  List<LoggedSetRow> currentExerciseSets = [];
  bool loadingSets = false;
  bool loggingSet = false;

  String sessionNotes = '';
  int? sessionRpe;
  List<String> sessionPain = [];

  List<WeightEntry> weightLog = [];
  ProteinTarget proteinTarget = ProteinTarget.placeholder;
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
      _guard('protein target', _syncAndFetchProteinTarget),
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
    var plan = await _service.fetchTodayPlan();
    if (!plan.hasPlan && profile.isComplete) {
      await _service.bootstrapProgram();
      plan = await _service.fetchTodayPlan();
    }
    _applyPlan(plan);

    _alternatives = {};
    if (plan.exercises.isNotEmpty) {
      final byId = await _service.fetchAlternatives(plan.exercises.map((e) => e.id).toList());
      _alternatives = {
        for (final ex in plan.exercises)
          if (byId[ex.id] != null) ex.name: byId[ex.id]!,
      };
    }
  }

  /// Re-fetches `today_plan` without touching alternatives or profile — the
  /// call every write makes afterward, so the screen always shows what the
  /// server actually has.
  Future<void> _refreshTodayPlan() async {
    final plan = await _service.fetchTodayPlan();
    _applyPlan(plan);
  }

  void _applyPlan(TodayPlan plan) {
    hasPlan = plan.hasPlan;
    planLabel = plan.label;
    planDate = plan.localDate;
    currentSessionId = plan.sessionId;
    sessionStatus = plan.sessionStatus;
    exercises = plan.exercises;
    sessionNow = plan.sessionNow;
    sessionLast = plan.sessionLast;
    sessionComplete = plan.sessionStatus == 'completed';
    if (exercises.isEmpty) {
      currentExerciseIndex = 0;
    } else if (currentExerciseIndex >= exercises.length) {
      currentExerciseIndex = exercises.length - 1;
    }
  }

  Future<void> _syncAndFetchProteinTarget() async {
    // Persists the goal-derived target if it's drifted, then reads it back —
    // keeps nutrition_targets from disagreeing with what the app shows.
    await _service.syncProteinTarget();
    proteinTarget = await _service.fetchProteinTarget();
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
    if (!hasPlan && profile.isComplete) {
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
    // The protein target's basis is bodyweight — a new reading can move it.
    await _guard('protein target', _syncAndFetchProteinTarget);
    notifyListeners();
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

  int loggedCount(int index) => exercises[index].setsLoggedToday;
  bool exerciseDone(int index) => exercises[index].progress == SetProgress.complete;

  int get totalDone =>
      exercises.where((e) => e.progress == SetProgress.complete).length;

  double get sessionVolumeKg => sessionNow?.volumeKg ?? 0;
  int get sessionSetsLogged => sessionNow?.setCount ?? 0;
  int get sessionSetsTarget => exercises.fold(0, (sum, ex) => sum + ex.setsTarget);

  /// The session-level result line: "Push Day · 2,475 kg · +155 vs last time".
  /// Null until there's both a session in progress and a prior one to compare.
  double? get sessionVolumeDeltaKg {
    final now = sessionNow, last = sessionLast;
    if (now == null || last == null) return null;
    return now.volumeKg - last.volumeKg;
  }

  Future<void> startSession(String label) async {
    if (!hasPlan) return;
    final id = await _service.openSessionForToday();
    currentSessionId = id;
    sessionComplete = false;
    sessionNotes = '';
    sessionRpe = null;
    sessionPain = [];
    notifyListeners();
    await _guard('plan', _refreshTodayPlan);
    notifyListeners();
  }

  void openExercise(int index) {
    if (!hasPlan) return;
    // Clamped: the plan can change under a pushed LogScreen (a swap, a
    // reload), and an out-of-range index there is a crash, not a glitch.
    currentExerciseIndex = index.clamp(0, exercises.length - 1);
    currentExerciseSets = [];
    notifyListeners();
    _guard('sets', loadSetsForCurrentExercise);
  }

  /// The real `session_sets` rows for the exercise currently open in the Log
  /// screen — fetched separately from `today_plan` because that RPC only
  /// returns aggregated pairs, with no row id to edit or delete against.
  Future<void> loadSetsForCurrentExercise() async {
    if (!hasPlan || currentSessionId == null || exercises.isEmpty) {
      currentExerciseSets = [];
      notifyListeners();
      return;
    }
    loadingSets = true;
    notifyListeners();
    final ex = exercises[currentExerciseIndex];
    currentExerciseSets = await _service.fetchSetsForExercise(
      currentSessionId!,
      ex.id,
      currentExerciseIndex + 1,
    );
    loadingSets = false;
    notifyListeners();
  }

  Future<void> logSet(int exerciseIndex, double weightKg, int reps) async {
    final sessionId = currentSessionId;
    if (sessionId == null || exerciseIndex >= exercises.length) return;

    loggingSet = true;
    notifyListeners();
    try {
      final ex = exercises[exerciseIndex];
      final setNumber = ex.setsLoggedToday + 1;
      await _service.logSet(sessionId, ex.id, exerciseIndex + 1, setNumber, weightKg, reps);
      await _refreshTodayPlan();
      if (exerciseIndex == currentExerciseIndex) {
        await loadSetsForCurrentExercise();
      }
    } finally {
      loggingSet = false;
      notifyListeners();
    }
  }

  Future<void> updateSet(String setId, double weightKg, int reps) async {
    await _service.updateSet(setId, weightKg: weightKg, reps: reps);
    await _refreshTodayPlan();
    await loadSetsForCurrentExercise();
  }

  Future<void> deleteSet(String setId) async {
    await _service.deleteSet(setId);
    await _refreshTodayPlan();
    await loadSetsForCurrentExercise();
  }

  Future<void> undoLastLoggedSet() async {
    if (currentExerciseSets.isEmpty) return;
    await deleteSet(currentExerciseSets.last.id);
  }

  /// PRs for the just-finished session: today's heaviest set (or, for
  /// bodyweight work, today's total reps) against the same exercise last time.
  List<String> get sessionHighlights {
    final out = <String>[];
    for (final ex in exercises) {
      final today = ex.today;
      if (today == null || today.sets.isEmpty) continue;
      final last = ex.last;

      if (ex.isBodyweight) {
        if (last == null || today.totalReps > last.totalReps) {
          out.add(last == null
              ? '${ex.name} — ${today.totalReps} reps, first time logged'
              : '${ex.name} — ${today.totalReps} reps, up from ${last.totalReps}');
        }
        continue;
      }

      final topToday = today.sets.map((s) => s.weightKg).reduce((a, b) => a > b ? a : b);
      final topLast = (last != null && last.sets.isNotEmpty)
          ? last.sets.map((s) => s.weightKg).reduce((a, b) => a > b ? a : b)
          : null;
      if (topLast == null || topToday > topLast) {
        out.add(topLast == null
            ? '${ex.name} — ${units.formatWeightWithUnit(topToday)}, first time logged'
            : '${ex.name} — ${units.formatWeightWithUnit(topToday)}, '
                'up from ${units.formatWeightWithUnit(topLast)}');
      }
    }
    return out;
  }

  Future<void> finishSession(String label) async {
    sessionComplete = true;
    notifyListeners();
    final id = currentSessionId;
    if (id != null) {
      await _service.completeSession(
        id,
        notes: sessionNotes,
        rpe: sessionRpe,
        pain: sessionPain,
      );
      await _guard('plan', _refreshTodayPlan);
      await _guard('progress', refreshProgress);
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
    // The swapped-in movement has its own history under its own exercise id.
    _guard('sets', loadSetsForCurrentExercise);
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
      return "You're aiming for ${proteinTarget.grams} g of protein today "
          "(${proteinTarget.rationale}) You've logged $proteinToday g so far.";
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
        exerciseId: ex.id,
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
      await _guard('plan', _refreshTodayPlan);
      await _guard('progress', refreshProgress);
    } else {
      // Offline fallback: write it locally against the open session. Set
      // numbers are tracked here rather than through logSet(), which trusts
      // the server's count after each write — refreshing between every set
      // in a multi-set batch would be both slow and, mid-batch, stale.
      currentSessionId ??= await _service.openSessionForToday();
      final sessionId = currentSessionId;
      if (sessionId != null) {
        final startCounts = <int, int>{};
        for (final row in rows) {
          final idx = exercises.indexWhere((e) => e.name == row.exerciseName);
          if (idx == -1) continue;
          final base = startCounts[idx] ?? exercises[idx].setsLoggedToday;
          for (var n = 0; n < row.sets; n++) {
            await _service.logSet(
              sessionId,
              exercises[idx].id,
              idx + 1,
              base + n + 1,
              row.weightKg,
              row.reps,
            );
          }
          startCounts[idx] = base + row.sets;
        }
        await _guard('plan', _refreshTodayPlan);
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
