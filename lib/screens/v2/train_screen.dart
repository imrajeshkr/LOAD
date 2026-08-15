import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../services/session_controller.dart';
import '../../services/haptics.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/v2_widgets.dart';
import 'session_flow_screen.dart';

/// The real Train tab. Three faces off one payload:
///   • training day, not done → plan + morning note + Start (before-state)
///   • rest day              → rest card + what's next
///   • session completed today → summary, charts, recap (after-state)
class TrainTab extends StatefulWidget {
  const TrainTab({super.key});
  @override
  State<TrainTab> createState() => _TrainTabState();
}

class _TrainTabState extends State<TrainTab> {
  TrainScreenV2? _plan;
  SessionSummaryV2? _summary;
  MorningNoteV2? _note;
  BodyFuelV2? _fuel;
  List<ProgressionV2> _progressions = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = SupabaseService.instance;
      final plan = await svc.fetchTrainScreen();
      final completed = plan?.sessionStatus == 'completed' && plan?.sessionId != null;

      final results = await Future.wait([
        svc.fetchBodyFuel(),
        svc.fetchMorningNote(),
        if (completed) svc.fetchSessionSummary(plan!.sessionId!),
        if (completed) svc.fetchProgressions(),
      ]);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _fuel = results[0] as BodyFuelV2;
        _note = results[1] as MorningNoteV2?;
        _summary = completed ? results[2] as SessionSummaryV2? : null;
        _progressions = completed ? results[3] as List<ProgressionV2> : const [];
        _loading = false;
      });
      // Surfacing the note counts as reading it.
      final note = _note;
      if (note != null && note.readAt == null) svc.markNoteRead(note.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // Refetches only the fuel card, not the whole tab — a +20g tap used to
  // flash the entire screen back to its loading spinner.
  Future<void> _logProtein(int grams) async {
    final svc = SupabaseService.instance;
    await svc.logProtein(grams);
    if (!mounted) return;
    final fuel = await svc.fetchBodyFuel();
    if (mounted) setState(() => _fuel = fuel);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _start() async {
    final plan = _plan;
    if (plan == null) return;
    // A visible Start bar with no exercises would tap into nothing — tell the
    // user rather than dead-ending silently.
    if (plan.exercises.isEmpty) {
      _snack("Today's plan has no exercises yet — pull to refresh.");
      return;
    }
    final svc = SupabaseService.instance;
    String? sessionId;
    try {
      sessionId = await svc.openSession(title: plan.label);
    } catch (e) {
      // Never swallow this again: a failed openSession is exactly what made the
      // Start button look dead. Surface it so the real cause is visible.
      Haptics.error();
      _snack('Could not start the session: $e');
      return;
    }
    if (sessionId == null || !mounted) return;
    final results = await Future.wait([
      svc.fetchEffortPromptPref(),
      svc.fetchKeepScreenAwakePref(),
      plan.sessionStatus == 'in_progress'
          ? svc.fetchResumeState(sessionId)
          : Future.value(<int, ResumedLiftV2>{}),
    ]);
    if (!mounted) return;
    final controller = SessionController(
      sessionId: sessionId,
      label: plan.label ?? 'Session',
      exercises: plan.exercises,
      effortPrompt: results[0] as String,
      startedAt: plan.startedAt,
      resume: results[2] as Map<int, ResumedLiftV2>,
    );
    final keepAwake = results[1] as bool;
    if (keepAwake) await WakelockPlus.enable();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: controller,
        child: const SessionFlowScreen(),
      ),
    ));
    if (keepAwake) await WakelockPlus.disable();
    controller.dispose();
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_error != null || _plan == null) {
      return _ErrorState(message: _error ?? 'Not signed in.', onRetry: _load);
    }
    final plan = _plan!;
    // Start/Continue floats above the list rather than living at the bottom
    // of the exercise cards — with a long plan it was scrolling out of reach.
    final showStartBar = _summary == null && !plan.isRest;
    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          RefreshIndicator(
            color: AppColors.accent,
            backgroundColor: AppColors.surface,
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.fromLTRB(20, 16, 20, showStartBar ? 96 : 8),
              children: [
                _Header(plan: plan, summary: _summary),
                const SizedBox(height: 16),
                _WeekCalendar(week: plan.week),
                const SizedBox(height: 16),
                if (_summary != null)
                  ..._afterState(plan, _summary!)
                else if (plan.isRest)
                  ..._restState(plan)
                else
                  ..._beforeState(plan),
              ],
            ),
          ),
          if (showStartBar)
            Positioned(
              left: 20,
              right: 20,
              bottom: 16,
              child: _StartSessionBar(
                resuming: plan.sessionStatus == 'in_progress',
                onTap: _start,
              ),
            ),
        ],
      ),
    );
  }

  // ── BEFORE: training day ──────────────────────────────────────────────────
  List<Widget> _beforeState(TrainScreenV2 plan) => [
        if (_note != null) ...[
          _MorningNoteCard(note: _note!),
          const SizedBox(height: 16),
        ],
        _PlanList(plan: plan),
        if (_fuel != null) ...[
          const SizedBox(height: 16),
          _BodyFuelCard(fuel: _fuel!, onQuickAdd: _logProtein),
        ],
        if (plan.upcoming.isNotEmpty) ...[
          const SizedBox(height: 16),
          _UpcomingCard(next: plan.upcoming.first, lead: 'Then'),
        ],
        const SizedBox(height: 24),
      ];

  // ── BEFORE: rest day ──────────────────────────────────────────────────────
  List<Widget> _restState(TrainScreenV2 plan) => [
        const _RestCard(),
        if (_note != null) ...[
          const SizedBox(height: 16),
          _MorningNoteCard(note: _note!),
        ],
        if (plan.upcoming.isNotEmpty) ...[
          const SizedBox(height: 16),
          _UpcomingCard(next: plan.upcoming.first, lead: 'Then'),
        ],
        if (_fuel != null) ...[
          const SizedBox(height: 16),
          _BodyFuelCard(fuel: _fuel!, onQuickAdd: _logProtein),
        ],
        const SizedBox(height: 24),
      ];

  // ── AFTER: session complete ───────────────────────────────────────────────
  List<Widget> _afterState(TrainScreenV2 plan, SessionSummaryV2 s) => [
        _HeroSummary(summary: s),
        const SizedBox(height: 16),
        _WorkBreakdown(summary: s),
        if (s.muscles.isNotEmpty) ...[
          const SizedBox(height: 16),
          _MuscleChips(muscles: s.muscles),
        ],
        if (s.trend.length >= 2) ...[
          const SizedBox(height: 16),
          _TrendCard(summary: s),
        ],
        for (final pb in s.pbs) ...[
          const SizedBox(height: 16),
          _PbCard(pb: pb),
        ],
        if (_progressions.any((p) => p.reason != 'no_history')) ...[
          const SizedBox(height: 16),
          _ProgressionCard(
              rows: _progressions.where((p) => p.reason != 'no_history').toList()),
        ],
        if (_fuel != null) ...[
          const SizedBox(height: 16),
          _BodyFuelCard(fuel: _fuel!, onQuickAdd: _logProtein),
        ],
        const SizedBox(height: 16),
        _WhatYouDid(summary: s),
        if (plan.upcoming.isNotEmpty) ...[
          const SizedBox(height: 16),
          _UpcomingCard(next: plan.upcoming.first, lead: 'Tomorrow'),
        ],
        const SizedBox(height: 24),
      ];
}

