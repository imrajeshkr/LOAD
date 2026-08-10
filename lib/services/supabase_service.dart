import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';

/// Thin wrapper around the Supabase client. Only the anon key is ever used
/// here — the service_role key must never appear in app code.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get client => Supabase.instance.client;
  User? get currentUser => client.auth.currentUser;

  Stream<AuthState> get authStateChanges => client.auth.onAuthStateChange;

  Future<void> signUpWithEmail(String email, String password) async {
    await client.auth.signUp(email: email, password: password);
  }

  Future<void> signInWithEmail(String email, String password) async {
    await client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signInWithGoogle() async {
    await client.auth.signInWithOAuth(OAuthProvider.google);
  }

  Future<void> signOut() async => client.auth.signOut();

  Future<Profile?> fetchProfile() async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final row = await client.from('profiles').select().eq('id', uid).maybeSingle();
    if (row == null) return null;
    return Profile.fromMap(row);
  }

  Future<void> saveProfile(Profile profile) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('profiles').upsert({'id': uid, ...profile.toMap()});
  }

  Future<String> startSession(String label) async {
    final uid = currentUser?.id;
    if (uid == null) throw StateError('Not signed in');
    final row = await client
        .from('sessions')
        .insert({'user_id': uid, 'label': label})
        .select('id')
        .single();
    return row['id'] as String;
  }

  Future<void> logSet(String sessionId, String exerciseName, int setNumber, double weight, int reps) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('session_sets').insert({
      'session_id': sessionId,
      'user_id': uid,
      'exercise_name': exerciseName,
      'set_number': setNumber,
      'weight': weight,
      'reps': reps,
    });
  }

  Future<void> completeSession(String sessionId, {String notes = '', int? rpe, List<String> pain = const []}) async {
    await client.from('sessions').update({
      'completed_at': DateTime.now().toIso8601String(),
      'notes': notes,
      'rpe': rpe,
      'pain': pain,
    }).eq('id', sessionId);
  }

  Future<void> logWeight(double weight) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('weight_logs').insert({'user_id': uid, 'weight': weight});
  }

  Future<List<WeightEntry>> fetchWeightLog({int limit = 8}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await client
        .from('weight_logs')
        .select()
        .eq('user_id', uid)
        .order('logged_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => WeightEntry(weight: (r['weight'] as num).toDouble(), loggedAt: DateTime.parse(r['logged_at'])))
        .toList()
        .reversed
        .toList();
  }

  Future<void> logProtein(int grams) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('protein_logs').insert({'user_id': uid, 'grams': grams});
  }

  Future<List<ProteinEntry>> fetchProteinLog({int limit = 7}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await client
        .from('protein_logs')
        .select()
        .eq('user_id', uid)
        .order('logged_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => ProteinEntry(grams: r['grams'] as int, loggedAt: DateTime.parse(r['logged_at'])))
        .toList()
        .reversed
        .toList();
  }

  Future<List<SessionHistoryEntry>> fetchSessionHistory({int limit = 5}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await client
        .from('sessions')
        .select()
        .eq('user_id', uid)
        .not('completed_at', 'is', null)
        .order('completed_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => SessionHistoryEntry(
              label: r['label'] as String,
              detail: '',
              date: DateTime.parse(r['completed_at']),
            ))
        .toList();
  }

  Future<void> saveChatMessage(String sender, String body) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await client.from('chat_messages').insert({'user_id': uid, 'sender': sender, 'body': body});
  }

  Future<List<ChatMessage>> fetchChatHistory({int limit = 50}) async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await client
        .from('chat_messages')
        .select()
        .eq('user_id', uid)
        .order('created_at', ascending: true)
        .limit(limit);
    return (rows as List).map((r) => ChatMessage(sender: r['sender'] as String, body: r['body'] as String)).toList();
  }
}
