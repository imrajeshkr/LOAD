import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:load_app/services/failure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The classifier is the whole safety property: if it mislabels something,
/// either a lifter is told to sign in over a flat wifi connection, or a dead
/// session hides behind a "try again" that can never work.
void main() {
  Failure at(Object e) => classifyFailure('test', e);

  group('network faults are offline, whatever wraps them', () {
    test('a socket failure', () {
      expect(at(const SocketException('no route')).kind, FailureKind.offline);
    });
    test('a timeout', () {
      expect(at(TimeoutException('slow')).kind, FailureKind.offline);
    });
    test('a DNS failure that only survives as text', () {
      // Plugin boundaries flatten exceptions to strings often enough that the
      // fallback matters more than it looks.
      expect(at('ClientException: Failed host lookup: api.supabase.co').kind,
          FailureKind.offline);
    });
  });

  group('a dead session is never presented as retryable', () {
    test('an auth exception', () {
      expect(at(const AuthException('token expired')).kind, FailureKind.session);
    });

    test('a foreign key against profiles — the deleted-account case', () {
      // The exact shape seen in production: a cached JWT whose user row was
      // cascade-deleted. It is a 23503, but it is not a server bug.
      final e = PostgrestException(
        message: 'insert or update on table "training_profiles" violates '
            'foreign key constraint "training_profiles_user_id_fkey" — '
            'key is not present in table "profiles"',
        code: '23503',
      );
      expect(at(e).kind, FailureKind.session);
      expect(at(e).retryable, isFalse);
    });

    test('a foreign key against anything else is ours to fix', () {
      final e = PostgrestException(
        message: 'violates foreign key constraint on table "sets"',
        code: '23503',
      );
      expect(at(e).kind, FailureKind.server);
      expect(at(e).retryable, isTrue);
    });

    test('PostgREST JWT codes', () {
      expect(
          at(PostgrestException(message: 'JWT expired', code: 'PGRST301')).kind,
          FailureKind.session);
    });
  });

  test('an ordinary database error is a server fault', () {
    expect(
        at(PostgrestException(message: 'boom', code: '42883')).kind,
        FailureKind.server);
  });

  test('anything unrecognised stays retryable rather than stranding anyone',
      () {
    final f = at(StateError('who knows'));
    expect(f.kind, FailureKind.unknown);
    expect(f.retryable, isTrue);
  });

  test('every kind has copy, and none of it is the exception', () {
    for (final k in FailureKind.values) {
      final f = Failure(k, PostgrestException(message: 'raw table name here'));
      expect(f.title, isNotEmpty);
      expect(f.message, isNotEmpty);
      expect(f.title, isNot(contains('raw table name')));
      expect(f.message, isNot(contains('raw table name')));
    }
  });
}