// ════════════════════════════════════════════════════════════════════════
// Shared header + streak strip
// ════════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final TrainScreenV2 plan;
  final SessionSummaryV2? summary;
  const _Header({required this.plan, required this.summary});

  @override
  Widget build(BuildContext context) {
    final title = summary?.label ?? (plan.isRest ? 'Rest day' : (plan.label ?? 'Train'));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(_fmtDate(plan.today),
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
        ),
      ],
    );
  }
}

/// Week calendar: each day shows date, split tag, and one of five states —
/// done (trained), missed (planned, past, not trained), today-pending
/// (planned today, not yet trained), upcoming (planned, dashed), rest (flat).
class _WeekCalendar extends StatelessWidget {
  final List<WeekDayV2> week;
  const _WeekCalendar({required this.week});

  static bool _isPast(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(d.year, d.month, d.day).isBefore(today);
  }

  static String _tag(String? label) {
    if (label == null || label.isEmpty) return '';
    final s = label.toLowerCase();
    if (s.startsWith('push')) return 'PUSH';
    if (s.startsWith('pull')) return 'PULL';
    if (s.startsWith('leg')) return 'LEGS';
    if (s.startsWith('upper')) return 'UP';
    if (s.startsWith('lower')) return 'LOW';
    if (s.startsWith('full body a')) return 'FB A';
    if (s.startsWith('full body b')) return 'FB B';
    return label.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final planned = week.where((d) => d.planned).toList();
    final done = planned.where((d) => d.trained).length;
    final missed = planned.where((d) => !d.trained && !d.isToday && _isPast(d.date)).length;
    // Trained on a day that wasn't actually scheduled — real effort, but it
    // can't count toward "X of Y" without breaking that math (Y is the plan).
    final extra = week.where((d) => d.trained && !d.planned).length;
    final tally = '$done of ${planned.length} done'
        '${extra > 0 ? ' · +$extra extra' : ''}'
        '${missed > 0 ? ' · $missed missed' : ''}';

    return V2Card(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('THIS WEEK',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 9.5,
                      letterSpacing: 0.7,
                      color: AppColors.textMuted)),
              const SizedBox(width: 8),
              const Expanded(child: Divider(color: AppColors.border, height: 1)),
              const SizedBox(width: 8),
              Text(tally,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 9.5,
                      color: AppColors.accent)),
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              for (final d in week) ...[
                Expanded(child: _DayCell(day: d, isPast: _isPast(d.date), tag: _tag(d.label))),
                if (d != week.last) const SizedBox(width: 4),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final WeekDayV2 day;
  final bool isPast;
  final String tag;
  const _DayCell({required this.day, required this.isPast, required this.tag});

  @override
  Widget build(BuildContext context) {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final letter = letters[(day.dow - 1).clamp(0, 6)];

    final missed = day.planned && !day.trained && !day.isToday && isPast;
    final todayPending = day.isToday && day.planned && !day.trained;
    final upcoming = day.planned && !day.trained && !day.isToday && !isPast;
    // Trained on a day that wasn't part of the plan — real effort, but it
    // can't wear the same "on-plan done" mark without misrepresenting it
    // (and it has no scheduled label to show, since none was ever set).
    final extraTrained = day.trained && !day.planned;

    final Color bg;
    final Color borderColor;
    final Color dateFg;
    final IconData? mark;
    final Color markFg;
    if (day.trained) {
      bg = AppColors.accent;
      borderColor = AppColors.accent;
      dateFg = AppColors.onAccent;
      mark = extraTrained ? Icons.add_rounded : Icons.check_rounded;
      markFg = AppColors.onAccent;
    } else if (missed) {
      bg = AppColors.warn.withValues(alpha: 0.1);
      borderColor = AppColors.warn;
      dateFg = AppColors.warn;
      mark = Icons.remove_rounded;
      markFg = AppColors.warn;
    } else if (todayPending) {
      bg = AppColors.accent.withValues(alpha: 0.12);
      borderColor = AppColors.accent;
      dateFg = AppColors.accent;
      mark = Icons.radio_button_unchecked_rounded;
      markFg = AppColors.accent;
    } else if (day.planned) {
      bg = AppColors.surface;
      borderColor = AppColors.borderStrong;
      dateFg = AppColors.textSecondary;
      mark = null;
      markFg = AppColors.accent;
    } else {
      bg = AppColors.surface;
      borderColor = AppColors.borderFaint;
      dateFg = AppColors.textDim;
      mark = null;
      markFg = AppColors.accent;
    }

    final tagFg = day.trained
        ? AppColors.accentDeep
        : missed
            ? AppColors.warn
            : todayPending
                ? AppColors.accent
                : day.planned
                    ? AppColors.textDim
                    : Colors.transparent;
    final tagText = extraTrained ? 'EXTRA' : tag;

    Widget cellBody = Container(
      height: 38,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(9),
        border: upcoming ? null : Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${day.date.day}',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  height: 1,
                  color: dateFg)),
          if (mark != null) ...[
            const SizedBox(height: 1),
            Icon(mark, size: 10, color: markFg),
          ],
        ],
      ),
    );
    if (upcoming) {
      cellBody = CustomPaint(
        painter: _DashedRRectPainter(color: borderColor, radius: 9),
        child: cellBody,
      );
    }

    return Column(
      children: [
        Text(letter,
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w500,
                fontSize: 9,
                color: day.isToday ? AppColors.accent : AppColors.textFaint)),
        const SizedBox(height: 5),
        cellBody,
        const SizedBox(height: 4),
        SizedBox(
          height: 9,
          child: Text(tagText,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 7.5,
                  letterSpacing: 0.3,
                  color: tagFg)),
        ),
      ],
    );
  }
}

