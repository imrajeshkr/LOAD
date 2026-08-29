import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../services/session_controller.dart';
import '../../services/haptics.dart';
import '../../theme/app_colors.dart';
import '../../widgets/pressable.dart';
import '../../theme/app_theme.dart';
import '../../widgets/v2_widgets.dart';
import 'session_flow_screen.dart';
import 'swap_sheet.dart';
import 'add_exercise_sheet.dart';

/// The calendar day the user last left the Train tab on. The post-session
/// "next time these go up" card shows right after finishing and stays until
/// the user navigates away from Train once, then hides for the rest of the day
/// (set by [NavShell] on tab-away). Resets on app restart — acceptable, the
/// card just reappears once more that day.
DateTime? trainProgressionDismissedOn;

bool _sameDay(DateTime? a, DateTime b) =>
    a != null && a.year == b.year && a.month == b.month && a.day == b.day;

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

  /// Which future day's plan is being previewed in place; null = today's view.
  /// A date, not an index, so it survives a swap and a background reconcile.
  DateTime? _previewDate;

  @override
  void initState() {
    super.initState();
    // Sequential on purpose: a rollover rewrites the plan, so the fetch has to
    // come after it or the tab shows the block that just ended.
    _checkRollover().then((_) => _load());
  }

  /// Block rollovers and layoff returns are checked here rather than on the
  /// server alone: coming back after weeks away produces no session finish to
  /// hang a trigger on. Runs before the fetch so the reload sees the new plan.
  Future<void> _checkRollover() async {
    final rolled = await SupabaseService.instance.rollBlockIfDue();
    if (rolled != null && mounted) {
      _snack(rolled == 'block_end'
          ? 'New block ready — check the trainer tab.'
          : 'Welcome back — your plan is ready.');
    }
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
      // Keep the calendar rolling ~5 weeks ahead. Fire-and-forget: today and
      // the near term already exist, so this load never waits on it.
      svc.ensureSchedule();
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

  // ── day preview (#4) ──────────────────────────────────────────────────────

  /// The week day being previewed, re-derived from the current plan so it
  /// follows a swap or a background reconcile rather than going stale.
  WeekDayV2? get _previewDay {
    final d = _previewDate;
    final plan = _plan;
    if (d == null || plan == null) return null;
    for (final w in plan.week) {
      if (_sameDate(w.date, d)) return w;
    }
    return null;
  }

  /// Tapping a chip: a future day opens its preview, today clears it, the past
  /// does nothing.
  void _onTapDay(WeekDayV2 d) {
    final plan = _plan;
    if (plan == null) return;
    if (d.isToday) {
      _clearPreview();
      return;
    }
    final today = DateTime(plan.today.year, plan.today.month, plan.today.day);
    final dd = DateTime(d.date.year, d.date.month, d.date.day);
    if (dd.isAfter(today)) {
      Haptics.selection();
      setState(() => _previewDate = d.date);
    }
  }

  void _clearPreview() {
    if (_previewDate == null) return;
    Haptics.selection();
    setState(() => _previewDate = null);
  }

  // ── calendar day swap / move (#4) ─────────────────────────────────────────

  /// A day dropped onto another (drag or picker). Confirm the scope, then apply
  /// optimistically with a toast + Undo.
  Future<void> _onDaySwap(WeekDayV2 from, WeekDayV2 to) async {
    if (from.date == to.date) return;
    Haptics.selection();
    final scope = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _MoveSheet(from: from, to: to),
    );
    if (scope == null || !mounted) return; // "Leave it where it was"
    await _applySwap(from.date, to.date, scope, announce: true);
  }

  /// The non-gestural route: pick a target day from a list, then confirm scope.
  Future<void> _openPicker(WeekDayV2 source) async {
    final plan = _plan;
    if (plan == null) return;
    final target = await showModalBottomSheet<WeekDayV2>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _PickerSheet(week: plan.week, source: source, today: plan.today),
    );
    if (target == null || !mounted) return;
    await _onDaySwap(source, target);
  }

  Future<void> _applySwap(DateTime a, DateTime b, String scope,
      {required bool announce}) async {
    final moved = _swapSessionsLocally(a, b);
    try {
      await SupabaseService.instance.swapScheduledDays(a, b, scope);
      Haptics.success();
      if (announce && moved != null) {
        _showSwapToast(moved.$1, moved.$2, scope, undo: () => _applySwap(b, a, scope, announce: false));
      }
      // Reconcile quietly so today re-derives and an every-week ripple shows,
      // without flashing the whole tab back to a spinner.
      await _reloadQuietly();
    } catch (e) {
      Haptics.error();
      _snack("Couldn't move that — putting it back.");
      _load(); // reconcile against the server
    }
  }

  /// Swap the two days' sessions optimistically (lifts travel with the day).
  /// A move onto a rest day leaves the origin a rest day. Returns the two
  /// resulting labels for toast copy (session name, moved-to day), or null.
  (String, String)? _swapSessionsLocally(DateTime a, DateTime b) {
    final plan = _plan;
    if (plan == null) return null;
    WeekDayV2? da, db;
    for (final d in plan.week) {
      if (_sameDate(d.date, a)) da = d;
      if (_sameDate(d.date, b)) db = d;
    }
    if (da == null || db == null) return null;
    final week = [
      for (final d in plan.week)
        _sameDate(d.date, a)
            ? _withSession(d, db)
            : _sameDate(d.date, b)
                ? _withSession(d, da)
                : d,
    ];
    setState(() => _plan = plan.copyWith(week: week));
    // For the toast: name the session and where it landed.
    final session = da.isRest ? db.label : da.label;
    final landedOn = da.isRest ? a : b;
    return (session ?? 'Session', _dayLabel(landedOn));
  }

  /// A copy of [target] carrying [src]'s session (label, program day, lifts).
  /// Built by hand rather than copyWith so a rest source can clear the target.
  static WeekDayV2 _withSession(WeekDayV2 target, WeekDayV2 src) => WeekDayV2(
        date: target.date,
        dow: target.dow,
        planned: !src.isRest,
        trained: target.trained,
        isToday: target.isToday,
        label: src.label,
        programDayId: src.programDayId,
        exercises: src.exercises,
      );

  Future<void> _reloadQuietly() async {
    try {
      final plan = await SupabaseService.instance.fetchTrainScreen();
      if (mounted && plan != null) setState(() => _plan = plan);
    } catch (_) {
      // The optimistic state stands; a manual refresh will reconcile.
    }
  }

  static String _dayLabel(DateTime d) => '${_weekdayShort(d)} ${d.day}';

  static bool _sameDate(DateTime x, DateTime y) =>
      x.year == y.year && x.month == y.month && x.day == y.day;

  void _showSwapToast(String session, String landedOn, String scope,
      {required VoidCallback undo}) {
    if (!mounted) return;
    final scopeLabel = scope == 'forever' ? 'every week from now' : 'this week';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$session → $landedOn · $scopeLabel.'),
        action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              Haptics.selection();
              undo();
            }),
      ));
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
    final preview = _previewDay;
    final inPreview = preview != null;
    // Start/Continue floats above the list rather than living at the bottom
    // of the exercise cards — with a long plan it was scrolling out of reach.
    // In a preview the (disabled) start button sits inline instead.
    final showStartBar = !inPreview && _summary == null && !plan.isRest;
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
                _Header(
                  plan: plan,
                  summary: _summary,
                  preview: preview,
                  onToday: _clearPreview,
                ),
                const SizedBox(height: 16),
                _WeekCalendar(
                  week: plan.week,
                  today: plan.today,
                  selected: _previewDate,
                  onSwap: _onDaySwap,
                  onTapDay: _onTapDay,
                ),
                const SizedBox(height: 16),
                if (inPreview)
                  ..._previewState(preview)
                else if (_summary != null)
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

  // ── PREVIEW: a future day, in place ───────────────────────────────────────
  List<Widget> _previewState(WeekDayV2 day) {
    if (day.isRest) {
      return [
        const _RestCard(),
        const SizedBox(height: 16),
        _PreviewSwapAction(
          label: 'Move a session here',
          onTap: () => _openPicker(day),
        ),
        const SizedBox(height: 24),
      ];
    }
    return [
      Text('${day.exercises.length} exercises',
          style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.3,
              color: AppColors.textMuted)),
      const SizedBox(height: 10),
      for (final e in day.exercises) ...[
        _TomorrowLiftRow(ex: e),
        const SizedBox(height: 7),
      ],
      if (day.exercises.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Lifts land here once the plan settles.',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
        ),
      const SizedBox(height: 8),
      _DisabledStartButton(day: day.date),
      const SizedBox(height: 12),
      _CoachLine(text: _coachTipFor(day.label ?? '')),
      const SizedBox(height: 12),
      _PreviewSwapAction(
        label: 'Swap with another day',
        onTap: () => _openPicker(day),
      ),
      const SizedBox(height: 24),
    ];
  }

  /// Swap a lift for another that trains the same muscle. Only offered before
  /// the session starts — `_beforeState` is the only caller that passes this.
  Future<void> _openSwap(PlanExerciseV2 ex) async {
    final swapped = await showSwapSheet(context, ex);
    if (swapped && mounted) {
      _snack('Swapped ${ex.name}.');
      _load();
    }
  }

  /// "+ Add exercise" at the end of the day's lift list — beyond what the
  /// generator prescribed. Needs today's program day, which only the week
  /// row carries; a rest day (no row) never shows this entry point.
  Future<void> _openAddExercise() async {
    final dayId = _plan?.todayProgramDayId;
    if (dayId == null) return;
    final added = await showAddExerciseSheet(context, dayId);
    if (added && mounted) _load();
  }

  // ── BEFORE: training day ──────────────────────────────────────────────────
  List<Widget> _beforeState(TrainScreenV2 plan) => [
        if (_note != null) ...[
          _MorningNoteCard(note: _note!),
          const SizedBox(height: 16),
        ],
        _PlanList(
          plan: plan,
          onSwap: _openSwap,
          onAdd: plan.todayProgramDayId == null ? null : _openAddExercise,
        ),
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
        if (!_sameDay(trainProgressionDismissedOn, plan.today) &&
            _progressions.any((p) => p.reason != 'no_history')) ...[
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
  /// The day being previewed, if any — retitles the header and shows the
  /// "Today" pill without navigating away.
  final WeekDayV2? preview;
  final VoidCallback onToday;
  const _Header({
    required this.plan,
    required this.summary,
    required this.preview,
    required this.onToday,
  });

  @override
  Widget build(BuildContext context) {
    final p = preview;
    if (p != null) {
      final title = p.isRest ? 'Rest day' : (p.label ?? 'Session');
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${_relativeLabel(p.date, plan.today)} · ${_fmtDate(p.date)}'.toUpperCase(),
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 10.5,
                        letterSpacing: 0.7,
                        fontWeight: FontWeight.w500,
                        color: AppColors.accent)),
                const SizedBox(height: 5),
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _TodayPill(onTap: onToday),
        ],
      );
    }
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

