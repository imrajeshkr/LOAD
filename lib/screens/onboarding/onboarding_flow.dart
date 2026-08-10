import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/option_chip.dart';

const _goalOptions = ['Build muscle', 'Lose fat', 'Recomposition', 'General health', 'Strength'];
const _experienceOptions = ['Beginner', 'Intermediate', 'Advanced'];
const _environmentOptions = ['Home gym', 'Commercial gym', 'Bodyweight only'];
const _splitOptions = ['Push / Pull / Legs', 'Upper / Lower', 'Full body', 'No preference'];

class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  int step = 0;
  static const totalSteps = 6; // 0..5, step 5 is the recap
  bool _generating = false;

  final _weightCtrl = TextEditingController();
  final _targetWeightCtrl = TextEditingController();
  final _injuriesCtrl = TextEditingController();

  bool get _canAdvance {
    final p = context.read<AppState>().profile;
    switch (step) {
      case 0:
        return p.goal != null;
      case 1:
        return _weightCtrl.text.trim().isNotEmpty;
      case 2:
        return p.experience != null;
      case 3:
        return p.environment != null;
      case 4:
        return true; // injuries optional
      case 5:
        return p.splitPref != null;
      default:
        return true;
    }
  }

  Future<void> _next() async {
    final state = context.read<AppState>();
    if (step == 1) {
      state.profile.currentWeight = double.tryParse(_weightCtrl.text.trim());
      state.profile.targetWeight = double.tryParse(_targetWeightCtrl.text.trim());
    }
    if (step == 4) {
      state.profile.injuries = _injuriesCtrl.text.trim();
    }
    if (step >= totalSteps) {
      setState(() => _generating = true);
      await state.saveProfile();
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) setState(() => _generating = false);
      return;
    }
    setState(() => step++);
  }

  void _back() => setState(() => step = (step - 1).clamp(0, totalSteps));

  @override
  Widget build(BuildContext context) {
    if (_generating) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.accent),
              SizedBox(height: 16),
              Text('BUILDING YOUR PLAN…', style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            ],
          ),
        ),
      );
    }

    final state = context.watch<AppState>();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: List.generate(totalSteps + 1, (i) {
                  return Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      height: 3,
                      color: i <= step ? AppColors.accent : AppColors.border,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 28),
              Expanded(
                child: SingleChildScrollView(
                  child: _buildStep(state),
                ),
              ),
              Row(
                children: [
                  if (step > 0)
                    Expanded(
                      child: OutlinedButton(onPressed: _back, child: const Text('Back')),
                    ),
                  if (step > 0) const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _canAdvance ? _next : null,
                      child: Text(step >= totalSteps ? 'Build my plan' : 'Next'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(AppState state) {
    switch (step) {
      case 0:
        return _StepShell(
          label: 'STEP 1 / 6',
          title: "What's the goal?",
          child: Column(
            children: _goalOptions
                .map((g) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: OptionChip(
                        label: g,
                        selected: state.profile.goal == g,
                        onTap: () => setState(() => state.profile.goal = g),
                      ),
                    ))
                .toList(),
          ),
        );
      case 1:
        return _StepShell(
          label: 'STEP 2 / 6',
          title: 'Body basics',
          subtitle: 'So your plan and progress chart start from somewhere real.',
          child: Column(
            children: [
              TextField(
                controller: _weightCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'Current weight (lb)'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _targetWeightCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'Target weight (lb) — optional'),
              ),
            ],
          ),
        );
      case 2:
        return _StepShell(
          label: 'STEP 3 / 6',
          title: 'Training background',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('EXPERIENCE', style: TextStyle(color: AppColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _experienceOptions
                    .map((e) => SizedBox(
                          width: 100,
                          child: OptionChip(
                            label: e,
                            compact: true,
                            selected: state.profile.experience == e,
                            onTap: () => setState(() => state.profile.experience = e),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 22),
              const Text('DAYS / WEEK', style: TextStyle(color: AppColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() => state.profile.daysPerWeek = (state.profile.daysPerWeek - 1).clamp(1, 7)),
                    icon: const Icon(Icons.remove),
                  ),
                  Text('${state.profile.daysPerWeek}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  IconButton(
                    onPressed: () => setState(() => state.profile.daysPerWeek = (state.profile.daysPerWeek + 1).clamp(1, 7)),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ],
          ),
        );
      case 3:
        return _StepShell(
          label: 'STEP 4 / 6',
          title: 'Where do you train?',
          child: Column(
            children: _environmentOptions
                .map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: OptionChip(
                        label: e,
                        selected: state.profile.environment == e,
                        onTap: () => setState(() => state.profile.environment = e),
                      ),
                    ))
                .toList(),
          ),
        );
      case 4:
        return _StepShell(
          label: 'STEP 5 / 6',
          title: 'Any injuries or limits?',
          subtitle: "So the plan avoids them from day one, and I'll flag exercises that conflict. Leave blank if none.",
          child: TextField(
            controller: _injuriesCtrl,
            maxLines: 4,
            decoration: const InputDecoration(hintText: 'e.g. bad left shoulder, avoid overhead pressing'),
          ),
        );
      case 5:
        return _StepShell(
          label: 'STEP 6 / 6',
          title: 'Split preference?',
          child: Column(
            children: _splitOptions
                .map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: OptionChip(
                        label: s,
                        selected: state.profile.splitPref == s,
                        onTap: () => setState(() => state.profile.splitPref = s),
                      ),
                    ))
                .toList(),
          ),
        );
      default:
        return _StepShell(
          label: 'REVIEW',
          title: "Here's what I've got",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _recapRow('Goal', state.profile.goal ?? '—'),
              _recapRow('Current weight', _weightCtrl.text.isEmpty ? '—' : '${_weightCtrl.text} lb'),
              _recapRow('Experience', state.profile.experience ?? '—'),
              _recapRow('Days / week', '${state.profile.daysPerWeek}'),
              _recapRow('Environment', state.profile.environment ?? '—'),
              _recapRow('Injuries', _injuriesCtrl.text.isEmpty ? 'None' : _injuriesCtrl.text),
              _recapRow('Split', state.profile.splitPref ?? '—'),
            ],
          ),
        );
    }
  }

  Widget _recapRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 120, child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13))),
            Expanded(child: Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600))),
          ],
        ),
      );
}

class _StepShell extends StatelessWidget {
  final String label;
  final String title;
  final String? subtitle;
  final Widget child;

  const _StepShell({required this.label, required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.6)),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
        if (subtitle != null) ...[
          const SizedBox(height: 10),
          Text(subtitle!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5)),
        ],
        const SizedBox(height: 24),
        child,
      ],
    );
  }
}
