import 'package:flutter/material.dart';
import '../../models/v2_models.dart';
import '../../services/haptics.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/v2_widgets.dart';

/// The Profile tab. Two kinds of control, kept apart on purpose (the design's
/// thesis): **preferences** in "In the gym" / "From your trainer" apply the
/// instant they're tapped; **plan inputs** (goal, days, target) are staged in a
/// client-side buffer and only committed when you Review → "Rewrite my week".
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  ProfileDataV2? _data;
  bool _loading = true;
  String? _error;

  // Instant state (mirrors the DB, written through on change).
  late PreferencesV2 _prefs;
  late List<double> _plates;
  late bool _paused;

  // Staged plan edits (D3: client-side only, discarded on discard).
  late List<GoalV2> _goals;
  late List<int> _weekdays; // ISO 1..7
  double? _target;
  late List<_WorkingFlag> _flags;
  String _painNote = '';
  double? _barKg;
  // Saved snapshot to diff against.
  late List<GoalV2> _savedGoals;
  late List<int> _savedWeekdays;
  double? _savedTarget;
  late List<_WorkingFlag> _savedFlags;
  double? _savedBarKg;

  List<JointV2> _joints = const [];

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
      final results = await Future.wait([svc.fetchProfileScreen(), svc.fetchJoints()]);
      final data = results[0] as ProfileDataV2?;
      if (!mounted) return;
      if (data == null) {
        setState(() {
          _error = 'Not signed in.';
          _loading = false;
        });
        return;
      }
      final flags = data.constraints.map(_WorkingFlag.fromConstraint).toList();
      setState(() {
        _data = data;
        _prefs = data.prefs;
        _plates = [...data.plateSizes];
        _paused = data.paused;
        _goals = [...data.goals];
        _weekdays = [...data.trainingWeekdays];
        _target = data.targetWeightKg;
        _flags = [...flags];
        _painNote = '';
        _barKg = data.barWeightKg;
        _savedGoals = [...data.goals];
        _savedWeekdays = [...data.trainingWeekdays];
        _savedTarget = data.targetWeightKg;
        _savedFlags = [...flags];
        _savedBarKg = data.barWeightKg;
        _joints = results[1] as List<JointV2>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ── dirty tracking ──────────────────────────────────────────────────────
  bool get _goalsDirty => !_sameGoals(_goals, _savedGoals);
  bool get _daysDirty => !_sameInts(_weekdays, _savedWeekdays);
  bool get _targetDirty => _target != _savedTarget;
  bool get _flagsDirty => !_sameFlags(_flags, _savedFlags) || _painNote.trim().isNotEmpty;
  bool get _barDirty => _barKg != _savedBarKg;
  bool get _dirty =>
      _goalsDirty || _daysDirty || _targetDirty || _flagsDirty || _barDirty;
  int get _changeCount =>
      (_goalsDirty ? 1 : 0) +
      (_daysDirty ? 1 : 0) +
      (_targetDirty ? 1 : 0) +
      (_flagsDirty ? 1 : 0) +
      (_barDirty ? 1 : 0);

  static bool _sameFlags(List<_WorkingFlag> a, List<_WorkingFlag> b) {
    final ka = a.map((f) => f.key).toSet();
    final kb = b.map((f) => f.key).toSet();
    return ka.length == kb.length && ka.containsAll(kb);
  }

  static bool _sameGoals(List<GoalV2> a, List<GoalV2> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);
  static bool _sameInts(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    final x = [...a]..sort(), y = [...b]..sort();
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  // ── instant preference write-through, with revert on failure ────────────
  Future<void> _applyPrefs(PreferencesV2 next, Map<String, dynamic> patch) async {
    Haptics.tap();
    final prev = _prefs;
    setState(() => _prefs = next);
    try {
      await SupabaseService.instance.updatePreferences(patch);
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _prefs = prev);
      _toast("Couldn't save that — try again.");
    }
  }

  Future<void> _togglePlate(double kg) async {
    Haptics.tap();
    final prev = [..._plates];
    setState(() {
      _plates.contains(kg) ? _plates.remove(kg) : _plates.add(kg);
    });
    try {
      await SupabaseService.instance.updatePlateSizes(_plates);
    } catch (_) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _plates = prev);
      _toast("Couldn't save that — try again.");
    }
  }

  Future<void> _togglePause() async {
    Haptics.tap();
    final want = !_paused;
    setState(() => _paused = want);
    try {
      final svc = SupabaseService.instance;
      want ? await svc.pauseTraining() : await svc.resumeTraining();
    } catch (_) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _paused = !want);
      _toast("Couldn't update pause — try again.");
    }
  }

  Future<void> _rewriteWeek() async {
    Navigator.of(context).pop(); // close review sheet
    setState(() => _loading = true);
    try {
      final svc = SupabaseService.instance;
      // Constraints first: the new plan generation reads them to exclude
      // (or re-admit) exercises, so this must land before generateProgram().
      if (_flagsDirty) {
        final removed = _savedFlags
            .where((sf) => sf.id != null && !_flags.any((f) => f.id == sf.id))
            .toList();
        final added = _flags.where((f) => f.id == null).toList();
        for (final r in removed) {
          await svc.removeConstraint(r.id!);
        }
        for (final a in added) {
          await svc.addConstraint(jointId: a.jointId, side: a.side, label: a.display);
        }
        final note = _painNote.trim();
        if (note.isNotEmpty) {
          await svc.addConstraint(label: note);
        }
      }
      final patch = <String, dynamic>{};
      if (_goalsDirty) {
        patch['goals'] = _goals.map((g) => g.db).toList();
        patch['goal_is_coach_choice'] = _goals.isEmpty;
      }
      if (_daysDirty) patch['training_weekdays'] = _weekdays;
      if (_targetDirty) patch['target_weight_kg'] = _target;
      if (_barDirty) patch['bar_weight_kg'] = _barKg;
      await svc.updatePlanProfile(patch);
      await svc.generateProgram();
      await _load();
      Haptics.success();
      if (mounted) _toast('Your week has been rewritten.');
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _loading = false);
      _toast("Couldn't rewrite the week — try again.");
    }
  }

  void _discard() {
    setState(() {
      _goals = [..._savedGoals];
      _weekdays = [..._savedWeekdays];
      _target = _savedTarget;
      _flags = [..._savedFlags];
      _painNote = '';
      _barKg = _savedBarKg;
    });
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_error != null || _data == null) {
      return _ErrorState(message: _error ?? 'Not signed in.', onRetry: _load);
    }
    final d = _data!;
    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          RefreshIndicator(
            color: AppColors.accent,
            backgroundColor: AppColors.surface,
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              children: [
                _header(d),
                const SizedBox(height: 12),
                _stats(d),
                if (_paused) ...[
                  const SizedBox(height: 12),
                  _pausedBanner(),
                ],
                const SizedBox(height: 12),
                _planCard(d),
                const SizedBox(height: 12),
                _gymCard(),
                const SizedBox(height: 12),
                _trainerCard(),
                const SizedBox(height: 12),
                _accountCard(d),
                if (!_paused) ...[
                  const SizedBox(height: 12),
                  _pauseRow(),
                ],
                const SizedBox(height: 16),
                const Center(
                  child: Text('LOAD 2.4.1 · every set you have logged stays yours',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 10,
                          height: 1.6,
                          color: AppColors.textMuted)),
                ),
              ],
            ),
          ),
          if (_dirty)
            Positioned(left: 14, right: 14, bottom: 8, child: _dirtyBar()),
        ],
      ),
    );
  }

  // ── header ──────────────────────────────────────────────────────────────
  Widget _header(ProfileDataV2 d) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 2),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(19),
            ),
            alignment: Alignment.center,
            child: Text(d.initials,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 21,
                    color: AppColors.onAccent)),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.displayName ?? 'Add your name',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                        height: 1.15,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 4),
                Text(d.email ?? '—',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 11.5,
                        color: AppColors.textMuted)),
              ],
            ),
          ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border),
            ),
            child: const Icon(Icons.edit_outlined, size: 16, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  // ── stats strip ─────────────────────────────────────────────────────────
  Widget _stats(ProfileDataV2 d) {
    Widget cell(String value, String label) => Expanded(
          child: Container(
            color: AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: AppColors.accent)),
                const SizedBox(height: 5),
                Text(label,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 9.5,
                        height: 1.3,
                        color: AppColors.textMuted)),
              ],
            ),
          ),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: AppColors.border,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              cell('${d.sessionsTotal}', 'sessions logged'),
              const SizedBox(width: 1),
              cell('${d.weeksTraining}', 'weeks training'),
              const SizedBox(width: 1),
              cell(d.sessionsPerWeek.toStringAsFixed(1), 'sessions a week'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pausedBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.warn.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.warn.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          const Icon(Icons.pause_circle_outline, size: 19, color: AppColors.warn),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Training paused',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 12.5,
                        color: AppColors.textPrimary)),
                SizedBox(height: 3),
                Text(
                    'No nudges, and these weeks will not count against your consistency. Your loads are held where they are.',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 10.5,
                        height: 1.45,
                        color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _togglePause,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.page,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text('Resume',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 10.5,
                      color: AppColors.warn)),
            ),
          ),
        ],
      ),
    );
  }

  // ── your plan ───────────────────────────────────────────────────────────
  Widget _planCard(ProfileDataV2 d) {
    final w = _weekdays.length;
    final rows = <Widget>[
      _PlanRow(
        icon: Icons.flag_outlined,
        label: 'Goal',
        value: _goals.isEmpty
            ? "Coach's call"
            : _goals.map((g) => g.label).join(' · '),
        dirty: _goalsDirty,
        onTap: _openGoalSheet,
      ),
      _PlanRow(
        icon: Icons.calendar_month_outlined,
        label: 'Training days',
        value: '$w a week · ${_weekdayNames(_weekdays)}',
        dirty: _daysDirty,
        onTap: _openDaysSheet,
      ),
      _PlanRow(
        icon: Icons.view_week_outlined,
        label: 'Split',
        value: _splitLabel(w),
        dirty: false,
        onTap: _openDaysSheet,
      ),
      _PlanRow(
        icon: Icons.monitor_weight_outlined,
        label: 'Bodyweight',
        value: _bodyweightValue(d),
        dirty: _targetDirty,
        onTap: _openTargetSheet,
      ),
      _PlanRow(
        icon: Icons.healing_outlined,
        label: 'Working around',
        value: _flags.isEmpty ? 'Nothing flagged' : _flags.map((f) => f.display).join(' · '),
        dirty: _flagsDirty,
        onTap: _openInjuriesSheet,
      ),
      _PlanRow(
        icon: Icons.fitness_center,
        label: 'Your bar',
        value: 'Full length · ${_n(_barKg ?? d.barWeightKg)} kg',
        dirty: _barDirty,
        last: true,
        onTap: _openBarSheet,
      ),
    ];
    return V2Card(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Your plan',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.textPrimary)),
              ),
              const Text('tap to change',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
            ],
          ),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  // ── in the gym (instant) ────────────────────────────────────────────────
  Widget _gymCard() {
    return V2Card(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('In the gym',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 14),
          _fieldLabel('Units'),
          _Segmented(
            options: const [('Kilograms', true), ('Pounds', false)],
            selectedValue: _prefs.metric,
            onSelect: (metric) => _applyPrefs(
                _prefs.copyWith(metric: metric), {'units': metric ? 'metric' : 'imperial'}),
          ),
          const SizedBox(height: 15),
          _fieldLabel('Default rest between sets'),
          _Segmented<int>(
            options: const [('60s', 60), ('90s', 90), ('2 min', 120), ('3 min', 180)],
            selectedValue: _prefs.defaultRestSeconds,
            onSelect: (v) => _applyPrefs(
                _prefs.copyWith(defaultRestSeconds: v), {'default_rest_seconds': v}),
          ),
          const SizedBox(height: 8),
          _note(_restNote(_prefs.defaultRestSeconds)),
          const SizedBox(height: 15),
          _fieldLabel('Ask how the set felt'),
          _Segmented<String>(
            options: const [
              ('First set', 'first_set'),
              ('Every set', 'every_set'),
              ('Never', 'never')
            ],
            selectedValue: _prefs.effortPrompt,
            onSelect: (v) => _applyPrefs(
                _prefs.copyWith(effortPrompt: v), {'effort_prompt': v}),
          ),
          const SizedBox(height: 8),
          _note(_effortNote(_prefs.effortPrompt)),
          const SizedBox(height: 6),
          _ToggleRow(
            label: 'Start rest automatically',
            sub: 'The timer begins the moment you log a set',
            value: _prefs.autoStartRest,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(autoStartRest: v), {'auto_start_rest': v}),
          ),
          _ToggleRow(
            label: 'Keep the screen awake',
            sub: 'No unlocking with chalk on your hands',
            value: _prefs.keepScreenAwake,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(keepScreenAwake: v), {'keep_screen_awake': v}),
          ),
          _ToggleRow(
            label: 'Sound when rest ends',
            sub: 'Off by default — most gyms are loud enough',
            value: _prefs.restEndSound,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(restEndSound: v), {'rest_end_sound': v}),
            last: true,
          ),
          const SizedBox(height: 12),
          _fieldLabel('Plates your gym has'),
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in _plateCatalog) _plateChip(p.$1, p.$2, p.$3),
            ],
          ),
        ],
      ),
    );
  }

  // Design's plate catalog: (kg, disc width, disc height).
  static const _plateCatalog = <(double, double, double)>[
    (20, 14, 30),
    (15, 13, 27),
    (10, 12, 24),
    (5, 10, 20),
    (2.5, 9, 16),
    (1.25, 8, 13),
  ];

  Widget _plateChip(double kg, double w, double h) {
    final on = _plates.contains(kg);
    return GestureDetector(
      onTap: () => _togglePlate(kg),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 8, 12, 8),
        decoration: BoxDecoration(
          color: on ? AppColors.accent.withValues(alpha: 0.09) : AppColors.page,
          border: Border.all(color: on ? AppColors.accent : AppColors.border),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: w,
              height: h,
              decoration: BoxDecoration(
                color: on ? AppColors.accent : AppColors.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 7),
            Text('${_plate(kg)} kg',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 11.5,
                    color: on ? AppColors.textPrimary : AppColors.textMuted)),
          ],
        ),
      ),
    );
  }

  // ── from your trainer (instant notifications) ───────────────────────────
  Widget _trainerCard() {
    return V2Card(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('From your trainer',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Nothing else pushes.',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 10.5,
                  height: 1.45,
                  color: AppColors.textMuted)),
          const SizedBox(height: 8),
          _ToggleRow(
            label: 'Morning note',
            sub: 'Before a training day, around 7 am',
            value: _prefs.notifyMorning,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(notifyMorning: v), {'notify_morning_note': v}),
          ),
          _ToggleRow(
            label: 'After a session',
            sub: 'What moved, and what changes next time',
            value: _prefs.notifyDebrief,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(notifyDebrief: v), {'notify_session_debrief': v}),
          ),
          _ToggleRow(
            label: 'When you go quiet',
            sub: 'One message after three days, never a guilt trip',
            value: _prefs.notifyMissed,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(notifyMissed: v), {'notify_missed_session': v}),
          ),
          _ToggleRow(
            label: 'Weekly review',
            sub: 'Sunday evening, the week in four lines',
            value: _prefs.notifyWeekly,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(notifyWeekly: v), {'notify_weekly_review': v}),
            last: true,
          ),
        ],
      ),
    );
  }

  // ── account ─────────────────────────────────────────────────────────────
  Widget _accountCard(ProfileDataV2 d) {
    final provider = SupabaseService.instance.currentUser?.appMetadata['provider'] as String?;
    final isGoogle = provider == 'google';
    return V2Card(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Account',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary)),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toast(isGoogle
                ? 'Managed by Google — nothing to change here.'
                : "Password changes aren't available yet."),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.border))),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, size: 17, color: AppColors.textMuted),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Password',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 12.5,
                            color: AppColors.textPrimary)),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < 8; i++)
                        Padding(
                          padding: const EdgeInsets.only(left: 3),
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: const BoxDecoration(
                                color: AppColors.textFaint, shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right, size: 16, color: AppColors.inactiveFill),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                Icon(isGoogle ? Icons.verified_user : Icons.mail_outline,
                    size: 17, color: AppColors.textMuted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(isGoogle ? 'Signed in with Google' : 'Signed in with email',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 12.5,
                          color: AppColors.textPrimary)),
                ),
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _AccountTile(
                icon: Icons.download_outlined,
                label: 'Export data',
                onTap: () => _toast('Export is coming in a later build.'),
              ),
              const SizedBox(width: 7),
              _AccountTile(icon: Icons.logout, label: 'Sign out', onTap: _confirmSignOut),
              const SizedBox(width: 7),
              _AccountTile(
                icon: Icons.delete_outline,
                label: 'Delete',
                warn: true,
                onTap: () => _confirmDeleteAccount(d),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pauseRow() {
    return GestureDetector(
      onTap: _togglePause,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            const Icon(Icons.pause_circle_outline, size: 18, color: AppColors.textMuted),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pause training',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 12.5,
                          color: AppColors.textSecondary)),
                  SizedBox(height: 3),
                  Text(
                      'Ill, travelling, or hurt. Nudges stop and the weeks off will not count against you.',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 10,
                          height: 1.45,
                          color: AppColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── dirty bar ───────────────────────────────────────────────────────────
  Widget _dirtyBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Color(0x80000000), blurRadius: 30, offset: Offset(0, 12)),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 19, color: AppColors.onAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    _changeCount == 1
                        ? '1 change to your plan'
                        : '$_changeCount changes to your plan',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: AppColors.onAccent)),
                const SizedBox(height: 2),
                Text('Nothing is saved until you look at it',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 10,
                        height: 1.4,
                        color: AppColors.onAccent.withValues(alpha: 0.7))),
              ],
            ),
          ),
          GestureDetector(
            onTap: _openReviewSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.page,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text('Review',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: AppColors.accent)),
            ),
          ),
        ],
      ),
    );
  }

  // ── sheets ──────────────────────────────────────────────────────────────
  Future<void> _sheet({required String title, required String sub, required Widget body}) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SheetShell(title: title, sub: sub, child: body),
    );
  }

  Future<void> _openGoalSheet() async {
    await _sheet(
      title: 'What are you chasing?',
      sub: 'Drives exercise choice and rep ranges. Pick as many as fit — the first one you tap leads.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          return Column(
            children: [
              for (final g in GoalV2.values)
                _selectRow(
                  label: g.label,
                  selected: _goals.contains(g),
                  leads: _goals.isNotEmpty && _goals.first == g,
                  onTap: () => setSheet(() => setState(() {
                        _goals.contains(g) ? _goals.remove(g) : _goals.add(g);
                      })),
                ),
              const SizedBox(height: 20),
              _sheetPrimary('Done', () => Navigator.of(ctx).pop()),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openDaysSheet() async {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    await _sheet(
      title: 'Which days are yours?',
      sub: 'Drives the split and how long each session runs. Tap the days you can actually show up.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          return Column(
            children: [
              Row(
                children: [
                  for (var i = 0; i < 7; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setSheet(() => setState(() {
                              final iso = i + 1;
                              _weekdays.contains(iso)
                                  ? _weekdays.remove(iso)
                                  : _weekdays.add(iso);
                              _weekdays.sort();
                            })),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _weekdays.contains(i + 1)
                                ? AppColors.accent
                                : AppColors.surface,
                            border: Border.all(
                                color: _weekdays.contains(i + 1)
                                    ? AppColors.accent
                                    : AppColors.border),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(letters[i],
                              style: TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: _weekdays.contains(i + 1)
                                      ? AppColors.onAccent
                                      : AppColors.textMuted)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              _verdictBox(_daysVerdict(_weekdays.length)),
              const SizedBox(height: 20),
              _sheetPrimary('Done', () => Navigator.of(ctx).pop()),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openTargetSheet() async {
    final bw = _data!.latestWeightKg ?? _target ?? 80;
    await _sheet(
      title: 'Target weight',
      sub: 'Moves the trend line on Progress. Nothing in your training depends on it.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          final t = (_target ?? bw).round();
          final delta = t - bw.round();
          return Column(
            children: [
              Row(
                children: [
                  _roundBtn(Icons.remove,
                      () => setSheet(() => setState(() => _target = (t - 1).toDouble()))),
                  Expanded(
                    child: Column(
                      children: [
                        Text('$t',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 42,
                                height: 1,
                                color: AppColors.accent)),
                        const SizedBox(height: 6),
                        Text(
                            delta == 0
                                ? 'where you are now'
                                : '${delta < 0 ? '−' : '+'}${delta.abs()} kg from today',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 11,
                                color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                  _roundBtn(Icons.add,
                      () => setSheet(() => setState(() => _target = (t + 1).toDouble()))),
                ],
              ),
              const SizedBox(height: 16),
              _verdictBox(
                  'Protein target moves with your weight, not this number. It stays at ${(bw * 1.8).round()} g a day.'),
              const SizedBox(height: 20),
              _sheetPrimary('Done', () => Navigator.of(ctx).pop()),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openReviewSheet() async {
    final changes = _buildChanges();
    await _sheet(
      title: 'Before I rewrite the week',
      sub: 'Here is exactly what moves.',
      body: Column(
        children: [
          for (final c in changes) ...[
            _changeCard(c),
            const SizedBox(height: 9),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.07),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.bolt, size: 16, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      'Your loads and history stay exactly where they are. Only the week ahead is rewritten, from tomorrow.',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 11.5,
                          height: 1.55,
                          color: AppColors.textSecondary)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sheetPrimary('Rewrite my week', _rewriteWeek),
          const SizedBox(height: 13),
          GestureDetector(
            onTap: () {
              Navigator.of(context).pop();
              _discard();
            },
            child: const Text('Discard these changes',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 11.5,
                    color: AppColors.textMuted)),
          ),
        ],
      ),
    );
  }

  /// One option per side of every joint — real schema data, not a hardcoded
  /// list, so it always matches whatever the body map itself can flag.
  List<_WorkingFlag> get _areaOptions {
    final out = <_WorkingFlag>[];
    for (final j in _joints) {
      if (j.isLateral) {
        out.add(_WorkingFlag(jointId: j.id, jointName: j.name, side: 'left', label: j.name));
        out.add(_WorkingFlag(jointId: j.id, jointName: j.name, side: 'right', label: j.name));
      } else {
        out.add(_WorkingFlag(jointId: j.id, jointName: j.name, side: 'bilateral', label: j.name));
      }
    }
    return out;
  }

  Future<void> _openInjuriesSheet() async {
    final painCtrl = TextEditingController(text: _painNote);
    await _sheet(
      title: 'Working around',
      sub: 'Lifts that come near a flagged area are capped, and the trainer warns you before them.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_flags.isEmpty)
                _verdictBox('Nothing flagged. Everything is on the table.')
              else
                for (final f in _flags)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.warn.withValues(alpha: 0.08),
                        border: Border.all(color: AppColors.warn.withValues(alpha: 0.4)),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.healing_outlined, size: 17, color: AppColors.warn),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(f.display,
                                    style: const TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontWeight: FontWeight.w500,
                                        fontSize: 12.5,
                                        color: AppColors.textPrimary)),
                                const SizedBox(height: 2),
                                Text(f.effect,
                                    style: const TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontSize: 10,
                                        height: 1.45,
                                        color: AppColors.textSecondary)),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setSheet(() => setState(() => _flags.removeWhere((x) => x.key == f.key))),
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: const BoxDecoration(color: AppColors.page, shape: BoxShape.circle),
                              child: const Icon(Icons.close, size: 16, color: AppColors.warn),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Text('ADD AN AREA',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 9.5,
                          letterSpacing: 0.7,
                          color: AppColors.textMuted)),
                  const SizedBox(width: 8),
                  const Expanded(child: Divider(color: AppColors.border, height: 1)),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final option in _areaOptions)
                    Builder(builder: (context) {
                      final on = _flags.any((f) => f.key == option.key);
                      return GestureDetector(
                        onTap: () => setSheet(() => setState(() {
                              on ? _flags.removeWhere((f) => f.key == option.key) : _flags.add(option);
                            })),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                          decoration: BoxDecoration(
                            color: on ? AppColors.warn.withValues(alpha: 0.12) : AppColors.surface,
                            border: Border.all(
                                color: on ? AppColors.warn.withValues(alpha: 0.45) : AppColors.border),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(option.display,
                              style: TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 11.5,
                                  color: on ? AppColors.warn : AppColors.textMuted)),
                        ),
                      );
                    }),
                ],
              ),
              const SizedBox(height: 16),
              const Text('IN YOUR OWN WORDS',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 9.5,
                      letterSpacing: 0.7,
                      color: AppColors.textMuted)),
              const SizedBox(height: 8),
              TextField(
                controller: painCtrl,
                maxLines: 2,
                onChanged: (v) => setSheet(() => setState(() => _painNote = v)),
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'Anything the list missed — an old surgery, a movement you avoid',
                  fillColor: AppColors.surface,
                ),
              ),
              const SizedBox(height: 20),
              _sheetPrimary('Done', () => Navigator.of(ctx).pop()),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openBarSheet() async {
    const bars = [
      ('full length', 20.0),
      ('short', 15.0),
      ('fixed', 10.0),
      ('training', 5.0),
    ];
    await _sheet(
      title: 'Your bar',
      sub: 'Every barbell load is built from this. Changing it recalculates all of them.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          return Column(
            children: [
              Row(
                children: [
                  for (final (sub, kg) in bars)
                    Expanded(
                      child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Builder(builder: (context) {
                        final sel = (_barKg ?? 20) == kg;
                        return GestureDetector(
                          onTap: () => setSheet(() => setState(() => _barKg = kg)),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            decoration: BoxDecoration(
                              color: sel ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
                              border: Border.all(color: sel ? AppColors.accent : AppColors.border),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                Text('${_n(kg)} kg',
                                    style: TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                        color: sel ? AppColors.accent : AppColors.textPrimary)),
                                const SizedBox(height: 3),
                                Text(sub,
                                    style: const TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontSize: 9.5,
                                        color: AppColors.textFaint)),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _verdictBox('Every barbell prescription is built up from this weight the next time your week is rewritten.'),
              const SizedBox(height: 20),
              _sheetPrimary('Done', () => Navigator.of(ctx).pop()),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    await _sheet(
      title: 'Sign out?',
      sub: 'Your data stays safe. You will need to sign in again.',
      body: Column(
        children: [
          _sheetPrimary('Sign out', () async {
            Navigator.of(context).pop();
            await SupabaseService.instance.signOut();
          }),
          const SizedBox(height: 13),
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: const Text('Stay signed in',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 11.5,
                    color: AppColors.textMuted)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteAccount(ProfileDataV2 d) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      isDismissible: true,
      builder: (_) => _SheetShell(
        title: 'Delete account?',
        sub: 'This cannot be undone. Everything below is removed immediately.',
        child: _DeleteAccountBody(d: d),
      ),
    );
  }

  // ── small sheet helpers ─────────────────────────────────────────────────
  Widget _selectRow({
    required String label,
    required bool selected,
    required bool leads,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
          border: Border.all(color: selected ? AppColors.accent : AppColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      color: AppColors.textPrimary)),
            ),
            if (selected)
              Icon(leads ? Icons.star : Icons.check_circle,
                  size: 18, color: AppColors.accent),
          ],
        ),
      ),
    );
  }

  Widget _verdictBox(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.accent, width: 2)),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(14),
          bottomRight: Radius.circular(14),
        ),
      ),
      child: Text(text,
          style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontSize: 11.5,
              height: 1.55,
              color: AppColors.textSecondary)),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border),
        ),
        child: Icon(icon, size: 20, color: AppColors.accent),
      ),
    );
  }

  Widget _sheetPrimary(String label, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.onAccent)),
        ),
      ),
    );
  }

  Widget _changeCard(_Change c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.label.toUpperCase(),
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 9.5,
                  letterSpacing: 0.7,
                  color: AppColors.textMuted)),
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: Text(c.from,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        decoration: TextDecoration.lineThrough,
                        color: AppColors.textMuted)),
              ),
              const SizedBox(width: 9),
              const Icon(Icons.arrow_forward, size: 15, color: AppColors.inactiveFill),
              const SizedBox(width: 9),
              Flexible(
                child: Text(c.to,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: AppColors.accent)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(c.effect,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 10.5,
                  height: 1.5,
                  color: AppColors.textMuted)),
        ],
      ),
    );
  }

  List<_Change> _buildChanges() {
    final out = <_Change>[];
    if (_goalsDirty) {
      final lead = _goals.isEmpty ? 'general strength' : _goals.first.label.toLowerCase();
      out.add(_Change(
        label: 'Goal',
        from: _savedGoals.isEmpty ? 'None' : _savedGoals.map((g) => g.label).join(' · '),
        to: _goals.isEmpty ? 'None' : _goals.map((g) => g.label).join(' · '),
        effect: 'Exercise selection and rep ranges shift toward $lead.',
      ));
    }
    if (_daysDirty) {
      final d0 = _savedWeekdays.length, d1 = _weekdays.length;
      out.add(_Change(
        label: 'Training days',
        from: '$d0 days · ${_weekdayNames(_savedWeekdays)}',
        to: '$d1 days · ${_weekdayNames(_weekdays)}',
        effect: d1 < d0
            ? 'Fewer days means fuller sessions. I will fold the dropped work into the days you kept.'
            : d1 > d0
                ? 'More room to split the week. Sessions get shorter, not harder.'
                : 'Same number of days, different ones. The split stays as it is.',
      ));
    }
    if (_targetDirty) {
      out.add(_Change(
        label: 'Target weight',
        from: _savedTarget == null ? 'Not set' : '${_n(_savedTarget!)} kg',
        to: _target == null ? 'Not set' : '${_n(_target!)} kg',
        effect: 'Only the trend line on Progress changes. Nothing in your training moves.',
      ));
    }
    if (_flagsDirty) {
      final f0 = _savedFlags.map((f) => f.display).join(', ');
      final f1 = _flags.map((f) => f.display).join(', ');
      out.add(_Change(
        label: 'Working around',
        from: f0.isEmpty ? 'Nothing flagged' : f0,
        to: f1.isEmpty ? 'Nothing flagged' : f1,
        effect: _flags.length > _savedFlags.length
            ? 'Lifts near the new area are capped, and you get a warning before each one.'
            : 'The lifts held back for that area go back to normal progression.',
      ));
    }
    if (_barDirty) {
      out.add(_Change(
        label: 'Your bar',
        from: '${_n(_savedBarKg ?? 20)} kg',
        to: '${_n(_barKg ?? 20)} kg',
        effect: 'Every barbell load in the new week is built up from this weight.',
      ));
    }
    return out;
  }

  // ── formatting helpers ──────────────────────────────────────────────────
  Widget _fieldLabel(String s) => Text(s.toUpperCase(),
      style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 9.5,
          letterSpacing: 0.7,
          color: AppColors.textMuted));

  Widget _note(String s) => Text(s,
      style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 10,
          height: 1.45,
          color: AppColors.textMuted));

  String _bodyweightValue(ProfileDataV2 d) {
    final bw = d.latestWeightKg;
    final t = _target;
    final bwStr = bw == null ? '—' : '${_n(bw)} kg';
    if (t == null) return bwStr;
    return '$bwStr · target ${_n(t)} kg';
  }

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String _weekdayNames(List<int> iso) {
    if (iso.isEmpty) return 'none';
    final s = [...iso]..sort();
    return s.map((d) => _dayNames[(d - 1).clamp(0, 6)]).join(', ');
  }

  String _splitLabel(int days) => switch (days) {
        0 => '—',
        1 || 2 => 'Full body',
        3 => 'Full body / PPL',
        4 || 5 => 'Upper / Lower',
        _ => 'PPL ×2',
      };

  String _daysVerdict(int c) => switch (c) {
        0 => 'Pick at least one. Even one real day beats a plan you skip.',
        1 || 2 => 'Two days works if both are full body. Your split would become full body.',
        3 => 'Three days means full body sessions, or a rotating push/pull/legs.',
        4 || 5 => 'Enough room for Upper / Lower with recovery between sessions.',
        _ => 'Six or more needs light days built in. I will keep two of them easy.',
      };

  String _restNote(int s) => s <= 60
      ? 'Short rests suit accessory work. Heavy compound sets will still get their full time.'
      : s >= 180
          ? 'Long rests for heavy triples. Your sessions will run longer.'
          : 'A sensible middle. Each lift can still override it.';

  String _effortNote(String e) => switch (e) {
        'never' =>
          'Loads will only move when you change them yourself, and the effort chart on Progress stays empty.',
        'every_set' =>
          'The most accurate picture, and the most tapping. Best if you are chasing a number.',
        _ =>
          "One answer per lift. Enough to move next week's loads without slowing you down.",
      };

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// Plate labels keep the fractional kg exactly (1.25 stays "1.25", not "1.3").
  static String _plate(double v) => v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

