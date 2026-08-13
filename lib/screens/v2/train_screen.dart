import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../services/session_controller.dart';
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

  Future<void> _start() async {
    final plan = _plan;
    if (plan == null || plan.exercises.isEmpty) return;
    final svc = SupabaseService.instance;
    String? sessionId;
    try {
      sessionId = await svc.openSession(title: plan.label);
    } catch (_) {
      return;
    }
    if (sessionId == null || !mounted) return;
    final controller = SessionController(
      sessionId: sessionId,
      label: plan.label ?? 'Session',
      exercises: plan.exercises,
      startedAt: plan.startedAt,
    );
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: controller,
        child: const SessionFlowScreen(),
      ),
    ));
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
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: AppColors.accent,
        backgroundColor: AppColors.surface,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          children: [
            _Header(plan: plan, summary: _summary),
            const SizedBox(height: 16),
            _StreakStrip(week: plan.week),
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
    );
  }

  // ── BEFORE: training day ──────────────────────────────────────────────────
  List<Widget> _beforeState(TrainScreenV2 plan) => [
        if (_note != null) ...[
          _MorningNoteCard(note: _note!),
          const SizedBox(height: 16),
        ],
        _PlanList(plan: plan, onStart: _start),
        if (_fuel != null) ...[
          const SizedBox(height: 16),
          _BodyFuelCard(fuel: _fuel!),
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
          _BodyFuelCard(fuel: _fuel!),
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
          _BodyFuelCard(fuel: _fuel!),
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

class _StreakStrip extends StatelessWidget {
  final List<WeekDayV2> week;
  const _StreakStrip({required this.week});

  @override
  Widget build(BuildContext context) {
    final trained = week.where((d) => d.trained).length;
    return V2Card(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          for (final d in week) Expanded(child: _DayDot(day: d)),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$trained',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                      height: 1,
                      color: AppColors.accent)),
              const Text('week',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayDot extends StatelessWidget {
  final WeekDayV2 day;
  const _DayDot({required this.day});

  @override
  Widget build(BuildContext context) {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final letter = letters[(day.dow - 1).clamp(0, 6)];
    final Color fill;
    final Widget glyph;
    if (day.trained) {
      fill = AppColors.accent;
      glyph = const Icon(Icons.check_rounded, size: 15, color: AppColors.onAccent);
    } else if (day.planned) {
      fill = Colors.transparent;
      glyph = Text(letter,
          style: TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: day.isToday ? AppColors.accent : AppColors.textMuted));
    } else {
      fill = Colors.transparent;
      glyph = Text(letter,
          style: const TextStyle(
              fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textFaint));
    }
    return Column(
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: day.trained
                ? null
                : Border.all(
                    color: day.isToday ? AppColors.accent : AppColors.border,
                    width: day.isToday ? 1.5 : 1),
          ),
          child: glyph,
        ),
      ],
    );
  }
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
  final VoidCallback onStart;
  const _PlanList({required this.plan, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final resuming = plan.sessionStatus == 'in_progress';
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
        const SizedBox(height: 4),
        GestureDetector(
          onTap: onStart,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 17),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.accent, borderRadius: BorderRadius.circular(26)),
            child: Text(resuming ? 'Continue session' : 'Start session',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppColors.onAccent)),
          ),
        ),
      ],
    );
  }
}

class _PlanRow extends StatelessWidget {
  final PlanExerciseV2 ex;
  const _PlanRow({required this.ex});

  @override
  Widget build(BuildContext context) {
    return V2Card(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ex.name,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        color: AppColors.textPrimary)),
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

  @override
  Widget build(BuildContext context) {
    return V2Card(
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
                Text('${next.liftCount} lifts',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.textFaint),
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

class _BodyFuelCard extends StatelessWidget {
  final BodyFuelV2 fuel;
  const _BodyFuelCard({required this.fuel});
  @override
  Widget build(BuildContext context) {
    final shortfall = fuel.proteinShortfall;
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
            children: [
              Expanded(
                child: _FuelStat(
                  value: fuel.weightKg == null ? '—' : '${_n(fuel.weightKg!)} kg',
                  label: 'logged',
                ),
              ),
              Expanded(
                child: _FuelStat(
                  value: fuel.proteinTargetG == null
                      ? '${_n(fuel.proteinG)} g'
                      : '${_n(fuel.proteinG)} / ${fuel.proteinTargetG} g',
                  label: shortfall != null && shortfall > 0 ? '$shortfall g short' : 'protein',
                  warn: shortfall != null && shortfall > 0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FuelStat extends StatelessWidget {
  final String value;
  final String label;
  final bool warn;
  const _FuelStat({required this.value, required this.label, this.warn = false});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
