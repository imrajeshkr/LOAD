import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../models/units.dart';
import '../../services/app_state.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';
import 'summary_screen.dart';

/// The full-screen, no-nav session flow: one exercise at a time, guidance
/// first, a pre-filled log sheet, and a non-blocking rest timer that
/// auto-advances. Replaces the old always-editable Log screen — logging a
/// set here is "confirm what's already filled in", not "type two numbers".
class SessionFlowScreen extends StatefulWidget {
  const SessionFlowScreen({super.key});

  @override
  State<SessionFlowScreen> createState() => _SessionFlowScreenState();
}

class _SessionFlowScreenState extends State<SessionFlowScreen> {
  Timer? _elapsedTimer;
  Timer? _restTimer;
  int _elapsedSec = 0;
  int? _restRemainingSec;
  bool _justLogged = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _tickElapsed();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickElapsed());
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _restTimer?.cancel();
    super.dispose();
  }

  // Anchored to the server-stamped session start rather than a local clock,
  // so re-entering a session (app killed, tab-switched away and back) shows
  // the real elapsed time instead of restarting from zero.
  void _tickElapsed() {
    final started = context.read<AppState>().sessionStartedAt;
    if (!mounted) return;
    setState(() {
      _elapsedSec = started == null
          ? 0
          : DateTime.now().difference(started).inSeconds.clamp(0, 1 << 30);
    });
  }

  String get _elapsedLabel {
    final m = _elapsedSec ~/ 60;
    final s = _elapsedSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String get _restLabel {
    final left = _restRemainingSec ?? 0;
    final m = left ~/ 60;
    final s = left % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _startRestTimer(int seconds) {
    _restTimer?.cancel();
    setState(() => _restRemainingSec = seconds);
    _restTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = (_restRemainingSec ?? 0) - 1;
      if (left <= 0) {
        t.cancel();
        setState(() => _restRemainingSec = null);
        _advance();
      } else {
        setState(() => _restRemainingSec = left);
      }
    });
  }

  void _skipRest() {
    _restTimer?.cancel();
    setState(() => _restRemainingSec = null);
    _advance();
  }

  Future<void> _advance() async {
    final state = context.read<AppState>();
    final idx = state.currentExerciseIndex;
    if (idx >= state.exercises.length - 1) {
      await _finish();
      return;
    }
    state.openExercise(idx + 1);
  }

  // The session isn't marked complete here — every number the celebration
  // screen counts up is already live in `sessionNow` from the last logged
  // set, and `workout_sessions.status` only flips to completed once the
  // reflection (RPE/pain/notes) is captured, via the celebration screen's
  // own Done button. That keeps "session complete" meaning what it says
  // server-side, rather than firing before the lifter has actually reflected.
  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SummaryScreen()),
    );
  }

  Future<void> _primaryAction(AppState state, ExerciseSpec ex, int idx, bool isLast) async {
    final loggedNow = ex.setsLoggedToday > 0;
    if (!loggedNow) {
      await _openLogSheet(state, ex, idx);
      return;
    }
    if (isLast) {
      await _finish();
      return;
    }
    _restTimer?.cancel();
    setState(() => _restRemainingSec = null);
    await _advance();
  }

  Future<void> _openLogSheet(AppState state, ExerciseSpec ex, int idx) async {
    final rows = await showModalBottomSheet<List<(double, int)>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LogSheet(exercise: ex, units: state.units),
    );
    if (rows == null || rows.isEmpty || !mounted) return;
    try {
      await state.logExerciseSets(idx, rows);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('That didn\'t save — try again. ($e)')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _justLogged = true);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _justLogged = false);
      final last = idx >= state.exercises.length - 1;
      if (!last) {
        _startRestTimer(ex.restSeconds);
      } else {
        // Nothing left to rest for or advance to — logging the last
        // exercise finishes the session on its own rather than making the
        // lifter tap "Finish session" a second time for work already done.
        _finish();
      }
    });
  }

  Future<void> _requestClose(AppState state) async {
    final anyLogged = state.exercises.any((e) => e.setsLoggedToday > 0);
    if (!anyLogged) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x66281405),
      builder: (_) => const _ExitConfirmDialog(),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  String? _loggedSummary(ExerciseSpec ex, UnitSystem units) {
    final today = ex.today;
    if (today == null || today.sets.isEmpty) return null;
    final first = today.sets.first;
    return ex.isBodyweight
        ? '${today.sets.length} × ${first.reps} reps'
        : '${today.sets.length} × '
            '${units.formatWeightWithUnit(first.weightKg, decimals: 1)} × ${first.reps}';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final units = state.units;
    final idx = state.currentExerciseIndex;
    final ex = state.exercises[idx];
    final isLast = idx >= state.exercises.length - 1;
    final flagged = state.exerciseFlagged(ex);
    final loggedNow = ex.setsLoggedToday > 0;
    final loggedSummary = _loggedSummary(ex, units);

    final primaryLabel =
        !loggedNow ? 'Done — log it' : (isLast ? 'Finish session' : 'Next exercise');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _requestClose(state);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _CircleGlyph(
                              icon: Icons.close_rounded,
                              onTap: () => _requestClose(state),
                            ),
                            Text(
                              _elapsedLabel,
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            for (var i = 0; i < state.exercises.length; i++) ...[
                              Expanded(
                                child: _SegmentBar(
                                  state: state.exercises[i].setsLoggedToday > 0
                                      ? _SegmentState.done
                                      : i == idx
                                          ? _SegmentState.current
                                          : _SegmentState.upcoming,
                                ),
                              ),
                              if (i != state.exercises.length - 1) const SizedBox(width: 5),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 240),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.05, 0),
                            end: Offset.zero,
                          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                          child: child,
                        ),
                      ),
                      child: ListView(
                        key: ValueKey(ex.id),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        children: [
                          Text(ex.name, style: Theme.of(context).textTheme.headlineMedium),
                          const SizedBox(height: 4),
                          Text(
                            ex.isBodyweight
                                ? ex.prescriptionLabel
                                : '${ex.prescriptionLabel} · last time '
                                    '${units.formatWeightWithUnit(ex.prefillKg, decimals: 1)}',
                            style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              height: 1.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          if (flagged) ...[
                            const SizedBox(height: 14),
                            SoftBanner(
                              message:
                                  "Careful — this one loads your ${state.flagLabel(ex)}.",
                              actionLabel: state.canSwap(ex.name) ? 'Swap' : null,
                              onAction: state.canSwap(ex.name)
                                  ? () => state.swapExercise(ex.name)
                                  : null,
                            ),
                          ],
                          const SizedBox(height: 16),
                          ExerciseDemoMedia(
                            url: SupabaseService.instance.demoUrl(ex.demoPath),
                          ),
                          const SizedBox(height: 20),
                          for (var i = 0; i < _cuesFor(ex).length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 24,
                                    height: 24,
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(
                                      color: AppColors.chipFill,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '${i + 1}',
                                      style: const TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12,
                                        color: AppColors.accent,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        _cuesFor(ex)[i],
                                        style: const TextStyle(
                                          fontFamily: AppTheme.fontFamily,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13.5,
                                          height: 1.55,
                                          color: AppColors.textBody,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (loggedSummary != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                        decoration: BoxDecoration(
                          color: AppColors.positiveSoft,
                          borderRadius: BorderRadius.circular(AppRadii.card),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$loggedSummary ✓',
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: AppColors.positive,
                              ),
                            ),
                            GestureDetector(
                              onTap: () => _openLogSheet(state, ex, idx),
                              child: const Text(
                                'Edit',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: AppColors.positive,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_restRemainingSec != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                        decoration: BoxDecoration(
                          color: AppColors.chipFill,
                          borderRadius: BorderRadius.circular(AppRadii.card),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Rest · $_restLabel',
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                            GestureDetector(
                              onTap: _skipRest,
                              child: const Text(
                                'Skip',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: AppColors.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: state.loggingSet
                            ? null
                            : () => _primaryAction(state, ex, idx, isLast),
                        child: state.loggingSet
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.onAccent),
                              )
                            : Text(primaryLabel),
                      ),
                    ),
                  ),
                ],
              ),
              if (_justLogged)
                IgnorePointer(
                  child: Center(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutBack,
                      builder: (context, v, child) =>
                          Opacity(opacity: v.clamp(0, 1), child: Transform.scale(scale: v, child: child)),
                      child: Container(
                        width: 88,
                        height: 88,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_rounded, color: Colors.white, size: 42),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> _cuesFor(ExerciseSpec ex) => ex.cues.isNotEmpty ? ex.cues : defaultCues;

enum _SegmentState { done, current, upcoming }

class _SegmentBar extends StatelessWidget {
  final _SegmentState state;
  const _SegmentBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _SegmentState.done => AppColors.accent,
      _SegmentState.current => AppColors.peach,
      _SegmentState.upcoming => AppColors.track,
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      height: 4,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
    );
  }
}

class _CircleGlyph extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleGlyph({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, size: 16, color: AppColors.textMuted),
        ),
      ),
    );
  }
}

