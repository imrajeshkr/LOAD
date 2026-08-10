import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/units.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';

const _goalOptions = [
  ('Build muscle', 'Add size and strength'),
  ('Lose fat', 'Lean out while keeping muscle'),
  ('Recomposition', 'Lose fat and build muscle together'),
  ('General health', 'Stay fit and consistent'),
  ('Strength', 'Move heavier weight over time'),
];
const _experienceOptions = ['Beginner', 'Intermediate', 'Advanced'];
const _environmentOptions = [
  ('Commercial gym', 'Full racks, machines, dumbbells'),
  ('Home gym', 'Whatever you have at home'),
  ('Bodyweight only', 'No equipment needed'),
];
const _splitOptions = [
  ('Push / Pull / Legs', 'Three-way split, 3–6 days'),
  ('Upper / Lower', 'Two-way split, 4 days'),
  ('Full body', 'Everything each session, 2–4 days'),
  ('No preference', "You pick what fits my goal"),
];

/// Seven-step intake. The coach asks rather than presenting a form dump —
/// one decision per screen, with a review at the end before anything is saved.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  static const _totalSteps = 7; // 0..6, last is review
  int _step = 0;
  bool _generating = false;

  final _weightCtrl = TextEditingController();
  final _targetWeightCtrl = TextEditingController();
  final _injuriesCtrl = TextEditingController();

  @override
  void dispose() {
    _weightCtrl.dispose();
    _targetWeightCtrl.dispose();
    _injuriesCtrl.dispose();
    super.dispose();
  }

  bool _canAdvance(AppState state) {
    switch (_step) {
      case 0:
        return state.profile.goal != null;
      case 1:
        return true; // units always has a default
      case 2:
        return double.tryParse(_weightCtrl.text.trim()) != null;
      case 3:
        return state.profile.experience != null;
      case 4:
        return state.profile.environment != null;
      case 5:
        return true; // injuries optional
      case 6:
        return state.profile.splitPref != null;
      default:
        return true;
    }
  }

  Future<void> _next(AppState state) async {
    final units = state.profile.units;

    if (_step == 2) {
      final w = double.tryParse(_weightCtrl.text.trim());
      final t = double.tryParse(_targetWeightCtrl.text.trim());
      state.profile.currentWeightKg = w == null ? null : units.toKg(w);
      state.profile.targetWeightKg = t == null ? null : units.toKg(t);
    }
    if (_step == 5) {
      state.profile.injuries = _injuriesCtrl.text.trim();
    }

    if (_step >= _totalSteps) {
      setState(() => _generating = true);
      await state.saveProfile();
      // Seed the first weigh-in so the Progress chart isn't empty on day one.
      if (state.profile.currentWeightKg != null) {
        await state.logWeight(state.profile.currentWeightKg!);
      }
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) setState(() => _generating = false);
      return;
    }
    setState(() => _step++);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (_generating) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.accent, strokeWidth: 3),
              SizedBox(height: 18),
              Text(
                'Building your plan…',
                style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  for (var i = 0; i <= _totalSteps; i++)
                    Expanded(
                      child: Container(
                        margin: EdgeInsets.only(right: i == _totalSteps ? 0 : 5),
                        height: 4,
                        decoration: BoxDecoration(
                          color: i <= _step ? AppColors.accent : AppColors.track,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
                children: [_buildStep(state)],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  if (_step > 0) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _step--),
                        child: const Text('Back'),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _canAdvance(state) ? () => _next(state) : null,
                      child: Text(_step >= _totalSteps ? 'Build my plan' : 'Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(AppState state) {
    final units = state.profile.units;

    switch (_step) {
      case 0:
        return _Step(
          index: 1,
          total: _totalSteps + 1,
          title: "What are you training for?",
          subtitle: "I'll shape the whole plan around this.",
          child: Column(
            children: [
              for (final (label, sub) in _goalOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SelectableRow(
                    label: label,
                    subtitle: sub,
                    selected: state.profile.goal == label,
                    onTap: () => setState(() => state.profile.goal = label),
                  ),
                ),
            ],
          ),
        );

      case 1:
        return _Step(
          index: 2,
          total: _totalSteps + 1,
          title: 'Which units do you think in?',
          subtitle: "Everything in the app follows this — I won't assume.",
          child: Column(
            children: [
              for (final u in UnitSystem.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SelectableRow(
                    label: u.title,
                    subtitle: u.subtitle,
                    selected: state.profile.units == u,
                    onTap: () => setState(() => state.profile.units = u),
                  ),
                ),
            ],
          ),
        );

      case 2:
        return _Step(
          index: 3,
          total: _totalSteps + 1,
          title: 'Where are you starting?',
          subtitle: 'So your plan and progress charts start from something real.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FieldLabel('Current weight (${units.weightLabel})'),
              TextField(
                controller: _weightCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(hintText: units == UnitSystem.metric ? '80' : '176'),
              ),
              const SizedBox(height: 18),
              _FieldLabel('Target weight (${units.weightLabel}) — optional'),
              TextField(
                controller: _targetWeightCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(hintText: units == UnitSystem.metric ? '76' : '168'),
              ),
            ],
          ),
        );

      case 3:
        return _Step(
          index: 4,
          total: _totalSteps + 1,
          title: 'How long have you been training?',
          subtitle: 'This sets your starting loads and how fast we progress.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _experienceOptions)
                    ChoiceChipButton(
                      label: e,
                      selected: state.profile.experience == e,
                      onTap: () => setState(() => state.profile.experience = e),
                    ),
                ],
              ),
              const SizedBox(height: 26),
              _FieldLabel('Days per week you can train'),
              AppCard(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _CircleStep(
                      icon: Icons.remove_rounded,
                      onTap: () => setState(() => state.profile.daysPerWeek =
                          (state.profile.daysPerWeek - 1).clamp(1, 7)),
                    ),
                    Text(
                      '${state.profile.daysPerWeek}',
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w800,
                        fontSize: 26,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    _CircleStep(
                      icon: Icons.add_rounded,
                      onTap: () => setState(() => state.profile.daysPerWeek =
                          (state.profile.daysPerWeek + 1).clamp(1, 7)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case 4:
        return _Step(
          index: 5,
          total: _totalSteps + 1,
          title: 'Where will you be training?',
          subtitle: "I'll only program what you can actually reach.",
          child: Column(
            children: [
              for (final (label, sub) in _environmentOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SelectableRow(
                    label: label,
                    subtitle: sub,
                    selected: state.profile.environment == label,
                    onTap: () => setState(() => state.profile.environment = label),
                  ),
                ),
            ],
          ),
        );

      case 5:
        return _Step(
          index: 6,
          total: _totalSteps + 1,
          title: 'Anything I should work around?',
          subtitle: 'Injuries, niggles, movements that hurt. I\'ll avoid them and '
              'flag anything that conflicts. Leave blank if none.',
          child: TextField(
            controller: _injuriesCtrl,
            maxLines: 4,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: AppColors.textBody,
            ),
            decoration: const InputDecoration(
              hintText: 'e.g. cranky left shoulder, avoid heavy overhead pressing',
            ),
          ),
        );

      case 6:
        return _Step(
          index: 7,
          total: _totalSteps + 1,
          title: 'How do you like to split your week?',
          subtitle: "No strong opinion? Pick the last one and I'll choose.",
          child: Column(
            children: [
              for (final (label, sub) in _splitOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SelectableRow(
                    label: label,
                    subtitle: sub,
                    selected: state.profile.splitPref == label,
                    onTap: () => setState(() => state.profile.splitPref = label),
                  ),
                ),
            ],
          ),
        );

      default:
        final w = double.tryParse(_weightCtrl.text.trim());
        final t = double.tryParse(_targetWeightCtrl.text.trim());
        return _Step(
          index: 8,
          total: _totalSteps + 1,
          title: 'Quick review',
          subtitle: 'Anything look wrong? Go back and change it.',
          child: AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                _RecapRow('Goal', state.profile.goal ?? '—'),
                _RecapRow('Units', units.title),
                _RecapRow('Current weight',
                    w == null ? '—' : '${w.toStringAsFixed(1)} ${units.weightLabel}'),
                _RecapRow('Target weight',
                    t == null ? 'Not set' : '${t.toStringAsFixed(1)} ${units.weightLabel}'),
                _RecapRow('Experience', state.profile.experience ?? '—'),
                _RecapRow('Days per week', '${state.profile.daysPerWeek}'),
                _RecapRow('Training at', state.profile.environment ?? '—'),
                _RecapRow('Injuries',
                    _injuriesCtrl.text.trim().isEmpty ? 'None' : _injuriesCtrl.text.trim()),
                _RecapRow('Split', state.profile.splitPref ?? '—', isLast: true),
              ],
            ),
          ),
        );
    }
  }
}

class _Step extends StatelessWidget {
  final int index;
  final int total;
  final String title;
  final String? subtitle;
  final Widget child;

  const _Step({
    required this.index,
    required this.total,
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step $index of $total',
            style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 8),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        if (subtitle != null) ...[
          const SizedBox(height: 10),
          Text(
            subtitle!,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 22),
        child,
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _CircleStep extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleStep({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.inputFill,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, size: 20, color: AppColors.textBody),
        ),
      ),
    );
  }
}

class _RecapRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLast;
  const _RecapRow(this.label, this.value, {this.isLast = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: isLast ? Colors.transparent : AppColors.divider),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                height: 1.4,
                color: AppColors.textBody,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
