import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/option_chip.dart';

const _goalOptions = ['Build muscle', 'Lose fat', 'Recomposition', 'General health', 'Strength'];
const _experienceOptions = ['Beginner', 'Intermediate', 'Advanced'];
const _environmentOptions = ['Home gym', 'Commercial gym', 'Bodyweight only'];
const _splitOptions = ['Push / Pull / Legs', 'Upper / Lower', 'Full body', 'No preference'];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _injuriesCtrl;
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!_initialized) {
      _injuriesCtrl = TextEditingController(text: state.profile.injuries);
      _initialized = true;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 22),
          const _Label('GOAL'),
          const SizedBox(height: 8),
          Column(
            children: _goalOptions
                .map((g) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OptionChip(label: g, selected: state.profile.goal == g, onTap: () => setState(() => state.profile.goal = g)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 18),
          const _Label('EXPERIENCE'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _experienceOptions
                .map((e) => SizedBox(width: 100, child: OptionChip(label: e, compact: true, selected: state.profile.experience == e, onTap: () => setState(() => state.profile.experience = e))))
                .toList(),
          ),
          const SizedBox(height: 18),
          const _Label('DAYS / WEEK'),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(onPressed: () => setState(() => state.profile.daysPerWeek = (state.profile.daysPerWeek - 1).clamp(1, 7)), icon: const Icon(Icons.remove)),
              Text('${state.profile.daysPerWeek}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              IconButton(onPressed: () => setState(() => state.profile.daysPerWeek = (state.profile.daysPerWeek + 1).clamp(1, 7)), icon: const Icon(Icons.add)),
            ],
          ),
          const SizedBox(height: 18),
          const _Label('ENVIRONMENT'),
          const SizedBox(height: 8),
          Column(
            children: _environmentOptions
                .map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OptionChip(label: e, selected: state.profile.environment == e, onTap: () => setState(() => state.profile.environment = e)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 18),
          const _Label('SPLIT PREFERENCE'),
          const SizedBox(height: 8),
          Column(
            children: _splitOptions
                .map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OptionChip(label: s, selected: state.profile.splitPref == s, onTap: () => setState(() => state.profile.splitPref = s)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 18),
          const _Label('INJURIES / LIMITS'),
          const SizedBox(height: 8),
          TextField(controller: _injuriesCtrl, maxLines: 3, decoration: const InputDecoration(hintText: 'e.g. bad left shoulder')),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                state.profile.injuries = _injuriesCtrl.text.trim();
                state.saveProfile();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved.')));
              },
              child: const Text('Save changes'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => SupabaseService.instance.signOut(),
              child: const Text('Sign out'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5));
}
