import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import 'supabase_service.dart';
import '../models/v2_models.dart';

/// v2 service methods, kept in an extension so `SupabaseService` stays the one
/// file that imports the Supabase client (it exposes `client`/`currentUser`).
extension SupabaseServiceV2 on SupabaseService {
  /// Everything the Train tab / session flow needs for today.
  Future<TrainScreenV2?> fetchTrainScreen() async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final json = await client.rpc('train_screen', params: {'p_user_id': uid});
    if (json is! Map) return null;
    return TrainScreenV2.fromJson(json.cast<String, dynamic>());
  }

  /// (Re)generate the active program via the v2 generator. Bench calibration
  /// optional. Returns the new program id.
  Future<String?> generateProgram({double? benchStartKg}) async {
    if (currentUser == null) return null;
    final id = await client.rpc('bootstrap_my_program', params: {
      'p_bench_start_kg': ?benchStartKg,
    });
    return id as String?;
  }

  /// Roll the schedule forward so the calendar is always ~5 weeks deep. Cheap,
  /// idempotent; called fire-and-forget after a Train load.
  Future<void> ensureSchedule() async {
    if (currentUser == null) return;
    try {
      await client.rpc('ensure_my_schedule');
    } catch (_) {/* the calendar is already filled near-term; harmless */}
  }

  /// Reorder the split by swapping two training days. [scope] is 'week' (just
  /// these dates) or 'forever' (the pattern, every week from now). Undo by
  /// calling again with [from] and [to] swapped.
  Future<void> swapScheduledDays(DateTime from, DateTime to, String scope) async {
    await client.rpc('swap_scheduled_days', params: {
      'p_from': _dateStr(from),
      'p_to': _dateStr(to),
      'p_scope': scope,
    });
  }

  /// "Make it the plan": persist a session's reordered lifts to today's program
  /// day so future sessions present the new order. [exerciseIds] in order.
  Future<void> reorderMyDay(List<String> exerciseIds) async {
    await client.rpc('reorder_my_day', params: {'p_exercise_ids': exerciseIds});
  }

  /// The single open session, created if needed. One in_progress session per
  /// user is a hard DB invariant, so an already-open session (even from an
  /// earlier day the lifter never finished) is resumed rather than colliding —
  /// re-stamped to today so it reads as today's work.
  Future<String?> openSession({String? title}) async {
    final uid = currentUser?.id;
    if (uid == null) return null;

    final open = await client
        .from('workout_sessions')
        .select('id, performed_on')
        .eq('user_id', uid)
        .eq('status', 'in_progress')
        .maybeSingle();

    if (open != null) {
      final today = DateTime.now();
      final todayStr = '${today.year.toString().padLeft(4, '0')}-'
          '${today.month.toString().padLeft(2, '0')}-'
          '${today.day.toString().padLeft(2, '0')}';
      if (open['performed_on'] != todayStr) {
        await client
            .from('workout_sessions')
            .update({'performed_on': todayStr, 'started_at': today.toUtc().toIso8601String()})
            .eq('id', open['id'] as String);
      }
      return open['id'] as String;
    }

    final id = await client.rpc('open_session_for_today', params: {
      'p_user_id': uid,
      'p_title': ?title,
    });
    return id as String?;
  }

  /// Everything already logged in a session, keyed by exercise ordinal — so
  /// "Continue session" can rehydrate the in-memory flow instead of starting
  /// blank at lift one every time.
  Future<Map<int, ResumedLiftV2>> fetchResumeState(String sessionId) async {
    final uid = currentUser?.id;
    if (uid == null) return {};
    final rows = await client
        .from('session_exercises')
        .select('ordinal, entry_mode, effort, is_unconfirmed, '
            'session_sets(weight_kg, reps, set_number, kind, is_completed)')
        .eq('session_id', sessionId)
        .eq('user_id', uid);

    final out = <int, ResumedLiftV2>{};
    for (final row in (rows as List).cast<Map<String, dynamic>>()) {
      final ordinal = (row['ordinal'] as num?)?.toInt();
      if (ordinal == null) continue;
      final rawSets = (row['session_sets'] as List?) ?? const [];
      final sets = rawSets
          .cast<Map<String, dynamic>>()
          .where((s) => s['kind'] == 'working' && s['is_completed'] == true)
          .toList()
        ..sort((a, b) =>
            ((a['set_number'] as num?) ?? 0).compareTo((b['set_number'] as num?) ?? 0));
      out[ordinal] = ResumedLiftV2(
        ordinal: ordinal,
        entryMode: EntryModeV2Parse.fromDb(row['entry_mode'] as String?),
        effort: EffortV2.fromDb(row['effort'] as String?),
        unconfirmed: row['is_unconfirmed'] as bool? ?? false,
        sets: sets
            .map((s) => ((s['weight_kg'] as num?)?.toDouble(), (s['reps'] as num?)?.toInt() ?? 0))
            .toList(),
      );
    }
    return out;
  }

  /// Look up (or create) the session_exercises row for one lift in a session,
  /// keyed by ordinal — the schema's unique key is (session_id, ordinal), so a
  /// mid-session swap repoints exercise_id rather than colliding.
  Future<String?> _sessionExerciseV2(
    String sessionId,
    String exerciseId,
    int ordinal,
  ) async {
    final uid = currentUser?.id;
    if (uid == null) return null;

    final existing = await client
        .from('session_exercises')
        .select('id, exercise_id')
        .eq('session_id', sessionId)
        .eq('ordinal', ordinal)
        .maybeSingle();

    if (existing != null) {
      final id = existing['id'] as String;
      if (existing['exercise_id'] != exerciseId) {
        await client.from('session_exercises').update({
          'exercise_id': exerciseId,
          'swapped_from_exercise_id': existing['exercise_id'],
        }).eq('id', id);
      }
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
    return row['id'] as String;
  }

  /// Write one lift's full result: the session_exercises provenance (effort,
  /// entry mode, unconfirmed) plus its set rows. Replaces any prior sets for
  /// that lift, so re-saving a corrected lift overwrites cleanly.
  ///
  /// [rows] are (weightKg, reps); weightKg is null for bodyweight lifts. The
  /// effort answer is written both onto session_exercises.effort and mapped
  /// onto every working set's rir (D1).
  Future<void> saveLift({
    required String sessionId,
    required String exerciseId,
    required int ordinal,
    required List<(double?, int)> rows,
    EffortV2? effort,
    required EntryModeV2 entryMode,
    bool unconfirmed = false,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return;

    final seId = await _sessionExerciseV2(sessionId, exerciseId, ordinal);
    if (seId == null) return;

    await client.from('session_exercises').update({
      'effort': effort?.dbValue,
      'entry_mode': entryMode.name,
      'is_unconfirmed': unconfirmed,
    }).eq('id', seId);

    // Overwrite: drop existing sets, then re-insert.
    await client.from('session_sets').delete().eq('session_exercise_id', seId);

    if (rows.isEmpty) return;
    final payload = <Map<String, dynamic>>[];
    for (var i = 0; i < rows.length; i++) {
      payload.add({
        'user_id': uid,
        'session_exercise_id': seId,
        'set_number': i + 1,
        'kind': 'working',
        'weight_kg': rows[i].$1,
        'reps': rows[i].$2,
        'rir': effort?.rir,
      });
    }
    await client.from('session_sets').insert(payload);
  }

  /// Persist a running rest countdown so it survives backgrounding (D4).
  Future<void> setRestTimer(String sessionId, {int? startedFromSeconds}) async {
    await client.from('workout_sessions').update({
      'rest_started_at': startedFromSeconds == null
          ? null
          : DateTime.now().toUtc().toIso8601String(),
      'rest_total_seconds': startedFromSeconds,
    }).eq('id', sessionId);
  }

  /// Mark the session complete, stamping the situation adaptation if any, then
  /// write the coach's debrief note from what actually happened.
  Future<void> finishSession(String sessionId, {String? situation}) async {
    await client.from('workout_sessions').update({
      'status': 'completed',
      'completed_at': DateTime.now().toUtc().toIso8601String(),
      'situation': situation,
      'rest_started_at': null,
      'rest_total_seconds': null,
    }).eq('id', sessionId);
    // Fire-and-forget: the session is already saved. The debrief note lands in
    // the Trainer thread in the background so finishing — and landing on the
    // post-session summary — is never gated on writing it. Idempotent, so a
    // retry or a double finish still yields one note.
    unawaited(_writeSessionDebrief(sessionId).catchError((_) {}));
  }

  Future<void> setSituation(String sessionId, String? situation) async {
    await client
        .from('workout_sessions')
        .update({'situation': situation}).eq('id', sessionId);
  }

  // ── Train after-state ────────────────────────────────────────────────────

  /// The completed-session recap: volume, bars, trend, muscles, PBs.
  Future<SessionSummaryV2?> fetchSessionSummary(String sessionId) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final json = await client.rpc('session_summary',
        params: {'p_user_id': uid, 'p_session_id': sessionId});
    if (json is! Map) return null;
    return SessionSummaryV2.fromJson(json.cast<String, dynamic>());
  }

  /// "Next time these go up" — one row per active-program lift.
  Future<List<ProgressionV2>> fetchProgressions() async {
    final uid = currentUser?.id;
    if (uid == null) return const [];
    final rows = await client.rpc('progression_suggestions', params: {'p_user_id': uid});
    if (rows is! List) return const [];
    return rows
        .cast<Map<String, dynamic>>()
        .map(ProgressionV2.fromJson)
        .toList();
  }

  // ── Train before-state extras ────────────────────────────────────────────

  /// Today's pinned trainer note with its receipts, if the coach left one.
  Future<MorningNoteV2?> fetchMorningNote() async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final row = await client
        .from('coach_messages')
        .select('id, content, created_at, pinned_until, read_at, acknowledged_at, '
            'receipts:coach_message_receipts(icon, label, position)')
        .eq('user_id', uid)
        .eq('category', 'morning_note')
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (row == null) return null;
    final receipts = (row['receipts'] as List?) ?? const [];
    receipts.sort((a, b) =>
        ((a as Map)['position'] as num).compareTo((b as Map)['position'] as num));
    return MorningNoteV2.fromJson({...row, 'receipts': receipts});
  }

  /// Today's weight + protein against target, for the "Body & fuel today" card.
  Future<BodyFuelV2> fetchBodyFuel() async {
    final uid = currentUser?.id;
    if (uid == null) {
      return const BodyFuelV2(weightKg: null, proteinG: 0, proteinTargetG: null);
    }
    final today = _todayStr();

    final weightRow = await client
        .from('body_measurements')
        .select('weight_kg')
        .eq('user_id', uid)
        .order('measured_on', ascending: false)
        .limit(1)
        .maybeSingle();

    final proteinRows = await client
        .from('nutrition_entries')
        .select('protein_g')
        .eq('user_id', uid)
        .eq('logged_on', today);
    final protein = (proteinRows as List).fold<double>(
        0, (sum, r) => sum + ((r as Map)['protein_g'] as num).toDouble());

    final targetRow = await client
        .from('nutrition_targets')
        .select('protein_g')
        .eq('user_id', uid)
        .isFilter('valid_to', null)
        .maybeSingle();

    return BodyFuelV2(
      weightKg: (weightRow?['weight_kg'] as num?)?.toDouble(),
      proteinG: protein,
      proteinTargetG: (targetRow?['protein_g'] as num?)?.toInt(),
    );
  }

  /// Mark a coach note read when the Train tab surfaces it.
  Future<void> markNoteRead(String messageId) async {
    await client.from('coach_messages').update({
      'read_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', messageId).isFilter('read_at', null);
  }

  String _todayStr() => _dateStr(DateTime.now());

  String _dateStr(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  // ── Progress tab ─────────────────────────────────────────────────────────

  Future<ProgressGatesV2?> fetchProgressGates() async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final json = await client.rpc('progress_gates', params: {'p_user_id': uid});
    if (json is! Map) return null;
    return ProgressGatesV2.fromJson(json.cast<String, dynamic>());
  }

  Future<List<LiftStatusV2>> fetchLiftStatus({DateTime? since}) async {
    final uid = currentUser?.id;
    if (uid == null) return const [];
    final rows = await client.rpc('lift_status', params: {
      'p_user_id': uid,
      'p_since': since == null ? null : _dateStr(since),
    });
    if (rows is! List) return const [];
    return rows.cast<Map<String, dynamic>>().map(LiftStatusV2.fromJson).toList();
  }

  /// [(rirBucket, setCount)], bucket 0..6.
  Future<List<(int, int)>> fetchEffortHistogram({DateTime? since}) async {
    final uid = currentUser?.id;
    if (uid == null) return const [];
    final rows = await client.rpc('effort_histogram', params: {
      'p_user_id': uid,
      'p_since': since == null ? null : _dateStr(since),
    });
    if (rows is! List) return const [];
    return rows
        .cast<Map<String, dynamic>>()
        .map((r) => ((r['rir_bucket'] as num).toInt(), (r['set_count'] as num).toInt()))
        .toList();
  }

  Future<List<MuscleChipV2>> fetchMuscleSets({required DateTime since}) async {
    final uid = currentUser?.id;
    if (uid == null) return const [];
    final rows = await client.rpc('weekly_sets_by_muscle',
        params: {'p_user_id': uid, 'p_since': _dateStr(since)});
    if (rows is! List) return const [];
    return rows
        .cast<Map<String, dynamic>>()
        .map((r) => MuscleChipV2(
            group: r['display_group'] as String? ?? '',
            sets: (r['set_count'] as num?)?.toInt() ?? 0))
        .toList();
  }

  Future<List<ConsistencyWeekV2>> fetchConsistency({DateTime? since}) async {
    final uid = currentUser?.id;
    if (uid == null) return const [];
    final rows = await client.rpc('consistency_weeks', params: {
      'p_user_id': uid,
      'p_since': since == null ? null : _dateStr(since),
    });
    if (rows is! List) return const [];
    return rows.cast<Map<String, dynamic>>().map(ConsistencyWeekV2.fromJson).toList();
  }

  Future<PhotoPairV2?> fetchPhotoPair({DateTime? since}) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final json = await client.rpc('progress_photo_pair', params: {
      'p_user_id': uid,
      'p_since': since == null ? null : _dateStr(since),
    });
    if (json is! Map) return null;
    return PhotoPairV2.fromJson(json.cast<String, dynamic>());
  }

  /// Calendar days [from]..[to] (inclusive) on which a session was completed —
  /// as 'yyyy-MM-dd' keys, for the Progress consistency month grid.
  Future<Set<String>> fetchTrainingDayKeys(DateTime from, DateTime to) async {
    final uid = currentUser?.id;
    if (uid == null) return <String>{};
    final rows = await client
        .from('workout_sessions')
        .select('performed_on')
        .eq('user_id', uid)
        .eq('status', 'completed')
        .gte('performed_on', _dateStr(from))
        .lte('performed_on', _dateStr(to));
    final out = <String>{};
    for (final r in rows as List) {
      final d = (r as Map)['performed_on'];
      if (d is String) out.add(d.substring(0, 10));
    }
    return out;
  }

  /// Upload a progress photo (private bucket) and record it. Returns the stored
  /// object path, or null if not signed in. [bytes] is the image data; [ext] the
  /// file extension without the dot (e.g. 'jpg'). Bodyweight is not stored here —
  /// the pair RPC reads it from the weigh-in on the photo's day.
  Future<String?> uploadProgressPhoto({
    required Uint8List bytes,
    String ext = 'jpg',
    DateTime? takenOn,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final day = takenOn ?? DateTime.now();
    final path = '$uid/${DateTime.now().millisecondsSinceEpoch}.$ext';
    await client.storage.from('progress-photos').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
            upsert: true,
          ),
        );
    await client.from('progress_photos').insert({
      'user_id': uid,
      'storage_path': path,
      'taken_on': _dateStr(day),
    });
    return path;
  }

  /// Every progress photo, oldest-first, each with the bodyweight logged on its
  /// day (if any) — for the swipable comparison gallery.
  Future<List<PhotoV2>> fetchAllProgressPhotos() async {
    final uid = currentUser?.id;
    if (uid == null) return const [];
    final rows = await client
        .from('progress_photos')
        .select('taken_on, storage_path')
        .eq('user_id', uid)
        .order('taken_on', ascending: true)
        .order('created_at', ascending: true);
    final wRows = await client
        .from('body_measurements')
        .select('measured_on, weight_kg')
        .eq('user_id', uid);
    final wByDay = <String, double>{};
    for (final r in wRows as List) {
      final d = (r as Map)['measured_on'];
      final w = r['weight_kg'] as num?;
      if (d is String && w != null) wByDay[d.substring(0, 10)] = w.toDouble();
    }
    final out = <PhotoV2>[];
    for (final r in rows as List) {
      final m = r as Map;
      final on = m['taken_on'] as String?;
      if (on == null) continue;
      out.add(PhotoV2(
        takenOn: DateTime.parse(on),
        storagePath: m['storage_path'] as String? ?? '',
        weightKg: wByDay[on.substring(0, 10)],
      ));
    }
    return out;
  }

  /// Delete one progress photo — the record first (RLS-scoped to the caller),
  /// then the stored object (best-effort; a leftover blob is harmless).
  Future<void> deleteProgressPhoto(String storagePath) async {
    final uid = currentUser?.id;
    if (uid == null || storagePath.isEmpty) return;
    await client
        .from('progress_photos')
        .delete()
        .eq('user_id', uid)
        .eq('storage_path', storagePath);
    try {
      await client.storage.from('progress-photos').remove([storagePath]);
    } catch (_) {
      // The row is gone; an orphaned object will never be referenced again.
    }
  }

  /// Short-lived signed URL for a progress photo (private bucket).
  Future<String?> signedPhotoUrl(String path) async {
    if (path.isEmpty) return null;
    try {
      return await client.storage
          .from('progress-photos')
          .createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  /// Bodyweight series + 7-day average + weekly slope, computed client-side.
  Future<BodyTrendV2> fetchBodyTrend({DateTime? since}) async {
    final uid = currentUser?.id;
    if (uid == null) {
      return const BodyTrendV2(sevenDayAvg: null, kgPerWeek: null, targetKg: null, points: []);
    }
    var q = client.from('body_measurements').select('measured_on, weight_kg').eq('user_id', uid);
    if (since != null) q = q.gte('measured_on', _dateStr(since));
    final rows = await q.order('measured_on', ascending: true);

    final points = <(DateTime, double)>[];
    for (final r in rows as List) {
      final w = (r as Map)['weight_kg'] as num?;
      if (w != null) points.add((DateTime.parse(r['measured_on'] as String), w.toDouble()));
    }

    final targetRow = await client
        .from('training_profiles')
        .select('target_weight_kg')
        .eq('user_id', uid)
        .isFilter('valid_to', null)
        .maybeSingle();
    final target = (targetRow?['target_weight_kg'] as num?)?.toDouble();

    if (points.isEmpty) {
      return BodyTrendV2(sevenDayAvg: null, kgPerWeek: null, targetKg: target, points: points);
    }

    // 7-day average: mean of weigh-ins within 7 days of the latest.
    final latest = points.last.$1;
    final window = points.where((p) => latest.difference(p.$1).inDays <= 7).toList();
    final avg7 = window.fold<double>(0, (s, p) => s + p.$2) / window.length;

    // Weekly slope via least squares over (days, weight).
    double? kgPerWeek;
    if (points.length >= 2) {
      final base = points.first.$1;
      final xs = points.map((p) => base.difference(p.$1).inDays.abs().toDouble()).toList();
      final ys = points.map((p) => p.$2).toList();
      final n = xs.length;
      final mx = xs.reduce((a, b) => a + b) / n;
      final my = ys.reduce((a, b) => a + b) / n;
      var num = 0.0, den = 0.0;
      for (var i = 0; i < n; i++) {
        num += (xs[i] - mx) * (ys[i] - my);
        den += (xs[i] - mx) * (xs[i] - mx);
      }
      if (den != 0) kgPerWeek = (num / den) * 7;
    }

    return BodyTrendV2(sevenDayAvg: avg7, kgPerWeek: kgPerWeek, targetKg: target, points: points);
  }

  /// Protein adherence over the trailing seven days.
  Future<ProteinWeekV2> fetchProteinWeek() async {
    final uid = currentUser?.id;
    if (uid == null) {
      return const ProteinWeekV2(hitDays: 0, loggedDays: 0, targetG: null, averageG: 0);
    }
    final since = _dateStr(DateTime.now().subtract(const Duration(days: 6)));
    final rows = await client
        .from('nutrition_entries')
        .select('logged_on, protein_g')
        .eq('user_id', uid)
        .gte('logged_on', since);

    final byDay = <String, double>{};
    for (final r in rows as List) {
      final d = (r as Map)['logged_on'] as String;
      byDay[d] = (byDay[d] ?? 0) + ((r['protein_g'] as num?)?.toDouble() ?? 0);
    }

    final targetRow = await client
        .from('nutrition_targets')
        .select('protein_g')
        .eq('user_id', uid)
        .isFilter('valid_to', null)
        .maybeSingle();
    final target = (targetRow?['protein_g'] as num?)?.toInt();

    final logged = byDay.length;
    final hit = target == null ? 0 : byDay.values.where((v) => v >= target).length;
    final avg = logged == 0 ? 0.0 : byDay.values.reduce((a, b) => a + b) / logged;
    return ProteinWeekV2(hitDays: hit, loggedDays: logged, targetG: target, averageG: avg);
  }

  // ── Profile tab ────────────────────────────────────────────────────────────

  /// One load for the whole Profile screen: identity, stats, plan inputs,
  /// preferences, constraints, pause state. Named `…Screen` to avoid the base
  /// service's `fetchProfile()` (a v1 method returning `Profile`).
  Future<ProfileDataV2?> fetchProfileScreen() async {
    final uid = currentUser?.id;
    if (uid == null) return null;

    final results = await Future.wait(<Future<dynamic>>[
      client.from('profiles').select('display_name, avatar_url').eq('id', uid).maybeSingle(),
      client
          .from('training_profiles')
          .select('goals, goal_is_coach_choice, target_weight_kg, '
              'target_direction, training_weekdays, split_preference, experience, '
              'environment, bar_weight_kg, plate_sizes_kg, intake_confirmed')
          .eq('user_id', uid)
          .isFilter('valid_to', null)
          .maybeSingle(),
      client.from('user_preferences').select('*').eq('user_id', uid).maybeSingle(),
      client
          .from('body_measurements')
          .select('weight_kg')
          .eq('user_id', uid)
          .order('measured_on', ascending: false)
          .limit(1)
          .maybeSingle(),
      client
          .from('user_constraints')
          .select('id, label, side, joint_id, joints(name)')
          .eq('user_id', uid)
          .isFilter('active_to', null),
      client.rpc('is_training_paused', params: {'p_user_id': uid}),
      client.rpc('progress_gates', params: {'p_user_id': uid}),
      client
          .from('program_weekday_slots')
          .select('weekday, program_days(label)')
          .eq('user_id', uid),
    ]);

    final profile = results[0] as Map<String, dynamic>?;
    final tp = results[1] as Map<String, dynamic>? ?? const {};
    final prefs = results[2] as Map<String, dynamic>?;
    final weight = results[3] as Map<String, dynamic>?;
    final constraints = (results[4] as List?) ?? const [];
    final paused = results[5] == true;
    final gates = (results[6] as Map?)?.cast<String, dynamic>() ?? const {};
    final slots = (results[7] as List?) ?? const [];
    final weekdaySlots = <int, String>{};
    for (final s in slots) {
      final m = s as Map;
      final wd = (m['weekday'] as num?)?.toInt();
      final label = (m['program_days'] as Map?)?['label'] as String?;
      if (wd != null && label != null) weekdaySlots[wd] = label;
    }

    // Fall back to the sign-in identity (Google fills these in the auth
    // metadata) when the profile row hasn't been named yet, and backfill it
    // once so initials and future loads have a real name.
    final meta = currentUser?.userMetadata ?? const {};
    var displayName = (profile?['display_name'] as String?)?.trim();
    // Default to just the first name from the sign-in identity, until the user
    // edits it to whatever they like.
    final rawName = ((meta['full_name'] ?? meta['name']) as String?)?.trim();
    final metaName = (rawName == null || rawName.isEmpty)
        ? null
        : rawName.split(RegExp(r'\s+')).first;
    final avatarUrl = (profile?['avatar_url'] as String?) ??
        (meta['avatar_url'] ?? meta['picture']) as String?;
    if ((displayName == null || displayName.isEmpty) &&
        metaName != null &&
        metaName.isNotEmpty) {
      displayName = metaName;
      unawaited(client
          .from('profiles')
          .update({'display_name': metaName})
          .eq('id', uid)
          .then((_) {}, onError: (_) {}));
    }

    return ProfileDataV2(
      displayName: (displayName == null || displayName.isEmpty) ? null : displayName,
      email: currentUser?.email,
      avatarUrl: avatarUrl,
      splitPreference: tp['split_preference'] as String? ?? 'no_preference',
      experience: tp['experience'] as String?,
      environment: tp['environment'] as String?,
      intakeConfirmed: (tp['intake_confirmed'] as bool?) ?? false,
      weekdaySlots: weekdaySlots,
      sessionsTotal: (gates['sessions_total'] as num?)?.toInt() ?? 0,
      weeksTraining: (gates['weeks_of_history'] as num?)?.toInt() ?? 0,
      paused: paused,
      goals: ((tp['goals'] as List?) ?? const [])
          .cast<String>()
          .map(GoalV2.fromDb)
          .whereType<GoalV2>()
          .toList(),
      goalIsCoachChoice: tp['goal_is_coach_choice'] as bool? ?? false,
      targetWeightKg: (tp['target_weight_kg'] as num?)?.toDouble(),
      targetDirection: tp['target_direction'] as String?,
      trainingWeekdays: ((tp['training_weekdays'] as List?) ?? const [])
          .map((d) => (d as num).toInt())
          .toList()
        ..sort(),
      barWeightKg: (tp['bar_weight_kg'] as num?)?.toDouble() ?? 20,
      plateSizes: ((tp['plate_sizes_kg'] as List?) ?? const [])
          .map((p) => (p as num).toDouble())
          .toList(),
      latestWeightKg: (weight?['weight_kg'] as num?)?.toDouble(),
      constraints: constraints
          .cast<Map<String, dynamic>>()
          .map(ConstraintV2.fromJson)
          .toList(),
      prefs: PreferencesV2.fromJson(prefs ?? const {}),
    );
  }

  /// Instant preference write-through (units, rest, effort, toggles).
  Future<void> updatePreferences(Map<String, dynamic> patch) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('user_preferences').update(patch).eq('user_id', uid);
  }

  /// Just the effort-prompt frequency — read once when a session starts, so
  /// the session flow doesn't have to load the whole Profile screen's worth
  /// of data to honour one setting.
  Future<String> fetchEffortPromptPref() async {
    final uid = currentUser?.id;
    if (uid == null) return 'first_set';
    final row = await client
        .from('user_preferences')
        .select('effort_prompt')
        .eq('user_id', uid)
        .maybeSingle();
    return row?['effort_prompt'] as String? ?? 'first_set';
  }

  /// Just the keep-screen-awake toggle — read once when a session starts,
  /// same reasoning as [fetchEffortPromptPref].
  Future<bool> fetchKeepScreenAwakePref() async {
    final uid = currentUser?.id;
    if (uid == null) return true;
    final row = await client
        .from('user_preferences')
        .select('keep_screen_awake')
        .eq('user_id', uid)
        .maybeSingle();
    return row?['keep_screen_awake'] as bool? ?? true;
  }

  /// Instant plate-inventory write.
  Future<void> updatePlateSizes(List<double> sizes) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    final sorted = [...sizes]..sort((a, b) => b.compareTo(a));
    await client
        .from('training_profiles')
        .update({'plate_sizes_kg': sorted})
        .eq('user_id', uid)
        .isFilter('valid_to', null);
  }

  /// Staged plan edits, committed on "Rewrite my week". Only the fields present
  /// in [patch] are written; keys are training_profiles column names.
  Future<void> updatePlanProfile(Map<String, dynamic> patch) async {
    final uid = currentUser?.id;
    if (uid == null || patch.isEmpty) return;
    await client
        .from('training_profiles')
        .update(patch)
        .eq('user_id', uid)
        .isFilter('valid_to', null);
  }

  /// Set the user's display name.
  Future<void> updateDisplayName(String name) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('profiles').update({'display_name': name.trim()}).eq('id', uid);
  }

  /// Upload a profile picture to the public `avatars` bucket and point
  /// profiles.avatar_url at it. Returns the public URL.
  Future<String?> uploadAvatar({required Uint8List bytes, String ext = 'jpg'}) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final path = '$uid/avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await client.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
            upsert: true,
          ),
        );
    final url = client.storage.from('avatars').getPublicUrl(path);
    await client.from('profiles').update({'avatar_url': url}).eq('id', uid);
    return url;
  }

  /// Swap which session lands on two weekdays — a permanent (every-week)
  /// rearrange of the split, from the Profile "Your plan" strip.
  Future<void> swapProgramWeekdays(int weekdayA, int weekdayB) async {
    await client.rpc('swap_program_weekdays', params: {
      'p_wf': weekdayA,
      'p_wt': weekdayB,
    });
  }

  /// Flag a new "working around" area — a real joint+side, or a free-text
  /// note when [jointId] is null. Written immediately (staged only on the
  /// client, like the rest of Profile's plan edits), so it's already in place
  /// by the time "Rewrite my week" regenerates the program.
  Future<void> addConstraint({
    String? jointId,
    String? side,
    required String label,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('user_constraints').insert({
      'user_id': uid,
      'joint_id': ?jointId,
      'side': ?side,
      'label': label,
      'severity': 'mild',
      'active_from': _todayStr(),
    });
  }

  /// Soft-close a constraint — the schema's own point-in-time model, same
  /// pattern reads already filter on (`active_to IS NULL`).
  Future<void> removeConstraint(String constraintId) async {
    await client
        .from('user_constraints')
        .update({'active_to': _todayStr()})
        .eq('id', constraintId);
  }

  /// Open a pause (Ill / travelling / hurt). At most one open pause exists —
  /// the DB enforces it — so this no-ops cleanly if already paused.
  Future<void> pauseTraining({String reason = 'other'}) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('training_pauses').insert({'user_id': uid, 'reason': reason});
  }

  /// Close the open pause, stamping today as the end.
  Future<void> resumeTraining() async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client
        .from('training_pauses')
        .update({'ended_on': _todayStr()})
        .eq('user_id', uid)
        .isFilter('ended_on', null);
  }

  // ── Onboarding ─────────────────────────────────────────────────────────────

  /// Whether the signed-in user already has a generated plan. The root gate
  /// uses this to route a returning user straight to the app, a fresh one to
  /// the intake.
  Future<bool> hasActiveProgram() async {
    final uid = currentUser?.id;
    if (uid == null) return false;
    final row = await client
        .from('programs')
        .select('id')
        .eq('user_id', uid)
        .eq('status', 'active')
        .limit(1)
        .maybeSingle();
    return row != null;
  }

  /// Body-map joints with their silhouette coordinates.
  Future<List<JointV2>> fetchJoints() async {
    final rows = await client
        .from('joints')
        .select('id, slug, name, map_view, map_x, map_y, is_lateral');
    return rows.cast<Map<String, dynamic>>().map(JointV2.fromJson).toList();
  }

  /// Persist the whole intake and generate the first program. Runs the writes
  /// in dependency order, then calls the generator (which archives any prior
  /// active plan itself). Returns the new program id.
  Future<String?> submitOnboarding(OnboardingDraft d) async {
    final uid = currentUser?.id;
    if (uid == null) return null;

    // 1. The current training profile — inserted, since handle_new_user()
    //    creates profiles + user_preferences but not this.
    await client.from('training_profiles').insert({
      'user_id': uid,
      'goal': d.leadGoal.db,
      'goals': d.goals.map((g) => g.db).toList(),
      'goal_is_coach_choice': d.coachChoice,
      'target_direction': d.targetDirection,
      'target_weight_kg': d.targetWeightKg,
      'training_weekdays': d.weekdaysIso,
      'days_per_week': d.weekdaysIso.isEmpty ? 3 : d.weekdaysIso.length,
      'split_preference': d.splitPreference,
      'experience': d.experience,
      'environment': d.environment,
      // The lifter answered these two steps, so the Profile prompt in
      // v2_0032 must not ask them again.
      'intake_confirmed': true,
      'bar_weight_kg': d.barWeightKg,
      'has_benched': d.hasBenched,
    });

    // 2. First weigh-in (the onboarding number is the first body_measurement).
    await client.from('body_measurements').upsert({
      'user_id': uid,
      'measured_on': _todayStr(),
      'weight_kg': d.bodyweightKg,
      'source': 'manual',
    }, onConflict: 'user_id,measured_on');

    // 2b. Protein target — 1.8 g/kg, the constant used everywhere else this
    // is shown. Without this row the Body & Fuel card has nothing to bar
    // against and silently renders as bare numbers with no visual.
    await client.from('nutrition_targets').insert({
      'user_id': uid,
      'protein_g': (d.bodyweightKg * 1.8).round(),
    });

    // 3. Units preference (row already exists from the signup trigger).
    await client
        .from('user_preferences')
        .update({'units': d.metric ? 'metric' : 'imperial'}).eq('user_id', uid);

    // 4. Injury flags + free-text note.
    final constraints = <Map<String, dynamic>>[
      for (final f in d.flags)
        {
          'user_id': uid,
          'joint_id': f.jointId,
          'label': f.label,
          'side': f.side,
          'severity': 'mild',
          'active_from': _todayStr(),
        },
      if (d.otherPain.trim().isNotEmpty)
        {
          'user_id': uid,
          'label': d.otherPain.trim(),
          'severity': 'mild',
          'active_from': _todayStr(),
        },
    ];
    if (constraints.isNotEmpty) {
      await client.from('user_constraints').insert(constraints);
    }

    // 5. Generate the first week (bench calibration only when they've benched).
    final id = await client.rpc('bootstrap_my_program', params: {
      'p_bench_start_kg': d.hasBenched ? d.benchStartKg : null,
    });

    // 6. Coach greeting + first pinned note, so a fresh account opens with
    //    something in the Trainer tab and the Train "from your trainer" card.
    try {
      await _writeOnboardingNotes(d);
    } catch (_) {/* non-fatal: the plan is what matters */}

    return id as String?;
  }

  // ── Trainer tab ────────────────────────────────────────────────────────────

  /// The whole coach thread for the user, oldest → newest, with receipts,
  /// card content, and any attached proposal. Treated as one continuous
  /// relationship, so messages across threads merge by time.
  Future<List<CoachMessageV2>> fetchTrainerThread() async {
    final uid = currentUser?.id;
    if (uid == null) return const [];
    final rows = await client
        .from('coach_messages')
        .select('id, role, content, created_at, category, needs_attention, '
            'read_at, acknowledged_at, pinned_until, card, '
            'receipts:coach_message_receipts(icon, label, position), '
            'proposals:coach_proposals(id, kind, status, payload)')
        .eq('user_id', uid)
        .order('created_at', ascending: true);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(CoachMessageV2.fromJson)
        .toList();
  }

  /// How many coach notes are unread — drives the nav badge on the Trainer tab.
  Future<int> unreadCoachCount() async {
    final uid = currentUser?.id;
    if (uid == null) return 0;
    final rows = await client
        .from('coach_messages')
        .select('id')
        .eq('user_id', uid)
        .eq('role', 'assistant')
        .isFilter('read_at', null);
    return (rows as List).length;
  }

  /// Mark every unread assistant note as read (clears the Train unread dot on
  /// next open). Call after the tab has computed its unread divider.
  Future<void> markCoachThreadRead() async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client
        .from('coach_messages')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', uid)
        .eq('role', 'assistant')
        .isFilter('read_at', null);
  }

  /// Resolve a note's decision (accept/reject). Records the decision on the
  /// proposal; actually writing the program change forward is a server task
  /// (F7 — `/coach/confirm` only executes `log_sets` today).
  Future<void> resolveCoachProposal(String proposalId, {required bool accept}) async {
    await client
        .from('coach_proposals')
        .update({
          'status': accept ? 'confirmed' : 'rejected',
          'resolved_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', proposalId)
        .eq('status', 'pending');
  }

  /// The explicit "Got it" — distinct from having read the note.
  Future<void> acknowledgeCoachMessage(String messageId) async {
    await client
        .from('coach_messages')
        .update({'acknowledged_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', messageId)
        .isFilter('acknowledged_at', null);
  }

  // ── Coach note generation (v1: on-completion, deterministic) ───────────────
  // D7: notes are written when the triggering event happens — onboarding, a
  // finished session — rather than by a cron. The AI coach still owns the
  // conversational replies; these are the scheduled/triggered notes.

  /// Get-or-create the user's coach thread.
  Future<String?> _ensureCoachThread() async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final existing = await client
        .from('coach_threads')
        .select('id')
        .eq('user_id', uid)
        .order('last_message_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (existing != null) return existing['id'] as String;
    final row = await client
        .from('coach_threads')
        .insert({'user_id': uid, 'title': 'Coach'})
        .select('id')
        .single();
    return row['id'] as String;
  }

  /// Write one assistant note with optional receipts and card, and bump the
  /// thread's last-message time.
  Future<void> _insertCoachNote({
    required String threadId,
    required String content,
    String category = 'reply',
    bool pinnedToday = false,
    bool needsAttention = false,
    List<(String, String)> receipts = const [],
    Map<String, dynamic>? card,
    String? sourceSessionId,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    final msg = await client
        .from('coach_messages')
        .insert({
          'user_id': uid,
          'thread_id': threadId,
          'role': 'assistant',
          'content': content,
          'category': category,
          'needs_attention': needsAttention,
          if (pinnedToday) 'pinned_until': _todayStr(),
          'card': ?card,
          'source_session_id': ?sourceSessionId,
        })
        .select('id')
        .single();
    if (receipts.isNotEmpty) {
      final id = msg['id'] as String;
      await client.from('coach_message_receipts').insert([
        for (var i = 0; i < receipts.length; i++)
          {
            'user_id': uid,
            'message_id': id,
            'position': i,
            'icon': receipts[i].$1,
            'label': receipts[i].$2,
          }
      ]);
    }
    await client
        .from('coach_threads')
        .update({'last_message_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', threadId);
  }

  /// Greeting + first pinned morning note, written once the plan is built.
  Future<void> _writeOnboardingNotes(OnboardingDraft d) async {
    final threadId = await _ensureCoachThread();
    if (threadId == null) return;
    final splitLabel = switch (d.splitPreference) {
      'push_pull_legs' => 'Push / Pull / Legs',
      'upper_lower' => 'Upper / Lower',
      _ => 'Full body',
    };
    await _insertCoachNote(
      threadId: threadId,
      content: "Hey — good to have you. I'm your trainer, and unlike a generic "
          "plan, I actually read your history before I say anything to you. "
          "You'll find me right here whenever you want to talk — tap the chat "
          "icon below, any time. Fair warning: I check in on you whether you "
          "ask or not. That's the job — I'm not letting you drift.",
      category: 'reply',
    );
    await _insertCoachNote(
      threadId: threadId,
      category: 'morning_note',
      pinnedToday: true,
      content: "I've built your first week — $splitLabel across "
          "${d.weekdaysIso.length} days — from what you just told me. "
          'Day one starts a touch light on purpose: end every set with about '
          'two reps still in you — that honest signal is what I use to load '
          'the next session, never a calendar.'
          '${d.flags.isNotEmpty ? " I'll route around what you flagged and warn you when a lift gets close." : ''}'
          ' Got a question before you start? I\'m on the Trainer tab.',
      receipts: [
        ('auto_awesome', 'Plan just built'),
        ('flag', d.leadGoal.label),
        if (d.flags.isNotEmpty) ('healing', d.flags.first.label),
      ],
    );
  }

  /// A debrief written when a session is finished, shaped by what happened.
  /// Idempotent: one debrief per session (a finish that fires twice is a
  /// no-op), backed by the unique index in v2_0013.
  Future<void> _writeSessionDebrief(String sessionId) async {
    final uid = currentUser?.id;
    if (uid == null) return;

    final existing = await client
        .from('coach_messages')
        .select('id')
        .eq('user_id', uid)
        .eq('category', 'session_debrief')
        .eq('source_session_id', sessionId)
        .maybeSingle();
    if (existing != null) return;

    final s = await fetchSessionSummary(sessionId);
    if (s == null || s.setCount == 0) return;
    final threadId = await _ensureCoachThread();
    if (threadId == null) return;

    final vol = s.volumeKg.round();
    final delta = s.vsLastDelta?.round();
    final deltaClause = delta == null
        ? ''
        : delta >= 0
            ? ' Up ${_grp(delta)} kg on your last ${s.label.toLowerCase()}.'
            : ' A little under your last ${s.label.toLowerCase()} — fine on a heavier day.';
    final pbClause = s.pbs.isEmpty
        ? ''
        : ' A personal best on ${s.pbs.first.name} — ${s.pbs.first.reps} reps'
            '${s.pbs.first.kg == null ? '' : ' at ${_num(s.pbs.first.kg!)} kg'}.';
    final content = '${s.label} done. ${s.setCount} sets, ${_grp(vol)} kg moved.'
        '$deltaClause$pbClause Rest up — the adaptation happens now, not in the gym.';

    await _insertCoachNote(
      threadId: threadId,
      category: 'session_debrief',
      content: content,
      sourceSessionId: sessionId,
      card: {
        'stats': [
          {'value': '${s.setCount}', 'label': 'sets'},
          {'value': _grp(vol), 'label': 'kg moved'},
          if (delta != null)
            {'value': '${delta >= 0 ? '+' : ''}${_grp(delta)}', 'label': 'vs last'}
          else
            {'value': '${s.durationMin ?? 0}', 'label': 'min'},
        ],
      },
    );
  }

  static String _grp(int n) {
    final s = n.abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}
