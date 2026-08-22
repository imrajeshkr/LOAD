import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Cold-start splash, direction 1a — "Load the bar".
///
/// Plates fly in from both edges, the rod scales out, the rig sags under the
/// load with a spring and the arms bend, then the "L○AD" wordmark fades up (the
/// O is a lime plate/ring) with the tagline. ~2.2s, holds, hands off. Geometry
/// and timing mirror the design handoff's 1a lockup.
class SplashV2 extends StatefulWidget {
  final VoidCallback onDone;
  const SplashV2({super.key, required this.onDone});

  @override
  State<SplashV2> createState() => _SplashV2State();
}

class _SplashV2State extends State<SplashV2> with SingleTickerProviderStateMixin {
  static const _total = 2500; // ms; keyframe delays below are /_total
  late final AnimationController _c;

  // Rig geometry, scaled from the 66px design plate. The full rest width is
  // ~184·_s; keep it inside a phone's width (≈402pt) with margin to spare.
  static const _s = 1.7;

  // Spring easing used for plates / bend / ring (gentle overshoot).
  static const _spring = Cubic(0.34, 1.4, 0.64, 1.0);

  late final Animation<double> _rod;      // rod scaleX
  late final Animation<double> _plate;    // 1 → seated (drives translateX)
  late final Animation<double> _bend;     // 0 → 1 (arm rotation)
  late final Animation<double> _settle;   // drives the sag keyframes
  late final Animation<double> _word;     // wordmark opacity
  late final Animation<double> _ring;     // O ring pop
  late final Animation<double> _tag;      // tagline opacity
  late final Animation<double> _line;     // bottom progress

  Animation<double> _at(double startMs, double endMs, Curve curve) => CurvedAnimation(
        parent: _c,
        curve: Interval(startMs / _total, endMs / _total, curve: curve),
      );

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: _total));
    _rod = _at(0, 500, const Cubic(0.22, 1, 0.36, 1));
    _plate = _at(300, 850, _spring);
    _settle = _at(850, 1550, Curves.linear);
    _bend = _at(900, 1400, _spring);
    _word = _at(1200, 1700, Curves.easeOut);
    _ring = _at(1350, 1900, _spring);
    _tag = _at(1700, 2200, Curves.easeOut);
    _line = _at(200, 2100, Curves.easeInOut);

    _c.forward();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        Future.delayed(const Duration(milliseconds: 260), () {
          if (mounted) widget.onDone();
        });
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // The sag: translateY 0 → 11 → -3 → 5 across the settle window.
  double _sagY(double t) {
    if (t <= 0) return 0;
    if (t < 0.5) return 11 * (t / 0.5);
    if (t < 0.72) return 11 + (-3 - 11) * ((t - 0.5) / 0.22);
    if (t < 1) return -3 + (5 - -3) * ((t - 0.72) / 0.28);
    return 5;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Stack(
        children: [
          Center(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      offset: Offset(0, _sagY(_settle.value)),
                      child: _rig(),
                    ),
                    const SizedBox(height: 46),
                    Opacity(opacity: _word.value.clamp(0.0, 1.0), child: _wordmark()),
                    const SizedBox(height: 16),
                    Opacity(
                      opacity: _tag.value.clamp(0.0, 1.0),
                      child: Text('TRACK IT TO IMPROVE IT',
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 11,
                              letterSpacing: 0.16 * 11,
                              fontWeight: FontWeight.w400,
                              color: AppColors.textMuted)),
                    ),
                  ],
                );
              },
            ),
          ),
          // Bottom progress hairline.
          Positioned(
            bottom: 54,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 64,
                height: 2,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
                clipBehavior: Clip.hardEdge,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedBuilder(
                    animation: _line,
                    builder: (context, _) => FractionallySizedBox(
                      widthFactor: _line.value.clamp(0.0, 1.0),
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── the barbell rig ────────────────────────────────────────────────────
  Widget _rig() {
    final dist = 150.0; // fly-in distance (plates start just off-screen)
    final off = (1 - _plate.value) * dist;
    final plateOpacity = (_plate.value * 1.6).clamp(0.0, 1.0);
    final bend = _bend.value * 4.5; // degrees

    // The rod is drawn BEHIND both arms, and the sleeves overlap its ends by
    // `_seam`, so the bar tucks up inside each bell rather than sitting on top
    // of it (symmetric — the old plain Row painted the rod over the left
    // sleeve but under the right one).
    const rodW = 96 * _s;
    const seam = 6 * _s;
    return Stack(
      alignment: Alignment.center,
      children: [
        _rodWidget(),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Left arm — bends down at the outer end as it loads.
            Transform.rotate(
              alignment: Alignment.centerRight,
              angle: -bend * 3.14159265 / 180,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.translate(
                    offset: Offset(-off, 0),
                    child: Opacity(
                      opacity: plateOpacity,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _plateRect(11, 44, AppColors.accentDeep),
                          const SizedBox(width: 3 * _s),
                          _plateRect(15, 66, AppColors.accent),
                        ],
                      ),
                    ),
                  ),
                  _sleeve(),
                ],
              ),
            ),
            const SizedBox(width: rodW - 2 * seam),
            // Right arm — mirror.
            Transform.rotate(
              alignment: Alignment.centerLeft,
              angle: bend * 3.14159265 / 180,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sleeve(),
                  Transform.translate(
                    offset: Offset(off, 0),
                    child: Opacity(
                      opacity: plateOpacity,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _plateRect(15, 66, AppColors.accent),
                          const SizedBox(width: 3 * _s),
                          _plateRect(11, 44, AppColors.accentDeep),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _plateRect(double w, double h, Color c) => Container(
        width: w * _s,
        height: h * _s,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3 * _s)),
      );

  Widget _sleeve() => Container(
        width: 15 * _s,
        height: 13 * _s,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2 * _s),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF9A8F87), Color(0xFF4E4744)],
          ),
        ),
      );

  Widget _rodBuilt() => Container(
        width: 96 * _s,
        height: 8 * _s,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4 * _s),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFB0A49B), Color(0xFF3A3532)],
          ),
        ),
      );

  Widget _rodWidget() => Transform.scale(
        scaleX: _rod.value.clamp(0.0, 1.0),
        alignment: Alignment.center,
        child: _rodBuilt(),
      );

  // ── the wordmark: L ○ AD ────────────────────────────────────────────────
  Widget _wordmark() {
    final ringScale = 0.3 + (_ring.value.clamp(0.0, 1.0)) * 0.7; // approx .3→1
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _letter('L'),
        const SizedBox(width: 3),
        Transform.scale(
          scale: ringScale,
          child: Opacity(
            opacity: _ring.value.clamp(0.0, 1.0),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.accent, width: 8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 3),
        _letter('AD'),
      ],
    );
  }

  Widget _letter(String s) => Text(
        s,
        style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontWeight: FontWeight.w700,
          fontSize: 44,
          height: 1,
          letterSpacing: -0.02 * 44,
          color: AppColors.textPrimary,
        ),
      );
}
