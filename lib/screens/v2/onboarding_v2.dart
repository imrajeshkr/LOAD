import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../widgets/ruler_picker.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../services/diagnostics.dart';
import '../../services/failure.dart';
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

// 'setup' merges training age and training place: two short questions that
// each fit a row of three, and that together describe one thing — what this
// app is allowed to prescribe you. The bench-calibration and injury-map steps
// were removed; their columns remain in the database.
const _steps = ['goal', 'body', 'days', 'setup', 'review'];

/// Artwork for the goals the first screen offers. Profile lists all five and
/// needs none of this — its sheet renders `GoalV2.label` alone.
const _goalAsset = {
  GoalV2.buildMuscle: 'assets/goals/build-muscle.svg',
  GoalV2.loseFat: 'assets/goals/lose-fat.svg',
  GoalV2.generalHealth: 'assets/goals/stay-consistent.svg',
};

class _OnboardingV2State extends State<OnboardingV2> {
  String _screen = 'intake'; // intake | building | done
  int _step = 0;

  // answers
  final List<GoalV2> _goals = [];
  bool _coachChoice = false;
  bool _metric = true;
  double _bw = 80;
  double _heightCm = 170;
  /// Null until the lifter overrides the direction BMI implies. Asking
  /// someone to pick a direction they have already told us — by giving a
  /// height and a weight — is a question with an answer already in it.
  String? _dirOverride; // lose | same | gain
  final List<int> _weekdays = [1, 3, 5]; // ISO
  String? _split; // full_body | upper_lower | push_pull_legs
  String? _experience; // beginner | intermediate | advanced
  String? _environment; // commercial_gym | home_gym | bodyweight_only

  int _build = 0;
  Timer? _buildTimer;
  Failure? _error;

  @override
  void dispose() {
    _buildTimer?.cancel();
    super.dispose();
  }

  // ── derived ───────────────────────────────────────────────────────────────
  String get _stepId => _steps[_step];
  int get _dayCount => _weekdays.length;

  double get _bmi =>
      _heightCm > 0 ? _bw / ((_heightCm / 100) * (_heightCm / 100)) : 0;

  /// The bands the BMI meter already draws (WHO Asian cut-points), read as a
  /// direction. Under is the only case that argues for gaining.
  String get _targetMode =>
      _dirOverride ?? (_bmi < 18.5 ? 'gain' : _bmi < 23 ? 'same' : 'lose');

  double get _target => switch (_targetMode) {
        'lose' => (_bw - 4).clamp(35, 180),
        'gain' => (_bw + 4).clamp(35, 180),
        _ => _bw,
      };

