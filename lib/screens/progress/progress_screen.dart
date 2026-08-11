import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/charts.dart';

class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final units = state.units;
    final dayFmt = DateFormat('d MMM');

    final hasAnything = state.weightLog.isNotEmpty ||
        state.sessionHistory.isNotEmpty ||
        state.proteinLog.isNotEmpty;

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () => state.refreshProgress(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          ScreenHeader(
            title: 'Progress',
            eyebrow: 'Your training over time',
            accentLine: state.trainingDays.isEmpty
                ? null
                : '${state.sessionsThisWeek} sessions this week'
                    '${state.trainingStreak > 0 ? ' · ${state.trainingStreak}-day streak' : ''}',
          ),

          if (!hasAnything)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 30, 20, 0),
              child: AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 34),
                child: const EmptyHint(
                  'Log a session, a weigh-in, or your protein and your trends '
                  'will start showing up here.',
                ),
              ),
            ),

          // ── consistency ────────────────────────────────────────────────
          if (state.trainingDays.isNotEmpty) ...[
            const _Section('Consistency'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AppCard(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: ConsistencyGrid(activeDays: state.trainingDays),
              ),
            ),
          ],

          // ── bodyweight ─────────────────────────────────────────────────
          if (state.weightLog.isNotEmpty) ...[
            _Section(
              'Bodyweight',
              caption: '7-day average — a single reading moves on water and food',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AppCard(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: TrendLineChart(
                  points: [
                    for (final e in state.weightLog)
                      ChartPoint(units.fromKg(e.avgKg), dayFmt.format(e.loggedAt)),
                  ],
                  color: AppColors.accent,
                  goalValue: state.profile.targetWeightKg == null
                      ? null
                      : units.fromKg(state.profile.targetWeightKg!),
                  goalLabel: state.profile.targetWeightKg == null
                      ? null
                      : 'Goal ${units.formatWeightWithUnit(state.profile.targetWeightKg!, decimals: 1)}',
                  formatValue: (v) => '${v.toStringAsFixed(1)} ${units.weightLabel}',
                ),
              ),
            ),
          ],

          // ── strength per lift ──────────────────────────────────────────
          if (state.trackedExercises.isNotEmpty) ...[
            const _Section('Strength'),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: state.trackedExercises.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final name = state.trackedExercises[i];
                  return ChoiceChipButton(
                    label: name,
                    selected: state.selectedTrendExercise == name,
                    onTap: () => state.selectTrendExercise(name),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AppCard(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: TrendLineChart(
                  points: [
                    for (final p in state.strengthTrend)
                      ChartPoint(units.fromKg(p.topSetKg), dayFmt.format(p.date)),
                  ],
                  color: AppColors.positive,
                  formatValue: (v) => '${v.toStringAsFixed(1)} ${units.weightLabel}',
                ),
              ),
            ),
          ],

          // ── protein ────────────────────────────────────────────────────
          if (state.proteinLog.isNotEmpty) ...[
            const _Section('Protein'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AppCard(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '${state.proteinToday} g',
                          style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w800,
                            fontSize: 26,
                            height: 1.1,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'today of ${state.proteinTarget.grams} g',
                          style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      state.proteinTarget.rationale,
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 10.5,
                        height: 1.4,
                        color: AppColors.textFaint,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TargetBarChart(
                      points: [
                        for (final e in state.proteinLog.length > 10
                            ? state.proteinLog.sublist(state.proteinLog.length - 10)
                            : state.proteinLog)
                          ChartPoint(e.grams.toDouble(), DateFormat('E').format(e.loggedAt)[0]),
                      ],
                      target: state.proteinTarget.grams.toDouble(),
                      color: AppColors.accent,
                    ),
                  ],
                ),
              ),
            ),
          ],

          // ── session history ────────────────────────────────────────────
          if (state.sessionHistory.isNotEmpty) ...[
            const _Section('Recent sessions'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0; i < state.sessionHistory.length; i++)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: i == state.sessionHistory.length - 1
                                  ? Colors.transparent
                                  : AppColors.divider,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    state.sessionHistory[i].label,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${state.sessionHistory[i].setCount} sets · '
                                    '${units.formatWeight(state.sessionHistory[i].volumeKg)} '
                                    '${units.weightLabel} volume',
                                    style: const TextStyle(
                                      fontFamily: AppTheme.fontFamily,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 11,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              dayFmt.format(state.sessionHistory[i].date),
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                                color: AppColors.textFaint,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? caption;
  const _Section(this.title, {this.caption});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(title),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10, top: 2),
              child: Text(
                caption!,
                style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w600,
                  fontSize: 10.5,
                  color: AppColors.textFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
