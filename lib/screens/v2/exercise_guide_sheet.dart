import 'package:flutter/material.dart';

import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pressable.dart';
import '../../widgets/v2_widgets.dart';

/// What a lift is, before you have to do it.
///
/// The Train tab used to spell out `4 × 6–12 · 2 min rest` under every lift.
/// That is the answer to a question nobody asks standing in the kitchen, and
/// the session flow shows it anyway once it matters. The row is now a name and
/// a weight; everything else lives here, one tap away, for the lifter who does
/// not know what a Lateral Raise is.
///
/// Everything shown comes from the plan row already in memory — opening this
/// costs no round trip.
Future<void> showExerciseGuide(BuildContext context, PlanExerciseV2 ex) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ExerciseGuideSheet(ex: ex),
  );
}

class _ExerciseGuideSheet extends StatelessWidget {
  final PlanExerciseV2 ex;
  const _ExerciseGuideSheet({required this.ex});

  @override
  Widget build(BuildContext context) {
    final url = SupabaseService.instance.demoUrl(ex.demoPath);
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.86,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(ex.name,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 21,
                          height: 1.15,
                          letterSpacing: -0.4,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      height: 188,
                      color: const Color(0xFFF1EDE7),
                      child: url != null
                          ? Image.network(url,
                              fit: BoxFit.contain,
                              errorBuilder: (_, e, s) => const _NoArt())
                          : const _NoArt(),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // The numbers the row no longer carries. Here they are read
                  // by someone who chose to look, not skimmed past by everyone.
                  Row(
                    children: [
                      Expanded(child: _Stat(value: ex.prescription, label: 'sets × reps')),
                      const SizedBox(width: 9),
                      Expanded(
                          child: _Stat(
                              value: '${(ex.restSeconds / 60).round()} min',
                              label: 'rest between sets')),
                      const SizedBox(width: 9),
                      Expanded(
                          child: _Stat(
                              value: ex.isBodyweight
                                  ? 'Body'
                                  : '${_n(ex.prefillKg)} kg',
                              label: 'starting load')),
                    ],
                  ),

                  if (ex.cues.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const _Label('HOW TO DO IT'),
                    const SizedBox(height: 8),
                    V2Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final cue in ex.cues)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    margin: const EdgeInsets.only(top: 6, right: 9),
                                    decoration: const BoxDecoration(
                                        color: AppColors.accent, shape: BoxShape.circle),
                                  ),
                                  Expanded(
                                    child: Text(cue,
                                        style: const TextStyle(
                                            fontFamily: AppTheme.fontFamily,
                                            fontSize: 12,
                                            height: 1.5,
                                            color: AppColors.textSecondary)),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],

                  if (ex.joints.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const _Label('JOINTS INVOLVED'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final j in ex.joints)
                          StatusChip(
                              icon: Icons.circle,
                              label: j,
                              color: AppColors.textMuted),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                18, 4, 18, 14 + MediaQuery.of(context).padding.bottom),
            child: Pressable(
              haptic: PressFx.medium,
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: const Text('Got it',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                        color: AppColors.textPrimary)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoArt extends StatelessWidget {
  const _NoArt();
  @override
  Widget build(BuildContext context) => const Center(
      child: Icon(Icons.fitness_center_rounded, color: Color(0xFFB9B0A6), size: 40));
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  height: 1,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 5),
          Text(label,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 10,
                  height: 1.25,
                  color: AppColors.textFaint)),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Text(text,
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 9.5,
                letterSpacing: 0.9,
                color: AppColors.textFaint)),
      );
}

String _n(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