/// Header pill during a preview — clears it and returns to today's view.
class _TodayPill extends StatelessWidget {
  final VoidCallback onTap;
  const _TodayPill({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(17),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.today_rounded, size: 14, color: AppColors.accent),
            SizedBox(width: 5),
            Text('Today',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 10.5,
                    color: AppColors.accent)),
          ],
        ),
      ),
    );
  }
}

/// "Today" / "Tomorrow" / "In N days" for a future date vs today.
String _relativeLabel(DateTime d, DateTime today) {
  final t = DateTime(today.year, today.month, today.day);
  final dd = DateTime(d.year, d.month, d.day);
  final days = dd.difference(t).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days == -1) return 'Yesterday';
  if (days < 0) return '${-days} days ago';
  return 'In $days days';
}

/// One coaching line per split type, for a future day's preview.
String _coachTipFor(String label) {
  final s = label.toLowerCase();
  if (s.contains('leg') || s.contains('lower')) {
    return 'Give the hips five easy minutes before you load anything — your first squat set should feel like a warm-up, not a test.';
  }
  if (s.contains('push') || s.contains('upper')) {
    return 'Get the shoulders moving first — a couple of easy band pull-aparts or arm circles before the first pressing set.';
  }
  if (s.contains('pull')) {
    return 'A light set of rows or a short deadhang wakes up the grip and back before you load the bar.';
  }
  return 'Loads below are provisional until you log set one — the plan adjusts to what actually happens.';
}

