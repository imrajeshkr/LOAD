import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../widgets/pressable.dart';
import '../../theme/app_theme.dart';

/// The v2 intake: six steps done by doing (dials, plates, a body map), then a
/// build animation and a plan-ready screen. Assumes the user is already
/// authenticated (the root gate handles auth) and has no active program yet.
class OnboardingV2 extends StatefulWidget {
  /// Called once the plan is generated and the user taps into the app.
  final VoidCallback onFinished;
  const OnboardingV2({super.key, required this.onFinished});

  @override
  State<OnboardingV2> createState() => _OnboardingV2State();
}

const _steps = ['goal', 'body', 'days', 'experience', 'place', 'bar', 'map', 'review'];

class _GoalMeta {
  final IconData icon;
  final String sub;
  const _GoalMeta(this.icon, this.sub);
}

const _goalMeta = {
  GoalV2.buildMuscle: _GoalMeta(Icons.fitness_center, 'Add size and strength'),
  GoalV2.loseFat: _GoalMeta(Icons.local_fire_department, 'Lean out while keeping muscle'),
  GoalV2.strength: _GoalMeta(Icons.trending_up, 'Move heavier weight over time'),
  GoalV2.generalHealth: _GoalMeta(Icons.favorite, 'Show up, feel good, no drama'),
  GoalV2.recomposition: _GoalMeta(Icons.healing, 'Rebuild carefully after time off'),
};

// Plate catalog for the bench-calibration bar (fixed, not the gym inventory).
const _plateCatalog = <double>[20, 10, 5, 2.5, 1.25];
Color _plateColorFor(double p) => switch (p) {
      20.0 => AppColors.accent,
      10.0 => AppColors.accentDeep,
      5.0 => AppColors.textPrimary,
      2.5 => AppColors.textMuted,
      _ => AppColors.inactiveFill,
    };

// Body-map node geometry, matched to the silhouette blocks below (from the
// design). Each entry is (topPx, dxPx, isLateral) in the 300-tall map; lateral
// nodes mirror dx to the other side. Keyed by `joints.slug`.
const _frontGeo = <String, (double, double, bool)>{
  'neck': (54, 0, false),
  'shoulder': (72, 31, true),
  'elbow': (112, 43, true),
  'wrist': (146, 43, true),
  'hip': (158, 0, false),
  'knee': (216, 15, true),
  'ankle': (264, 15, true),
};
const _backGeo = <String, (double, double, bool)>{
  'neck': (54, 0, false),
  'upper-back': (86, 0, false),
  'lumbar': (134, 0, false),
  'shoulder-blade': (82, 24, true),
  'glute': (158, 16, true),
  'hamstring': (206, 15, true),
  'calf': (250, 15, true),
};

class _OnboardingV2State extends State<OnboardingV2> {
  String _screen = 'intake'; // intake | building | done
  int _step = 0;

  // answers
  final List<GoalV2> _goals = [];
  bool _coachChoice = false;
  bool _metric = true;
  double _bw = 80;
  String? _targetMode; // lose | same | gain | none
  double _target = 76;
  final List<int> _weekdays = [1, 3, 5]; // ISO
  String? _split; // full_body | upper_lower | push_pull_legs
  String? _experience; // beginner | intermediate | advanced
  String? _environment; // commercial_gym | home_gym | bodyweight_only
  bool _benched = true;
  double _barKg = 20;
  final List<double> _plates = [];
  String _view = 'front';
  final List<OnboardingFlag> _flags = [];
  final _painCtrl = TextEditingController();

