import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/units.dart';
import '../../services/app_state.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';

const _goalOptions = [
  'Build muscle',
  'Lose fat',
  'Recomposition',
  'General health',
  'Strength',
];
const _experienceOptions = ['Beginner', 'Intermediate', 'Advanced'];
const _environmentOptions = ['Commercial gym', 'Home gym', 'Bodyweight only'];
const _splitOptions = [
  'Push / Pull / Legs',
  'Upper / Lower',
  'Full body',
  'No preference',
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TextEditingController? _injuriesCtrl;
  TextEditingController? _targetCtrl;

  @override
  void dispose() {
    _injuriesCtrl?.dispose();
    _targetCtrl?.dispose();
    super.dispose();
  }

  Future<void> _save(AppState state) async {
    state.profile.injuries = _injuriesCtrl?.text.trim() ?? '';
    final t = double.tryParse(_targetCtrl?.text.trim() ?? '');
    state.profile.targetWeightKg = t == null ? null : state.units.toKg(t);
    await state.saveProfile();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Saved.')));
  }

  Future<void> _confirmSignOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        title: Text('Sign out?', style: Theme.of(ctx).textTheme.titleLarge),
        content: const Text(
          'Your training history stays saved to your account.',
          style: TextStyle(
            fontFamily: AppTheme.fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok == true) await SupabaseService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final units = state.units;

    _injuriesCtrl ??= TextEditingController(text: state.profile.injuries);
    _targetCtrl ??= TextEditingController(
      text: state.profile.targetWeightKg == null
          ? ''
          : units.formatWeight(state.profile.targetWeightKg!, decimals: 1),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const ScreenHeader(title: 'Profile', eyebrow: 'Your coaching setup'),

        _Group(
          title: 'Units',
          child: Column(
            children: [
              for (final u in UnitSystem.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableRow(
                    label: u.title,
                    subtitle: u.subtitle,
                    selected: units == u,
                    onTap: () {
                      state.setUnits(u);
                      // Re-render the target field in the new units.
                      _targetCtrl?.text = state.profile.targetWeightKg == null
                          ? ''
                          : u.formatWeight(state.profile.targetWeightKg!, decimals: 1);
                    },
                  ),
                ),
            ],
          ),
        ),

        _Group(
          title: 'Goal',
          child: Column(
            children: [
              for (final g in _goalOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableRow(
                    label: g,
                    selected: state.profile.goal == g,
                    onTap: () => setState(() => state.profile.goal = g),
                  ),
                ),
              const SizedBox(height: 6),
              AppCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Target weight (${units.weightLabel})',
                        style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 76,
                      child: TextField(
                        controller: _targetCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.textBody,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        _Group(
          title: 'Experience',
          child: Wrap(
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
        ),

        _Group(
          title: 'Days per week',
          child: AppCard(
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
                    fontSize: 24,
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
        ),

        _Group(
          title: 'Training environment',
          child: Column(
            children: [
              for (final e in _environmentOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableRow(
                    label: e,
                    selected: state.profile.environment == e,
                    onTap: () => setState(() => state.profile.environment = e),
                  ),
                ),
            ],
          ),
        ),

        _Group(
          title: 'Split preference',
          child: Column(
            children: [
              for (final s in _splitOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableRow(
                    label: s,
                    selected: state.profile.splitPref == s,
                    onTap: () => setState(() => state.profile.splitPref = s),
                  ),
                ),
            ],
          ),
        ),

        _Group(
          title: 'Injuries and limits',
          child: TextField(
            controller: _injuriesCtrl,
            maxLines: 3,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: AppColors.textBody,
            ),
            decoration: const InputDecoration(
              hintText: 'e.g. cranky left shoulder',
              fillColor: AppColors.surface,
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _save(state),
              child: const Text('Save changes'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _confirmSignOut,
              child: const Text('Sign out'),
            ),
          ),
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final Widget child;
  const _Group({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [SectionLabel(title), child],
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