/// Week calendar: each day shows date, split tag, and one of six states —
/// done (trained), missed (planned, past, not trained), today-pending, today-
/// rest (today, no session), upcoming (dashed), rest. Tap a future day to
/// preview it; hold a training day and drop it on another to swap or move.
class _WeekCalendar extends StatefulWidget {
  final List<WeekDayV2> week;
  final DateTime today;
  final DateTime? selected;
  final Future<void> Function(WeekDayV2 from, WeekDayV2 to) onSwap;
  final void Function(WeekDayV2 day) onTapDay;
  const _WeekCalendar({
    required this.week,
    required this.today,
    required this.selected,
    required this.onSwap,
    required this.onTapDay,
  });

  static String _tag(String? label) {
    if (label == null || label.isEmpty) return 'REST';
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
  State<_WeekCalendar> createState() => _WeekCalendarState();
}

class _WeekCalendarState extends State<_WeekCalendar> {
  DateTime? _dragFrom;

  DateTime get _today =>
      DateTime(widget.today.year, widget.today.month, widget.today.day);

  bool _isPast(DateTime d) =>
      DateTime(d.year, d.month, d.day).isBefore(_today);

  /// Today or later, and — for today — not already trained (a logged day is
  /// settled). Governs both drag and drop eligibility.
  bool _movable(WeekDayV2 d) {
    if (_isPast(d.date)) return false;
    if (d.isToday && d.trained) return false;
    return true;
  }