  List<JointV2> _joints = const [];
  int _build = 0;
  Timer? _buildTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    SupabaseService.instance.fetchJoints().then((j) {
      if (mounted) setState(() => _joints = j);
    });
  }

  @override
  void dispose() {
    _buildTimer?.cancel();
    _painCtrl.dispose();
    super.dispose();
  }

  // ── derived ───────────────────────────────────────────────────────────────
  String get _stepId => _steps[_step];
  int get _dayCount => _weekdays.length;

  int _disp(double kg) => _metric ? kg.round() : (kg * 2.2046).round();

  double get _benchTotal =>
      _plates.fold<double>(_barKg, (n, p) => n + p * 2);

  List<(String label, String enumVal, String sub)> get _splitOptions {
    if (_dayCount <= 2) {
      return [('Full body', 'full_body', 'Everything, twice a week')];
    } else if (_dayCount == 3) {
      return [
        ('Full body', 'full_body', 'Everything each session'),
        ('Push / Pull / Legs', 'push_pull_legs', 'One rotation a week'),
      ];
    } else if (_dayCount <= 5) {
      return [
        ('Upper / Lower', 'upper_lower', 'Alternating, 4 days'),
        ('Push / Pull / Legs', 'push_pull_legs', 'Rotating, hits twice'),
      ];
    }
    return [
      ('Push / Pull / Legs', 'push_pull_legs', 'Twice through the week'),
      ('Upper / Lower', 'upper_lower', 'Three-on, one-off'),
    ];
  }

  bool get _canAdvance => switch (_stepId) {
        'goal' => _goals.isNotEmpty || _coachChoice,
        'body' => _targetMode != null,
        'days' => _dayCount > 0 && _split != null,
        'experience' => _experience != null,
        'place' => _environment != null,
        _ => true,
      };

  String get _coachLine {
    switch (_stepId) {
      case 'goal':
        if (_coachChoice) return "Fine by me — I'll start you on general strength and adjust.";
        if (_goals.isEmpty) return 'Pick one or several. This is the only answer that shapes the whole plan.';
        if (_goals.length == 1) return 'Good. Everything downstream bends toward ${_goals.first.label.toLowerCase()}.';
        return '${_goals.first.label.toLowerCase()} leads, the rest ride along.';
      case 'body':
        if (_targetMode == null) return "Set a target or tell me you don't want one — I won't pick silently.";
        if (_targetMode == 'none') return "No target. I'll just show you the trend.";
        return 'Target noted. Roughly ${(_bw - _target).abs().round()} kg of change at a sane pace.';
      case 'days':
        if (_dayCount == 0) return 'Pick at least one. Even one real day beats a perfect plan you skip.';
        return '$_dayCount days means I can give you ${_dayCount >= 4 ? 'a proper split' : 'full-body sessions'}.';
      case 'bar':
        if (!_benched) return "Nothing to guess then — week one is the bar and the technique.";
        if (_plates.isNotEmpty) return '${_n(_benchTotal)} kg to start. Every pressing lift scales off this.';
        return 'Empty bar is a fine answer — ${_n(_barKg)} kg and we build from there.';
      case 'map':
        if (_flags.isNotEmpty) return "I'll route around what you flagged and warn you when a lift gets close.";
        return 'Blank is a great answer here.';
      default:
        return 'One tap and you have a week of training.';
    }
  }

  // ── navigation ────────────────────────────────────────────────────────────
  void _back() {
    if (_step == 0) return;
    setState(() => _step -= 1);
  }

  void _next() {
    if (!_canAdvance) return;
    if (_stepId == 'review') {
      _runBuild();
      return;
    }
    setState(() => _step += 1);
  }

  Future<void> _runBuild() async {
    setState(() {
      _screen = 'building';
      _build = 0;
      _error = null;
    });
    _buildTimer = Timer.periodic(const Duration(milliseconds: 620), (t) {
      if (!mounted) return;
      setState(() => _build = (_build + 1).clamp(0, 4));
    });

    final draft = OnboardingDraft(
      goals: List.of(_goals),
      coachChoice: _coachChoice,
      metric: _metric,
      bodyweightKg: _bw,
      targetDirection: switch (_targetMode) {
        'lose' => 'lose',
        'gain' => 'gain',
        'same' => 'maintain',
        _ => 'declined',
      },
      targetWeightKg: (_targetMode == 'lose' || _targetMode == 'gain')
          ? _target
          : (_targetMode == 'same' ? _bw : null),
      weekdaysIso: List.of(_weekdays)..sort(),
      splitPreference: _split ?? 'full_body',
      experience: _experience ?? 'beginner',
      environment: _environment ?? 'commercial_gym',
      barWeightKg: _barKg,
      hasBenched: _benched,
      benchStartKg: _benchTotal,
      flags: List.of(_flags),
      otherPain: _painCtrl.text,
    );

    try {
      await SupabaseService.instance.submitOnboarding(draft);
      _buildTimer?.cancel();
      if (!mounted) return;
      // Let the checklist finish visually, then drop straight into the app —
      // the Train tab already shows the plan and today's session.
      setState(() => _build = 4);
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      widget.onFinished();
    } catch (e) {
      _buildTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _screen = 'intake';
        _step = _steps.length - 1;
      });
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.page,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        switchInCurve: const Cubic(0.22, 1, 0.36, 1),
        child: KeyedSubtree(
          key: ValueKey(_screen),
          child: switch (_screen) {
            'building' => _buildingView(),
            _ => _intakeView(),
          },
        ),
      ),
    );
  }

  Widget _intakeView() {
    return SafeArea(
      child: Column(
        children: [
          // progress header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Pressable(
                      onTap: _back,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(
                            color: AppColors.surface, shape: BoxShape.circle),
                        child: Icon(Icons.arrow_back,
                            size: 17,
                            color: _step == 0
                                ? AppColors.textDim
                                : AppColors.textMuted),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: (_step + 1) / _steps.length,
                          minHeight: 4,
                          backgroundColor: AppColors.border,
                          valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('${_step + 1}/${_steps.length}',
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 11,
                            color: AppColors.textFaint)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(9)),
                      child: const Icon(Icons.bolt, size: 16, color: AppColors.onAccent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                        decoration: const BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(14),
                            bottomLeft: Radius.circular(14),
                            bottomRight: Radius.circular(14),
                          ),
                        ),
                        child: Text(_coachLine,
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 12,
                                height: 1.5,
                                color: AppColors.textSecondary)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // body — each step fades/slides up on change, matching the design.
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 340),
              switchInCurve: const Cubic(0.22, 1, 0.36, 1),
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.035), end: Offset.zero)
                      .animate(anim),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.topLeft, children: [
                ?current,
                ...previous,
              ]),
              child: ListView(
                key: ValueKey(_step),
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
                children: [
                  Text(_titleFor(_stepId).$1,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 24,
                          height: 1.2,
                          letterSpacing: -0.24,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 9),
                  Text(_titleFor(_stepId).$2,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 12.5,
                          height: 1.55,
                          color: AppColors.textMuted)),
                  const SizedBox(height: 20),
                  _stepBody(),
                ],
              ),
            ),
          ),
          // footer
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
            child: Column(
              children: [
                if (_error != null) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, size: 15, color: AppColors.warn),
                      const SizedBox(width: 7),
                      Expanded(
                        // The real exception is shown, not swallowed. The
                        // generic "try again" that used to live here hid the
                        // cause from the person best placed to report it, and
                        // cost several rounds of guesswork diagnosing a
                        // failure the app already knew the answer to.
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Couldn't build your plan.",
                                style: TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.warn)),
                            const SizedBox(height: 3),
                            Text(_error!,
                                style: const TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontSize: 10.5,
                                    height: 1.4,
                                    color: AppColors.textMuted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (_stepId == 'bar' && _benched) ...[
                  Pressable(
                    onTap: () => setState(() {
                      _benched = false;
                      _plates.clear();
                      _step += 1;
                    }),
                    child: const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text("Never — I'm new. Skip this.",
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w500,
                              fontSize: 11.5,
                              color: AppColors.textFaint)),
                    ),
                  ),
                ],
                _primaryButton(
                  label: _stepId == 'review'
                      ? 'Build my week'
                      : _canAdvance
                          ? 'Continue'
                          : (_stepId == 'body'
                              ? 'Pick a direction first'
                              : 'Pick one to continue'),
                  enabled: _canAdvance,
                  onTap: _next,
                ),
                if (_stepId == 'map' && _flags.isEmpty && _painCtrl.text.trim().isEmpty) ...[
                  const SizedBox(height: 12),
                  Pressable(
                    onTap: () => setState(() => _step += 1),
                    child: const Text('Nothing hurts — skip',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 11.5,
                            color: AppColors.textFaint)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  (String, String) _titleFor(String id) => switch (id) {
        'goal' => ('What are we chasing?', "Pick as many as fit. If two pull against each other I'll tell you which one leads."),
        'body' => ('Where are you starting?', 'Drag for the rough number, tap ± to land it exactly.'),
        'days' => ('Which days are yours?', 'Tap the days you can actually show up. Be honest, not ambitious.'),
        'experience' => ('How long have you trained?', 'Not a label — it just tells me how fast to add weight and how much work you can recover from.'),
        'place' => ('Where do you train?', 'This decides which equipment I am allowed to program. I will never put a machine in your plan that you cannot reach.'),
        'bar' => ('How heavy is your bench?', 'One honest number sets the starting load for every press. I move it after your first set, so a low guess costs nothing.'),
        'map' => ('Anything that hurts?', "Tap it on the body. I'll program around it and warn you when a lift gets close."),
        _ => ('Look right?', 'Tap anything to change it. Nothing is saved until you build.'),
      };

  Widget _stepBody() => switch (_stepId) {
        'goal' => _goalStep(),
        'body' => _bodyStep(),
        'days' => _daysStep(),
        'experience' => _experienceStep(),
        'place' => _placeStep(),
        'bar' => _barStep(),
        'map' => _mapStep(),
        _ => _reviewStep(),
      };

  // ── step: goal ──────────────────────────────────────────────────────────
  Widget _goalStep() {
    return Column(
      children: [
        for (final g in GoalV2.values) _goalCard(g),
        _coachChoiceCard(),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _coachChoice
                ? 'You can change this any time from Profile.'
                : _goals.length > 1
                    ? 'The starred one leads — tap it off to promote another.'
                    : 'Multiple is fine. The first one you tap leads.',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 11,
                height: 1.5,
                color: AppColors.textFaint),
          ),
        ),
      ],
    );
  }

  Widget _goalCard(GoalV2 g) {
    final meta = _goalMeta[g]!;
    final sel = _goals.contains(g);
    final leads = sel && _goals.first == g;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Pressable(
        onTap: () => setState(() {
          _coachChoice = false;
          sel ? _goals.remove(g) : _goals.add(g);
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            color: sel ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
            border: Border.all(color: sel ? AppColors.accent : AppColors.border),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: sel ? AppColors.accent : AppColors.page,
                    borderRadius: BorderRadius.circular(12)),
                child: Icon(meta.icon,
                    size: 20, color: sel ? AppColors.onAccent : AppColors.textMuted),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.label,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(meta.sub,
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 11,
                            height: 1.45,
                            color: sel ? AppColors.textSecondary : AppColors.textMuted)),
                  ],
                ),
              ),
              if (sel)
                Icon(leads ? Icons.star : Icons.check_circle,
                    size: 19, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }

  /// A single-select card, styled like the goal cards. Used by the experience
  /// and place steps.
  Widget _choiceCard({
    required String title,
    required String sub,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
            border: Border.all(color: selected ? AppColors.accent : AppColors.border),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                            color: selected ? AppColors.accent : AppColors.textPrimary)),
                    const SizedBox(height: 3),
                    Text(sub,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 11.5,
                            height: 1.45,
                            color: AppColors.textMuted)),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle, size: 20, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }

  // ── step: experience ──────────────────────────────────────────────────────
  Widget _experienceStep() {
    const options = [
      ('Under 6 months', 'beginner', 'Weight can climb almost every session.'),
      ('6 months to 2 years', 'intermediate', 'Weight climbs across the week, not every session.'),
      ('Over 2 years', 'advanced', 'Progress comes in blocks, with lighter weeks built in.'),
    ];
    return Column(
      children: [
        for (final (label, value, sub) in options)
          _choiceCard(
            title: label,
            sub: sub,
            selected: _experience == value,
            onTap: () => setState(() => _experience = value),
          ),
      ],
    );
  }

  // ── step: place ───────────────────────────────────────────────────────────
  Widget _placeStep() {
    const options = [
      ('A commercial gym', 'commercial_gym', 'Full racks, machines and cables.'),
      ('A home gym', 'home_gym', 'Barbell, dumbbells and a bench — no machines.'),
      ('No equipment', 'bodyweight_only', 'Bodyweight only, wherever you are.'),
    ];
    return Column(
      children: [
        for (final (label, value, sub) in options)
          _choiceCard(
            title: label,
            sub: sub,
            selected: _environment == value,
            onTap: () => setState(() => _environment = value),
          ),
      ],
    );
  }

  Widget _coachChoiceCard() {
    return Pressable(
      onTap: () => setState(() {
        _coachChoice = true;
        _goals.clear();
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: _coachChoice
              ? AppColors.accent.withValues(alpha: 0.09)
              : const Color(0xFF150F0D),
          borderRadius: BorderRadius.circular(18),
        ),
        child: DottedBorderRow(
          selected: _coachChoice,
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: _coachChoice ? AppColors.accent : AppColors.page,
                    borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.auto_awesome,
                    size: 20,
                    color: _coachChoice ? AppColors.onAccent : AppColors.textMuted),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("I don't know — you choose",
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                            color: AppColors.textPrimary)),
                    SizedBox(height: 2),
                    Text("I'll start you on general strength and read your first two weeks.",
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 11,
                            height: 1.45,
                            color: AppColors.textMuted)),
                  ],
                ),
              ),
              if (_coachChoice)
                const Icon(Icons.check_circle, size: 19, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }

  // ── step: body ──────────────────────────────────────────────────────────
  Widget _bodyStep() {
    return Column(
      children: [
        _unitToggle(),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _circleBtn(Icons.remove, () => setState(() => _bw = (_bw - 1).clamp(40, 160))),
            SizedBox(
              width: 130,
              child: Column(
                children: [
                  Text('${_disp(_bw)}',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 56,
                          height: 1,
                          letterSpacing: -1.6,
                          color: AppColors.accent)),
                  const SizedBox(height: 5),
                  Text(_metric ? 'kg' : 'lb',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 11.5,
                          color: AppColors.textMuted)),
                ],
              ),
            ),
            _circleBtn(Icons.add, () => setState(() => _bw = (_bw + 1).clamp(40, 160))),
          ],
        ),
        const SizedBox(height: 8),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 8,
            activeTrackColor: AppColors.accent,
            inactiveTrackColor: AppColors.border,
            thumbColor: AppColors.accent,
            overlayShape: SliderComponentShape.noOverlay,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
          ),
          child: Slider(
            min: 40,
            max: 160,
            value: _bw,
            onChanged: (v) => setState(() => _bw = v.roundToDouble()),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('drag rough, tap ± exact',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 10.5,
                  color: AppColors.textDim)),
        ),
        const SizedBox(height: 22),
        _targetCard(),
        const SizedBox(height: 14),
        _leftAccentBox(
          title: 'Protein target ${(_bw * 1.8).round()} g a day',
          body: '1.8 g per kilo of bodyweight — the usual recommendation when you are training to keep or build muscle. It updates with every weigh-in.',
        ),
      ],
    );
  }

  Widget _targetCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
            color: _targetMode == null
                ? AppColors.accent.withValues(alpha: 0.4)
                : AppColors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Where should this number go?',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  fontSize: 12.5,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
                color: AppColors.page, borderRadius: BorderRadius.circular(22)),
            child: Row(
              children: [
                _dirChip('Lose', Icons.trending_down, 'lose'),
                _dirChip('Stay here', Icons.remove, 'same'),
                _dirChip('Gain', Icons.trending_up, 'gain'),
              ],
            ),
          ),
          if (_targetMode == 'lose' || _targetMode == 'gain') ...[
            const SizedBox(height: 14),
            Row(
              children: [
                _circleBtnSmall(Icons.remove, () => setState(() => _target -= 1)),
                Expanded(
                  child: Column(
                    children: [
                      Text.rich(TextSpan(children: [
                        TextSpan(
                            text: '${_disp(_target)}',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 24,
                                color: AppColors.textPrimary)),
                        TextSpan(
                            text: ' ${_metric ? 'kg' : 'lb'}',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 11,
                                color: AppColors.textMuted)),
                      ])),
                      const SizedBox(height: 4),
                      Text(
                          _target == _bw
                              ? 'same as today'
                              : '${_target < _bw ? '−' : '+'}${(_disp(_target) - _disp(_bw)).abs()} ${_metric ? 'kg' : 'lb'} from today',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 10.5,
                              color: AppColors.textMuted)),
                    ],
                  ),
                ),
                _circleBtnSmall(Icons.add, () => setState(() => _target += 1)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: Pressable(
              onTap: () => setState(() => _targetMode = 'none'),
              child: Text(
                  _targetMode == 'none'
                      ? 'Not chasing a number — tap a direction to change'
                      : "I'd rather not set a target",
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 11,
                      color: _targetMode == 'none' ? AppColors.accent : AppColors.textDim)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dirChip(String label, IconData icon, String mode) {
    final sel = _targetMode == mode;
    return Expanded(
      child: Pressable(
        onTap: () => setState(() {
          _targetMode = mode;
          _target = mode == 'lose' ? _bw - 4 : mode == 'gain' ? _bw + 4 : _bw;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
              color: sel ? AppColors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(18)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: sel ? AppColors.onAccent : AppColors.textMuted),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 11.5,
                      color: sel ? AppColors.onAccent : AppColors.textMuted)),
            ],
          ),
        ),
      ),
    );
  }

  // ── step: days ──────────────────────────────────────────────────────────
  Widget _daysStep() {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < 7; i++) ...[
              if (i > 0) const SizedBox(width: 7),
              Expanded(child: _dayChip(letters[i], i)),
            ],
          ],
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('$_dayCount',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 46,
                    height: 1,
                    color: AppColors.accent)),
            const SizedBox(width: 9),
            const Text('days a week',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 12.5,
                    color: AppColors.textMuted)),
          ],
        ),
        const SizedBox(height: 16),
        _leftAccentBox(body: _daysVerdict()),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in _splitOptions) _splitCard(o.$1, o.$2, o.$3),
          ],
        ),
      ],
    );
  }

  /// A single weekday chip: uniform square (Expanded width → AspectRatio height),
  /// selected state pops 6% like the design.
  Widget _dayChip(String letter, int i) {
    final sel = _weekdays.contains(i + 1);
    return Pressable(
      onTap: () => setState(() {
        final iso = i + 1;
        sel ? _weekdays.remove(iso) : _weekdays.add(iso);
        if (_split != null && !_splitOptions.any((o) => o.$2 == _split)) {
          _split = null;
        }
      }),
      child: AspectRatio(
        aspectRatio: 0.92,
        child: AnimatedScale(
          scale: sel ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: const Cubic(0.22, 1, 0.36, 1),
          child: Container(
            decoration: BoxDecoration(
              color: sel ? AppColors.accent : AppColors.surface,
              border: Border.all(color: sel ? AppColors.accent : AppColors.border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(letter,
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: sel ? AppColors.onAccent : AppColors.textMuted)),
                const SizedBox(height: 7),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: sel
                        ? AppColors.onAccent.withValues(alpha: 0.45)
                        : AppColors.borderStrong,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _daysVerdict() => switch (_dayCount) {
        0 => 'Nothing picked yet.',
        1 || 2 => 'Two days is enough to get stronger if both are full-body. No filler.',
        3 => 'Three days is the sweet spot for a first month.',
        4 || 5 => 'Enough room to split it and still recover between sessions.',
        _ => "Six-plus days needs light days built in. I'll keep two of them easy.",
      };

  Widget _splitCard(String label, String enumVal, String sub) {
    final sel = _split == enumVal;
    return Pressable(
      onTap: () => setState(() => _split = enumVal),
      child: Container(
        width: 150,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: sel ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
          border: Border.all(color: sel ? AppColors.accent : AppColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
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
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 10.5,
                    height: 1.4,
                    color: sel ? AppColors.textSecondary : AppColors.textMuted)),
          ],
        ),
      ),
    );
  }

  // ── step: bar ───────────────────────────────────────────────────────────
  Widget _barStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_benched) ...[
          Pressable(
            onTap: () => setState(() => _benched = true),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.07),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  const Icon(Icons.school, size: 18, color: AppColors.accent),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                        "Starting at the bar — week one is technique, and I add weight once you tell me a set felt easy.",
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 11.5,
                            height: 1.5,
                            color: AppColors.textSecondary)),
                  ),
                  const SizedBox(width: 8),
                  const Text('Undo',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          color: AppColors.accent)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(_benched ? 'YOUR BAR' : 'WHICH BAR DOES YOUR GYM HAVE?',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 10.5,
                letterSpacing: 0.6,
                color: AppColors.textFaint)),
        const SizedBox(height: 11),
        Row(
          children: [
            _barType('full length', 20),
            const SizedBox(width: 8),
            _barType('short', 15),
            const SizedBox(width: 8),
            _barType('fixed', 10),
            const SizedBox(width: 8),
            _barType('training', 5),
          ],
        ),
        const SizedBox(height: 14),
        _barVisual(),
        if (_benched) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final p in _plateCatalog) _plateAddBtn(p),
              _smallRound(Icons.undo, () {
                if (_plates.isNotEmpty) setState(() => _plates.removeLast());
              }),
              Pressable(
                onTap: () => setState(_plates.clear),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                      color: AppColors.page,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(20)),
                  child: const Text('Strip it',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 11.5,
                          color: AppColors.textMuted)),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text(
            !_benched
                ? 'Bench is the reference lift the plan scales from. Since you have not benched, I set it from your first real sets instead of asking you to guess.'
                : _plates.isNotEmpty
                    ? 'Bench is the reference lift — presses scale from it. I move it after your first set, so this only has to be close.'
                    : 'The bare bar is a real answer: leave it empty and I start you there.',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 11,
                height: 1.55,
                color: AppColors.textFaint)),
      ],
    );
  }

  Widget _barType(String sub, double kg) {
    final sel = _barKg == kg;
    return Expanded(
      child: Pressable(
        onTap: () => setState(() => _barKg = kg),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 13, 8, 11),
          decoration: BoxDecoration(
            color: sel ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
            border: Border.all(color: sel ? AppColors.accent : AppColors.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Container(
                width: kg == 20 ? 44 : kg == 15 ? 34 : 24,
                height: 4,
                decoration: BoxDecoration(
                    color: sel ? AppColors.accent : AppColors.textFaint,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 9),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text: _n(kg),
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: sel ? AppColors.accent : AppColors.textPrimary)),
                const TextSpan(
                    text: ' kg',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 9.5,
                        color: AppColors.textMuted)),
              ])),
              const SizedBox(height: 2),
              Text(sub,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 9.5,
                      color: AppColors.textFaint)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barVisual() {
    // Heavy → light; heavy plates load nearest the collar.
    final sorted = [..._plates]..sort((a, b) => b.compareTo(a));
    final ratio = ((_benchTotal - _barKg) / 80).clamp(0.0, 1.0);

    // One plate that scales up on the vertical when it first appears.
    Widget plate(double p, String side, int idx) {
      final h = switch (p) {
        20.0 => 88.0,
        10.0 => 70.0,
        5.0 => 54.0,
        2.5 => 42.0,
        _ => 32.0,
      };
      final w = switch (p) {
        20.0 => 15.0,
        10.0 => 13.0,
        5.0 => 11.0,
        2.5 => 9.0,
        _ => 8.0,
      };
      return TweenAnimationBuilder<double>(
        key: ValueKey('pl-$side-$idx-$p'),
        tween: Tween(begin: 0.25, end: 1.0),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        builder: (_, v, child) =>
            Transform(alignment: Alignment.center, transform: Matrix4.diagonal3Values(1, v.clamp(0.0, 1.0), 1), child: child),
        child: Container(
          width: w,
          height: h,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: _plateColorFor(p),
            borderRadius: BorderRadius.circular(3),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), offset: Offset(-1, 0), blurRadius: 1),
            ],
          ),
        ),
      );
    }

    Widget collar() => Container(
        width: 6,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
            color: AppColors.inactiveFill, borderRadius: BorderRadius.circular(2)));
    Widget endcap() => Container(
        width: 5,
        height: 14,
        decoration: BoxDecoration(
            color: AppColors.textFaint, borderRadius: BorderRadius.circular(2)));

    // Knurled centre shaft.
    Widget shaft() => Container(
          width: 92,
          height: 7,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFB0A49B), Color(0xFF3A3532)]),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var k = 0; k < 2; k++)
                Container(
                  width: 22,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0x996E655F), Color(0x00000000)],
                      stops: [0.5, 0.5],
                      tileMode: TileMode.repeated,
                      begin: Alignment(-1, 0),
                      end: Alignment(-0.9, 0),
                    ),
                  ),
                ),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
      decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          SizedBox(
            height: 108,
            child: Center(
              // The loaded bar sags a touch under weight.
              child: AnimatedSlide(
                offset: Offset(0, ratio * 0.06),
                duration: const Duration(milliseconds: 400),
                curve: const Cubic(0.34, 1.5, 0.64, 1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // left plate group bends outward under load
                    Transform.rotate(
                      angle: -ratio * 0.06,
                      alignment: Alignment.centerRight,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        endcap(),
                        for (var i = sorted.length - 1; i >= 0; i--)
                          plate(sorted[i], 'l', i),
                      ]),
                    ),
                    collar(),
                    shaft(),
                    collar(),
                    Transform.rotate(
                      angle: ratio * 0.06,
                      alignment: Alignment.centerLeft,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (var i = 0; i < sorted.length; i++)
                          plate(sorted[i], 'r', i),
                        endcap(),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text.rich(TextSpan(children: [
            TextSpan(
                text: _n(_benchTotal),
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 32,
                    color: AppColors.textPrimary)),
            const TextSpan(
                text: ' kg',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 12.5,
                    color: AppColors.textMuted)),
          ])),
          const SizedBox(height: 4),
          Text(
              _plates.isEmpty
                  ? 'empty bar, ${_n(_barKg)} kg'
                  : 'bar ${_n(_barKg)} + ${_plates.map(_n).join(' + ')} per side',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 11,
                  color: AppColors.textFaint)),
        ],
      ),
    );
  }

  Widget _plateAddBtn(double p) {
    return Pressable(
      onTap: () => setState(() => _plates.add(p)),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 8, 13, 8),
        decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: switch (p) {
                20.0 => 24.0,
                10.0 => 19.0,
                5.0 => 15.0,
                2.5 => 11.0,
                _ => 8.0,
              },
              decoration: BoxDecoration(
                  color: _plateColorFor(p), borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 8),
            Text('+ ${_n(p)}',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                    color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }

  // ── step: map ─────────────────────────────────────────────────────────────
  Widget _mapStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _viewTab('Front', 'front'),
              const SizedBox(width: 6),
              _viewTab('Back', 'back'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _bodyMap(),
        const SizedBox(height: 14),
        Text(
            _flags.isEmpty
                ? 'Tap a dot. Left and right are separate — check both views. Most people tap nothing.'
                : 'Flagged ${_flags.length}: tap a chip to clear it, or switch view for the other side.',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 11.5,
                height: 1.5,
                color: AppColors.textMuted)),
        if (_flags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final f in _flags)
                Pressable(
                  onTap: () => setState(() => _flags.removeWhere((x) => x.key == f.key)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                        color: AppColors.warn.withValues(alpha: 0.14),
                        border: Border.all(color: AppColors.warn),
                        borderRadius: BorderRadius.circular(20)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(f.label,
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w500,
                                fontSize: 11.5,
                                color: AppColors.warn)),
                        const SizedBox(width: 6),
                        const Icon(Icons.close, size: 14, color: AppColors.warn),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        const Text('IN YOUR OWN WORDS, IF IT HELPS',
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 10.5,
                letterSpacing: 0.6,
                color: AppColors.textFaint)),
        const SizedBox(height: 8),
        TextField(
          controller: _painCtrl,
          maxLines: 2,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontSize: 12.5,
              height: 1.5,
              color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Anything the map missed — a stiff morning, an old surgery, a movement you avoid',
            fillColor: AppColors.surface,
          ),
        ),
      ],
    );
  }

  Widget _viewTab(String label, String v) {
    final sel = _view == v;
    return Pressable(
      onTap: () => setState(() => _view = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
            color: sel ? AppColors.accent : AppColors.surface,
            borderRadius: BorderRadius.circular(20)),
        child: Text(label,
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w500,
                fontSize: 11.5,
                color: sel ? AppColors.onAccent : AppColors.textMuted)),
      ),
    );
  }

  Widget _bodyMap() {
    JointV2? jointFor(String slug) {
      for (final j in _joints) {
        if (j.slug == slug) return j;
      }
      return null;
    }

    final geo = _view == 'front' ? _frontGeo : _backGeo;

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      const h = 300.0;
      final cx = w / 2;

      // Nodes from the design geometry, so they land on the silhouette in both
      // views. Absolute px in the 300-tall map.
      final nodes = <({JointV2 j, String side, double x, double y})>[];
      geo.forEach((slug, g) {
        final j = jointFor(slug);
        if (j == null) return;
        final (top, dx, lateral) = g;
        if (lateral) {
          nodes.add((j: j, side: 'right', x: cx + dx, y: top));
          nodes.add((j: j, side: 'left', x: cx - dx, y: top));
        } else {
          nodes.add((j: j, side: 'bilateral', x: cx, y: top));
        }
      });

      Widget block(double left, double top, double bw, double bh, double r) =>
          Positioned(
            left: left,
            top: top,
            child: Container(
              width: bw,
              height: bh,
              decoration: BoxDecoration(
                  color: AppColors.border, borderRadius: BorderRadius.circular(r)),
            ),
          );
      return Container(
        height: h,
        decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(20)),
        child: Stack(
          children: [
            // silhouette
            block(cx - 17, 18, 34, 34, 17), // head
            block(cx - 12, 52, 24, 12, 4), // neck
            block(cx - 33, 62, 66, 88, 14), // torso
            block(cx - 29, 148, 58, 26, 8), // hips
            block(cx - 52, 66, 18, 88, 9), // left arm
            block(cx + 34, 66, 18, 88, 9), // right arm
            block(cx - 26, 172, 22, 104, 11), // left leg
            block(cx + 4, 172, 22, 104, 11), // right leg
            for (final n in nodes)
              Positioned(
                left: n.x - 16,
                top: n.y - 16,
                child: Pressable(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() {
                    final key = '${n.j.id}|${n.side}';
                    if (_flags.any((f) => f.key == key)) {
                      _flags.removeWhere((f) => f.key == key);
                    } else {
                      _flags.add(OnboardingFlag(
                          jointId: n.j.id, jointName: n.j.name, side: n.side));
                    }
                  }),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Center(
                      child: _MapDot(
                        on: _flags.any((f) => f.key == '${n.j.id}|${n.side}'),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }

  // ── step: review ──────────────────────────────────────────────────────────
  Widget _reviewStep() {
    final tiles = <({String label, String value, int step, IconData icon, int span, bool warm})>[
      (
        label: 'Training for',
        value: _coachChoice
            ? "Your call, coach"
            : (_goals.isEmpty ? 'Not picked' : _goals.map((g) => g.label).join(' · ')),
        step: _steps.indexOf('goal'),
        icon: Icons.flag_outlined,
        span: 2,
        warm: false
      ),
      (label: 'Bodyweight', value: '${_disp(_bw)} ${_metric ? 'kg' : 'lb'}', step: _steps.indexOf('body'), icon: Icons.monitor_weight_outlined, span: 1, warm: false),
      (
        label: 'Target',
        value: (_targetMode == 'none' || _targetMode == null)
            ? 'None'
            : '${_disp(_target)} ${_metric ? 'kg' : 'lb'}',
        step: _steps.indexOf('body'),
        icon: Icons.flag_circle_outlined,
        span: 1,
        warm: false
      ),
      (label: 'Week', value: '$_dayCount days', step: _steps.indexOf('days'), icon: Icons.calendar_month_outlined, span: 1, warm: false),
      (
        label: 'Training age',
        value: switch (_experience) {
          'beginner' => 'Under 6 months',
          'intermediate' => '6 months to 2 years',
          'advanced' => 'Over 2 years',
          _ => 'Not picked',
        },
        step: _steps.indexOf('experience'),
        icon: Icons.timeline_outlined,
        span: 1,
        warm: false
      ),
      (
        label: 'Where you train',
        value: switch (_environment) {
          'commercial_gym' => 'Commercial gym',
          'home_gym' => 'Home gym',
          'bodyweight_only' => 'No equipment',
          _ => 'Not picked',
        },
        step: _steps.indexOf('place'),
        icon: Icons.place_outlined,
        span: 1,
        warm: false
      ),
      (label: 'Bench start', value: _benched ? '${_n(_benchTotal)} kg' : 'Bar only', step: _steps.indexOf('bar'), icon: Icons.fitness_center, span: 1, warm: false),
      (label: 'Split', value: _splitLabel(), step: _steps.indexOf('days'), icon: Icons.view_week_outlined, span: 2, warm: false),
      (label: 'Protein', value: '${(_bw * 1.8).round()} g a day', step: _steps.indexOf('body'), icon: Icons.restaurant, span: 2, warm: false),
      (
        label: 'Working around',
        value: (_flags.isNotEmpty || _painCtrl.text.trim().isNotEmpty)
            ? [
                _flags.map((f) => f.label).join(', '),
                _painCtrl.text.trim(),
              ].where((x) => x.isNotEmpty).join(' · ')
            : 'Nothing flagged',
        step: _steps.indexOf('map'),
        icon: Icons.healing_outlined,
        span: 2,
        warm: _flags.isNotEmpty || _painCtrl.text.trim().isNotEmpty
      ),
    ];
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: [
        for (final t in tiles)
          Pressable(
            onTap: () => setState(() => _step = t.step),
            child: Container(
              width: t.span == 2 ? double.infinity : _halfTileWidth(context),
              constraints: BoxConstraints(minHeight: t.span == 2 ? 0 : 92),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
              decoration: BoxDecoration(
                color: t.warm ? AppColors.warn.withValues(alpha: 0.07) : AppColors.surface,
                border: Border.all(
                    color: t.warm ? AppColors.warn.withValues(alpha: 0.45) : AppColors.border),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(t.icon, size: 15, color: t.warm ? AppColors.warn : AppColors.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(t.label.toUpperCase(),
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 9.5,
                                letterSpacing: 0.7,
                                color: AppColors.textFaint)),
                      ),
                      const Icon(Icons.edit, size: 13, color: AppColors.inactiveFill),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(t.value,
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: t.span == 2 ? FontWeight.w500 : FontWeight.w700,
                          fontSize: t.span == 2 ? 13.5 : 20,
                          height: 1.25,
                          color: t.value == 'Not picked' ? AppColors.textFaint : AppColors.textPrimary)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  double _halfTileWidth(BuildContext context) =>
      (MediaQuery.of(context).size.width - 48 - 9) / 2;

  String _splitLabel() {
    for (final o in _splitOptions) {
      if (o.$2 == _split) return o.$1;
    }
    return _split == null ? 'Not picked' : 'Full body';
  }

  // ── building ──────────────────────────────────────────────────────────────
  Widget _buildingView() {
    const lines = [
      ('Reading your goal', Icons.check_circle),
      ('Fitting your days into a split', Icons.check_circle),
      ('Setting starting loads', Icons.check_circle),
      ('Routing around what hurts', Icons.check_circle),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 0, 30, 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _RisingBars(),
            const SizedBox(height: 26),
            const Text('Writing your first week',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 24,
                    height: 1.2,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 22),
            for (var i = 0; i < lines.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(
                        _build > i ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 17,
                        color: _build > i ? AppColors.accent : AppColors.inactiveFill),
                    const SizedBox(width: 10),
                    Text(lines[i].$1,
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 12.5,
                            color: _build > i ? AppColors.textPrimary : AppColors.inactiveFill)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── shared bits ───────────────────────────────────────────────────────────
  Widget _unitToggle() {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, metric) in [('Kilograms', true), ('Pounds', false)]) ...[
            Pressable(
              onTap: () => setState(() => _metric = metric),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                    color: _metric == metric ? AppColors.accent : AppColors.surface,
                    borderRadius: BorderRadius.circular(20)),
                child: Text(label,
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 11.5,
                        color: _metric == metric ? AppColors.onAccent : AppColors.textMuted)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) => Pressable(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border)),
          child: Icon(icon, size: 20, color: AppColors.accent),
        ),
      );

  Widget _circleBtnSmall(IconData icon, VoidCallback onTap) => Pressable(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: const BoxDecoration(color: AppColors.page, shape: BoxShape.circle),
          child: Icon(icon, size: 18, color: AppColors.textMuted),
        ),
      );

  Widget _smallRound(IconData icon, VoidCallback onTap) => Pressable(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
              color: AppColors.page,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border)),
          child: Icon(icon, size: 17, color: AppColors.textMuted),
        ),
      );

  Widget _leftAccentBox({String? title, required String body}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(left: BorderSide(color: AppColors.accent, width: 2)),
          borderRadius: BorderRadius.only(
              topRight: Radius.circular(14), bottomRight: Radius.circular(14)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(title,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 12.5,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 5),
            ],
            Text(body,
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: title == null ? 12 : 11,
                    height: 1.55,
                    color: title == null ? AppColors.textSecondary : AppColors.textMuted)),
          ],
        ),
      );

  Widget _primaryButton(
          {required String label, required bool enabled, required VoidCallback onTap}) =>
      Pressable(
        haptic: PressFx.medium,
        onTap: enabled ? onTap : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 17),
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: enabled ? AppColors.accent : AppColors.border,
              borderRadius: BorderRadius.circular(26)),
          child: Text(label,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: enabled ? AppColors.onAccent : AppColors.textFaint)),
        ),
      );

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

