import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';

class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Progress', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 24),

          _SectionLabel('BODYWEIGHT — LAST ${state.weightLog.length} ENTRIES'),
          const SizedBox(height: 14),
          if (state.weightLog.isEmpty)
            const _EmptyHint('Log a weigh-in on Today to start this chart.')
          else
            _BarChart(
              values: state.weightLog.map((e) => e.weight).toList(),
              labels: state.weightLog.map((e) => DateFormat('M/d').format(e.loggedAt)).toList(),
              color: AppColors.accent,
            ),

          const SizedBox(height: 28),
          _SectionLabel('CURRENT WORKING WEIGHT'),
          const SizedBox(height: 12),
          ...state.exercises.map((ex) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(ex.name, style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 13)),
                    Text('${ex.startingWeight.toStringAsFixed(0)} lb', style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
                  ],
                ),
              )),

          const SizedBox(height: 28),
          _SectionLabel('PROTEIN — LAST ${state.proteinLog.length} DAYS (${state.proteinStreak}-DAY STREAK)'),
          const SizedBox(height: 14),
          if (state.proteinLog.isEmpty)
            const _EmptyHint('Log today\'s protein on Today to start this chart.')
          else
            _BarChart(
              values: state.proteinLog.map((e) => e.grams.toDouble()).toList(),
              labels: state.proteinLog.map((e) => DateFormat('M/d').format(e.loggedAt)).toList(),
              color: AppColors.positive,
            ),

          const SizedBox(height: 28),
          _SectionLabel('SESSION HISTORY'),
          const SizedBox(height: 10),
          if (state.sessionHistory.isEmpty)
            const _EmptyHint('Finish a session to see it here.')
          else
            ...state.sessionHistory.map((s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(s.label, style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 13)),
                      Text(DateFormat('MMM d').format(s.date).toUpperCase(), style: const TextStyle(color: AppColors.textTertiary, fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5));
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(color: AppColors.textTertiary, fontSize: 12));
}

class _BarChart extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color color;
  const _BarChart({required this.values, required this.labels, required this.color});

  @override
  Widget build(BuildContext context) {
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV) == 0 ? 1 : (maxV - minV);
    return SizedBox(
      height: 100,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(values.length, (i) {
          final pct = 0.25 + ((values[i] - minV) / range) * 0.75;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: FractionallySizedBox(
                      alignment: Alignment.bottomCenter,
                      heightFactor: pct.clamp(0.05, 1.0),
                      child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(labels[i], style: const TextStyle(color: AppColors.textTertiary, fontSize: 8)),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
