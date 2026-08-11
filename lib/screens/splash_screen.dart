import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'auth_gate.dart';

/// One-shot boot animation: the barbell bends into shape, the LOAD
/// wordmark drops in, the accent dot pops, the tagline fades — then hands
/// off to [AuthGate]. Ported from the beats of
/// `.local/design-guides/LOAD-Splash-standalone.html`'s looping mark
/// (compressed to a single play instead of an infinite loop, since a splash
/// is seen once per launch, not admired on repeat).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  static const _totalMs = 2600;
  static const _barEnd = 1000 / _totalMs;
  static const _wordStart = 550 / _totalMs;
  static const _wordEnd = 1250 / _totalMs;
  static const _dotStart = 1150 / _totalMs;
  static const _dotEnd = 1750 / _totalMs;
  static const _tagStart = 1500 / _totalMs;
  static const _tagEnd = 2100 / _totalMs;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _totalMs),
    )..forward();
    Future.delayed(const Duration(milliseconds: _totalMs + 500), () {
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const AuthGate()));
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _seg(double t, double start, double end, Curve curve) {
    if (t <= start) return 0;
    if (t >= end) return 1;
    return curve.transform((t - start) / (end - start));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            final barDraw = _seg(t, 0, _barEnd * 0.55, Curves.easeOutCubic);
            final barBend = _seg(t, 0, _barEnd, Curves.elasticOut);
            final plateT = _seg(t, 0, _barEnd * 0.7, Curves.elasticOut);
            final wordT = _seg(t, _wordStart, _wordEnd, Curves.easeOutBack);
            final dotT = _seg(t, _dotStart, _dotEnd, Curves.elasticOut);
            final tagT = _seg(t, _tagStart, _tagEnd, Curves.easeOut);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 252,
                  height: 115,
                  child: CustomPaint(
                    painter: _BarbellPainter(
                      drawProgress: barDraw,
                      bend: barBend,
                      plateT: plateT,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Opacity(
                  opacity: wordT.clamp(0, 1),
                  child: Transform.translate(
                    offset: Offset(0, (1 - wordT) * -16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'LOAD',
                          style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w900,
                            fontSize: 48,
                            height: 1,
                            letterSpacing: 1.5,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 6, bottom: 6),
                          child: Opacity(
                            opacity: dotT.clamp(0, 1),
                            child: Transform.translate(
                              offset: Offset(0, (1 - dotT) * -30),
                              child: Transform.scale(
                                scale: 0.3 + 0.7 * dotT,
                                child: Container(
                                  width: 13,
                                  height: 13,
                                  decoration: const BoxDecoration(
                                    color: AppColors.accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Opacity(
                  opacity: tagT.clamp(0, 1),
                  child: const Text(
                    'Personal training, computed\nfrom your actual history.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The bending-barbell mark: a quadratic-bezier bar between two plate
/// stacks, drawn stroke-first then settling into its resting curve.
class _BarbellPainter extends CustomPainter {
  final double drawProgress;
  final double bend;
  final double plateT;
  const _BarbellPainter({
    required this.drawProgress,
    required this.bend,
    required this.plateT,
  });

  static const _flatY = 50.0;
  static const _settledY = 37.0;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 220;
    canvas.save();
    canvas.scale(scale);

    final controlY = _flatY - (_flatY - _settledY) * bend;
    final bar = Path()
      ..moveTo(45, _flatY)
      ..quadraticBezierTo(110, controlY, 175, _flatY);
    final metric = bar.computeMetrics().first;
    final partial = metric.extractPath(0, metric.length * drawProgress);
    final barPaint = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(partial, barPaint);

    final plateColor = Paint()..color = AppColors.textPrimary;
    final plateOpacity = plateT.clamp(0.0, 1.0);
    final slide = (1 - plateT) * 40;
    final rotate = 0.0785 * plateT; // ~4.5deg settled

    canvas.save();
    canvas.translate(-slide, 0);
    canvas.saveLayer(
      const Rect.fromLTWH(0, 0, 220, 100),
      Paint()..color = Colors.white.withValues(alpha: plateOpacity),
    );
    canvas.translate(45, 50);
    canvas.rotate(-rotate);
    canvas.translate(-45, -50);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(38, 20, 14, 60),
        const Radius.circular(7),
      ),
      plateColor,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(20, 31, 12, 38),
        const Radius.circular(6),
      ),
      plateColor,
    );
    canvas.restore();
    canvas.restore();

    canvas.save();
    canvas.translate(slide, 0);
    canvas.saveLayer(
      const Rect.fromLTWH(0, 0, 220, 100),
      Paint()..color = Colors.white.withValues(alpha: plateOpacity),
    );
    canvas.translate(175, 50);
    canvas.rotate(rotate);
    canvas.translate(-175, -50);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(168, 20, 14, 60),
        const Radius.circular(7),
      ),
      plateColor,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(188, 31, 12, 38),
        const Radius.circular(6),
      ),
      plateColor,
    );
    canvas.restore();
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BarbellPainter oldDelegate) =>
      oldDelegate.drawProgress != drawProgress ||
      oldDelegate.bend != bend ||
      oldDelegate.plateT != plateT;
}
