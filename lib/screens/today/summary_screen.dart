import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/units.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';

/// "+155 kg vs your last Push Day" — the number a lifter would actually
/// repeat to someone. Compares against the same program day, not simply the
/// previous session, since Push-vs-Leg-day tonnage swings wildly and would
/// look like progress or regression that isn't real.
String _volumeCaption(AppState state, UnitSystem units) {
  final last = state.sessionLast;
  if (last == null) return 'total ${units.weightLabel} moved';
  final delta = state.sessionVolumeDeltaKg;
  if (delta == null) return 'total ${units.weightLabel} moved';
  final sign = delta >= 0 ? '+' : '';
  return '$sign${units.formatWeight(delta)} ${units.weightLabel} vs last time';
}

const _painParts = ['Shoulder', 'Elbow', 'Wrist', 'Knee', 'Lower back'];
const _rpeLabels = {
  1: 'Easy',
  2: 'Comfortable',
  3: 'Solid',
  4: 'Hard',
  5: 'All out',
};

/// Post-session reflection. RPE and pain are asked once here rather than
/// per set — mid-workout attention is too short for extra taps.
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final _notesCtrl = TextEditingController();

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final units = state.units;
    final highlights = state.sessionHighlights;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppColors.positiveSoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      color: AppColors.positive, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Session complete',
                          style: Theme.of(context).textTheme.headlineMedium),
                      Text(
                        state.planLabel ?? 'Training',
                        style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Sets',
                    value: '${state.sessionSetsLogged}',
                    caption: 'of ${state.sessionSetsTarget} planned',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatTile(
                    label: 'Volume',
                    value: units.formatWeight(state.sessionVolumeKg),
                    caption: _volumeCaption(state, units),
                  ),
                ),
              ],
            ),

            if (highlights.isNotEmpty) ...[
              const SizedBox(height: 22),
              const SectionLabel('Highlights'),
              for (final h in highlights)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppCard(
                    color: AppColors.positiveSoft,
                    child: Row(
                      children: [
                        const Icon(Icons.emoji_events_rounded,
                            size: 17, color: AppColors.positive),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            h,
                            style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                              height: 1.4,
                              color: AppColors.positive,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],

            const SizedBox(height: 22),
            const SectionLabel('How did it feel overall?'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var v = 1; v <= 5; v++)
                  ChoiceChipButton(
                    label: _rpeLabels[v]!,
                    selected: state.sessionRpe == v,
                    onTap: () => setState(
                      () => state.sessionRpe = state.sessionRpe == v ? null : v,
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 22),
            const SectionLabel('Anything hurt?'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final part in _painParts)
                  ChoiceChipButton(
                    label: part,
                    selected: state.sessionPain.contains(part),
                    selectedColor: AppColors.peach,
                    selectedFg: AppColors.warning,
                    onTap: () => setState(() {
                      if (state.sessionPain.contains(part)) {
                        state.sessionPain.remove(part);
                      } else {
                        state.sessionPain.add(part);
                      }
                    }),
                  ),
              ],
            ),
            if (state.sessionPain.isNotEmpty) ...[
              const SizedBox(height: 12),
              SoftBanner(
                message: "Noted — I'll ease off anything that loads your "
                    "${state.sessionPain.join(', ').toLowerCase()} next session. "
                    "If it's sharp or lingering, please get it looked at.",
              ),
            ],

            const SizedBox(height: 22),
            const SectionLabel('Notes (optional)'),
            TextField(
              controller: _notesCtrl,
              maxLines: 3,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.textBody,
              ),
              decoration: const InputDecoration(
                hintText: 'e.g. felt strong, gym was busy so rest was short',
              ),
            ),

            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  state.sessionNotes = _notesCtrl.text.trim();
                  state.finishSession(state.planLabel ?? 'Training');
                  Navigator.of(context).popUntil((r) => r.isFirst);
                },
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String caption;
  const _StatTile({required this.label, required this.value, required this.caption});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w800,
              fontSize: 24,
              height: 1.1,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            caption,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              color: AppColors.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}