/// A dashed rounded-rect border, for the "upcoming" week-cell and its legend
/// swatch — Flutter's Border has no dashed style built in.
class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  const _DashedRRectPainter({required this.color, required this.radius});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1), Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    const dash = 3.0, gap = 2.5;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) => old.color != color || old.radius != radius;
}

// ════════════════════════════════════════════════════════════════════════
// BEFORE-state widgets
// ════════════════════════════════════════════════════════════════════════

class _MorningNoteCard extends StatelessWidget {
  final MorningNoteV2 note;
  const _MorningNoteCard({required this.note});

  @override
  Widget build(BuildContext context) {
    return V2Card(
      color: AppColors.surfaceRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              const Text('From your trainer',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 0.3,
                      color: AppColors.textPrimary)),
              const Spacer(),
              Text(_fmtTime(note.createdAt),
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
              if (note.pinned) ...[
                const SizedBox(width: 6),
                const Icon(Icons.push_pin_rounded, size: 13, color: AppColors.textMuted),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(note.content,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 14,
                  height: 1.45,
                  color: AppColors.textSecondary)),
          if (note.receipts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in note.receipts)
                  StatusChip(icon: _iconFor(r.icon), label: r.label, color: AppColors.textMuted),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PlanList extends StatelessWidget {
  final TrainScreenV2 plan;
  const _PlanList({required this.plan});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${plan.exercises.length} exercises',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 0.3,
                color: AppColors.textMuted)),
        const SizedBox(height: 10),
        for (final e in plan.exercises) ...[
          _PlanRow(ex: e),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// Floats above the exercise list rather than sitting at its end — with a
/// long plan the button used to scroll out of reach.
class _StartSessionBar extends StatelessWidget {
  final bool resuming;
  final VoidCallback onTap;
  const _StartSessionBar({required this.resuming, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 17),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(26),
          boxShadow: const [
            BoxShadow(color: Color(0x80000000), blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        child: Text(resuming ? 'Continue session' : 'Start session',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: AppColors.onAccent)),
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  final PlanExerciseV2 ex;
  const _PlanRow({required this.ex});

  @override
  Widget build(BuildContext context) {
    final started = ex.doneSets > 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: started ? AppColors.accent.withValues(alpha: 0.35) : AppColors.border),
        ),
        child: Stack(
          children: [
            if (started)
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: ex.progress,
                  child: Container(color: AppColors.accent.withValues(alpha: 0.1)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(ex.name,
                                style: const TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 14,
                                    color: AppColors.textPrimary)),
                            if (started) ...[
                              const SizedBox(width: 7),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: ex.isDone
                                      ? AppColors.accent
                                      : AppColors.accent.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: ex.isDone
                                    ? const Icon(Icons.check, size: 11, color: AppColors.onAccent)
                                    : Text('${ex.doneSets}/${ex.setsTarget}',
                                        style: const TextStyle(
                                            fontFamily: AppTheme.fontFamily,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 9.5,
                                            color: AppColors.accent)),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text('${ex.prescription}  ·  ${(ex.restSeconds / 60).round()} min rest',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                  Text(ex.isBodyweight ? 'Bodyweight' : '${_n(ex.prefillKg)} kg',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.accent)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RestCard extends StatelessWidget {
  const _RestCard();
  @override
  Widget build(BuildContext context) {
    return V2Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(
            children: [
              Icon(Icons.bedtime_rounded, size: 18, color: AppColors.accent),
              SizedBox(width: 8),
              Text('Rest day',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: AppColors.textPrimary)),
            ],
          ),
          SizedBox(height: 10),
          Text(
              'Rest is where today lands. Walk, hit your protein, and sleep early — '
              'tired muscles make for a short next session.',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 13.5,
                  height: 1.45,
                  color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _UpcomingCard extends StatelessWidget {
  final UpcomingV2 next;
  final String lead;
  const _UpcomingCard({required this.next, required this.lead});

  /// A short, pattern-based prep note. Not coach-generated — a sensible
  /// client-side default keyed off the upcoming day's split label.
  static String _tipFor(String label) {
    final s = label.toLowerCase();
    if (s.contains('leg')) {
      return 'Give the hips five easy minutes before you load anything — your first squat set should feel like a warm-up, not a test.';
    }
    if (s.contains('push') || s.contains('upper')) {
      return 'Get the shoulders moving first — a couple of easy band pull-aparts or arm circles before the first pressing set.';
    }
    if (s.contains('pull') || s.contains('lower')) {
      return 'A light set of rows or a short deadhang wakes up the grip and back before you load the bar.';
    }
    return 'Loads below are provisional until you log set one — the plan adjusts to what actually happens.';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openTomorrowSheet(context),
      child: V2Card(
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(next.on.day.toString(),
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        height: 1,
                        color: AppColors.textPrimary)),
                Text(_weekdayShort(next.on).toUpperCase(),
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$lead · ${next.label}',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text('${next.liftCount} lifts · tap to see them',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.textFaint),
          ],
        ),
      ),
    );
  }

  void _openTomorrowSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TomorrowSheet(next: next, tip: _tipFor(next.label)),
    );
  }
}

class _TomorrowSheet extends StatelessWidget {
  final UpcomingV2 next;
  final String tip;
  const _TomorrowSheet({required this.next, required this.tip});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceRaised,
          border: Border(top: BorderSide(color: AppColors.border)),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: EdgeInsets.fromLTRB(20, 10, 20, 24 + MediaQuery.of(context).padding.bottom),
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
                    color: AppColors.borderStrong, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${_weekdayLabel(next.on)} · ${_shortDate(next.on)}',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 9.5,
                              letterSpacing: 0.7,
                              color: AppColors.accent)),
                      const SizedBox(height: 6),
                      Text(next.label,
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 21,
                              height: 1.15,
                              color: AppColors.textPrimary)),
                    ],
                  ),
                ),
                Text('${next.liftCount} lifts\nabout ${next.liftCount * 11} min',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 10.5,
                        height: 1.5,
                        color: AppColors.textMuted)),
              ],
            ),
            const SizedBox(height: 16),
            for (final e in next.exercises) ...[
              _TomorrowLiftRow(ex: e),
              const SizedBox(height: 7),
            ],
            if (next.exercises.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Lifts land here once the plan settles.',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
              ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(left: BorderSide(color: AppColors.accent, width: 2)),
                borderRadius: BorderRadius.only(
                    topRight: Radius.circular(14), bottomRight: Radius.circular(14)),
              ),
              child: Text(tip,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 11.5,
                      height: 1.55,
                      color: AppColors.textSecondary)),
            ),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppColors.accent, borderRadius: BorderRadius.circular(24)),
                child: const Text('Got it',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.onAccent)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _weekdayLabel(DateTime d) => const [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
      ][(d.weekday - 1).clamp(0, 6)];

  static String _shortDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${months[(d.month - 1).clamp(0, 11)]}';
  }
}

