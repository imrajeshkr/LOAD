import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'diagnostics.dart';

/// What went wrong, in terms a screen can act on.
///
/// Screens used to keep `String? _error` and fill it with `'$e'`. That threw
/// away the only thing worth knowing — whether this was a dead network, a dead
/// session or a dead server — and then showed the wreckage to the lifter. A
/// kind can be reasoned about: it decides the words, the picture, and whether
/// the button says "Try again" or "Sign in".
enum FailureKind {
  /// No usable connection. Retrying once there is one will work.
  offline,

  /// The session is gone or was never valid — signed out elsewhere, token
  /// expired, or the account itself deleted. Retrying cannot fix it; only
  /// signing in again can.
  session,

  /// Reached the server, and the server could not do it. Ours to fix.
  server,

  /// Unclassified. Treated as retryable, because assuming otherwise strands
  /// people over something transient.
  unknown,
}

class Failure {
  final FailureKind kind;
  final Object raw;
  final StackTrace? stack;
  const Failure(this.kind, this.raw, [this.stack]);

  /// Whether the primary action should be "Try again". False only when the
  /// session is gone, where retrying just fails again in the same way.
  bool get retryable => kind != FailureKind.session;

  /// The headline. Short, and about the lifter's situation rather than ours.
  String get title => switch (kind) {
        FailureKind.offline => 'No connection',
        FailureKind.session => 'You have been signed out',
        FailureKind.server => 'That did not go through',
        FailureKind.unknown => 'Something went wrong',
      };

  /// One line, and it must earn its place: say what happened or what to do,
  /// never both in the vague. No apologies — they add length, not information.
  String get message => switch (kind) {
        FailureKind.offline =>
          'Your plan is here waiting. Reconnect and pull it down again.',
        FailureKind.session =>
          'Sign in again and everything picks up where it was.',
        FailureKind.server =>
          'Nothing you did — the fault is on our side. Try once more.',
        FailureKind.unknown => 'Give it another go.',
      };

  /// The exception itself, for a developer. Callers must gate this behind
  /// [Diagnostics.showRawErrors]; it is never safe to render unconditionally.
  String get detail => raw.toString();
}

/// Turn anything thrown into a [Failure], and log it on the way past.
///
/// [where] names the call site so a log line is traceable without a stack.
Failure classifyFailure(String where, Object e, [StackTrace? stack]) {
  Diagnostics.record(where, e, stack);
  return Failure(_kindOf(e), e, stack);
}

FailureKind _kindOf(Object e) {
  // Order matters: the network cases are the most specific and the most
  // common, and a socket failure inside a Postgrest call still presents as a
  // ClientException rather than anything Postgres-shaped.
  if (e is SocketException || e is TimeoutException || e is HttpException) {
    return FailureKind.offline;
  }
  if (e is AuthException || e is AuthApiException) return FailureKind.session;

  if (e is PostgrestException) {
    final code = e.code ?? '';
    // 23503 is a foreign-key violation. Ordinarily a server-side bug — except
    // against `profiles`, where it means this JWT's user no longer has a row
    // because the account was deleted out from under a cached session. That
    // presented as a raw constraint error on the last screen of onboarding.
    if (code == '23503' && e.message.contains('profiles')) {
      return FailureKind.session;
    }
    // PostgREST's own JWT errors arrive as PGRST301/302 or a 401.
    if (code.startsWith('PGRST3') || code == '401' || code == '42501') {
      return FailureKind.session;
    }
    return FailureKind.server;
  }
  if (e is StorageException || e is FunctionException) return FailureKind.server;

  // Last resort: the transport layers stringify to something recognisable even
  // when the type does not survive the plugin boundary.
  final s = e.toString().toLowerCase();
  if (s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('connection closed') ||
      s.contains('network is unreachable') ||
      s.contains('clientexception')) {
    return FailureKind.offline;
  }
  if (s.contains('jwt') || s.contains('not authenticated')) {
    return FailureKind.session;
  }
  return FailureKind.unknown;
}
