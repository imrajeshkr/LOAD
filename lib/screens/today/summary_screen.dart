import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';

const _painParts = ['Shoulder', 'Elbow', 'Wrist', 'Knee', 'Lower back'];
const _rpeLabels = {
  1: 'Easy',
  2: 'Comfortable',
  3: 'Solid',
  4: 'Hard',
  5: 'All out',
};
const _confettiColors = [
  AppColors.accent,
  AppColors.positive,
  Color(0xFFD9A441),
  Color(0xFF6E8FB0),
];

/// Post-session celebration: reward first (confetti, a drawn ring and
/// checkmark, numbers counting up, a PR card if there is one), reflection
/// second (RPE, pain, an optional note) — the lifter sees what they did
/// before being asked how it felt.
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> with SingleTickerProviderStateMixin {
  final _notesCtrl = TextEditingController();
  bool _notesExpanded = false;
  bool _finishing = false;
  late final AnimationController _celebrate;

  @override
  void initState() {
    super.initState();
    _celebrate = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
      ..forward();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _celebrate.dispose();
    super.dispose();
  }

  Future<void> _done(AppState state) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    state.sessionNotes = _notesCtrl.text.trim();
    await state.finishSession(state.planLabel ?? 'Training');
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final units = state.units;
    final highlights = state.sessionHighlights;
    final label = state.planLabel ?? 'Session';

    final targetVolume = units.fromKg(state.sessionVolumeKg);
    final targetSets = state.sessionSetsLogged;
    final targetMinutes = state.sessionNow?.elapsedMin ?? 0;

    final delta = state.sessionVolumeDeltaKg;
    final hasVolume = state.sessionVolumeKg > 0;
    final String compareValue;
    final String compareText;
    final Color compareBg;
    final Color compareFg;
    if (delta == null) {
      compareValue = '';
      compareText = hasVolume
          ? "First $label logged — this is your baseline now."
          : 'Logged and banked.';
      compareBg = AppColors.chipFill;
      compareFg = AppColors.textSecondary;
    } else {
      final sign = delta >= 0 ? '+' : '';
      compareValue = '$sign${units.formatWeight(delta)}';
      compareText = '${units.weightLabel} vs your last $label';
      compareBg = delta >= 0 ? AppColors.positiveSoft : AppColors.chipFill;
      compareFg = delta >= 0 ? AppColors.positive : AppColors.textSecondary;
    }

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Center(
                  child: AnimatedBuilder(
                    animation: _celebrate,
                    builder: (context, _) => CustomPaint(
                      size: const Size(78, 78),
                      painter: _RingCheckPainter(
                        ringProgress: Curves.easeOutCubic
                            .transform(_intervalValue(_celebrate.value, 0, 0.5)),
                        checkProgress: Curves.easeOutCubic
                            .transform(_intervalValue(_celebrate.value, 0.39, 0.61)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '$label, done.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  highlights.isNotEmpty ? 'You moved more than last time.' : 'Logged and banked.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 22),
                AnimatedBuilder(
                  animation: _celebrate,
                  builder: (context, _) {
                    final p = Curves.easeOut.transform(_intervalValue(_celebrate.value, 0, 0.45));
                    return Row(
                      children: [
                        Expanded(
                          child: _CountTile(
                            label: 'Volume (${units.weightLabel})',
                            value: (targetVolume * p).round().toString(),
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _CountTile(
                            label: 'Sets done',
                            value:
                                '${(targetSets * p).round()} of ${state.sessionSetsTarget}',
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _CountTile(
                            label: 'Minutes',
                            value: (targetMinutes * p).round().toString(),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
                  decoration: BoxDecoration(
                    color: compareBg,
                    borderRadius: BorderRadius.circular(AppRadii.card),
                  ),
                  child: Row(
                    children: [
                      if (compareValue.isNotEmpty) ...[
                        Text(
                          compareValue,
                          style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                            color: compareFg,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Text(
                          compareText,
                          style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            height: 1.4,
                            color: compareFg,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (highlights.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final h in highlights)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFBEFD6),
                          borderRadius: BorderRadius.circular(AppRadii.card),
                        ),
                        child: Text(
                          '🏆 $h',
                          style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                            height: 1.45,
                            color: AppColors.note,
                          ),
                        ),
                      ),
                    ),
                ],

                const SizedBox(height: 26),
                const SectionLabel('How did it feel?'),
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

                const SizedBox(height: 20),
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
                  const SizedBox(height: 10),
                  Text(
                    "Noted — I'll ease off anything that loads your "
                    "${state.sessionPain.join(', ').toLowerCase()} next session.",
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      height: 1.5,
                      color: AppColors.warning,
                    ),
                  ),
                ],

                const SizedBox(height: 20),
                if (!_notesExpanded)
                  GestureDetector(
                    onTap: () => setState(() => _notesExpanded = true),
                    child: const Text(
                      'Add a note',
                      style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: AppColors.accent,
                      ),
                    ),
                  )
                else
                  TextField(
                    controller: _notesCtrl,
                    maxLines: 3,
                    autofocus: true,
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AppColors.textBody,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Anything worth remembering about today?',
                    ),
                  ),

                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _finishing ? null : () => _done(state),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
            AnimatedBuilder(
              animation: _celebrate,
              builder: (context, _) {
                if (_celebrate.isCompleted) return const SizedBox.shrink();
                return IgnorePointer(
                  child: SizedBox(
                    height: 240,
                    child: Stack(
                      children: [
                        for (var i = 0; i < 14; i++) _ConfettiPiece(index: i, controller: _celebrate),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

double _intervalValue(double t, double start, double end) {
  if (t <= start) return 0;
  if (t >= end) return 1;
  return (t - start) / (end - start);
}

class _CountTile extends StatelessWidget {
  final String label;
  final String value;
  const _CountTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w900,
              fontSize: 21,
              height: 1.1,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              height: 1.3,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The circular progress ring + checkmark drawn on entry — done with
/// [PathMetric] partial-extraction so the check genuinely traces itself
/// rather than just fading in.
class _RingCheckPainter extends CustomPainter {
  final double ringProgress;
  final double checkProgress;
  const _RingCheckPainter({required this.ringProgress, required this.checkProgress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    final track = Paint()
      ..color = AppColors.chipFill
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7;
    canvas.drawCircle(center, radius, track);

    if (ringProgress > 0) {
      final ring = Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * ringProgress,
        false,
        ring,
      );
    }

    if (checkProgress > 0) {
      final path = Path()
        ..moveTo(size.width * 0.32, size.height * 0.51)
        ..lineTo(size.width * 0.44, size.height * 0.63)
        ..lineTo(size.width * 0.69, size.height * 0.37);
      final metric = path.computeMetrics().first;
      final partial = metric.extractPath(0, metric.length * checkProgress);
      final checkPaint = Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(partial, checkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingCheckPainter oldDelegate) =>
      oldDelegate.ringProgress != ringProgress || oldDelegate.checkProgress != checkProgress;
}

class _ConfettiPiece extends StatelessWidget {
  final int index;
  final AnimationController controller;
  const _ConfettiPiece({required this.index, required this.controller});

  @override
  Widget build(BuildContext context) {
    final leftPct = ((index * 7 + (index % 3) * 9) % 92) / 100;
    final color = _confettiColors[index % _confettiColors.length];
    final delayMs = (index % 5) * 90;
    final durationMs = 1100 + (index % 4) * 180;
    final totalMs = controller.duration!.inMilliseconds;
    final start = delayMs / totalMs;
    final end = ((delayMs + durationMs) / totalMs).clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final p = _intervalValue(controller.value, start, end);
        final fallY = Curves.easeIn.transform(p) * 210;
        final opacity = p < 0.75 ? 1.0 : (1 - (p - 0.75) / 0.25).clamp(0.0, 1.0);
        final rotate = p * (index.isEven ? 4.0 : -4.0);
        return Positioned(
          top: fallY,
          left: leftPct * MediaQuery.of(context).size.width,
          child: Opacity(
            opacity: p == 0 ? 0 : opacity,
            child: Transform.rotate(
              angle: rotate,
              child: Container(
                width: 7,
                height: 11,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
        );
      },
    );
  }
}