class _TomorrowLiftRow extends StatelessWidget {
  final UpcomingExerciseV2 ex;
  const _TomorrowLiftRow({required this.ex});
  @override
  Widget build(BuildContext context) {
    final range = ex.repLow == ex.repHigh ? '${ex.repLow}' : '${ex.repLow}–${ex.repHigh}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.surfaceSunken, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.fitness_center_rounded, size: 17, color: AppColors.inactiveFill),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ex.name,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 12.5,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text('${ex.setsTarget} sets · $range reps',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textMuted)),
              ],
            ),
          ),
          Text(
              ex.isBodyweight
                  ? 'Bodyweight'
                  : '${_n(ex.targetWeightKg ?? 0)} kg',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  color: AppColors.accent)),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// AFTER-state widgets
// ════════════════════════════════════════════════════════════════════════

class _HeroSummary extends StatelessWidget {
  final SessionSummaryV2 summary;
  const _HeroSummary({required this.summary});

  @override
  Widget build(BuildContext context) {
    final delta = summary.vsLastDelta;
    final where = summary.durationMin != null ? '${summary.durationMin} min in the gym' : null;
    return V2Card(
      color: AppColors.accent,
      borderColor: AppColors.accent,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(where == null ? summary.label : '${summary.label}  ·  $where',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.onAccent)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_grouped(summary.volumeKg),
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 40,
                      height: 1,
                      color: AppColors.onAccent)),
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 5),
                child: Text('kg moved',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: AppColors.onAccent)),
              ),
              const Spacer(),
              if (delta != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${delta >= 0 ? '+' : '−'}${_grouped(delta.abs())}',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                              height: 1,
                              color: AppColors.onAccent)),
                      Text('vs last ${summary.label.split(' ').first.toLowerCase()}',
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 10,
                              color: AppColors.onAccent.withValues(alpha: 0.7))),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _HeroStat(value: '${summary.setCount}', label: 'sets'),
              _HeroStat(value: '${summary.exerciseCount}', label: 'lifts'),
              if (summary.durationMin != null)
                _HeroStat(value: '${summary.durationMin}', label: 'min'),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  final String value;
  final String label;
  const _HeroStat({required this.value, required this.label});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  height: 1,
                  color: AppColors.onAccent)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 10,
                  color: AppColors.onAccent.withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}

