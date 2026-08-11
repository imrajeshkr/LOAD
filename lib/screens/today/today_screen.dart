import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/app_state.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';
import 'guide_screen.dart';
import 'session_flow_screen.dart';

/// The Today tab: one hero card that carries the whole session — start it,
/// watch it fill in, see it done — instead of a checklist of separate
/// exercise rows each needing its own tap.
class TodayScreen extends StatefulWidget {
  final VoidCallback? onOpenProfile;
  const TodayScreen({super.key, this.onOpenProfile});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  bool _nudgeDismissed = false;
  bool _weighInNudgeDismissed = false;

  Future<void> _startSession(AppState state) async {
    if (!state.hasPlan) return;
    // First exercise with nothing logged today — not "first incomplete
    // target", so re-opening a session lands on real unfinished work rather
    // than skipping past a set that's merely short of its rep goal.
    var next = state.exercises.indexWhere((e) => e.setsLoggedToday == 0);
    if (next == -1) next = 0;
    if (state.currentSessionId == null) {
      await state.startSession(state.planLabel ?? 'Training');
    }
    if (!mounted) return;
    state.openExercise(next);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SessionFlowScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _openProteinSheet(AppState state) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ProteinSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dateLabel = DateFormat('EEEE, MMMM d').format(DateTime.now());
    final showMissedNudge =
        !_nudgeDismissed &&
        !state.sessionComplete &&
        !state.heroAnyLogged &&
        state.sessionsThisWeek == 0;
    final showWeighInNudge = !_weighInNudgeDismissed && state.weighInNudgeDue;

    if (!state.loading && !state.hasPlan) {
      return _NoPlanState(profileComplete: state.profile.isComplete);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        ScreenHeader(
          eyebrow: dateLabel,
          title: state.planLabel ?? 'Training',
          accentLine: state.momentumLine,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: state.sessionComplete
              ? _HeroComplete(state: state)
              : _HeroActive(state: state, onTap: () => _startSession(state)),
        ),
        if (state.sessionComplete && (state.nextSession?.hasNext ?? false))
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _UpNextCard(preview: state.nextSession!),
          ),
        if (showWeighInNudge)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _NudgeRow(
              message: "It's been a while — quick weigh-in?",
              primaryLabel: 'Log',
              onPrimary: () {
                setState(() => _weighInNudgeDismissed = true);
                widget.onOpenProfile?.call();
              },
              onDismiss: () => setState(() => _weighInNudgeDismissed = true),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: GestureDetector(
            onTap: () => _openProteinSheet(state),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.inputFill,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Text(
                        'Protein',
                        style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      Text(
                        '${state.proteinToday} / ${state.proteinTarget.grams} g',
                        style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: AppColors.textBody,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: state.proteinTarget.grams == 0
                          ? 0
                          : (state.proteinToday / state.proteinTarget.grams)
                                .clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: AppColors.track,
                      valueColor: const AlwaysStoppedAnimation(
                        AppColors.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showMissedNudge)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: SoftBanner(
              message:
                  "Nothing logged this week yet — want to start with today's session?",
              actionLabel: 'Dismiss',
              onAction: () => setState(() => _nudgeDismissed = true),
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _NudgeRow extends StatelessWidget {
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback onDismiss;
  const _NudgeRow({
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 12,
                height: 1.45,
                color: AppColors.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onPrimary,
            child: Text(
              primaryLabel,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
                color: AppColors.accent,
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onDismiss,
            child: const Text(
              'Later',
              style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
                color: AppColors.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroActive extends StatelessWidget {
  final AppState state;
  final VoidCallback onTap;
  const _HeroActive({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(26),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 26,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Today's session",
                        style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        state.planLabel ?? 'Training',
                        style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w900,
                          fontSize: 19,
                          height: 1.2,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  if (state.heroAnyLogged)
                    CustomPaint(
                      size: const Size(46, 46),
                      painter: _RingPainter(progress: state.heroProgress),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < state.exercises.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Builder(
                    builder: (context) {
                      final ex = state.exercises[i];
                      final done = ex.setsLoggedToday > 0;
                      return Row(
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: done
                                  ? AppColors.accent
                                  : AppColors.chipFill,
                              shape: BoxShape.circle,
                            ),
                            child: done
                                ? const Icon(
                                    Icons.check_rounded,
                                    size: 12,
                                    color: Colors.white,
                                  )
                                : Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      fontFamily: AppTheme.fontFamily,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 9.5,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              ex.name,
                              style: TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                                color: done
                                    ? AppColors.textSecondary
                                    : AppColors.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            ex.prescriptionLabel,
                            style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color: AppColors.textFaint,
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => GuideScreen(exercise: ex),
                              ),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(
                                Icons.info_outline_rounded,
                                size: 15,
                                color: AppColors.textFaint,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              const SizedBox(height: 7),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  state.heroCta,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: AppColors.onAccent,
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

class _HeroComplete extends StatelessWidget {
  final AppState state;
  const _HeroComplete({required this.state});

  Color _toneColor(DeltaTone tone) => switch (tone) {
    DeltaTone.positive => AppColors.positive,
    DeltaTone.warning => AppColors.warning,
    DeltaTone.neutral => AppColors.textFaint,
  };

  @override
  Widget build(BuildContext context) {
    final breakdown = state.sessionBreakdown;
    final skipped = state.skippedExerciseCount;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${state.planLabel ?? 'Session'}, done.',
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        height: 1.2,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.heroCompleteStats,
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (breakdown.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),
            for (var i = 0; i < breakdown.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i == breakdown.length - 1 ? 0 : 11,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            breakdown[i].name,
                            style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                              color: AppColors.textBody,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            breakdown[i].delta,
                            style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              height: 1.5,
                              color: _toneColor(breakdown[i].tone),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      breakdown[i].detail,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        height: 1.45,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            if (skipped > 0) ...[
              const SizedBox(height: 11),
              Text(
                '$skipped exercise${skipped > 1 ? 's' : ''} not logged today.',
                style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w600,
                  fontSize: 11.5,
                  color: AppColors.textFaint,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _UpNextCard extends StatefulWidget {
  final NextSessionPreview preview;
  const _UpNextCard({required this.preview});

  @override
  State<_UpNextCard> createState() => _UpNextCardState();
}

class _UpNextCardState extends State<_UpNextCard> {
  bool _open = true;

  String _whenLabel(DateTime d) {
    final today = DateTime.now();
    final diff = DateTime(
      d.year,
      d.month,
      d.day,
    ).difference(DateTime(today.year, today.month, today.day)).inDays;
    final dateStr = DateFormat('EEE, MMM d').format(d);
    return diff == 1 ? 'Tomorrow · $dateStr' : dateStr;
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final when = preview.scheduledFor == null
        ? ''
        : _whenLabel(preview.scheduledFor!);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Up next',
                      style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      preview.label ?? 'Next session',
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.3,
                        color: AppColors.textBody,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '$when · ${preview.exercises.length} exercises · ${preview.totalSets} sets',
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, left: 8),
                  child: Text(
                    _open ? 'Hide' : 'Show',
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_open) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: preview.exercises.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final ex = preview.exercises[i];
                  return GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GuideScreen(exercise: ex),
                      ),
                    ),
                    child: Container(
                      width: 132,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(11),
                            child: SizedBox(
                              height: 66,
                              width: double.infinity,
                              child: ExerciseDemoMedia(
                                url: SupabaseService.instance.demoUrl(
                                  ex.demoPath,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            ex.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 11.5,
                              color: AppColors.textBody,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            ex.prescriptionLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w600,
                              fontSize: 10,
                              color: AppColors.textFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  const _RingPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;
    final track = Paint()
      ..color = AppColors.chipFill
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6;
    canvas.drawCircle(center, radius, track);
    if (progress > 0) {
      final ring = Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        ring,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _ProteinSheet extends StatefulWidget {
  const _ProteinSheet();

  @override
  State<_ProteinSheet> createState() => _ProteinSheetState();
}

class _ProteinSheetState extends State<_ProteinSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
            Text('Protein', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${state.proteinToday} / ${state.proteinTarget.grams} g today'
              '${state.proteinStreak > 0 ? '  ·  ${state.proteinStreak}-day streak' : ''}',
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.textBody,
                    ),
                    decoration: const InputDecoration(hintText: 'grams'),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () {
                    final g = int.tryParse(_ctrl.text.trim());
                    if (g == null || g <= 0) return;
                    state.logProtein(g);
                    Navigator.of(context).pop();
                  },
                  child: const Text('Log'),
                ),
              ],
            ),
          ],
        ),
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
            const Icon(
              Icons.event_available_rounded,
              size: 40,
              color: AppColors.textFaint,
            ),
            const SizedBox(height: 16),
            Text(
              profileComplete
                  ? 'Building your plan…'
                  : "Let's finish setting you up",
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
