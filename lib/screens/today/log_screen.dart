import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';
import 'guide_screen.dart';
import 'summary_screen.dart';

/// Mid-workout set logging. Deliberately the fastest screen in the app:
/// weight and reps only, two taps to record a set.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  double? _weightKg;
  int? _reps;
  int? _syncedIndex;

  /// Re-seed the steppers when the user moves to a different exercise.
  void _syncTo(AppState state) {
    if (_syncedIndex == state.currentExerciseIndex) return;
    final ex = state.exercises[state.currentExerciseIndex];
    _syncedIndex = state.currentExerciseIndex;
    _weightKg = ex.weightKg;
    _reps = ex.reps;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _syncTo(state);

    final units = state.units;
    final idx = state.currentExerciseIndex;
    final ex = state.exercises[idx];
    final sets = state.loggedSets[idx] ?? const [];
    final isLast = idx >= state.exercises.length - 1;
    final flagged = state.exerciseFlagged(ex);
    final step = units.weightStep;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Exercise ${idx + 1} of ${state.exercises.length}',
          style: Theme.of(context).textTheme.titleMedium,
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
            'Target ${ex.setsLabel} · working weight '
            '${units.formatWeightWithUnit(ex.weightKg)}',
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

          const SizedBox(height: 18),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Column(
              children: [
                _StepperRow(
                  label: 'Weight',
                  value: units.formatWeight(_weightKg ?? ex.weightKg, decimals: 1),
                  unit: units.weightLabel,
                  onDec: () => setState(() {
                    final shown = units.fromKg(_weightKg ?? ex.weightKg);
                    _weightKg = units.toKg((shown - step).clamp(0, 999));
                  }),
                  onInc: () => setState(() {
                    final shown = units.fromKg(_weightKg ?? ex.weightKg);
                    _weightKg = units.toKg(shown + step);
                  }),
                ),
                const Divider(height: 26),
                _StepperRow(
                  label: 'Reps',
                  value: '${_reps ?? ex.reps}',
                  onDec: () => setState(() => _reps = ((_reps ?? ex.reps) - 1).clamp(1, 99)),
                  onInc: () => setState(() => _reps = ((_reps ?? ex.reps) + 1).clamp(1, 99)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                state.logSet(idx, _weightKg ?? ex.weightKg, _reps ?? ex.reps);
              },
              child: Text('Log set ${sets.length + 1}'),
            ),
          ),

          const SizedBox(height: 24),
          SectionLabel(
            'Logged today',
            trailing: sets.isEmpty
                ? null
                : GestureDetector(
                    onTap: () => state.undoLastSet(idx),
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
            child: sets.isEmpty
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
                        Container(
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
                              Text(
                                '${units.formatWeightWithUnit(sets[i].weightKg, decimals: 1)}'
                                '  ×  ${sets[i].reps}',
                                style: const TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  color: AppColors.textBody,
                                ),
                              ),
                            ],
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
                    onPressed: () {
                      state.openExercise(idx - 1);
                      setState(() {});
                    },
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
                      await state.finishSession('Push Day');
                      if (!context.mounted) return;
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const SummaryScreen()),
                      );
                    } else {
                      state.openExercise(idx + 1);
                      setState(() {});
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
