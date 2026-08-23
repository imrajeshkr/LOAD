import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/v2_models.dart';
import '../../services/haptics.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../widgets/pressable.dart';
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
  late String _split; // split_preference
  String? _experience;
  String? _environment;
  double? _target;
  late List<_WorkingFlag> _flags;
  String _painNote = '';
  double? _barKg;
  // Saved snapshot for the training-week strip's staged diff.
  late List<int> _savedWeekdays;
  late String _savedSplit;
  // The plan's live weekday → session-label map (from the server), for the
  // "Your plan" strip. Rendered when there are no staged plan edits.
  Map<int, String> _slots = const {};
  bool _swapping = false;

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
        _split = data.splitPreference;
        _experience = data.experience;
        _environment = data.environment;
        _slots = data.weekdaySlots;
        _target = data.targetWeightKg;
        _flags = [...flags];
        _painNote = '';
        _barKg = data.barWeightKg;
        _savedWeekdays = [...data.trainingWeekdays];
        _savedSplit = data.splitPreference;
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

  // ── training-week staging (the one widget that stages, then rebuilds) ─────
  bool get _daysDirty => !_sameInts(_weekdays, _savedWeekdays);
  bool get _splitDirty => _split != _savedSplit;
  /// A staged change to the week's shape — days or split — pending a rebuild.
  bool get _planShapeDirty => _daysDirty || _splitDirty;

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

  /// Apply one independent change, then regenerate the program. [apply] writes
  /// just that change to the DB; the confirm names what it costs. Reshape edits
  /// (goal, split, days, working-around, bar) each call this on their own.
  Future<bool> _rebuild({
    required String title,
    required String effect,
    required Future<void> Function() apply,
  }) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ConfirmSheet(title: title, body: effect, confirmLabel: 'Rebuild'),
    );
    if (ok != true) return false;
    setState(() => _loading = true);
    try {
      await apply();
      await SupabaseService.instance.generateProgram();
      await _load();
      Haptics.success();
      if (mounted) _toast('Your week has been rebuilt.');
      return true;
    } catch (e) {
      if (!mounted) return false;
      Haptics.error();
      setState(() => _loading = false);
      _toast("Couldn't rebuild your week — try again.");
      return false;
    }
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
        ],
      ),
    );
  }

  // ── header ──────────────────────────────────────────────────────────────
  Widget _header(ProfileDataV2 d) {
    return Pressable(
      behavior: HitTestBehavior.opaque,
      onTap: () => _editHeader(d),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 0, 2),
        child: Row(
          children: [
            _avatar(d, size: 56, radius: 19, fontSize: 21),
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
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.edit_outlined, size: 16, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(ProfileDataV2 d,
      {required double size, required double radius, required double fontSize}) {
    final url = d.avatarUrl;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.network(url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _initialsBox(d, size, radius, fontSize)),
      );
    }
    return _initialsBox(d, size, radius, fontSize);
  }

  Widget _initialsBox(ProfileDataV2 d, double size, double radius, double fontSize) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(d.initials,
          style: TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
              color: AppColors.onAccent)),
    );
  }

  Future<void> _editHeader(ProfileDataV2 d) async {
    final ctrl = TextEditingController(text: d.displayName ?? '');
    var avatarUrl = d.avatarUrl;
    var busy = false;
    await _sheet(
      title: 'Your profile',
      sub: 'How you show up in the app.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> pick() async {
            if (busy) return;
            final picked = await ImagePicker()
                .pickImage(source: ImageSource.gallery, maxWidth: 900, imageQuality: 85);
            if (picked == null) return;
            setSheet(() => busy = true);
            try {
              final bytes = await picked.readAsBytes();
              final ext = picked.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
              final url = await SupabaseService.instance.uploadAvatar(bytes: bytes, ext: ext);
              setSheet(() {
                avatarUrl = url;
                busy = false;
              });
              await _load();
            } catch (e) {
              setSheet(() => busy = false);
              _toast("Couldn't upload that photo.");
            }
          }

          return Column(
            children: [
              Pressable(
                onTap: pick,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: (avatarUrl != null && avatarUrl!.isNotEmpty)
                          ? Image.network(avatarUrl!, width: 76, height: 76, fit: BoxFit.cover)
                          : Container(
                              width: 76,
                              height: 76,
                              color: AppColors.accent,
                              alignment: Alignment.center,
                              child: Text(d.initials,
                                  style: const TextStyle(
                                      fontFamily: AppTheme.fontFamily,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 28,
                                      color: AppColors.onAccent)),
                            ),
                    ),
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceRaised,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Icon(busy ? Icons.hourglass_top_rounded : Icons.photo_camera_outlined,
                            size: 14, color: AppColors.accent),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 14, color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'Your name',
                  fillColor: AppColors.surface,
                ),
              ),
              const SizedBox(height: 20),
              _sheetPrimary('Save', () async {
                await SupabaseService.instance.updateDisplayName(ctrl.text);
                if (ctx.mounted) Navigator.of(ctx).pop();
                await _load();
              }),
            ],
          );
        },
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
          Pressable(
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
          const SizedBox(height: 14),
          _trainingWeekBlock(),
          const SizedBox(height: 6),
          const Divider(height: 1, color: AppColors.border),
          _PlanRow(
            icon: Icons.flag_outlined,
            label: 'Goal',
            value: _goals.isEmpty ? "Coach's call" : _goals.map((g) => g.label).join(' · '),
            dirty: false,
            onTap: _openGoalSheet,
          ),
          _PlanRow(
            icon: Icons.timeline_outlined,
            label: 'Training age',
            value: _experienceDisplay(_experience),
            dirty: false,
            onTap: _openExperienceSheet,
          ),
          _PlanRow(
            icon: Icons.place_outlined,
            label: 'Where you train',
            value: _environmentDisplay(_environment),
            dirty: false,
            onTap: _openEnvironmentSheet,
          ),
          _PlanRow(
            icon: Icons.monitor_weight_outlined,
            label: 'Bodyweight',
            value: _bodyweightValue(d),
            dirty: false,
            onTap: _openTargetSheet,
          ),
          _PlanRow(
            icon: Icons.healing_outlined,
            label: 'Working around',
            value: _flags.isEmpty ? 'Nothing flagged' : _flags.map((f) => f.display).join(' · '),
            dirty: false,
            onTap: _openInjuriesSheet,
          ),
          _PlanRow(
            icon: Icons.fitness_center,
            label: 'Your bar',
            value: 'Full length · ${_n(_barKg ?? d.barWeightKg)} kg',
            dirty: false,
            last: true,
            onTap: _openBarSheet,
          ),
        ],
      ),
    );
  }

  // ── training-week strip: split toggle + draggable day chips ────────────────
  static const _splitOptions = [
    ('Full body', 'full_body'),
    ('PPL ×2', 'push_pull_legs'),
    ('Up / Low', 'upper_lower'),
    ('Coach', 'no_preference'),
  ];

  /// The day-type labels a split lays across the training weekdays, matching
  /// how the program generator assigns them (ascending weekdays, cycling).
  List<String> _splitTypeLabels(String split, int dayCount) {
    switch (split) {
      case 'push_pull_legs':
        return const ['Push day', 'Pull day', 'Leg day'];
      case 'upper_lower':
        return const ['Upper body', 'Lower body'];
      case 'full_body':
        return const ['Full body A', 'Full body B'];
      default: // no_preference → derived from the day count
        if (dayCount <= 3) return const ['Full body A', 'Full body B'];
        if (dayCount <= 5) return const ['Upper body', 'Lower body'];
        return const ['Push day', 'Pull day', 'Leg day'];
    }
  }

  /// The weekday→label map to render. While there's a staged shape change, the
  /// real types aren't known until the rebuild, so preview the split's default
  /// assignment; otherwise use the live plan.
  Map<int, String> _effectiveSlots() {
    if (!_planShapeDirty) return _slots;
    final wd = [..._weekdays]..sort();
    final types = _splitTypeLabels(_split, wd.length);
    final m = <int, String>{};
    for (var i = 0; i < wd.length; i++) {
      m[wd[i]] = types.isEmpty ? '' : types[i % types.length];
    }
    return m;
  }

  void _setSplit(String s) {
    if (_split == s) return;
    Haptics.selection();
    setState(() => _split = s);
  }

  void _toggleDay(int wd) {
    Haptics.selection();
    setState(() {
      if (_weekdays.contains(wd)) {
        _weekdays.remove(wd);
      } else {
        _weekdays.add(wd);
        _weekdays.sort();
      }
    });
  }

  /// The date in the current Mon–Sun week for an ISO weekday (1=Mon..7=Sun).
  DateTime _thisWeekDate(int isoWeekday) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    return monday.add(Duration(days: isoWeekday - 1));
  }

  Future<void> _swapDays(int a, int b) async {
    if (a == b || _swapping || _planShapeDirty) return;
    Haptics.selection();
    final scope = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _SwapScopeSheet(fromTag: _planTag(_slots[a]), toTag: _planTag(_slots[b])),
    );
    if (scope == null || !mounted) return;
    setState(() => _swapping = true);
    try {
      if (scope == 'forever') {
        await SupabaseService.instance.swapProgramWeekdays(a, b);
      } else {
        await SupabaseService.instance
            .swapScheduledDays(_thisWeekDate(a), _thisWeekDate(b), 'week');
      }
      Haptics.success();
      await _load();
      if (mounted) {
        _toast(scope == 'forever' ? 'Swapped — every week from now.' : 'Swapped for this week.');
      }
    } catch (e) {
      Haptics.error();
      if (mounted) _toast("Couldn't swap those days.");
      await _load();
    } finally {
      if (mounted) setState(() => _swapping = false);
    }
  }

  /// Apply the staged split / day-count change as an independent rebuild.
  Future<void> _applyShapeRebuild() async {
    final title = _splitDirty ? 'Switch to ${_splitDisplay(_split)}?' : 'Change your training days?';
    await _rebuild(
      title: title,
      effect: 'New sessions and exercise picks for the days ahead. Every set you have logged is kept.',
      apply: () async {
        final patch = <String, dynamic>{};
        if (_daysDirty) patch['training_weekdays'] = _weekdays;
        if (_splitDirty) patch['split_preference'] = _split;
        await SupabaseService.instance.updatePlanProfile(patch);
      },
    );
  }

  void _cancelShape() {
    setState(() {
      _split = _savedSplit;
      _weekdays = [..._savedWeekdays];
    });
  }

  Widget _trainingWeekBlock() {
    final n = _weekdays.length;
    final slots = _effectiveSlots();
    final preview = _planShapeDirty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('TRAINING SPLIT',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 9,
                    letterSpacing: 0.8,
                    color: AppColors.textFaint)),
            const Spacer(),
            Text('$n ${n == 1 ? 'day' : 'days'} a week',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              for (final o in _splitOptions)
                Expanded(
                  child: Pressable(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _setSplit(o.$2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _split == o.$2 ? AppColors.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(o.$1,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 10.5,
                              color: _split == o.$2 ? AppColors.onAccent : AppColors.textMuted)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 11),
        _PlanWeekStrip(
          weekdays: _weekdays,
          slots: slots,
          draggable: !preview && !_swapping,
          preview: preview,
          onToggle: _toggleDay,
          onSwap: _swapDays,
        ),
        const SizedBox(height: 9),
        if (preview)
          _ShapeConfirmBar(onCancel: _cancelShape, onRebuild: _applyShapeRebuild)
        else
          Row(
            children: [
              const Icon(Icons.drag_indicator_rounded, size: 12, color: AppColors.textFaint),
              const SizedBox(width: 5),
              const Expanded(
                child: Text('Drag a day onto another to swap · tap a day to add or rest',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 9.5, color: AppColors.textFaint)),
              ),
            ],
          ),
      ],
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
          const SizedBox(height: 6),
          _ToggleRow(
            label: 'Start rest between sets automatically',
            value: _prefs.autoStartRest,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(autoStartRest: v), {'auto_start_rest': v}),
          ),
          _ToggleRow(
            label: 'Keep screen awake while a session runs',
            value: _prefs.keepScreenAwake,
            onChanged: (v) => _applyPrefs(
                _prefs.copyWith(keepScreenAwake: v), {'keep_screen_awake': v}),
          ),
          _ToggleRow(
            label: 'Sound when rest ends',
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
    return Pressable(
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
          Pressable(
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
                icon: Icons.delete_outline,
                label: 'Delete',
                warn: true,
                onTap: () => _confirmDeleteAccount(d),
              ),
              const SizedBox(width: 7),
              _AccountTile(icon: Icons.logout, label: 'Sign out', onTap: _confirmSignOut),
              const SizedBox(width: 7),
              _AccountTile(
                icon: Icons.download_outlined,
                label: 'Export data',
                onTap: () => _toast('Export is coming in a later build.'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pauseRow() {
    return Pressable(
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
    final snapshot = [..._goals];
    var applied = false;
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
              _sheetPrimary('Save', () async {
                Navigator.of(ctx).pop();
                applied = true;
                final ok = await _rebuild(
                  title: 'Update your goal?',
                  effect: 'Exercise picks and rep ranges shift toward your goal. Every logged set is kept.',
                  apply: () => SupabaseService.instance.updatePlanProfile({
                    'goals': _goals.map((g) => g.db).toList(),
                    'goal_is_coach_choice': _goals.isEmpty,
                  }),
                );
                if (!ok && mounted) setState(() => _goals = [...snapshot]);
              }),
            ],
          );
        },
      ),
    );
    if (!applied && mounted) setState(() => _goals = [...snapshot]);
  }

  Future<void> _openExperienceSheet() async {
    const options = [
      ('Under 6 months', 'beginner'),
      ('6 months to 2 years', 'intermediate'),
      ('Over 2 years', 'advanced'),
    ];
    final snapshot = _experience;
    var applied = false;
    await _sheet(
      title: 'How long have you trained?',
      sub: 'Sets how fast weight climbs and how much work I plan for you.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          children: [
            for (final (label, value) in options)
              _selectRow(
                label: label,
                selected: _experience == value,
                leads: false,
                onTap: () => setSheet(() => setState(() => _experience = value)),
              ),
            const SizedBox(height: 20),
            _sheetPrimary('Save', () async {
              Navigator.of(ctx).pop();
              applied = true;
              final ok = await _rebuild(
                title: 'Rebuild for your training age?',
                effect: 'Changes how much work I plan and how quickly weight climbs. Every logged set is kept.',
                apply: () => SupabaseService.instance
                    .updatePlanProfile({'experience': _experience}),
              );
              if (!ok && mounted) setState(() => _experience = snapshot);
            }),
          ],
        ),
      ),
    );
    if (!applied && mounted) setState(() => _experience = snapshot);
  }

  Future<void> _openEnvironmentSheet() async {
    const options = [
      ('Commercial gym', 'commercial_gym'),
      ('Home gym', 'home_gym'),
      // 'bodyweight_only' is intentionally omitted: the current catalog has no
      // bodyweight leg exercises, so it would generate an empty Leg day.
      // Restored when the catalog import lands.
    ];
    final snapshot = _environment;
    var applied = false;
    await _sheet(
      title: 'Where do you train?',
      sub: 'I only program equipment you can actually reach.',
      body: StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          children: [
            for (final (label, value) in options)
              _selectRow(
                label: label,
                selected: _environment == value,
                leads: false,
                onTap: () => setSheet(() => setState(() => _environment = value)),
              ),
            const SizedBox(height: 20),
            _sheetPrimary('Save', () async {
              Navigator.of(ctx).pop();
              applied = true;
              final ok = await _rebuild(
                title: 'Rebuild for your gym?',
                effect: 'Exercises you cannot do here are swapped for ones you can. Every logged set is kept.',
                apply: () => SupabaseService.instance
                    .updatePlanProfile({'environment': _environment}),
              );
              if (!ok && mounted) setState(() => _environment = snapshot);
            }),
          ],
        ),
      ),
    );
    if (!applied && mounted) setState(() => _environment = snapshot);
  }

  Future<void> _openTargetSheet() async {
    final bw = _data!.latestWeightKg ?? _target ?? 80;
    final snapshot = _target;
    var applied = false;
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
              _sheetPrimary('Save', () async {
                Navigator.of(ctx).pop();
                applied = true;
                try {
                  await SupabaseService.instance
                      .updatePlanProfile({'target_weight_kg': _target});
                  await _load();
                  Haptics.success();
                } catch (e) {
                  if (mounted) setState(() => _target = snapshot);
                  _toast("Couldn't save that — try again.");
                }
              }),
            ],
          );
        },
      ),
    );
    if (!applied && mounted) setState(() => _target = snapshot);
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
    final snapshot = [..._flags];
    final snapNote = _painNote;
    var applied = false;
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
                          Pressable(
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
                      return Pressable(
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
              _sheetPrimary('Save', () async {
                Navigator.of(ctx).pop();
                applied = true;
                final ok = await _rebuild(
                  title: 'Update what you work around?',
                  effect: 'Lifts near a flagged area get capped or swapped; cleared areas go back to normal. Logged sets kept.',
                  apply: () async {
                    final svc = SupabaseService.instance;
                    final orig = _data!.constraints.map(_WorkingFlag.fromConstraint).toList();
                    final removed = orig
                        .where((sf) => sf.id != null && !_flags.any((f) => f.id == sf.id))
                        .toList();
                    for (final r in removed) {
                      await svc.removeConstraint(r.id!);
                    }
                    for (final a in _flags.where((f) => f.id == null)) {
                      await svc.addConstraint(jointId: a.jointId, side: a.side, label: a.display);
                    }
                    final note = _painNote.trim();
                    if (note.isNotEmpty) await svc.addConstraint(label: note);
                  },
                );
                if (!ok && mounted) {
                  setState(() {
                    _flags = [...snapshot];
                    _painNote = snapNote;
                  });
                }
              }),
            ],
          );
        },
      ),
    );
    if (!applied && mounted) {
      setState(() {
        _flags = [...snapshot];
        _painNote = snapNote;
      });
    }
  }

  Future<void> _openBarSheet() async {
    const bars = [
      ('full length', 20.0),
      ('short', 15.0),
      ('fixed', 10.0),
      ('training', 5.0),
    ];
    final snapshot = _barKg;
    var applied = false;
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
                        return Pressable(
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
              _verdictBox('Every barbell prescription is rebuilt from this weight.'),
              const SizedBox(height: 20),
              _sheetPrimary('Save', () async {
                Navigator.of(ctx).pop();
                applied = true;
                final ok = await _rebuild(
                  title: 'Rebuild with the new bar?',
                  effect: 'Every barbell load is recalculated from this weight. Logged sets kept.',
                  apply: () => SupabaseService.instance.updatePlanProfile({'bar_weight_kg': _barKg}),
                );
                if (!ok && mounted) setState(() => _barKg = snapshot);
              }),
            ],
          );
        },
      ),
    );
    if (!applied && mounted) setState(() => _barKg = snapshot);
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
          Pressable(
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
    return Pressable(
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
    return Pressable(
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
      child: Pressable(
        haptic: PressFx.medium,
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

  // ── formatting helpers ──────────────────────────────────────────────────
  Widget _fieldLabel(String s) => Text(s.toUpperCase(),
      style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 9.5,
          letterSpacing: 0.7,
          color: AppColors.textMuted));

  String _bodyweightValue(ProfileDataV2 d) {
    final bw = d.latestWeightKg;
    final t = _target;
    final bwStr = bw == null ? '—' : '${_n(bw)} kg';
    if (t == null) return bwStr;
    return '$bwStr · target ${_n(t)} kg';
  }

  String _splitDisplay(String s) => switch (s) {
        'push_pull_legs' => 'Push / Pull / Legs',
        'upper_lower' => 'Upper / Lower',
        'full_body' => 'Full body',
        _ => "Coach's call",
      };

  String _experienceDisplay(String? e) => switch (e) {
        'beginner' => 'Under 6 months',
        'intermediate' => '6 months to 2 years',
        'advanced' => 'Over 2 years',
        _ => 'Not set',
      };

  String _environmentDisplay(String? v) => switch (v) {
        'commercial_gym' => 'Commercial gym',
        'home_gym' => 'Home gym',
        'bodyweight_only' => 'No equipment',
        _ => 'Not set',
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

String _planTag(String? label) {
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

/// The 7-day strip inside "Your plan": each training weekday carries its
/// session tag, rest days are muted. Drag one training day onto another to
/// swap (instant), tap a day to add it or make it rest (staged rebuild).
class _PlanWeekStrip extends StatelessWidget {
  final List<int> weekdays; // ISO training weekdays
  final Map<int, String> slots; // weekday → session label
  final bool draggable;
  final bool preview;
  final void Function(int wd) onToggle;
  final void Function(int a, int b) onSwap;
  const _PlanWeekStrip({
    required this.weekdays,
    required this.slots,
    required this.draggable,
    required this.preview,
    required this.onToggle,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var wd = 1; wd <= 7; wd++) ...[
          if (wd > 1) const SizedBox(width: 5),
          Expanded(child: _chip(wd)),
        ],
      ],
    );
  }

  Widget _chip(int wd) {
    final training = weekdays.contains(wd);
    final label = training ? slots[wd] : null;

    Widget tapCell({bool hovering = false}) => Pressable(
          behavior: HitTestBehavior.opaque,
          onTap: () => onToggle(wd),
          child: _PlanChipCell(wd: wd, label: label, preview: preview, hovering: hovering),
        );

    if (!draggable) return tapCell();

    Widget content = DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != wd,
      onAcceptWithDetails: (d) => onSwap(d.data, wd),
      builder: (ctx, cand, rej) => AnimatedScale(
        scale: cand.isNotEmpty ? 1.06 : 1,
        duration: const Duration(milliseconds: 120),
        child: tapCell(hovering: cand.isNotEmpty),
      ),
    );

    if (training) {
      content = LongPressDraggable<int>(
        data: wd,
        onDragStarted: Haptics.selection,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
              width: 46, child: _PlanChipCell(wd: wd, label: label, preview: false)),
        ),
        childWhenDragging:
            Opacity(opacity: 0.3, child: _PlanChipCell(wd: wd, label: label, preview: preview)),
        child: content,
      );
    }
    return content;
  }
}

