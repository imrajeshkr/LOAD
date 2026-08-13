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

  /// Mark the session complete, stamping the situation adaptation if any.
  Future<void> finishSession(String sessionId, {String? situation}) async {
    await client.from('workout_sessions').update({
      'status': 'completed',
      'completed_at': DateTime.now().toUtc().toIso8601String(),
      'situation': situation,
      'rest_started_at': null,
      'rest_total_seconds': null,
    }).eq('id', sessionId);
  }

  Future<void> setSituation(String sessionId, String? situation) async {
    await client
        .from('workout_sessions')
        .update({'situation': situation}).eq('id', sessionId);
  }
}
