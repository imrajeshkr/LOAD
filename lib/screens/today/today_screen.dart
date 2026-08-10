import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';

class TodayScreen extends StatefulWidget {
  final VoidCallback onStartSession;
  final VoidCallback onOpenExercise;
  const TodayScreen({super.key, required this.onStartSession, required this.onOpenExercise});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  bool _nudgeDismissed = false;
  final _weighInCtrl = TextEditingController();
  final _proteinCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dateLabel = DateFormat('EEE MM.dd').format(DateTime.now()).toUpperCase();

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dateLabel, style: const TextStyle(color: AppColors.textSecondary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.6)),
                    const SizedBox(height: 6),
                    const Text('Push Day', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
                  ],
                ),
                Text('${state.totalDone.toString().padLeft(2, '0')}/${state.exercises.length.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
              ],
            ),
          ),
          const Divider(height: 1),
          if (!_nudgeDismissed && state.sessionHistory.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(14)),
                child: Row(
                  children: [
                    const Expanded(
                        child: Text("First session — let's build the habit from day one.",
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 12))),
                    GestureDetector(
                      onTap: () => setState(() => _nudgeDismissed = true),
                      child: const Text('DISMISS', style: TextStyle(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
          if (state.sessionComplete)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(14)),
                child: const Text('SESSION COMPLETE ✓', textAlign: TextAlign.center, style: TextStyle(color: AppColors.accentOn, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    Text('EXERCISE', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                    Text('LOAD', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                  ],
                ),
                const Divider(height: 18),
                ...List.generate(state.exercises.length, (i) => _ExerciseRow(index: i, onTap: () {
                      state.openExercise(i);
                      widget.onOpenExercise();
                    })),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final idx = List.generate(state.exercises.length, (i) => i).firstWhere((i) => !state.exerciseDone(i), orElse: () => 0);
                  state.startSession('Push Day').then((_) {
                    state.openExercise(idx);
                    widget.onStartSession();
                  });
                },
                child: Text(state.sessionComplete ? 'Session Complete' : 'Start Session'),
              ),
            ),
          ),
          _QuickLogCard(
            label: 'Log today\'s weigh-in',
            controller: _weighInCtrl,
            suffix: 'lb',
            onSubmit: () {
              final v = double.tryParse(_weighInCtrl.text.trim());
              if (v != null && v > 0) {
                state.logWeight(v);
                _weighInCtrl.clear();
              }
            },
          ),
          const SizedBox(height: 10),
          _QuickLogCard(
            label: 'Log today\'s protein',
            trailingLabel: '${state.proteinStreak}-DAY STREAK',
            controller: _proteinCtrl,
            suffix: 'g',
            onSubmit: () {
              final v = int.tryParse(_proteinCtrl.text.trim());
              if (v != null && v > 0) {
                state.logProtein(v);
                _proteinCtrl.clear();
              }
            },
          ),
        ],
      ),
    );
  }
}

class _ExerciseRow extends StatelessWidget {
  final int index;
  final VoidCallback onTap;
  const _ExerciseRow({required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ex = state.exercises[index];
    final flagged = state.exerciseFlagged(ex);
    final done = state.exerciseDone(index);
    final logged = state.loggedCount(index);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(ex.name.toUpperCase(), style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => state.openGuide(index),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(4)),
                          child: const Text('GUIDE', style: TextStyle(color: AppColors.textTertiary, fontSize: 9, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text('${ex.setsTarget}×${ex.reps}', style: const TextStyle(color: AppColors.textTertiary, fontSize: 11)),
                  if (flagged)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('⚠ Conflicts with your ${state.flagLabel(ex)}', style: const TextStyle(color: AppColors.caution, fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${ex.startingWeight.toStringAsFixed(0)} lb', style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
                Text(done ? 'DONE' : '$logged/${ex.setsTarget}', style: TextStyle(color: done ? AppColors.positive : AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickLogCard extends StatelessWidget {
  final String label;
  final String? trailingLabel;
  final TextEditingController controller;
  final String suffix;
  final VoidCallback onSubmit;

  const _QuickLogCard({
    required this.label,
    this.trailingLabel,
    required this.controller,
    required this.suffix,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                  children: [
                    TextSpan(text: label),
                    if (trailingLabel != null) TextSpan(text: '  $trailingLabel', style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 52,
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                decoration: InputDecoration(hintText: suffix, contentPadding: const EdgeInsets.symmetric(vertical: 8)),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onSubmit,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(10)),
                child: const Text('Log', style: TextStyle(color: AppColors.accentOn, fontWeight: FontWeight.w700, fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