// ─────────────────────────────────────────────────────────────────────────
// Leaf widgets
// ─────────────────────────────────────────────────────────────────────────

class _Change {
  final String label, from, to, effect;
  const _Change({required this.label, required this.from, required this.to, required this.effect});
}

/// One "Working around" entry, staged the same way as Goal/Days/Target:
/// [id] is the real `user_constraints.id` once saved, null while newly added
/// and not yet committed on "Rewrite my week".
class _WorkingFlag {
  final String? id;
  final String? jointId;
  final String? jointName;
  final String? side; // left | right | bilateral | null (free text)
  final String label;

  const _WorkingFlag({
    this.id,
    this.jointId,
    this.jointName,
    this.side,
    required this.label,
  });

  factory _WorkingFlag.fromConstraint(ConstraintV2 c) => _WorkingFlag(
        id: c.id,
        jointId: c.jointId,
        jointName: c.jointName,
        side: c.side,
        label: c.label,
      );

  String get display {
    if (jointName == null) return label;
    final prefix = switch (side) {
      'left' => 'Left ',
      'right' => 'Right ',
      'bilateral' => 'Both ',
      _ => '',
    };
    final text = '$prefix${jointName!.toLowerCase()}'.trim();
    return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
  }

  /// What changes, shown under each flagged row — mirrors the design's
  /// per-area copy, keyed by the joint name.
  String get effect {
    final area = (jointName ?? label).toLowerCase();
    if (area.contains('shoulder')) return 'Overhead pressing capped, flagged before every press';
    if (area.contains('back') || area.contains('lumbar')) {
      return 'Loaded hinges swapped for supported variants';
    }
    if (area.contains('knee')) return 'Depth limited on squats, no jumping';
    if (area.contains('wrist')) return 'Neutral-grip alternatives offered first';
    if (area.contains('hip')) return 'Range kept short until it settles';
    if (area.contains('ankle')) return 'Standing calf work replaced with seated';
    if (area.contains('neck')) return 'No loaded neck positions, shrugs dropped';
    return 'Nearby lifts capped and flagged';
  }