class _ExitConfirmDialog extends StatelessWidget {
  const _ExitConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.card)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Leave the session?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'Your logged sets are saved — you can pick up where you left off.',
              style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Stay'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Leave'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SetRow {
  double weightKg;
  int reps;
  _SetRow(this.weightKg, this.reps);
}

/// The pre-filled log sheet. Simple mode (one weight/reps applied to every
/// set) is the default and the fast path; per-set mode is the escape hatch
/// for the day a set didn't match the rest.
class _LogSheet extends StatefulWidget {
  final ExerciseSpec exercise;
  final UnitSystem units;
  const _LogSheet({required this.exercise, required this.units});

  @override
  State<_LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<_LogSheet> {
  late double _weightKg;
  late int _reps;
  late int _sets;
  bool _perSetMode = false;
  late List<_SetRow> _rows;

  @override
  void initState() {
    super.initState();
    final ex = widget.exercise;
    final existing = ex.today?.sets;
    if (existing != null && existing.isNotEmpty) {
      _weightKg = existing.first.weightKg;
      _reps = existing.first.reps;
      _sets = existing.length;
      _rows = existing.map((s) => _SetRow(s.weightKg, s.reps)).toList();
    } else {
      _weightKg = ex.prefillKg;
      _reps = ex.prefillReps;
      _sets = ex.setsTarget;
      _rows = List.generate(_sets, (_) => _SetRow(_weightKg, _reps));
    }
  }

  bool get _hasWeight => !widget.exercise.isBodyweight;

  void _syncRowsToSets() {
    if (_rows.length == _sets) return;
    if (_rows.length < _sets) {
      _rows.addAll(List.generate(_sets - _rows.length, (_) => _SetRow(_weightKg, _reps)));
    } else {
      _rows.removeRange(_sets, _rows.length);
    }
  }

  void _togglePerSetMode() {
    setState(() {
      if (!_perSetMode) {
        // Entering per-set mode always starts from the shared values — the
        // whole point is to override individual sets from a known baseline.
        _rows = List.generate(_sets, (_) => _SetRow(_weightKg, _reps));
      }
      _perSetMode = !_perSetMode;
    });
  }

  void _confirm() {
    final rows = _perSetMode
        ? _rows.map((r) => (r.weightKg, r.reps)).toList()
        : List.generate(_sets, (_) => (_weightKg, _reps));
    Navigator.pop(context, rows);
  }

  @override
  Widget build(BuildContext context) {
    final units = widget.units;
    final ex = widget.exercise;
    final headline = ex.isBodyweight
        ? '$_sets sets · $_reps reps · bodyweight'
        : '$_sets sets · ${units.formatWeight(_weightKg)} ${units.weightLabel} · $_reps reps';

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.track,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              Text(ex.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                headline,
                style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),
              if (!_perSetMode) ...[
                Row(
                  children: [
                    if (_hasWeight)
                      Expanded(
                        child: _SheetStat(
                          label: 'Weight',
                          value: units.formatWeight(_weightKg),
                          onDec: () => setState(() {
                            final shown = units.fromKg(_weightKg);
                            _weightKg = units.toKg((shown - units.weightStep).clamp(0, 999));
                          }),
                          onInc: () => setState(() {
                            final shown = units.fromKg(_weightKg);
                            _weightKg = units.toKg(shown + units.weightStep);
                          }),
                        ),
                      ),
                    if (_hasWeight) const SizedBox(width: 10),
                    Expanded(
                      child: _SheetStat(
                        label: 'Reps',
                        value: '$_reps',
                        onDec: () => setState(() => _reps = (_reps - 1).clamp(1, 99)),
                        onInc: () => setState(() => _reps = (_reps + 1).clamp(1, 99)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadii.card),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Sets',
                        style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                      Row(
                        children: [
                          _SmallStepButton(
                            icon: Icons.remove_rounded,
                            onTap: () => setState(() {
                              _sets = (_sets - 1).clamp(1, 20);
                              _syncRowsToSets();
                            }),
                          ),
                          SizedBox(
                            width: 32,
                            child: Text(
                              '$_sets',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          _SmallStepButton(
                            icon: Icons.add_rounded,
                            onTap: () => setState(() {
                              _sets = (_sets + 1).clamp(1, 20);
                              _syncRowsToSets();
                            }),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ] else
                Column(
                  children: [
                    for (var i = 0; i < _rows.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(AppRadii.card),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 42,
                                child: Text(
                                  'Set ${i + 1}',
                                  style: const TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11.5,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (_hasWeight)
                                _RowStepper(
                                  value: units.formatWeight(_rows[i].weightKg),
                                  onDec: () => setState(() {
                                    final shown = units.fromKg(_rows[i].weightKg);
                                    _rows[i].weightKg =
                                        units.toKg((shown - units.weightStep).clamp(0, 999));
                                  }),
                                  onInc: () => setState(() {
                                    final shown = units.fromKg(_rows[i].weightKg);
                                    _rows[i].weightKg = units.toKg(shown + units.weightStep);
                                  }),
                                ),
                              if (_hasWeight) const SizedBox(width: 14),
                              _RowStepper(
                                value: '${_rows[i].reps}',
                                onDec: () => setState(
                                    () => _rows[i].reps = (_rows[i].reps - 1).clamp(1, 99)),
                                onInc: () => setState(
                                    () => _rows[i].reps = (_rows[i].reps + 1).clamp(1, 99)),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _confirm,
                  child: Text('Log ${_perSetMode ? _rows.length : _sets} sets'),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: GestureDetector(
                  onTap: _togglePerSetMode,
                  child: Text(
                    _perSetMode
                        ? 'Back to one weight for all sets'
                        : "Sets weren't all the same",
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetStat extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onDec;
  final VoidCallback onInc;
  const _SheetStat({
    required this.label,
    required this.value,
    required this.onDec,
    required this.onInc,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 10.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _SmallStepButton(icon: Icons.remove_rounded, onTap: onDec),
              SizedBox(
                width: 56,
                child: Text(
                  value,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w900,
                    fontSize: 21,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              _SmallStepButton(icon: Icons.add_rounded, onTap: onInc),
            ],
          ),
        ],
      ),
    );
  }
}

class _RowStepper extends StatelessWidget {
  final String value;
  final VoidCallback onDec;
  final VoidCallback onInc;
  const _RowStepper({required this.value, required this.onDec, required this.onInc});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _SmallStepButton(icon: Icons.remove_rounded, size: 26, onTap: onDec),
        SizedBox(
          width: 36,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w800,
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        _SmallStepButton(icon: Icons.add_rounded, size: 26, onTap: onInc),
      ],
    );
  }
}

class _SmallStepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  const _SmallStepButton({required this.icon, required this.onTap, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.inputFill,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.5, color: AppColors.textBody),
        ),
      ),
    );
  }
}
