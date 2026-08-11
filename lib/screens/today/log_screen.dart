import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../models/units.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';
import 'guide_screen.dart';
import 'summary_screen.dart';

/// Mid-workout set logging. Deliberately the fastest screen in the app:
/// weight and reps only, two taps to record a set.
///
/// The steppers seed from what was actually lifted — today's last set on
/// this movement if there is one (so re-opening the screen mid-session, or
/// after the app was killed, doesn't lose your place), else `prefillKg` /
/// `prefillReps` from the server, which is what was lifted last *session*,
/// never a pre-progressed number.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  double? _weightKg;
  int? _reps;
  int? _syncedIndex;

  Timer? _restTimer;
  int? _restRemainingSec;

  @override
  void dispose() {
    _restTimer?.cancel();
    super.dispose();
  }

  void _syncTo(AppState state) {
    if (_syncedIndex == state.currentExerciseIndex) return;
    final ex = state.exercises[state.currentExerciseIndex];
    _syncedIndex = state.currentExerciseIndex;
    final lastToday = ex.today?.sets.isNotEmpty == true ? ex.today!.sets.last : null;
    _weightKg = lastToday?.weightKg ?? ex.prefillKg;
    _reps = lastToday?.reps ?? ex.prefillReps;
    _restTimer?.cancel();
    _restRemainingSec = null;
  }

  void _startRestTimer(int seconds) {
    _restTimer?.cancel();
    setState(() => _restRemainingSec = seconds);
    _restTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = (_restRemainingSec ?? 0) - 1;
      if (left <= 0) {
        t.cancel();
        setState(() => _restRemainingSec = null);
      } else {
        setState(() => _restRemainingSec = left);
      }
    });
  }

  Future<void> _logSet(AppState state, int idx, ExerciseSpec ex) async {
    final wasComplete = ex.progress == SetProgress.complete;
    await state.logSet(idx, _weightKg ?? ex.prefillKg, _reps ?? ex.prefillReps);
    if (!mounted) return;
    _startRestTimer(ex.restSeconds);
    final nowComplete = state.exercises[idx].progress == SetProgress.complete;
    if (!wasComplete && nowComplete) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Target hit for this one — nice.'),
          duration: const Duration(seconds: 2),
          backgroundColor: AppColors.textPrimary,
        ),
      );
    }
  }

  Future<void> _editSet(AppState state, LoggedSetRow set, UnitSystem units) async {
    final result = await showModalBottomSheet<_EditResult>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.card * 1.2)),
      ),
      builder: (_) => _EditSetSheet(set: set, units: units),
    );
    if (result == null) return;
    if (result.delete) {
      await state.deleteSet(set.id);
    } else {
      await state.updateSet(set.id, result.weightKg!, result.reps!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _syncTo(state);

    final units = state.units;
    final idx = state.currentExerciseIndex;
    final ex = state.exercises[idx];
    final sets = state.currentExerciseSets;
    final isLast = idx >= state.exercises.length - 1;
    final flagged = state.exerciseFlagged(ex);
    final step = units.weightStep;
    final justHitTarget = ex.progress == SetProgress.complete;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Exercise ${idx + 1} of ${state.exercises.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (state.sessionNow?.elapsedMin != null)
              Text(
                '${state.planLabel ?? 'Session'} · ${state.sessionNow!.elapsedMin} min in',
                style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w600,
                  fontSize: 10.5,
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'How to do it',
            icon: const Icon(Icons.help_outline_rounded, color: AppColors.accent),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => GuideScreen(exercise: ex)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(ex.name, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(
            ex.isBodyweight
                ? 'Target ${ex.prescriptionLabel}'
                : 'Target ${ex.prescriptionLabel} · last time '
                    '${units.formatWeightWithUnit(ex.prefillKg, decimals: 1)}',
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),

          if (flagged) ...[
            const SizedBox(height: 12),
            SoftBanner(
              title: 'Heads up',
              message: 'This one loads your ${state.flagLabel(ex)}, which you '
                  'flagged. Keep it controlled — or swap it.',
              actionLabel: state.canSwap(ex.name) ? 'Swap' : null,
              onAction: state.canSwap(ex.name)
                  ? () {
                      state.swapExercise(ex.name);
                      setState(() => _syncedIndex = null);
                    }
                  : null,
            ),
          ],

          if (_restRemainingSec != null) ...[
            const SizedBox(height: 12),
            _RestTimerBanner(
              secondsLeft: _restRemainingSec!,
              onSkip: () {
                _restTimer?.cancel();
                setState(() => _restRemainingSec = null);
              },
            ),
          ] else if (justHitTarget) ...[
            const SizedBox(height: 12),
            SoftBanner(
              background: AppColors.positiveSoft,
              message: isLast
                  ? "That's your last exercise — finish up when you're ready."
                  : 'Set target hit — move on whenever you like.',
            ),
          ],

          const SizedBox(height: 18),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Column(
              children: [
                if (!ex.isBodyweight) ...[
                  _StepperRow(
                    label: 'Weight',
                    value: units.formatWeight(_weightKg ?? ex.prefillKg, decimals: 1),
                    unit: units.weightLabel,
                    onDec: () => setState(() {
                      final shown = units.fromKg(_weightKg ?? ex.prefillKg);
                      _weightKg = units.toKg((shown - step).clamp(0, 999));
                    }),
                    onInc: () => setState(() {
                      final shown = units.fromKg(_weightKg ?? ex.prefillKg);
                      _weightKg = units.toKg(shown + step);
                    }),
                  ),
                  const Divider(height: 26),
                ],
                _StepperRow(
                  label: 'Reps',
                  value: '${_reps ?? ex.prefillReps}',
                  onDec: () => setState(
                      () => _reps = ((_reps ?? ex.prefillReps) - 1).clamp(1, 99)),
                  onInc: () => setState(
                      () => _reps = ((_reps ?? ex.prefillReps) + 1).clamp(1, 99)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: state.loggingSet ? null : () => _logSet(state, idx, ex),
              child: state.loggingSet
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onAccent),
                    )
                  : Text('Log set ${ex.setsLoggedToday + 1}'),
            ),
          ),

          const SizedBox(height: 24),
          SectionLabel(
            'Logged today',
            trailing: sets.isEmpty
                ? null
                : GestureDetector(
                    onTap: () => state.undoLastLoggedSet(),
                    child: const Text(
                      'Undo last',
                      style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
          ),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: state.loadingSets
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : sets.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'No sets logged yet.',
                          style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          for (var i = 0; i < sets.length; i++)
                            InkWell(
                              onTap: () => _editSet(state, sets[i], units),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: i == sets.length - 1
                                          ? Colors.transparent
                                          : AppColors.divider,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Set ${i + 1}',
                                      style: const TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12.5,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        Text(
                                          ex.isBodyweight
                                              ? '${sets[i].reps} reps'
                                              : '${units.formatWeightWithUnit(sets[i].weightKg, decimals: 1)}'
                                                  '  ×  ${sets[i].reps}',
                                          style: const TextStyle(
                                            fontFamily: AppTheme.fontFamily,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                            color: AppColors.textBody,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        const Icon(Icons.edit_outlined,
                                            size: 14, color: AppColors.textFaint),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
          ),

          const SizedBox(height: 24),
          Row(
            children: [
              if (idx > 0) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => state.openExercise(idx - 1),
                    child: const Text('Previous'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () async {
                    if (isLast) {
                      await state.finishSession(state.planLabel ?? 'Training');
                      if (!context.mounted) return;
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const SummaryScreen()),
                      );
                    } else {
                      state.openExercise(idx + 1);
                    }
                  },
                  child: Text(isLast ? 'Finish session' : 'Next exercise'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RestTimerBanner extends StatelessWidget {
  final int secondsLeft;
  final VoidCallback onSkip;
  const _RestTimerBanner({required this.secondsLeft, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    final m = secondsLeft ~/ 60;
    final s = secondsLeft % 60;
    final label = '$m:${s.toString().padLeft(2, '0')}';
    return AppCard(
      color: AppColors.chipFill,
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Rest — $label',
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: AppColors.accent,
              ),
            ),
          ),
          GestureDetector(
            onTap: onSkip,
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
    );
  }
}

class _EditResult {
  final bool delete;
  final double? weightKg;
  final int? reps;
  const _EditResult({this.delete = false, this.weightKg, this.reps});
}

class _EditSetSheet extends StatefulWidget {
  final LoggedSetRow set;
  final UnitSystem units;
  const _EditSetSheet({required this.set, required this.units});

  @override
  State<_EditSetSheet> createState() => _EditSetSheetState();
}

class _EditSetSheetState extends State<_EditSetSheet> {
  late double _weightKg = widget.set.weightKg;
  late int _reps = widget.set.reps;

  @override
  Widget build(BuildContext context) {
    final units = widget.units;
    final step = units.weightStep;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit set ${widget.set.setNumber}', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 18),
          _StepperRow(
            label: 'Weight',
            value: units.formatWeight(_weightKg, decimals: 1),
            unit: units.weightLabel,
            onDec: () => setState(() {
              final shown = units.fromKg(_weightKg);
              _weightKg = units.toKg((shown - step).clamp(0, 999));
            }),
            onInc: () => setState(() {
              final shown = units.fromKg(_weightKg);
              _weightKg = units.toKg(shown + step);
            }),
          ),
          const SizedBox(height: 18),
          _StepperRow(
            label: 'Reps',
            value: '$_reps',
            onDec: () => setState(() => _reps = (_reps - 1).clamp(1, 99)),
            onInc: () => setState(() => _reps = (_reps + 1).clamp(1, 99)),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, const _EditResult(delete: true)),
                  child: const Text('Delete'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _EditResult(weightKg: _weightKg, reps: _reps),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final VoidCallback onDec;
  final VoidCallback onInc;

  const _StepperRow({
    required this.label,
    required this.value,
    this.unit,
    required this.onDec,
    required this.onInc,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        _RoundButton(icon: Icons.remove_rounded, onTap: onDec),
        SizedBox(
          width: 96,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w800,
                  fontSize: 26,
                  height: 1.1,
                  color: AppColors.textPrimary,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Text(
                  unit!,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        _RoundButton(icon: Icons.add_rounded, onTap: onInc),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.inputFill,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, size: 20, color: AppColors.textBody),
        ),
      ),
    );
  }
}