  /// Identity for diffing: the real row id once saved, else the
  /// joint+side/free-text combination (stable across a session).
  String get key => id ?? '$jointId|$side|$label';
}

class _PlanRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final bool dirty, last;
  final VoidCallback onTap;
  const _PlanRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.dirty,
    required this.onTap,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = dirty ? AppColors.accent : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: last
              ? null
              : const Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 17, color: accent ?? AppColors.textMuted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(label.toUpperCase(),
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 9.5,
                              letterSpacing: 0.7,
                              color: AppColors.textMuted)),
                      if (dirty) ...[
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text('EDITED',
                              style: TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 8.5,
                                  color: AppColors.accent)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(value,
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                          height: 1.35,
                          color: accent ?? AppColors.textPrimary)),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Icon(Icons.chevron_right, size: 17, color: AppColors.inactiveFill),
            ),
          ],
        ),
      ),
    );
  }
}

/// Segmented pill control. [T] is the value carried by each option.
class _Segmented<T> extends StatelessWidget {
  final List<(String, T)> options;
  final T selectedValue;
  final ValueChanged<T> onSelect;
  const _Segmented({
    required this.options,
    required this.selectedValue,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.page,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: GestureDetector(
                onTap: () => onSelect(options[i].$2),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: options[i].$2 == selectedValue
                        ? AppColors.accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Text(options[i].$1,
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 11.5,
                          color: options[i].$2 == selectedValue
                              ? AppColors.onAccent
                              : AppColors.textMuted)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label, sub;
  final bool value, last;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.label,
    required this.sub,
    required this.value,
    required this.onChanged,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: last
              ? null
              : const Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 12.5,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 3),
                  Text(sub,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 10,
                          height: 1.45,
                          color: AppColors.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _Switch(value: value),
          ],
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  final bool value;
  const _Switch({required this.value});
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: 44,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? AppColors.accent : AppColors.border,
        borderRadius: BorderRadius.circular(14),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 220),
        curve: const Cubic(0.22, 1, 0.36, 1),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: value ? AppColors.onAccent : AppColors.textFaint,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// The delete-account confirmation body: an itemized loss list, a "type
/// DELETE" gate (destructive actions get an active step, not just a tap —
/// this one is irreversible), then the real call.
class _DeleteAccountBody extends StatefulWidget {
  final ProfileDataV2 d;
  const _DeleteAccountBody({required this.d});
  @override
  State<_DeleteAccountBody> createState() => _DeleteAccountBodyState();
}

class _DeleteAccountBodyState extends State<_DeleteAccountBody> {
  final _ctrl = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SupabaseService.instance.deleteAccount();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't delete your account — try again.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.warn.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _lossRow('${d.sessionsTotal} logged sessions and every set in them'),
              _lossRow('Progress photos and weigh-in history'),
              _lossRow('Your program, plan inputs, and trainer conversations'),
              _lossRow('Streak and consistency history — nothing carries over'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          autocorrect: false,
          enabled: !_busy,
          onChanged: (v) => setState(() => _confirmed = v.trim() == 'DELETE'),
          style: const TextStyle(
              fontFamily: AppTheme.fontFamily, fontSize: 13, color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Type DELETE to confirm',
            fillColor: AppColors.surface,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 11.5, color: AppColors.warn)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: GestureDetector(
            onTap: (_confirmed && !_busy) ? _delete : null,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _confirmed ? AppColors.warn : AppColors.surface,
                border: _confirmed ? null : Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(24),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onAccent))
                  : Text('Delete my account permanently',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: _confirmed ? AppColors.onAccent : AppColors.textFaint)),
            ),
          ),
        ),
        const SizedBox(height: 13),
        Center(
          child: GestureDetector(
            onTap: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Keep my account',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 11.5,
                    color: AppColors.textMuted)),
          ),
        ),
      ],
    );
  }

  Widget _lossRow(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.close_rounded, size: 14, color: AppColors.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.textSecondary)),
            ),
          ],
        ),
      );
}

/// One of the three Account icon tiles (Export / Sign out / Delete).
class _AccountTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool warn;
  final VoidCallback onTap;
  const _AccountTile({
    required this.icon,
    required this.label,
    this.warn = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = warn ? AppColors.warn : AppColors.textPrimary;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 6),
          decoration: BoxDecoration(
            color: warn ? AppColors.warn.withValues(alpha: 0.07) : AppColors.surfaceSunken,
            border: Border.all(color: warn ? AppColors.warn.withValues(alpha: 0.3) : AppColors.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(height: 7),
              Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 10.5,
                      color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bottom-sheet chrome: veil handled by the modal, this is the panel.
class _SheetShell extends StatelessWidget {
  final String title, sub;
  final Widget child;
  const _SheetShell({required this.title, required this.sub, required this.child});

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
                  color: AppColors.borderStrong,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Text(title,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    height: 1.2,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 7),
            Text(sub,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 11.5,
                    height: 1.55,
                    color: AppColors.textMuted)),
            const SizedBox(height: 16),
            Flexible(child: SingleChildScrollView(child: child)),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: AppColors.textFaint),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 13,
                    color: AppColors.textMuted)),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