  bool _canPickUp(WeekDayV2 d) => _movable(d) && !d.isRest; // nothing to lift on a rest day
  bool _canDropOn(WeekDayV2 d) => _movable(d); // rest days accept a move

  static bool _same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final week = widget.week;
    final planned = week.where((d) => d.planned).toList();
    final done = planned.where((d) => d.trained).length;
    final missed =
        planned.where((d) => !d.trained && !d.isToday && _isPast(d.date)).length;
    final extra = week.where((d) => d.trained && !d.planned).length;
    final tally = '$done of ${planned.length} done'
        '${extra > 0 ? ' · +$extra extra' : ''}'
        '${missed > 0 ? ' · $missed missed' : ''}';
    final dragging = _dragFrom != null;

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
                Expanded(
                  child: _CalendarDay(
                    day: d,
                    tag: _WeekCalendar._tag(d.label),
                    isPast: _isPast(d.date),
                    selected: widget.selected != null && _same(d.date, widget.selected!),
                    canPickUp: _canPickUp(d),
                    canDropOn: _canDropOn(d),
                    dragging: dragging,
                    isOrigin: _dragFrom != null && _same(d.date, _dragFrom!),
                    onTap: () => widget.onTapDay(d),
                    onDragStarted: () => setState(() => _dragFrom = d.date),
                    onDragEnd: () => setState(() => _dragFrom = null),
                    onAccept: (from) => widget.onSwap(from, d),
                  ),
                ),
                if (d != week.last) const SizedBox(width: 4),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(dragging ? Icons.swap_horiz_rounded : Icons.drag_indicator_rounded,
                  size: 11, color: dragging ? AppColors.accent : AppColors.textFaint),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                    dragging
                        ? 'Drop on any day from today on — a training day swaps, a rest day moves.'
                        : 'Hold a day to rearrange your split · tap a day ahead to see it',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 9.5,
                        color: dragging ? AppColors.accent : AppColors.textFaint)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One chip: base state + tap-to-preview + (for movable days) drag source and
/// drop target + selection ring. Locked days fade during a drag.
class _CalendarDay extends StatelessWidget {
  final WeekDayV2 day;
  final String tag;
  final bool isPast;
  final bool selected;
  final bool canPickUp;
  final bool canDropOn;
  final bool dragging;
  final bool isOrigin;
  final VoidCallback onTap;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnd;
  final void Function(WeekDayV2 from) onAccept;
  const _CalendarDay({
    required this.day,
    required this.tag,
    required this.isPast,
    required this.selected,
    required this.canPickUp,
    required this.canDropOn,
    required this.dragging,
    required this.isOrigin,
    required this.onTap,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.onAccept,
  });

  static bool _same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    Widget content = Pressable(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: _DayCell(day: day, isPast: isPast, tag: tag, selected: selected),
    );

    if (canDropOn) {
      content = DragTarget<WeekDayV2>(
        onWillAcceptWithDetails: (d) => !_same(d.data.date, day.date),
        onAcceptWithDetails: (d) => onAccept(d.data),
        builder: (context, candidate, rejected) {
          final hovering = candidate.isNotEmpty;
          return AnimatedScale(
            scale: hovering ? 1.06 : 1,
            duration: const Duration(milliseconds: 120),
            child: Pressable(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: _DayCell(
                  day: day, isPast: isPast, tag: tag, selected: selected, hovering: hovering),
            ),
          );
        },
      );
    }

