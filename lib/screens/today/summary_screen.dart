import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';

const _painParts = ['Shoulder', 'Elbow', 'Wrist', 'Knee', 'Back'];

class SummaryScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SummaryScreen({super.key, required this.onDone});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final _notesCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    int totalSets = 0, totalSetsTarget = 0;
    double totalVolume = 0;
    final highlights = <String>[];
    for (var i = 0; i < state.exercises.length; i++) {
      final ex = state.exercises[i];
      totalSetsTarget += ex.setsTarget;
      final sets = state.loggedSets[i] ?? [];
      totalSets += sets.length;
      for (final s in sets) {
        totalVolume += s.weight * s.reps;
      }
      if (sets.isNotEmpty) {
        final maxWeight = sets.map((s) => s.weight).reduce((a, b) => a > b ? a : b);
        if (maxWeight > ex.startingWeight) {
          highlights.add('${ex.name} — ${maxWeight.toStringAsFixed(0)} lb, up from ${ex.startingWeight.toStringAsFixed(0)} lb');
        }
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SESSION COMPLETE', style: TextStyle(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.6)),
          const SizedBox(height: 8),
          const Text('Push Day', style: TextStyle(color: AppColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _StatTile(label: 'SETS', value: '$totalSets/$totalSetsTarget')),
              const SizedBox(width: 10),
              Expanded(child: _StatTile(label: 'VOLUME', value: '${totalVolume.toStringAsFixed(0)} lb')),
            ],
          ),
          const SizedBox(height: 22),
          if (highlights.isNotEmpty) ...[
            const Text('HIGHLIGHTS', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            const SizedBox(height: 10),
            ...highlights.map((h) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                  decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.15), border: Border.all(color: AppColors.positive), borderRadius: BorderRadius.circular(10)),
                  child: Text('🏆 $h', style: const TextStyle(color: AppColors.positive, fontWeight: FontWeight.w600, fontSize: 12.5)),
                )),
            const SizedBox(height: 8),
          ],
          const Text('SESSION NOTES (OPTIONAL)', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          TextField(
            controller: _notesCtrl,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'e.g. felt strong today, bumped rest between sets'),
          ),
          const SizedBox(height: 22),
          const Text('HOW DID TODAY FEEL OVERALL?', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 10),
          Row(
            children: List.generate(5, (i) {
              final v = i + 1;
              final selected = state.sessionRpe == v;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => state.sessionRpe = selected ? null : v),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected ? AppColors.accent : Colors.transparent,
                      border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('$v', style: TextStyle(color: selected ? AppColors.accentOn : AppColors.textPrimary, fontWeight: FontWeight.w600)),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 20),
          const Text('ANYTHING HURT?', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _painParts.map((p) {
              final selected = state.sessionPain.contains(p);
              return GestureDetector(
                onTap: () => setState(() {
                  if (selected) {
                    state.sessionPain.remove(p);
                  } else {
                    state.sessionPain.add(p);
                  }
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.cautionBg : Colors.transparent,
                    border: Border.all(color: selected ? AppColors.caution : AppColors.border),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(p, style: TextStyle(color: selected ? AppColors.caution : AppColors.textSecondary, fontWeight: FontWeight.w600, fontSize: 12)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                state.sessionNotes = _notesCtrl.text.trim();
                widget.onDone();
              },
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