class _PlanChipCell extends StatelessWidget {
  final int wd; // ISO 1..7
  final String? label; // null = rest
  final bool preview;
  final bool hovering;
  const _PlanChipCell(
      {required this.wd, required this.label, required this.preview, this.hovering = false});

  @override
  Widget build(BuildContext context) {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final training = label != null;
    final tag = training ? _planTag(label) : 'REST';

    Color bg, border, pillFg, pillBg;
    if (hovering) {
      bg = AppColors.accent.withValues(alpha: 0.14);
      border = AppColors.accent;
      pillFg = AppColors.accent;
      pillBg = AppColors.accent.withValues(alpha: 0.14);
    } else if (training) {
      bg = AppColors.surface;
      border = AppColors.border;
      pillFg = AppColors.accent;
      pillBg = AppColors.accent.withValues(alpha: 0.14);
    } else {
      bg = Colors.transparent;
      border = AppColors.borderFaint;
      pillFg = AppColors.textDim;
      pillBg = Colors.transparent;
    }

    final chip = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: hovering ? 1.5 : 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(letters[(wd - 1).clamp(0, 6)],
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  fontSize: 8.5,
                  height: 1,
                  color: training ? AppColors.textMuted : AppColors.textFaint)),
          const SizedBox(height: 5),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(5)),
            child: Text(tag,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 7,
                    letterSpacing: 0.3,
                    color: pillFg)),
          ),
        ],
      ),
    );
    return Opacity(opacity: preview && !hovering ? 0.55 : 1, child: chip);
  }
}