    if (canPickUp) {
      content = LongPressDraggable<WeekDayV2>(
        data: day,
        onDragStarted: () {
          Haptics.selection();
          onDragStarted();
        },
        onDragEnd: (_) => onDragEnd(),
        onDraggableCanceled: (_, _) => onDragEnd(),
        onDragCompleted: onDragEnd,
        feedback: _DragChip(day: day, tag: tag),
        childWhenDragging: const _EmptySlot(),
        child: content,
      );
    }

    // Locked days recede so the legal drop zone reads as one shape.
    if (dragging && !isOrigin && !canDropOn) {
      content = Opacity(opacity: 0.35, child: content);
    }
    return content;
  }
}

class _DayCell extends StatelessWidget {
  final WeekDayV2 day;
  final bool isPast;
  final String tag;
  final bool selected;
  final bool hovering;
  const _DayCell({
    required this.day,
    required this.isPast,
    required this.tag,
    this.selected = false,
    this.hovering = false,
  });

  @override
  Widget build(BuildContext context) {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final letter = letters[(day.dow - 1).clamp(0, 6)];

    // Resolution order — today first, so a session-less today keeps its anchor.
    final trained = day.trained;
    final extra = trained && !day.planned;
    final todayPending = day.isToday && !day.isRest && !trained;
    final todayRest = day.isToday && day.isRest && !trained;
    final missed = !day.isToday && !trained && !day.isRest && isPast;
    final upcoming = !day.isToday && !trained && !day.isRest && !isPast;

    Color bg, border, dateFg, letterFg, glyphFg, pillFg, pillBg;
    IconData glyph;
    if (trained) {
      bg = AppColors.accent;
      border = AppColors.accent;
      dateFg = AppColors.onAccent;
      letterFg = AppColors.onAccent.withValues(alpha: 0.6);
      glyph = extra ? Icons.add_rounded : Icons.check_rounded;
      glyphFg = AppColors.onAccent;
      pillFg = AppColors.onAccent;
      pillBg = AppColors.onAccent.withValues(alpha: 0.16);
    } else if (todayPending) {
      bg = AppColors.accent.withValues(alpha: 0.10);
      border = AppColors.accent;
      dateFg = AppColors.accent;
      letterFg = AppColors.textMuted;
      glyph = Icons.radio_button_unchecked_rounded;
      glyphFg = AppColors.accent;
      pillFg = AppColors.accent;
      pillBg = AppColors.accent.withValues(alpha: 0.16);
    } else if (todayRest) {
      bg = AppColors.accent.withValues(alpha: 0.06);
      border = AppColors.accent;
      dateFg = AppColors.accent;
      letterFg = AppColors.textMuted;
      glyph = Icons.remove_rounded;
      glyphFg = AppColors.accent;
      pillFg = AppColors.textFaint;
      pillBg = Colors.transparent;
    } else if (missed) {
      bg = AppColors.warn.withValues(alpha: 0.10);
      border = AppColors.warn;
      dateFg = AppColors.warn;
      letterFg = AppColors.textFaint;
      glyph = Icons.remove_rounded;
      glyphFg = AppColors.warn;
      pillFg = AppColors.warn;
      pillBg = AppColors.warn.withValues(alpha: 0.12);
    } else if (upcoming) {
      bg = AppColors.surface;
      border = AppColors.border;
      dateFg = AppColors.textPrimary;
      letterFg = AppColors.textFaint;
      glyph = Icons.radio_button_unchecked_rounded;
      glyphFg = AppColors.textFaint;
      pillFg = AppColors.textMuted;
      pillBg = AppColors.surfaceSunken;
    } else {
      // rest (past or future)
      bg = AppColors.surface;
      border = AppColors.borderFaint;
      dateFg = AppColors.textDim;
      letterFg = AppColors.textFaint;
      glyph = Icons.remove_rounded;
      glyphFg = AppColors.textDim;
      pillFg = AppColors.textDim;
      pillBg = Colors.transparent;
    }

    // Overlays: hover (drop target) wins, then selection ring.
    if (hovering) {
      bg = AppColors.accent.withValues(alpha: 0.14);
      border = AppColors.accent;
    } else if (selected) {
      // A softer ring than the drop-target/today lime, so a previewed day reads
      // as "looking at" rather than "active".
      border = AppColors.accent.withValues(alpha: 0.5);
    }

    final pillText = extra ? 'EXTRA' : (day.isRest ? 'REST' : tag);
    final showPill = pillText.isNotEmpty;

    Widget chip = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: upcoming && !hovering && !selected
            ? null
            : Border.all(color: border, width: hovering || selected ? 1.5 : 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(letter,
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 8.5,
                      height: 1,
                      color: letterFg)),
              const SizedBox(width: 3),
              Icon(glyph, size: 9, color: glyphFg),
            ],
          ),
          const SizedBox(height: 3),
          Text('${day.date.day}',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  height: 1,
                  color: dateFg)),
          const SizedBox(height: 4),
          SizedBox(
            height: 12,
            child: showPill
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                        color: pillBg, borderRadius: BorderRadius.circular(5)),
                    child: Text(pillText,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 7,
                            letterSpacing: 0.3,
                            color: pillFg)),
                  )
                : null,
          ),
        ],
      ),
    );

    if (upcoming && !hovering && !selected) {
      chip = CustomPaint(
        painter: _DashedRRectPainter(color: AppColors.border, radius: 12),
        child: chip,
      );
    }

    return Semantics(
      button: true,
      label: _a11yLabel(),
      child: chip,
    );
  }

  String _a11yLabel() {
    const names = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
    ];
    final wd = names[(day.dow - 1).clamp(0, 6)];
    final plan = day.isRest ? 'rest day' : (day.label ?? 'training day');
    final rel = day.isToday ? 'today' : (isPast ? 'past' : 'upcoming');
    final status = day.trained
        ? 'logged'
        : (day.isToday || !isPast || day.isRest ? 'not logged' : 'missed');
    return '$wd ${day.date.day}, $plan, $rel, $status';
  }
}