class _WorkBreakdown extends StatelessWidget {
  final SessionSummaryV2 summary;
  const _WorkBreakdown({required this.summary});

  @override
  Widget build(BuildContext context) {
    final maxVol = summary.exercises.fold<double>(
        1, (m, e) => e.volumeKg > m ? e.volumeKg : m);
    return V2Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Where the work went',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 14),
          for (var i = 0; i < summary.exercises.length; i++) ...[
            _WorkBar(
                ex: summary.exercises[i],
                fraction: summary.exercises[i].volumeKg / maxVol,
                rank: i),
            if (i < summary.exercises.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _WorkBar extends StatelessWidget {
  final SummaryExerciseV2 ex;
  final double fraction;
  final int rank;
  const _WorkBar({required this.ex, required this.fraction, required this.rank});

  @override
  Widget build(BuildContext context) {
    const ranked = [AppColors.accent, AppColors.accentMid, AppColors.accentDeep];
    final color = rank < ranked.length ? ranked[rank] : AppColors.inactiveFill;
    final value = ex.isBodyweight ? '${ex.totalReps} reps' : _grouped(ex.volumeKg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(ex.name,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 13, color: AppColors.textSecondary)),
            ),
            Text(value,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.textPrimary)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ex.isBodyweight ? 0.25 : fraction.clamp(0.04, 1),
            minHeight: 7,
            backgroundColor: AppColors.surfaceSunken,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

class _MuscleChips extends StatelessWidget {
  final List<MuscleChipV2> muscles;
  const _MuscleChips({required this.muscles});
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final m in muscles)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text('${m.group} · ${m.sets}',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                    color: AppColors.textSecondary)),
          ),
      ],
    );
  }
}