/// The inline "rebuild" bar shown under the training-week strip while a split
/// or day change is staged. Independent of every other plan edit.
class _ShapeConfirmBar extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onRebuild;
  const _ShapeConfirmBar({required this.onCancel, required this.onRebuild});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
      decoration: BoxDecoration(
        color: AppColors.warn.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.warn.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.autorenew_rounded, size: 14, color: AppColors.warn),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('New shape — rebuild to apply',
                style: TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textSecondary)),
          ),
          Pressable(
            onTap: onCancel,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text('Cancel',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: AppColors.textMuted)),
            ),
          ),
          const SizedBox(width: 4),
          Pressable(
            onTap: onRebuild,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(14)),
              child: const Text('Rebuild',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: AppColors.onAccent)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Scope sheet for a day swap — pops 'week' / 'forever', or null to cancel.
class _SwapScopeSheet extends StatelessWidget {
  final String fromTag;
  final String toTag;
  const _SwapScopeSheet({required this.fromTag, required this.toTag});
  @override
  Widget build(BuildContext context) {
    return _sheetShell(
      context,
      children: [
        Text('Swap $fromTag and $toTag',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: AppColors.textPrimary)),
        const SizedBox(height: 6),
        const Text('Rearrange which session lands on which day.',
            style: TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 11.5, color: AppColors.textMuted)),
        const SizedBox(height: 16),
        _scopeBtn(context, 'Just this week', 'week', filled: true),
        const SizedBox(height: 10),
        _scopeBtn(context, 'Every week from now', 'forever', filled: false),
        const SizedBox(height: 12),
        Center(
          child: Pressable(
            onTap: () => Navigator.of(context).pop(),
            child: const Text('Leave it as it is',
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

  Widget _scopeBtn(BuildContext context, String label, String scope, {required bool filled}) {
    return SizedBox(
      width: double.infinity,
      child: Pressable(
        onTap: () => Navigator.of(context).pop(scope),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 15),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? AppColors.accent : Colors.transparent,
            border: filled ? null : Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(label,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: filled ? AppColors.onAccent : AppColors.textPrimary)),
        ),
      ),
    );
  }
}

/// A compact confirm sheet — pops true on confirm.
class _ConfirmSheet extends StatelessWidget {
  final String title;
  final String body;
  final String confirmLabel;
  const _ConfirmSheet({required this.title, required this.body, required this.confirmLabel});
  @override
  Widget build(BuildContext context) {
    return _sheetShell(
      context,
      children: [
        Text(title,
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: AppColors.textPrimary)),
        const SizedBox(height: 8),
        Text(body,
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily, fontSize: 13, height: 1.5, color: AppColors.textSecondary)),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Pressable(
                onTap: () => Navigator.of(context).pop(false),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.borderStrong),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Text('Keep as is',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.textPrimary)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Pressable(
                onTap: () => Navigator.of(context).pop(true),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(22)),
                  child: Text(confirmLabel,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.onAccent)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Shared bottom-sheet chrome for the confirm / scope sheets.
Widget _sheetShell(BuildContext context, {required List<Widget> children}) {
  return Container(
    decoration: const BoxDecoration(
      color: AppColors.surfaceRaised,
      border: Border(top: BorderSide(color: AppColors.border)),
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    padding: EdgeInsets.fromLTRB(20, 10, 20, 22 + MediaQuery.of(context).padding.bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: AppColors.borderStrong, borderRadius: BorderRadius.circular(3)),
          ),
        ),
        ...children,
      ],
    ),
  );
}

/// One "Working around" entry: [id] is the real `user_constraints.id` once
/// saved, null while newly added and not yet committed.
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
    return Pressable(
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
              child: Pressable(
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
  final String label;
  final String? sub;
  final bool value, last;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.label,
    this.sub,
    required this.value,
    required this.onChanged,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
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
                  if (sub != null) ...[
                    const SizedBox(height: 3),
                    Text(sub!,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 10,
                            height: 1.45,
                            color: AppColors.textMuted)),
                  ],
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
          child: Pressable(
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
          child: Pressable(
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
      child: Pressable(
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
            OutlinedButton(onPressed: () { Haptics.tap(); onRetry(); }, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
