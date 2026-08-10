import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';

class GuideOverlay extends StatelessWidget {
  const GuideOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final idx = state.guideExerciseIndex!;
    final ex = state.exercises[idx];
    final cues = formCues[ex.name] ?? defaultCues;

    return Positioned.fill(
      child: Material(
        color: AppColors.background,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('FORM GUIDE', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                        const SizedBox(height: 6),
                        Text(ex.name.toUpperCase(), style: const TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    GestureDetector(
                      onTap: state.closeGuide,
                      child: const Text('CLOSE', style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  height: 180,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppColors.surfaceAlt, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(14)),
                  child: const Text('LOOPING FORM DEMO\n3s CLIP', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textTertiary, fontSize: 11, fontWeight: FontWeight.w600, height: 1.6)),
                ),
                const SizedBox(height: 22),
                const Text('FORM CUES', style: TextStyle(color: AppColors.textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                const SizedBox(height: 10),
                ...cues.map((c) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(margin: const EdgeInsets.only(top: 7, right: 10), width: 5, height: 5, decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle)),
                          Expanded(child: Text(c, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, height: 1.5))),
                        ],
                      ),
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