/// The dashed hole a dragged chip leaves behind at its origin.
class _EmptySlot extends StatelessWidget {
  const _EmptySlot();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(color: AppColors.borderStrong, radius: 12),
      child: Container(
        width: double.infinity,
        height: 51,
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

/// The floating chip that follows the pointer during a drag, with a lime badge
/// naming the session so the gesture reads clearly.
class _DragChip extends StatelessWidget {
  final WeekDayV2 day;
  final String tag;
  const _DragChip({required this.day, required this.tag});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: AppColors.accent, width: 1.5),
              boxShadow: const [
                BoxShadow(color: Color(0xA60A0908), blurRadius: 30, offset: Offset(0, 14)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${day.date.day}',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 1,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(5)),
                  child: Text(tag,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 7,
                          letterSpacing: 0.3,
                          color: AppColors.accent)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: AppColors.accent, borderRadius: BorderRadius.circular(9)),
            child: Text(day.label ?? 'Session',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 9,
                    color: AppColors.onAccent)),
          ),
        ],
      ),
    );
  }
}

/// Confirmation for a day swap: the before → after, then the scope. Pops
/// 'week' / 'forever', or null for "leave it".
class _MoveSheet extends StatelessWidget {
  final WeekDayV2 from;
  final WeekDayV2 to;
  const _MoveSheet({required this.from, required this.to});

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String _dayName(WeekDayV2 d) => '${_wd[(d.dow - 1).clamp(0, 6)]} ${d.date.day}';

