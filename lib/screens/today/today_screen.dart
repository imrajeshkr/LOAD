import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';
import 'guide_screen.dart';
import 'log_screen.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  bool _nudgeDismissed = false;
  final _weighInCtrl = TextEditingController();
  final _proteinCtrl = TextEditingController();

  @override
  void dispose() {
    _weighInCtrl.dispose();
    _proteinCtrl.dispose();
    super.dispose();
  }

  void _openLog(AppState state, int index) {
    state.openExercise(index);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LogScreen(), fullscreenDialog: false),
    );
  }

  Future<void> _startSession(AppState state) async {
    // No plan means nothing to open — pushing the log screen would index
    // into an empty list.
    if (!state.hasPlan) return;
    final next = List.generate(state.exercises.length, (i) => i)
        .firstWhere((i) => !state.exerciseDone(i), orElse: () => 0);
    if (state.currentSessionId == null) {
      await state.startSession(state.planLabel ?? 'Training');
    }
    if (!mounted) return;
    _openLog(state, next);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final units = state.units;
    final dateLabel = DateFormat('EEEE, MMMM d').format(DateTime.now());
    final showNudge = !_nudgeDismissed && !state.sessionComplete && state.sessionsThisWeek == 0;

    if (!state.loading && !state.hasPlan) {
      return _NoPlanState(profileComplete: state.profile.isComplete);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        ScreenHeader(
          eyebrow: dateLabel,
          title: state.planLabel ?? 'Training',
          accentLine: state.trainingStreak > 0
              ? '${state.trainingStreak}-day streak · ${state.sessionsThisWeek} sessions this week'
              : null,
          trailing: Text(
            '${state.totalDone}/${state.exercises.length}',
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: AppColors.accent,
            ),
          ),
        ),

        if (state.sessionComplete)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: AppCard(
              color: AppColors.accent,
              child: Text(
                "Nice work — session's in the books.",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  height: 1.4,
                  color: AppColors.onAccent,
                ),
              ),
            ),
          ),

        if (showNudge)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: SoftBanner(
              message: "Nothing logged this week yet — want to start with today's session?",
              actionLabel: 'Dismiss',
              onAction: () => setState(() => _nudgeDismissed = true),
            ),
          ),

        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              for (var i = 0; i < state.exercises.length; i++) ...[
                _ExerciseCard(
                  index: i,
                  onOpen: () => _openLog(state, i),
                ),
                if (i != state.exercises.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _startSession(state),
              child: Text(
                state.sessionComplete
                    ? 'Session complete'
                    : state.sessionSetsLogged > 0
                        ? 'Continue session'
                        : 'Start session',
              ),
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _QuickLogRow(
            title: "Log today's weigh-in",
            subtitle: state.weightLog.isNotEmpty
                ? 'Last: ${units.formatWeightWithUnit(state.weightLog.last.weightKg, decimals: 1)}'
                : null,
            hint: units.weightLabel,
            controller: _weighInCtrl,
            onSubmit: () {
              final shown = double.tryParse(_weighInCtrl.text.trim());
              if (shown == null || shown <= 0) return;
              state.logWeight(units.toKg(shown));
              _weighInCtrl.clear();
              FocusScope.of(context).unfocus();
            },
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _QuickLogRow(
            title: "Log today's protein",
            subtitle: '${state.proteinToday} / ${state.proteinTarget.grams} g'
                '${state.proteinStreak > 0 ? '  ·  ${state.proteinStreak}-day streak' : ''}',
            hint: 'g',
            controller: _proteinCtrl,
            progress: state.proteinTarget.grams == 0
                ? 0
                : (state.proteinToday / state.proteinTarget.grams).clamp(0.0, 1.0),
            onSubmit: () {
              final g = int.tryParse(_proteinCtrl.text.trim());
              if (g == null || g <= 0) return;
              state.logProtein(g);
              _proteinCtrl.clear();
              FocusScope.of(context).unfocus();
            },
          ),
        ),
      ],
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  final int index;
  final VoidCallback onOpen;
  const _ExerciseCard({required this.index, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ex = state.exercises[index];
    final units = state.units;
    final flagged = state.exerciseFlagged(ex);
    final done = state.exerciseDone(index);
    final logged = state.loggedCount(index);

    return AppCard(
      onTap: onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        ex.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    MiniPill(
                      label: 'Guide',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => GuideScreen(exercise: ex),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  ex.prescriptionLabel,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    height: 1.6,
                    color: AppColors.textSecondary,
                  ),
                ),
                if (flagged)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            size: 12, color: AppColors.warning),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Watch your ${state.flagLabel(ex)}',
                            style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 10.5,
                              height: 1.5,
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (ex.isBodyweight)
                const Text(
                  'Bodyweight',
                  style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                )
              else
                RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      height: 1.2,
                      color: AppColors.textBody,
                    ),
                    children: [
                      TextSpan(text: units.formatWeight(ex.weightKg)),
                      TextSpan(
                        text: ' ${units.weightLabel}',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                done ? 'Done' : '$logged/${ex.setsTarget} sets',
                style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 10.5,
                  height: 1.5,
                  color: done ? AppColors.positive : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickLogRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String hint;
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final double? progress;

  const _QuickLogRow({
    required this.title,
    this.subtitle,
    required this.hint,
    required this.controller,
    required this.onSubmit,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                        height: 1.4,
                        color: AppColors.textMuted,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 10.5,
                          height: 1.5,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(
                width: 62,
                child: TextField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onSubmit(),
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.textBody,
                  ),
                  decoration: InputDecoration(
                    hintText: hint,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSubmit,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(AppRadii.smallButton),
                  ),
                  child: const Text(
                    'Log',
                    style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      color: AppColors.onAccent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 11),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: AppColors.track,
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoPlanState extends StatelessWidget {
  final bool profileComplete;
  const _NoPlanState({required this.profileComplete});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.event_available_rounded, size: 40, color: AppColors.textFaint),
            const SizedBox(height: 16),
            Text(
              profileComplete ? 'Building your plan…' : "Let's finish setting you up",
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              profileComplete
                  ? "This shouldn't take long — pull to refresh in a moment."
                  : 'Finish your profile in Settings so I can build a program around it.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