class _TrendCard extends StatelessWidget {
  final SessionSummaryV2 summary;
  const _TrendCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final pts = summary.trend;
    final maxVol = pts.fold<double>(1, (m, p) => p.volumeKg > m ? p.volumeKg : m);
    final first = pts.first.volumeKg;
    final last = pts.last.volumeKg;
    final pct = first > 0 ? ((last - first) / first * 100).round() : 0;
    return V2Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${summary.label}, last ${pts.length}',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.textPrimary)),
              const Spacer(),
              Text('${pct >= 0 ? '+' : ''}$pct%',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: AppColors.accent)),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 84,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < pts.length; i++) ...[
                  Expanded(
                    child: Container(
                      height: (pts[i].volumeKg / maxVol * 84).clamp(6, 84),
                      decoration: BoxDecoration(
                        color: i == pts.length - 1 ? AppColors.accent : AppColors.accentDeep,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  if (i < pts.length - 1) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(_fmtDayMonth(pts.first.on),
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
              const Spacer(),
              Text('today · ${_grouped(last)} kg',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _PbCard extends StatelessWidget {
  final PbV2 pb;
  const _PbCard({required this.pb});
  @override
  Widget build(BuildContext context) {
    final set = pb.kg == null ? '${pb.reps} reps' : '${_n(pb.kg!)} kg × ${pb.reps}';
    return V2Card(
      borderColor: AppColors.accent,
      child: Row(
        children: [
          const Icon(Icons.emoji_events_rounded, size: 22, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Best ${pb.name.toLowerCase()} set yet — $set',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: AppColors.textPrimary)),
                if (pb.prevReps != null) ...[
                  const SizedBox(height: 3),
                  Text('${pb.reps - pb.prevReps!} more than the same weight before.',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 11.5,
                          color: AppColors.textMuted)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressionCard extends StatelessWidget {
  final List<ProgressionV2> rows;
  const _ProgressionCard({required this.rows});
  @override
  Widget build(BuildContext context) {
    return V2Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Next time these go up',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          for (var i = 0; i < rows.length; i++) ...[
            _ProgressionRow(row: rows[i]),
            if (i < rows.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: AppColors.borderFaint),
              ),
          ],
        ],
      ),
    );
  }
}

class _ProgressionRow extends StatelessWidget {
  final ProgressionV2 row;
  const _ProgressionRow({required this.row});
  @override
  Widget build(BuildContext context) {
    final up = row.goesUp;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.name,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 13.5,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 2),
              Text(row.reasonLabel,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
            ],
          ),
        ),
        if (up && row.suggestedKg != null) ...[
          Text('${_n(row.suggestedKg!)} kg',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: AppColors.accent)),
          const SizedBox(width: 6),
          Text('+${_n(row.deltaKg)}',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  color: AppColors.accent)),
        ] else
          Text(row.currentKg == null ? '—' : '${_n(row.currentKg!)} kg',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                  color: AppColors.textMuted)),
      ],
    );
  }
}

