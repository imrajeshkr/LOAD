import 'package:flutter/foundation.dart';

/// The one switch that decides whether a lifter can see a stack trace.
///
/// Raw exception text is for whoever is fixing the app, never for whoever is
/// using it: `PostgrestException(message: insert or update on table
/// "training_profiles" violates foreign key constraint …)` tells a person in a
/// gym nothing they can act on, and it leaks table names, column names and
/// constraint names to anyone who reads it.
///
/// So the rule is enforced in one place rather than remembered at every catch
/// site. [showRawErrors] is false in a release build unless it is deliberately
/// switched on:
///
/// ```
/// flutter run --release --dart-define=LOAD_DIAGNOSTICS=on
/// ```
///
/// That escape hatch matters — the bugs worth chasing are usually the ones
/// that only appear in a release build on a real device, and a diagnostic you
/// cannot turn on there is a diagnostic you do not have.
///
/// Hiding a failure is not the same as ignoring it. Everything routed through
/// [record] is logged whatever the mode, so the detail still exists; only its
/// audience changes. That method is also the seam a crash reporter drops into
/// later — one call site to change, not forty.
abstract final class Diagnostics {
  static const _override =
      String.fromEnvironment('LOAD_DIAGNOSTICS', defaultValue: '');

  /// True in debug, or in any build launched with LOAD_DIAGNOSTICS=on.
  /// A build launched with `off` stays quiet even in debug, which is how you
  /// check what a user would actually see without cutting a release build.
  static bool get showRawErrors => switch (_override) {
        'on' => true,
        'off' => false,
        _ => kDebugMode,
      };

  /// Log a failure. Always runs; only [showRawErrors] governs what is *shown*.
  static void record(String where, Object error, [StackTrace? stack]) {
    debugPrint('LOAD failure · $where · $error');
    if (stack != null && showRawErrors) debugPrintStack(stackTrace: stack);
  }
}