  int _disp(double kg) => _metric ? kg.round() : (kg * 2.2046).round();

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
        'body' => true,
        'days' => _dayCount > 0 && _split != null,
        'setup' => _experience != null && _environment != null,
        _ => true,
      };

  String get _coachLine {
    switch (_stepId) {
      case 'goal':
        if (_coachChoice) return "Fine by me — I'll start you on general strength and adjust.";
        if (_goals.isEmpty) return 'This one shapes the whole plan.';
        if (_goals.length == 1) return 'Good. Everything downstream bends toward ${_goals.first.label.toLowerCase()}.';
        return '${_goals.first.label.toLowerCase()} leads, the rest ride along.';
      case 'body':
        if (_targetMode == 'same') return 'Holding steady. I will train you to recomposition.';
        return 'Roughly ${(_bw - _target).abs().round()} kg to ${_targetMode == 'lose' ? 'lose' : 'gain'}, at a sane pace.';
      case 'days':
        if (_dayCount == 0) return 'Pick at least one. Even one real day beats a perfect plan you skip.';
        return '$_dayCount days means I can give you ${_dayCount >= 4 ? 'a proper split' : 'full-body sessions'}.';
      case 'setup':
        if (_experience != null && _environment != null) {
          return 'That is everything I need to build the week.';
        }
        return 'Two taps and the plan knows what it may ask of you.';
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
      heightCm: _heightCm,
      targetDirection: switch (_targetMode) {
        'lose' => 'lose',
        'gain' => 'gain',
        'same' => 'maintain',
        _ => 'declined',
      },
      targetWeightKg: _target,
      weekdaysIso: List.of(_weekdays)..sort(),
      splitPreference: _split ?? 'full_body',
      experience: _experience ?? 'beginner',
      environment: _environment ?? 'commercial_gym',
      // Nothing asks for these any more. A standard bar and "never benched"
      // are the conservative reading: empty bar on barbell work, 40% of the
      // catalogue default elsewhere. Linear progression closes that in a
      // session or two, where guessing high would have someone fail set one.
      barWeightKg: 20,
      hasBenched: false,
      benchStartKg: null,
      // The injury step is gone. user_constraints and the derived joint data
      // behind it stay, so re-asking later costs nothing.
      flags: const [],
      otherPain: '',
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
    } catch (e, st) {
      _buildTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _error = classifyFailure('onboarding.submit', e, st);
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
                        // The failure is classified, not stringified. Showing
                        // the raw exception here once saved a real diagnosis —
                        // but it also put a Postgres constraint name on a
                        // stranger's screen, so the exception now goes to the
                        // log and only a debug build renders it.
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_error!.title,
                                style: const TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.warn)),
                            const SizedBox(height: 3),
                            Text(
                                Diagnostics.showRawErrors
                                    ? _error!.detail
                                    : _error!.message,
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  (String, String) _titleFor(String id) => switch (id) {
        'goal' => ('What are we chasing?', ''),
        'body' => ('Where are you starting?', ''),
        'days' => ('Which days are yours?', 'Tap the days you can actually show up. Be honest, not ambitious.'),
        'setup' => ('How you train', ''),
        _ => ('Look right?', 'Tap anything to change it. Nothing is saved until you build.'),
      };

  Widget _stepBody() => switch (_stepId) {
        'goal' => _goalStep(),
        'body' => _bodyStep(),
        'days' => _daysStep(),
        'setup' => _setupStep(),
        _ => _reviewStep(),
      };

  // ── step: goal ──────────────────────────────────────────────────────────
  Widget _goalStep() {
    // Three goals plus the coach's-choice tile. "Get stronger" and
    // "Rehab / return" are deliberately absent: five options to weigh before
    // you have trained once is a lot, and both remain reachable from Profile,
    // which lists every goal.
    const tiles = [GoalV2.buildMuscle, GoalV2.loseFat, GoalV2.generalHealth];
    return Column(
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 11,
          crossAxisSpacing: 11,
          childAspectRatio: 0.94,
          children: [
            for (final g in tiles) _goalCard(g),
            _coachChoiceCard(),
          ],
        ),
        if (_goals.length > 1) ...[
          const SizedBox(height: 14),
          Text('${_goals.first.label} leads.',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 11,
                  color: AppColors.textFaint)),
        ],
      ],
    );
  }

  Widget _goalCard(GoalV2 g) {
    final sel = _goals.contains(g);
    return _goalTile(
      asset: _goalAsset[g]!,
      label: g.label,
      selected: sel,
      leads: sel && _goals.first == g,
      onTap: () => setState(() {
        _coachChoice = false;
        sel ? _goals.remove(g) : _goals.add(g);
      }),
    );
  }

  Widget _coachChoiceCard() {
    return _goalTile(
      asset: 'assets/goals/coach-choice.svg',
      label: "I don't know",
      selected: _coachChoice,
      leads: false,
      onTap: () => setState(() {
        _coachChoice = true;
        _goals.clear();
      }),
    );
  }

  /// Icon over label, nothing else. Each goal used to carry a subtitle
  /// explaining it; the pictures do that job, and five stacked paragraphs made
  /// the first screen of the app read like a form.
  Widget _goalTile({
    required String asset,
    required String label,
    required bool selected,
    required bool leads,
    required VoidCallback onTap,
  }) {
    final fg = selected ? AppColors.accent : AppColors.textMuted;
    return Pressable(
      haptic: PressFx.light,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
          border: Border.all(color: selected ? AppColors.accent : AppColors.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset(asset,
                      width: 44,
                      height: 44,
                      colorFilter: ColorFilter.mode(fg, BlendMode.srcIn)),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 13.5,
                            height: 1.25,
                            color: selected
                                ? AppColors.textPrimary
                                : AppColors.textSecondary)),
                  ),
                ],
              ),
            ),
            if (leads)
              const Positioned(
                top: 10,
                right: 10,
                child: Icon(Icons.star_rounded, size: 16, color: AppColors.accent),
              ),
          ],
        ),
      ),
    );
  }

  /// A single-select card, styled like the goal cards. Used by the experience
  /// and place steps.
  Widget _setupStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _setupLabel('HOW LONG HAVE YOU TRAINED'),
        Row(children: [
          Expanded(child: _levelTile('Under\n6 months', 'beginner', 1)),
          const SizedBox(width: 9),
          Expanded(child: _levelTile('6 months\nto 2 years', 'intermediate', 2)),
          const SizedBox(width: 9),
          Expanded(child: _levelTile('Over\n2 years', 'advanced', 3)),
        ]),
        const SizedBox(height: 22),
        _setupLabel('WHAT YOU WILL TRAIN WITH'),
        Row(children: [
          Expanded(child: _kitTile('Full gym', 'commercial_gym', 'full-gym')),
          const SizedBox(width: 10),
          Expanded(child: _kitTile('Dumbbells', 'home_gym', 'dumbbells')),
          const SizedBox(width: 10),
          Expanded(child: _kitTile('Bodyweight', 'bodyweight_only', 'bodyweight')),
        ]),
      ],
    );
  }

  Widget _setupLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 9),
        child: Text(text,
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 9.5,
                letterSpacing: 0.9,
                color: AppColors.textFaint)),
      );

  /// Training age drawn as filled bars rather than described. "Under 6 months"
  /// is hard to illustrate and easy to rank, so the picture is the ranking.
  Widget _levelTile(String label, String value, int filled) {
    final sel = _experience == value;
    return _setupTile(
      selected: sel,
      label: label,
      leading: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 1; i <= 3; i++) ...[
            Container(
              width: 7,
              height: 9.0 + i * 6,
              decoration: BoxDecoration(
                color: i <= filled
                    ? (sel ? AppColors.accent : AppColors.textMuted)
                    : (sel ? AppColors.accent.withValues(alpha: 0.22) : AppColors.border),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (i < 3) const SizedBox(width: 3),
          ],
        ],
      ),
      onTap: () => setState(() => _experience = value),
    );
  }

  /// The kit, not the room.
  ///
  /// This asked "Where do you train?" with Gym / Home / Bodyweight, which
  /// is two questions wearing one hat: the tense is ambiguous (where you
  /// have trained, or where you are about to?) and home and bodyweight are
  /// not alternatives — you can train at home with dumbbells. What the
  /// generator actually needs is the equipment it may prescribe, so that
  /// is what the tiles say.
  Widget _kitTile(String label, String value, String asset) {
    final sel = _environment == value;
    return _setupTile(
      selected: sel,
      label: label,
      height: 138,
      leadingBox: 62,
      leading: SvgPicture.asset('assets/environment/$asset.svg',
          width: 58,
          height: 58,
          colorFilter: ColorFilter.mode(
              sel ? AppColors.accent : AppColors.textMuted, BlendMode.srcIn)),
      onTap: () => setState(() => _environment = value),
    );
  }

  Widget _setupTile({
    required bool selected,
    required String label,
    required Widget leading,
    required VoidCallback onTap,
    double height = 96,
    double leadingBox = 28,
  }) {
    return Pressable(
      haptic: PressFx.light,
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
          border: Border.all(color: selected ? AppColors.accent : AppColors.border),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(height: leadingBox, child: Center(child: leading)),
            const SizedBox(height: 10),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 11.5,
                    height: 1.25,
                    color: selected ? AppColors.textPrimary : AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _bodyStep() {
    final bmi = _heightCm > 0 ? _bw / ((_heightCm / 100) * (_heightCm / 100)) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _unitToggle()),
        const SizedBox(height: 18),
        _measure(
          label: 'Weight',
          reading: _metric ? '${_disp(_bw)} kg' : '${_disp(_bw * 2.20462)} lb',
          value: _metric ? _bw : _bw * 2.20462,
          min: _metric ? 35 : 77,
          max: _metric ? 180 : 397,
          step: _metric ? 0.5 : 1,
          onChanged: (v) => setState(() => _bw = _metric ? v : v / 2.20462),
        ),
        const SizedBox(height: 14),
        _measure(
          label: 'Height',
          reading: _metric ? '${_heightCm.round()} cm' : _feetInches(_heightCm),
          value: _metric ? _heightCm : _heightCm / 2.54,
          min: _metric ? 130 : 51,
          max: _metric ? 215 : 85,
          step: 1,
          onChanged: (v) => setState(() => _heightCm = _metric ? v : v * 2.54),
        ),
        const SizedBox(height: 20),
        _bmiCard(bmi),
        const SizedBox(height: 14),
        _targetCard(),
        const SizedBox(height: 12),
        _proteinCard(),
      ],
    );
  }

  /// A reading and the ruler that sets it. The number is the headline; the
  /// ruler is the control. No caption — the ticks explain themselves.
  Widget _measure({
    required String label,
    required String reading,
    required double value,
    required double min,
    required double max,
    required double step,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 9.5,
                  letterSpacing: 0.9,
                  color: AppColors.textFaint)),
          const SizedBox(height: 2),
          Text(reading,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 34,
                  height: 1.15,
                  letterSpacing: -1,
                  color: AppColors.accent)),
          RulerPicker(
            value: value.clamp(min, max),
            min: min,
            max: max,
            step: step,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  String _feetInches(double cm) {
    final total = (cm / 2.54).round();
    return "${total ~/ 12}'${total % 12}\"";
  }

  /// BMI as context, not a verdict. The band shows where the number sits; the
  /// caveat is there because this app is for people building muscle, and
  /// muscle raises BMI without meaning what the guideline means by it.
  Widget _bmiCard(double bmi) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(bmi.toStringAsFixed(1),
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                      height: 1,
                      letterSpacing: -0.8,
                      color: AppColors.textPrimary)),
              const SizedBox(width: 7),
              Text('BMI · ${BmiBand.label(bmi)}',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 12,
                      color: AppColors.textMuted)),
            ],
          ),
          const SizedBox(height: 10),
          BmiBand(bmi: bmi),
        ],
      ),
    );
  }

  /// The direction, arrived at pre-selected. "No target" is gone: it opted a
  /// lifter out of the one number the plan is allowed to move, and every
  /// answer it produced was one the height and weight already gave.
  Widget _targetCard() {
    return Row(
      children: [
        Expanded(child: _dirTile('Lose', Icons.trending_down_rounded, 'lose')),
        const SizedBox(width: 9),
        Expanded(child: _dirTile('Stay', Icons.trending_flat_rounded, 'same')),
        const SizedBox(width: 9),
        Expanded(child: _dirTile('Gain', Icons.trending_up_rounded, 'gain')),
      ],
    );
  }

  Widget _dirTile(String label, IconData icon, String mode) {
    final sel = _targetMode == mode;
    return Pressable(
      haptic: PressFx.light,
      onTap: () => setState(() => _dirOverride = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: sel ? AppColors.accent.withValues(alpha: 0.09) : AppColors.surface,
          border: Border.all(color: sel ? AppColors.accent : AppColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(icon, size: 21, color: sel ? AppColors.accent : AppColors.textMuted),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 12.5,
                    color: sel ? AppColors.textPrimary : AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  /// Protein drawn as the portions it takes to hit, not explained in a
  /// paragraph. Each block is 30 g — roughly a chicken breast or a scoop.
  Widget _proteinCard() {
    final grams = (_bw * 1.8).round();
    final blocks = (grams / 30).ceil().clamp(1, 9);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('$grams g',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                      height: 1,
                      color: AppColors.accent)),
              const SizedBox(width: 7),
              const Text('protein a day',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 12,
                      color: AppColors.textMuted)),
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              for (var i = 0; i < 9; i++) ...[
                Expanded(
                  child: Container(
                    height: 22,
                    decoration: BoxDecoration(
                      color: i < blocks
                          ? AppColors.accent.withValues(alpha: 0.85)
                          : AppColors.surfaceSunken,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
                if (i < 8) const SizedBox(width: 4),
              ],
            ],
          ),
          const SizedBox(height: 7),
          Text('$blocks portions of about 30 g',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 10.5,
                  color: AppColors.textFaint)),
        ],
      ),
    );
  }

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
        value: '${_disp(_target)} ${_metric ? 'kg' : 'lb'}',
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
        step: _steps.indexOf('setup'),
        icon: Icons.timeline_outlined,
        span: 1,
        warm: false
      ),
      (
        label: 'Where you train',
        value: switch (_environment) {
          'commercial_gym' => 'Full gym',
          'home_gym' => 'Dumbbells',
          'bodyweight_only' => 'Bodyweight',
          _ => 'Not picked',
        },
        step: _steps.indexOf('setup'),
        icon: Icons.place_outlined,
        span: 1,
        warm: false
      ),
      (label: 'Split', value: _splitLabel(), step: _steps.indexOf('days'), icon: Icons.view_week_outlined, span: 2, warm: false),
      (label: 'Protein', value: '${(_bw * 1.8).round()} g a day', step: _steps.indexOf('body'), icon: Icons.restaurant, span: 2, warm: false),
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