  @override
  Widget build(BuildContext context) {
    final fromTag = _WeekCalendar._tag(from.label);
    final toTag = _WeekCalendar._tag(to.label);
    // A move: one side is a rest day. Derive the title from the session side —
    // never the drag origin, or a rest origin reads "REST moves to …".
    final isMove = from.isRest || to.isRest;
    final sessionTag = from.isRest ? toTag : fromTag;
    final destDay = from.isRest ? from : to;
    final title =
        isMove ? '$sessionTag moves to ${_dayName(destDay)}' : 'Swap $fromTag and $toTag';
    final kicker = isMove ? 'MOVE A SESSION' : 'SWAP DAYS';
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(top: BorderSide(color: AppColors.border)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + MediaQuery.of(context).padding.bottom),
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
          Text(kicker,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 9.5,
                  letterSpacing: 0.7,
                  color: AppColors.accent)),
          const SizedBox(height: 6),
          Text(title,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 14),
          _row('Now', _dayName(from), fromTag, _dayName(to), toTag),
          const SizedBox(height: 6),
          const Center(
              child: Icon(Icons.south_rounded, size: 16, color: AppColors.textMuted)),
          const SizedBox(height: 6),
          _row('After', _dayName(from), toTag, _dayName(to), fromTag, accent: true),
          const SizedBox(height: 18),
          _primary(context, 'Just this week', 'week'),
          const SizedBox(height: 10),
          _primary(context, 'Every week from now', 'forever', outline: true),
          const SizedBox(height: 12),
          Center(
            child: Pressable(
              onTap: () => Navigator.of(context).pop(),
              child: const Text('Leave it where it was',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 11.5,
                      color: AppColors.textMuted)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String lead, String d1, String t1, String d2, String t2,
      {bool accent = false}) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(lead,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textMuted)),
        ),
        Expanded(child: _chip(d1, t1, accent)),
        const SizedBox(width: 8),
        Expanded(child: _chip(d2, t2, accent)),
      ],
    );
  }

  Widget _chip(String day, String tag, bool accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: accent ? AppColors.accent.withValues(alpha: 0.1) : AppColors.surface,
        border: Border.all(color: accent ? AppColors.accent : AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(day,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
          Text(tag,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  color: accent ? AppColors.accent : AppColors.textPrimary)),
        ],
      ),
    );
  }

  Widget _primary(BuildContext context, String label, String scope,
      {bool outline = false}) {
    return SizedBox(
      width: double.infinity,
      child: Pressable(
        onTap: () => Navigator.of(context).pop(scope),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 15),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: outline ? Colors.transparent : AppColors.accent,
            border: outline ? Border.all(color: AppColors.border) : null,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(label,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: outline ? AppColors.textPrimary : AppColors.onAccent)),
        ),
      ),
    );
  }
}

/// The preview's start button — same slot as the live one, but inert, so the
/// layout doesn't jump between today and a future day.
class _DisabledStartButton extends StatelessWidget {
  final DateTime day;
  const _DisabledStartButton({required this.day});
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(color: AppColors.border, radius: 26),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 17),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Text('Starts ${_weekdayLong(day)}',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
                color: AppColors.textDim)),
      ),
    );
  }
}

/// The one-line coach note on a preview — a plan, not a briefing.
class _CoachLine extends StatelessWidget {
  final String text;
  const _CoachLine({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.accent, width: 2)),
        borderRadius: BorderRadius.only(
            topRight: Radius.circular(14), bottomRight: Radius.circular(14)),
      ),
      child: Text(text,
          style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontSize: 11.5,
              height: 1.55,
              color: AppColors.textSecondary)),
    );
  }
}

/// The preview's rescheduling action — opens the day picker.
class _PreviewSwapAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PreviewSwapAction({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.borderStrong),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.swap_horiz_rounded, size: 17, color: AppColors.accent),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: AppColors.accent)),
          ],
        ),
      ),
    );
  }
}

/// The non-gestural swap path: pick a day to trade with. Pops the chosen
/// [WeekDayV2], or null on dismiss.
class _PickerSheet extends StatelessWidget {
  final List<WeekDayV2> week;
  final WeekDayV2 source;
  final DateTime today;
  const _PickerSheet({required this.week, required this.source, required this.today});

  bool _movable(WeekDayV2 d) {
    final t = DateTime(today.year, today.month, today.day);
    final dd = DateTime(d.date.year, d.date.month, d.date.day);
    if (dd.isBefore(t)) return false;
    if (d.isToday && d.trained) return false;
    return true;
  }