class _BodyFuelCard extends StatefulWidget {
  final BodyFuelV2 fuel;
  final Future<void> Function(int grams) onQuickAdd;
  const _BodyFuelCard({required this.fuel, required this.onQuickAdd});

  @override
  State<_BodyFuelCard> createState() => _BodyFuelCardState();
}

class _BodyFuelCardState extends State<_BodyFuelCard> {
  bool _busy = false;

  Future<void> _add(int grams) async {
    if (_busy || grams <= 0) return;
    setState(() => _busy = true);
    try {
      await widget.onQuickAdd(grams);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logMeal() async {
    final ctrl = TextEditingController();
    final grams = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('Log a meal',
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(fontFamily: AppTheme.fontFamily, color: AppColors.textPrimary),
          decoration: const InputDecoration(
              hintText: 'Protein, in grams',
              hintStyle: TextStyle(fontFamily: AppTheme.fontFamily, color: AppColors.textDim)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(fontFamily: AppTheme.fontFamily, color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(int.tryParse(ctrl.text.trim())),
            child: const Text('Add',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (grams != null && grams > 0) await _add(grams);
  }

  @override
  Widget build(BuildContext context) {
    final fuel = widget.fuel;
    final target = fuel.proteinTargetG;
    final shortfall = fuel.proteinShortfall;
    final ratio = target == null || target <= 0 ? 0.0 : (fuel.proteinG / target).clamp(0.0, 1.0);
    return V2Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Body & fuel today',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _FuelStat(
                  value: fuel.weightKg == null ? '—' : '${_n(fuel.weightKg!)} kg',
                  label: 'logged',
                ),
              ),
              _FuelStat(
                value: target == null ? '${_n(fuel.proteinG)} g' : '${_n(fuel.proteinG)} / $target g',
                label: shortfall != null && shortfall > 0 ? '$shortfall g short' : 'protein',
                warn: shortfall != null && shortfall > 0,
                alignRight: true,
              ),
            ],
          ),
          if (target != null) ...[
            const SizedBox(height: 13),
            _ProteinSegments(ratio: ratio),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _FuelChip(label: '+ 20 g', onTap: _busy ? null : () => _add(20)),
              const SizedBox(width: 7),
              _FuelChip(label: '+ 30 g', onTap: _busy ? null : () => _add(30)),
              const SizedBox(width: 7),
              _FuelChip(label: 'Log meal', onTap: _busy ? null : _logMeal),
            ],
          ),
        ],
      ),
    );
  }
}