class _MapDot extends StatelessWidget {
  final bool on;
  const _MapDot({required this.on});
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: on ? 16 : 11,
      height: on ? 16 : 11,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? AppColors.warn : AppColors.textPrimary.withValues(alpha: 0.22),
        border: Border.all(
            color: on ? AppColors.warn : AppColors.textPrimary.withValues(alpha: 0.35)),
      ),
    );
  }
}

class _RisingBars extends StatefulWidget {
  const _RisingBars();
  @override
  State<_RisingBars> createState() => _RisingBarsState();
}

class _RisingBarsState extends State<_RisingBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  static const _heights = [26.0, 46.0, 64.0, 38.0, 22.0];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 70,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < _heights.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Builder(builder: (context) {
                final phase = (_c.value + i * 0.15) % 1.0;
                final scale = 0.6 + 0.4 * (1 - (phase - 0.5).abs() * 2);
                return Container(
                  width: 10,
                  height: _heights[i] * scale,
                  decoration: BoxDecoration(
                      color: AppColors.accent, borderRadius: BorderRadius.circular(3)),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

/// A dashed-border wrapper for the "you choose" card.
class DottedBorderRow extends StatelessWidget {
  final Widget child;
  final bool selected;
  const DottedBorderRow({super.key, required this.child, required this.selected});
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(
          color: selected ? AppColors.accent : const Color(0xFF332D29)),
      child: Padding(padding: const EdgeInsets.all(1), child: child),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  _DashedBorderPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(17));
    final path = Path()..addRRect(rrect);
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