  static bool _same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    // A rest source has no session to place, so it can only pull one from a
    // day that holds one; a session source can trade with any movable day.
    final rows = [
      for (final d in week)
        if (!_same(d.date, source.date) && _movable(d) && (!source.isRest || !d.isRest)) d
    ];
    final title = source.isRest
        ? 'Which session moves to ${_weekdayShort(source.date)} ${source.date.day}?'
        : '${_WeekCalendar._tag(source.label)} trades places with…';
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(top: BorderSide(color: AppColors.border)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.72),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + MediaQuery.of(context).padding.bottom),
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
          Text(source.isRest ? 'MOVE A SESSION' : 'SWAP DAYS',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 9.5,
                  letterSpacing: 0.7,
                  color: AppColors.accent)),
          const SizedBox(height: 6),
          Text(title,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 14),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No other day is free to move right now.',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 7),
                itemBuilder: (_, i) => _pickerRow(context, rows[i]),
              ),
            ),
          const SizedBox(height: 12),
          Center(
            child: Pressable(
              onTap: () => Navigator.of(context).pop(),
              child: const Text('Never mind',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 11.5,
                      color: AppColors.textMuted)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickerRow(BuildContext context, WeekDayV2 d) {
    final rest = d.isRest;
    final rel = _relativeLabel(d.date, today);
    return Pressable(
      onTap: () => Navigator.of(context).pop(d),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.surfaceSunken, borderRadius: BorderRadius.circular(12)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${d.date.day}',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          height: 1,
                          color: rest ? AppColors.textFaint : AppColors.accent)),
                  Text(_weekdayShort(d.date).toUpperCase(),
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 7.5, color: AppColors.textFaint)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rest ? 'Rest day' : (d.label ?? 'Session'),
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 12.5,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 1),
                  Text('$rel${rest ? ' · free' : ''}',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textFaint)),
                ],
              ),
            ),
            const Icon(Icons.swap_horiz_rounded, size: 18, color: AppColors.inactiveFill),
          ],
        ),
      ),
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
  final void Function(PlanExerciseV2 ex)? onSwap;
  /// Null once there is no program day to append to (a rest day never shows
  /// this list) or while the session is already under way.
  final VoidCallback? onAdd;
  const _PlanList({required this.plan, this.onSwap, this.onAdd});

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
          _PlanRow(ex: e, onSwap: onSwap == null ? null : () => onSwap!(e)),
          const SizedBox(height: 8),
        ],
        if (onAdd != null) _AddExerciseRow(onTap: onAdd!),
      ],
    );
  }
}

/// The entry point for Task 5: appending a lift beyond what the generator
/// prescribed. The generator's 4-6 lift cap is a rule about what we
/// prescribe, not a limit on what a lifter may do.
class _AddExerciseRow extends StatelessWidget {
  final VoidCallback onTap;
  const _AddExerciseRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      haptic: PressFx.light,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, size: 16, color: AppColors.accent),
            SizedBox(width: 6),
            Text('Add exercise',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: AppColors.accent)),
          ],
        ),
      ),
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
    return Pressable(
      haptic: PressFx.medium,
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
  /// Null once the session is under way — swapping a lift mid-session would
  /// orphan the sets already logged against it.
  final VoidCallback? onSwap;
  const _PlanRow({required this.ex, this.onSwap});

  @override
  Widget build(BuildContext context) {
    final started = ex.doneSets > 0;
    final row = ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: started ? AppColors.accent.withValues(alpha: 0.35) : AppColors.border),
          // Match the clip so the border follows the rounded corners instead of
          // being shaved off at them.
          borderRadius: BorderRadius.circular(18),
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
                  // Marks the row as replaceable, not merely tappable — a
                  // gesture nobody finds is not a feature.
                  if (onSwap != null) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.swap_horiz_rounded,
                        size: 16, color: AppColors.textFaint),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Not tappable during a live session: swapping a lift you have already
    // logged sets against would orphan them.
    if (onSwap == null) return row;
    return Pressable(haptic: PressFx.light, onTap: onSwap, child: row);
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
    return Pressable(
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
            Pressable(
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
            onPressed: () {
              Haptics.selection();
              Navigator.of(ctx).pop();
            },
            child: const Text('Cancel',
                style: TextStyle(fontFamily: AppTheme.fontFamily, color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () {
              Haptics.tap();
              Navigator.of(ctx).pop(int.tryParse(ctrl.text.trim()));
            },
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
      child: Pressable(
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
            OutlinedButton(onPressed: () { Haptics.tap(); onRetry(); }, child: const Text('Retry')),
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

const _weekdaysLong = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];
String _weekdayShort(DateTime d) => _weekdays[(d.weekday - 1).clamp(0, 6)];
String _weekdayLong(DateTime d) => _weekdaysLong[(d.weekday - 1).clamp(0, 6)];
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