/// Today's protein as a row of filling "portions" rather than a plain bar —
/// reads more like a meal tracker (roughly one segment per serving) than a
/// generic loading indicator.
class _ProteinSegments extends StatelessWidget {
  final double ratio; // 0..1
  static const _segments = 6;
  const _ProteinSegments({required this.ratio});

  @override
  Widget build(BuildContext context) {
    final filled = ratio * _segments;
    return Row(
      children: [
        for (var i = 0; i < _segments; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: (filled - i).clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 500),
              curve: const Cubic(0.22, 1, 0.36, 1),
              builder: (context, fill, _) => Stack(
                children: [
                  Container(
                    height: 16,
                    decoration: BoxDecoration(
                        color: AppColors.surfaceSunken, borderRadius: BorderRadius.circular(5)),
                  ),
                  FractionallySizedBox(
                    widthFactor: fill,
                    child: Container(
                      height: 16,
                      decoration: BoxDecoration(
                          color: AppColors.accent, borderRadius: BorderRadius.circular(5)),
                    ),
                  ),
                  if (fill >= 0.999)
                    const Positioned.fill(
                      child: Icon(Icons.restaurant, size: 10, color: AppColors.onAccent),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _FuelChip extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _FuelChip({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AppColors.surfaceSunken,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(16)),
          child: Text(label,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  fontSize: 11,
                  color: AppColors.accent)),
        ),
      ),
    );
  }
}

class _FuelStat extends StatelessWidget {
  final String value;
  final String label;
  final bool warn;
  final bool alignRight;
  const _FuelStat({
    required this.value,
    required this.label,
    this.warn = false,
    this.alignRight = false,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(value,
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: AppColors.textPrimary)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 11,
                color: warn ? AppColors.warn : AppColors.textMuted)),
      ],
    );
  }
}

class _WhatYouDid extends StatelessWidget {
  final SessionSummaryV2 summary;
  const _WhatYouDid({required this.summary});
  @override
  Widget build(BuildContext context) {
    final totalSets = summary.exercises.fold<int>(0, (s, e) => s + e.setCount);
    return V2Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.checklist_rounded, size: 16, color: AppColors.textMuted),
              const SizedBox(width: 8),
              const Text('What you did',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: AppColors.textPrimary)),
              const Spacer(),
              Text('${summary.exerciseCount} exercises · $totalSets sets',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
            ],
          ),
          const SizedBox(height: 12),
          for (final e in summary.exercises) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(e.name,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 13,
                            color: AppColors.textSecondary)),
                  ),
                  Text(_recap(e),
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 12,
                          color: AppColors.textMuted)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _recap(SummaryExerciseV2 e) {
    if (e.isBodyweight) return '${e.setCount} × ${e.totalReps ~/ (e.setCount == 0 ? 1 : e.setCount)}';
    return '${e.setCount} × ${_n(e.topKg ?? 0)} kg';
  }
}

// ════════════════════════════════════════════════════════════════════════
// Misc
// ════════════════════════════════════════════════════════════════════════

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load Train',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ── formatting + icon mapping ─────────────────────────────────────────────

String _n(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String _grouped(double v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _weekdayShort(DateTime d) => _weekdays[(d.weekday - 1).clamp(0, 6)];
String _fmtDate(DateTime d) => '${_weekdayShort(d)} ${d.day} ${_months[d.month - 1]}';
String _fmtDayMonth(DateTime d) => '${d.day} ${_months[d.month - 1]}';

String _fmtTime(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m ${local.hour < 12 ? 'am' : 'pm'}';
}

/// Maps the Material icon names the coach stores as strings to Flutter glyphs.
IconData _iconFor(String name) => switch (name) {
      'history' => Icons.history_rounded,
      'healing' => Icons.healing_rounded,
      'local_fire_department' => Icons.local_fire_department_rounded,
      'fitness_center' => Icons.fitness_center_rounded,
      'calendar_month' => Icons.calendar_month_rounded,
      'trending_flat' => Icons.trending_flat_rounded,
      'bolt' => Icons.bolt_rounded,
      'check' => Icons.check_rounded,
      'straighten' => Icons.straighten_rounded,
      _ => Icons.check_rounded,
    };
