import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';

class LogScreen extends StatefulWidget {
  final VoidCallback onBackToToday;
  final VoidCallback onFinish;
  const LogScreen({super.key, required this.onBackToToday, required this.onFinish});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  late double _weight;
  late int _reps;
  int? _lastIndex;

  void _syncFromExercise(AppState state) {
    final idx = state.currentExerciseIndex;
    if (_lastIndex != idx) {
      _lastIndex = idx;
      _weight = state.exercises[idx].startingWeight;
      _reps = state.exercises[idx].reps;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _syncFromExercise(state);
    final ex = state.exercises[state.currentExerciseIndex];
    final flagged = state.exerciseFlagged(ex);
    final loggedSets = state.loggedSets[state.currentExerciseIndex] ?? [];
    final isLast = state.currentExerciseIndex >= state.exercises.length - 1;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: widget.onBackToToday,
                  child: const Text('‹ TODAY', style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 10),
                Text('EXERCISE ${state.currentExerciseIndex + 1} / ${state.exercises.length}',
                    style: const TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(ex.name.toUpperCase(), style: const TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => state.openGuide(state.currentExerciseIndex),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(5)),
                        child: const Text('GUIDE', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Target ${ex.setsTarget}×${ex.reps} · starting ${ex.startingWeight.toStringAsFixed(0)} lb',
                    style: const TextStyle(color: AppColors.textTertiary, fontSize: 12)),
                if (flagged)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                      decoration: BoxDecoration(color: AppColors.cautionBg, border: Border.all(color: AppColors.caution), borderRadius: BorderRadius.circular(10)),
                      child: Text('⚠ Conflicts with your ${state.flagLabel(ex)}', style: const TextStyle(color: AppColors.caution, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
                if (exerciseAlts.containsKey(ex.name))
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton(
                      onPressed: () => setState(() => state.swapExercise(ex.name)),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                      child: Text('Swap for ${exerciseAlts[ex.name]!.name}', style: const TextStyle(fontSize: 12)),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Stepper(label: 'WEIGHT (LB)', value: _weight.toStringAsFixed(0), onDec: () => setState(() => _weight = (_weight - 5).clamp(0, 999)), onInc: () => setState(() => _weight += 5)),
                _Stepper(label: 'REPS', value: '$_reps', onDec: () => setState(() => _reps = (_reps - 1).clamp(0, 99)), onInc: () => setState(() => _reps += 1)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => state.logSet(state.currentExerciseIndex, _weight, _reps),
                child: const Text('Log Set'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LOGGED TODAY', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                if (loggedSets.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('No sets logged yet.', style: TextStyle(color: AppColors.textTertiary, fontSize: 12))),
                ...loggedSets.asMap().entries.map((e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('SET ${e.key + 1}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                          Text('${e.value.weight.toStringAsFixed(0)} lb × ${e.value.reps}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                        ],
                      ),
                    )),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: state.currentExerciseIndex > 0 ? () => state.openExercise(state.currentExerciseIndex - 1) : null,
                    child: const Text('Prev'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: OutlinedButton(
                    onPressed: () {
                      if (isLast) {
                        state.finishSession('Push Day');
                        widget.onFinish();
                      } else {
                        state.openExercise(state.currentExerciseIndex + 1);
                      }
                    },
                    child: Text(isLast ? 'Finish Session' : 'Next Exercise'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onDec;
  final VoidCallback onInc;
  const _Stepper({required this.label, required this.value, required this.onDec, required this.onInc});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
        const SizedBox(height: 10),
        Row(
          children: [
            _stepBtn(Icons.remove, onDec),
            SizedBox(width: 56, child: Text(value, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
            _stepBtn(Icons.add, onInc),
          ],
        ),
      ],
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: AppColors.textPrimary),
        ),
      );
}
