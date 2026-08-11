import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';

/// Thin wrapper around the Supabase client. Only the anon/publishable key is
/// ever used here — the service_role key must never appear in app code.
///
/// All weights crossing this boundary are kilograms.
///
/// This talks to the v2 schema (supabase/migrations/0003–0006): identity,
/// preferences and training intent are three tables; exercises are catalog
/// rows; and performance is session → session_exercise → set.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get client => Supabase.instance.client;
  User? get currentUser => client.auth.currentUser;

  Stream<AuthState> get authStateChanges => client.auth.onAuthStateChange;

  /// The program day the loaded plan came from, so a session can be linked
  /// back to its prescription.
  String? _programDayId;

  /// Public CDN URL for an exercise demo asset. [path] is the object path
  /// `today_plan()` returns on `demo_path` (e.g.
  /// "exercise-guide-web/bench-press.webp"); null in, null out, so callers can
  /// pass `exercise.demoPath` straight through and fall back on null.
  String? demoUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    return client.storage.from('exercise-media').getPublicUrl(path);
  }

  /// exercise name -> exercise id, for the exercises the user has logged.
  /// Lets the progress screen keep selecting a trend by display name.
  final Map<String, String> _exerciseIdsByName = {};

  /// session id + exercise id -> session_exercises id, so repeated sets on the
  /// same movement reuse one row.
  final Map<String, String> _sessionExerciseIds = {};

  String? _threadId;

  // ── auth ─────────────────────────────────────────────────────────────
  Future<void> signUpWithEmail(String email, String password) async {
    await client.auth.signUp(email: email, password: password);
  }

  Future<void> signInWithEmail(String email, String password) async {
    await client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signInWithGoogle() async {
    await client.auth.signInWithOAuth(OAuthProvider.google);
  }

  Future<void> signOut() async {
    _programDayId = null;
    _threadId = null;
    _exerciseIdsByName.clear();
    _sessionExerciseIds.clear();
    await client.auth.signOut();
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  // ── profile ──────────────────────────────────────────────────────────

  /// Reassembles the old single-table profile from `user_preferences`, the
  /// current `training_profiles` row, the latest weigh-in and the active
  /// `user_constraints`.
  Future<Profile?> fetchProfile() async {
    final uid = currentUser?.id;
    if (uid == null) return null;

    final results = await Future.wait<dynamic>([
      client.from('user_preferences').select().eq('user_id', uid).maybeSingle(),
      client
          .from('training_profiles')
          .select()
          .eq('user_id', uid)
          .isFilter('valid_to', null)
          .maybeSingle(),
      client
          .from('body_measurements')
          .select('weight_kg')
          .eq('user_id', uid)
          .not('weight_kg', 'is', null)
          .order('measured_on', ascending: false)
          .limit(1)
          .maybeSingle(),
      client
          .from('user_constraints')
          .select('label')
          .eq('user_id', uid)
          .isFilter('active_to', null),
    ]);

    final prefs = results[0] as Map<String, dynamic>?;
    final training = results[1] as Map<String, dynamic>?;
    final weighIn = results[2] as Map<String, dynamic>?;
    final constraints = (results[3] as List).cast<Map<String, dynamic>>();

    // The free text is stored verbatim on every row it produced, so the
    // distinct labels rejoin into what the user actually typed.
    final labels = <String>{};
    for (final c in constraints) {
      final l = (c['label'] as String?)?.trim();
      if (l != null && l.isNotEmpty) labels.add(l);
    }

    return Profile.fromRows(
      preferences: prefs,
      training: training,
      currentWeightKg: (weighIn?['weight_kg'] as num?)?.toDouble(),
      injuries: labels.join(', '),
    );
  }

  Future<void> saveProfile(Profile profile) async {
    final uid = currentUser?.id;
    if (uid == null) return;

    // profiles is identity only now, but the row must exist for the FKs.
    await client.from('profiles').upsert({'id': uid});
    await client.from('user_preferences').upsert({
      'user_id': uid,
      'units': profile.units.id,
    });

    await _saveTrainingProfile(uid, profile);
    await _saveConstraints(uid, profile.injuries);
  }

  /// Training intent is slowly-changing: a change closes the current row and
  /// opens a new one, so history stays interpretable.
  Future<void> _saveTrainingProfile(String uid, Profile profile) async {
    final payload = profile.toTrainingProfileMap();
    if (payload == null) return;

    final current = await client
        .from('training_profiles')
        .select()
        .eq('user_id', uid)
        .isFilter('valid_to', null)
        .maybeSingle();

    if (current != null) {
      final unchanged = payload.entries.every((e) {
        final a = current[e.key];
        final b = e.value;
        if (a is num && b is num) return a.toDouble() == b.toDouble();
        return a == b;
      });
      if (unchanged) return;
      await client
          .from('training_profiles')
          .update({'valid_to': DateTime.now().toIso8601String()})
          .eq('id', current['id'] as String);
    }

    await client.from('training_profiles').insert({'user_id': uid, ...payload});
  }

  /// The injuries field is still one free-text box in the UI. It is stored as
  /// one active constraint row per joint it mentions (so the catalog joins
  /// work), each carrying the original text as its label.
  Future<void> _saveConstraints(String uid, String injuries) async {
    final text = injuries.trim();

    final existing = await client
        .from('user_constraints')
        .select('label')
        .eq('user_id', uid)
        .isFilter('active_to', null);
    final existingLabels = (existing as List)
        .map((r) => ((r as Map)['label'] as String?)?.trim() ?? '')
        .where((l) => l.isNotEmpty)
        .toSet();

    if (existingLabels.length == 1 && existingLabels.first == text) return;
    if (existingLabels.isEmpty && text.isEmpty) return;

    // Close whatever was active; a resolved niggle should stop filtering.
    await client
        .from('user_constraints')
        .update({'active_to': _today()})
        .eq('user_id', uid)
        .isFilter('active_to', null);

    if (text.isEmpty) return;

    final joints = await client.from('joints').select('id, slug');
    final lower = text.toLowerCase();
    final rows = <Map<String, dynamic>>[];
    for (final j in (joints as List).cast<Map<String, dynamic>>()) {
      final slug = j['slug'] as String;
      // 'lumbar' is spelled "lower back" by every human who has one.
      final needles = slug == 'lumbar'
          ? const ['lumbar', 'lower back']
          : [slug];
      if (needles.any(lower.contains)) {
        rows.add({'user_id': uid, 'joint_id': j['id'], 'label': text});
      }
    }
    if (rows.isEmpty) rows.add({'user_id': uid, 'label': text});
    await client.from('user_constraints').insert(rows);
  }

  // ── today's plan ─────────────────────────────────────────────────────

  /// Creates a program from the catalog for the user's current training
  /// profile. Returns the new program id, or null if it couldn't run (most
  /// often: no training profile yet).
  Future<String?> bootstrapProgram() async {
    if (currentUser == null) return null;
    final id = await client.rpc('bootstrap_my_program');
    return id as String?;
  }

  /// Everything the Today screen renders, in one call: the prescription, what
  /// was done last time, what's logged today, and the session-level totals —
  /// see `today_plan(uuid)` in migrations 0011/0013/0015.
  Future<TodayPlan> fetchTodayPlan() async {
    final uid = currentUser?.id;
    if (uid == null) return TodayPlan.empty;

    final json = await client.rpc('today_plan', params: {'p_user_id': uid});
    if (json is! Map) return TodayPlan.empty;

    final plan = TodayPlan.fromJson(json.cast<String, dynamic>());
    _programDayId = plan.programDayId;
    return plan;
  }

  /// The session for the lifter's local day — the same one whichever logging
  /// path (Today screen or chat) reaches for, so a day is never split across
  /// two rows. Safe to call repeatedly: it returns the existing session if
  /// one is already open.
  Future<String?> openSessionForToday({String? title}) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final id = await client.rpc(
      'open_session_for_today',
      params: {'p_user_id': uid, 'p_title': ?title},
    );
    return id as String?;
  }

  List<String> _jointSlugs(Map<String, dynamic> exercise) {
    final out = <String>[];
    for (final j in (exercise['exercise_joints'] as List? ?? const [])) {
      final joint = (j as Map)['joints'] as Map?;
      final slug = joint?['slug'] as String?;
      if (slug != null) out.add(slug);
    }
    return out;
  }

  List<String> _cues(Map<String, dynamic> exercise) {
    final raw =
        (exercise['exercise_cues'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .toList()
          ..sort(
            (a, b) => ((a['position'] as int?) ?? 0).compareTo(
              (b['position'] as int?) ?? 0,
            ),
          );
    return raw.map((c) => c['body'] as String).toList();
  }

  /// Joint-friendly substitutes for the given catalog exercises, keyed by the
  /// exercise they replace. Backs the Swap button, which used to read a const.
  Future<Map<String, ExerciseSpec>> fetchAlternatives(
    List<String> exerciseIds,
  ) async {
    if (exerciseIds.isEmpty) return {};
    const altSelect =
        'exercise_id, rank, reason, '
        'alt:exercises!exercise_alternatives_alternative_id_fkey('
        'id, name, load_type, default_rep_low, default_rep_high, '
        'default_start_kg, demo_path, '
        'exercise_cues(position, body), '
        'exercise_joints(joints(slug)))';

    final rows = await client
        .from('exercise_alternatives')
        .select(altSelect)
        .inFilter('exercise_id', exerciseIds)
        .order('rank', ascending: true);

    final out = <String, ExerciseSpec>{};
    // Joint-friendly wins; anything else is only a fallback.
    for (final preferJointFriendly in [true, false]) {
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final isJointFriendly = r['reason'] == 'joint_friendly';
        if (isJointFriendly != preferJointFriendly) continue;
        final id = r['exercise_id'] as String;
        if (out.containsKey(id)) continue;
        final alt = r['alt'] as Map<String, dynamic>?;
        if (alt == null) continue;
        // No lifting history for a movement swapped in mid-session, so the
        // catalog's own conservative starting load stands in for prefill —
        // the same fallback bootstrap_user_program uses — rather than 0,
        // which reads as "bodyweight" for a movement that very much isn't.
        final startKg = (alt['default_start_kg'] as num?)?.toDouble() ?? 0;
        out[id] = ExerciseSpec(
          id: alt['id'] as String,
          name: alt['name'] as String,
          setsTarget: 3,
          reps: (alt['default_rep_high'] as int?) ?? 10,
          weightKg: startKg,
          loadType: (alt['load_type'] as String?) ?? 'weight_reps',
          prefillKg: startKg,
          joints: _jointSlugs(alt),
          cues: _cues(alt),
          demoPath: alt['demo_path'] as String?,
        );
      }
    }
    return out;
  }

  /// What's scheduled after today, for the "Up next" card on a completed
  /// session — see `next_session_preview(uuid)`.
  Future<NextSessionPreview> fetchNextSessionPreview() async {
    final uid = currentUser?.id;
    if (uid == null) return NextSessionPreview.none;
    final json = await client.rpc(
      'next_session_preview',
      params: {'p_user_id': uid},
    );
    if (json is! Map) return NextSessionPreview.none;
    return NextSessionPreview.fromJson(json.cast<String, dynamic>());
  }

  // ── sessions ─────────────────────────────────────────────────────────

  /// Logs one set. Sets hang off `session_exercises` now, so the parent row is
  /// created on first use and reused after that.
  Future<void> logSet(
    String sessionId,
    String exerciseId,
    int ordinal,
    int setNumber,
    double weightKg,
    int reps,
  ) async {
    final uid = currentUser?.id;
    if (uid == null) return;

    final sessionExerciseId = await _sessionExercise(
      uid,
      sessionId,
      exerciseId,
      ordinal,
    );

    await client.from('session_sets').insert({
      'user_id': uid,
      'session_exercise_id': sessionExerciseId,
      'set_number': setNumber,
      'weight_kg': weightKg,
      'reps': reps,
      'kind': 'working',
    });
  }

  /// The slot, not the exercise, is what's unique per session (`unique
  /// (session_id, ordinal)`) — a lifter can swap mid-session after this row
  /// already exists (e.g. just viewing the page creates it), and looking
  /// this up by exercise_id would then try to insert a second row for the
  /// same ordinal and hit that constraint. Keying and matching on ordinal
  /// instead, and repointing exercise_id on a mismatch, is what
  /// `swapped_from_exercise_id` exists for — this is the substitution the
  /// schema already models, not a workaround.
  Future<String> _sessionExercise(
    String uid,
    String sessionId,
    String exerciseId,
    int ordinal,
  ) async {
    final key = '$sessionId:$ordinal';
    final cached = _sessionExerciseIds[key];
    if (cached != null) return cached;

    final existing = await client
        .from('session_exercises')
        .select('id, exercise_id')
        .eq('session_id', sessionId)
        .eq('ordinal', ordinal)
        .maybeSingle();
    if (existing != null) {
      final id = existing['id'] as String;
      final currentExerciseId = existing['exercise_id'] as String;
      if (currentExerciseId != exerciseId) {
        await client
            .from('session_exercises')
            .update({
              'exercise_id': exerciseId,
              'swapped_from_exercise_id': currentExerciseId,
            })
            .eq('id', id);
      }
      _sessionExerciseIds[key] = id;
      return id;
    }

    final row = await client
        .from('session_exercises')
        .insert({
          'user_id': uid,
          'session_id': sessionId,
          'exercise_id': exerciseId,
          'ordinal': ordinal,
        })
        .select('id')
        .single();
    final id = row['id'] as String;
    _sessionExerciseIds[key] = id;
    return id;
  }

  /// The individual set rows for one exercise in one session, in the order
  /// they were logged — with real row ids, so a specific set can be edited
  /// or deleted. `today_plan` only returns the aggregated `[weight, reps]`
  /// pairs, which is enough to render the list but not enough to address one.
  Future<List<LoggedSetRow>> fetchSetsForExercise(
    String sessionId,
    String exerciseId,
    int ordinal,
  ) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final sessionExerciseId = await _sessionExercise(
      uid,
      sessionId,
      exerciseId,
      ordinal,
    );

    final rows = await client
        .from('session_sets')
        .select('id, set_number, weight_kg, reps')
        .eq('session_exercise_id', sessionExerciseId)
        .eq('is_completed', true)
        .order('set_number', ascending: true);

    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(
          (r) => LoggedSetRow(
            id: r['id'] as String,
            setNumber: r['set_number'] as int,
            weightKg: (r['weight_kg'] as num).toDouble(),
            reps: r['reps'] as int,
          ),
        )
        .toList();
  }

  Future<void> updateSet(
    String setId, {
    required double weightKg,
    required int reps,
  }) async {
    await client
        .from('session_sets')
        .update({'weight_kg': weightKg, 'reps': reps})
        .eq('id', setId);
  }

  Future<void> deleteSet(String setId) async {
    await client.from('session_sets').delete().eq('id', setId);
  }

  Future<void> completeSession(
    String sessionId, {
    String notes = '',
    int? rpe,
    List<String> pain = const [],
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return;

    await client
        .from('workout_sessions')
        .update({
          'status': 'completed',
          'completed_at': DateTime.now().toIso8601String(),
          'notes': notes,
          'session_rpe': rpe,
        })
        .eq('id', sessionId);

    if (pain.isNotEmpty) await _savePainReports(uid, sessionId, pain);

    // Mark the matching scheduled slot done, so adherence stays honest.
    if (_programDayId != null) {
      await client
          .from('scheduled_workouts')
          .update({'status': 'completed'})
          .eq('user_id', uid)
          .eq('program_day_id', _programDayId!)
          .eq('scheduled_for', _today());
    }
  }

  /// The summary screen collects body-part labels; these map onto joint slugs.
  static const _painSlugs = {
    'shoulder': 'shoulder',
    'elbow': 'elbow',
    'wrist': 'wrist',
    'knee': 'knee',
    'lower back': 'lumbar',
    'hip': 'hip',
    'ankle': 'ankle',
  };

  Future<void> _savePainReports(
    String uid,
    String sessionId,
    List<String> pain,
  ) async {
    final slugs = pain
        .map((p) => _painSlugs[p.toLowerCase()])
        .whereType<String>()
        .toSet()
        .toList();
    if (slugs.isEmpty) return;

    final joints = await client
        .from('joints')
        .select('id, slug')
        .inFilter('slug', slugs);
    final rows = (joints as List)
        .cast<Map<String, dynamic>>()
        .map(
          (j) => {
            'user_id': uid,
            'session_id': sessionId,
            'joint_id': j['id'],
            'severity': 'moderate',
          },
        )
        .toList();
    if (rows.isNotEmpty) {
      await client.from('session_pain_reports').insert(rows);
    }
  }

  // ── bodyweight and nutrition ─────────────────────────────────────────

  /// One weigh-in per calendar day: a second entry corrects the first.
  Future<void> logWeight(double weightKg) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('body_measurements').upsert({
      'user_id': uid,
      'measured_on': _today(),
      'weight_kg': weightKg,
    }, onConflict: 'user_id,measured_on');
  }

  /// From `v_bodyweight_trend`, so each entry carries both the raw reading
  /// and the 7-day trailing mean — day-to-day bodyweight swings ±1-2 kg on
  /// water and food alone, so the mean is what's worth charting.
  Future<List<WeightEntry>> fetchWeightLog({int limit = 12}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await client
        .from('v_bodyweight_trend')
        .select('measured_on, raw_kg, avg_7d')
        .eq('user_id', uid)
        .order('measured_on', ascending: false)
        .limit(limit);
    return (rows as List)
        .map(
          (r) => WeightEntry(
            weightKg: (r['raw_kg'] as num).toDouble(),
            avgKg: (r['avg_7d'] as num?)?.toDouble(),
            loggedAt: DateTime.parse(r['measured_on'] as String),
          ),
        )
        .toList()
        .reversed
        .toList();
  }

  /// The goal-derived daily protein target — see `protein_target_for(uuid)`.
  /// `protein_target_for` alone computes it; `syncProteinTarget` also
  /// persists it to `nutrition_targets`, worth calling after a weigh-in
  /// changes the basis.
  Future<ProteinTarget> fetchProteinTarget() async {
    final uid = currentUser?.id;
    if (uid == null) return ProteinTarget.placeholder;
    final rows = await client.rpc(
      'protein_target_for',
      params: {'p_user_id': uid},
    );
    final list = (rows as List?) ?? const [];
    if (list.isEmpty) return ProteinTarget.placeholder;
    return ProteinTarget.fromRow((list.first as Map).cast<String, dynamic>());
  }

  Future<void> syncProteinTarget() async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.rpc('sync_protein_target', params: {'p_user_id': uid});
  }

  Future<void> logProtein(int grams) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('nutrition_entries').insert({
      'user_id': uid,
      'logged_on': _today(),
      'protein_g': grams,
    });
  }

  Future<List<ProteinEntry>> fetchProteinLog({int limit = 14}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await client
        .from('nutrition_entries')
        .select('logged_at, protein_g')
        .eq('user_id', uid)
        .order('logged_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map(
          (r) => ProteinEntry(
            grams: (r['protein_g'] as num).round(),
            loggedAt: DateTime.parse(r['logged_at'] as String).toLocal(),
          ),
        )
        .toList()
        .reversed
        .toList();
  }

  // ── progress ─────────────────────────────────────────────────────────

  /// Completed sessions, newest first. Set count and tonnage come from
  /// v_session_totals rather than being recomputed over raw sets.
  Future<List<SessionHistoryEntry>> fetchSessionHistory({
    int limit = 12,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await client
        .from('v_session_totals')
        .select('title, performed_on, completed_at, set_count, volume_kg')
        .eq('user_id', uid)
        .order('performed_on', ascending: false)
        .limit(limit);

    return (rows as List).cast<Map<String, dynamic>>().map((r) {
      final completed = r['completed_at'] as String?;
      return SessionHistoryEntry(
        label: (r['title'] as String?) ?? 'Session',
        date: DateTime.parse(
          completed ?? r['performed_on'] as String,
        ).toLocal(),
        setCount: (r['set_count'] as num?)?.toInt() ?? 0,
        volumeKg: (r['volume_kg'] as num?)?.toDouble() ?? 0,
      );
    }).toList();
  }

  /// Top set per day for a given exercise, oldest first — the series behind
  /// the strength trend chart. Takes the display name the progress screen
  /// shows and resolves it back to a catalog id.
  Future<List<StrengthPoint>> fetchStrengthTrend(
    String exerciseName, {
    int limit = 12,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return [];

    final exerciseId = await _resolveExerciseId(uid, exerciseName);
    if (exerciseId == null) return [];

    final rows = await client
        .from('v_exercise_daily_bests')
        .select('performed_on, top_weight_kg')
        .eq('user_id', uid)
        .eq('exercise_id', exerciseId)
        .not('top_weight_kg', 'is', null)
        .order('performed_on', ascending: false)
        .limit(limit);

    return (rows as List)
        .map(
          (r) => StrengthPoint(
            date: DateTime.parse(r['performed_on'] as String),
            topSetKg: (r['top_weight_kg'] as num).toDouble(),
          ),
        )
        .toList()
        .reversed
        .toList();
  }

  Future<String?> _resolveExerciseId(String uid, String name) async {
    final cached = _exerciseIdsByName[name];
    if (cached != null) return cached;

    final rows = await client.rpc(
      'resolve_exercise',
      params: {'p_user_id': uid, 'p_name': name},
    );
    final list = (rows as List?) ?? const [];
    if (list.isEmpty) return null;
    final id = (list.first as Map)['exercise_id'] as String?;
    if (id != null) _exerciseIdsByName[name] = id;
    return id;
  }

  /// Exercise names the user has actually logged, most frequent first.
  Future<List<String>> fetchLoggedExerciseNames({int limit = 6}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    // The FK must be named explicitly: session_exercises points at exercises
    // twice (exercise_id and swapped_from_exercise_id), so a bare
    // `exercises(...)` embed is ambiguous and PostgREST rejects it (PGRST201).
    final rows = await client
        .from('session_exercises')
        .select(
          'exercise_id, '
          'exercises!session_exercises_exercise_id_fkey!inner(name)',
        )
        .eq('user_id', uid)
        .limit(500);

    final counts = <String, int>{};
    for (final r in (rows as List).cast<Map<String, dynamic>>()) {
      final name = (r['exercises'] as Map?)?['name'] as String?;
      final id = r['exercise_id'] as String?;
      if (name == null || id == null) continue;
      _exerciseIdsByName[name] = id;
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final sorted = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return sorted.take(limit).toList();
  }

  /// Dates (date-only) of completed sessions in the last [days] days — drives
  /// the consistency grid and the streak counter. `performed_on` is already
  /// stamped in the user's own timezone by the database.
  Future<Set<DateTime>> fetchTrainingDays({int days = 84}) async {
    final uid = currentUser?.id;
    if (uid == null) return {};
    final since = DateTime.now().subtract(Duration(days: days));
    final sinceDate =
        '${since.year.toString().padLeft(4, '0')}-'
        '${since.month.toString().padLeft(2, '0')}-'
        '${since.day.toString().padLeft(2, '0')}';

    final rows = await client
        .from('workout_sessions')
        .select('performed_on')
        .eq('user_id', uid)
        .eq('status', 'completed')
        .gte('performed_on', sinceDate);

    return (rows as List).map((r) {
      final d = DateTime.parse(r['performed_on'] as String);
      return DateTime(d.year, d.month, d.day);
    }).toSet();
  }

  // ── coach chat ───────────────────────────────────────────────────────

  Future<String?> _thread({bool create = true}) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    if (_threadId != null) return _threadId;

    final existing = await client
        .from('coach_threads')
        .select('id')
        .eq('user_id', uid)
        .order('last_message_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (existing != null) return _threadId = existing['id'] as String;
    if (!create) return null;

    final row = await client
        .from('coach_threads')
        .insert({'user_id': uid, 'title': 'Coach'})
        .select('id')
        .single();
    return _threadId = row['id'] as String;
  }

  /// [sender] is the app's own vocabulary ('user' | 'coach'); the coach maps
  /// onto the schema's 'assistant' role.
  Future<void> saveChatMessage(String sender, String body) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    final threadId = await _thread();
    if (threadId == null) return;

    await client.from('coach_messages').insert({
      'user_id': uid,
      'thread_id': threadId,
      'role': sender == 'user' ? 'user' : 'assistant',
      'content': body,
    });
    await client
        .from('coach_threads')
        .update({'last_message_at': DateTime.now().toIso8601String()})
        .eq('id', threadId);
  }

  Future<List<ChatMessage>> fetchChatHistory({int limit = 50}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final threadId = await _thread(create: false);
    if (threadId == null) return [];

    final rows = await client
        .from('coach_messages')
        .select('role, content')
        .eq('user_id', uid)
        .eq('thread_id', threadId)
        .inFilter('role', ['user', 'assistant'])
        .order('created_at', ascending: true)
        .limit(limit);

    return (rows as List)
        .map(
          (r) => ChatMessage(
            sender: r['role'] == 'user' ? 'user' : 'coach',
            body: r['content'] as String,
          ),
        )
        .toList();
  }

  /// Placeholder for the Gemini Edge Function. AppState routes every reply
  /// through one call site, so switching to this is a one-line change there.
  // ── coach Edge Function ────────────────────────────────────────────────
  // The function owns the conversation: it persists both sides of the turn
  // into coach_messages itself, so callers must NOT also save the message.

  String? _coachThreadId;

  /// One chat turn. Returns the reply and any proposal awaiting confirmation.
  Future<CoachTurn> coachTurn(String text) async {
    final res = await client.functions.invoke(
      'coach',
      body: {
        'text': text,
        if (_coachThreadId != null) 'thread_id': _coachThreadId,
      },
    );

    final data = res.data;
    if (data is! Map) throw StateError('Unexpected coach response: $data');
    if (data['error'] != null) throw StateError(data['error'].toString());

    _coachThreadId = data['thread_id'] as String? ?? _coachThreadId;

    final reply = (data['reply'] as String?)?.trim() ?? '';
    final proposal = data['proposal'];
    if (proposal is! Map) return CoachTurn(reply: reply);

    final payload = proposal['payload'];
    final sets = (payload is Map ? payload['sets'] : null) as List? ?? const [];

    return CoachTurn(
      reply: reply,
      proposalId: proposal['id'] as String?,
      pending: sets.map((s) {
        final row = s as Map;
        return PendingLogRow(
          exerciseId: row['exercise_id'] as String?,
          exerciseName: row['exercise_name'] as String? ?? 'Exercise',
          weightKg: (row['weight_kg'] as num?)?.toDouble() ?? 0,
          reps: (row['reps'] as num?)?.toInt() ?? 0,
          sets: (row['count'] as num?)?.toInt() ?? 1,
        );
      }).toList(),
    );
  }

  /// Execute a proposal. Deterministic server-side — no model on this path.
  /// Safe to call twice: the server guards on `status = 'pending'`.
  Future<void> confirmProposal(String proposalId) async {
    final res = await client.functions.invoke(
      'coach/confirm',
      body: {'proposal_id': proposalId},
    );
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw StateError(data['error'].toString());
    }
  }

  Future<void> rejectProposal(String proposalId) async {
    await client.functions.invoke(
      'coach/reject',
      body: {'proposal_id': proposalId},
    );
  }
}
