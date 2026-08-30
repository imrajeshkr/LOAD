import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/diagnostics.dart';
import '../services/failure.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

/// The screen a lifter gets when something did not load.
///
/// One widget for every such moment in the app, so the words, the picture and
/// the recovery are decided once. What it shows comes from [Failure.kind], not
/// from the exception's text — see `failure.dart`.
///
/// The artwork is drawn in code on purpose. An error screen has to work on the
/// worst day the app has: an asset that fails to decode, or that someone
/// removes from pubspec during a refactor, turns the thing meant to explain a
/// failure into a second failure. A painter has no file to lose, no licence to
/// honour, no attribution to strip, re-themes itself when the palette moves,
/// and is sharp at any size.
class FailureView extends StatefulWidget {
  final Failure failure;

  /// Runs when the lifter asks to try again. Null hides the button entirely —
  /// an action that cannot work is worse than no action.
  final VoidCallback? onRetry;

  /// Shown instead of retry when the session is gone.
  final VoidCallback? onSignIn;

  const FailureView({
    super.key,
    required this.failure,
    this.onRetry,
    this.onSignIn,
  });

  @override
  State<FailureView> createState() => _FailureViewState();
}

class _FailureViewState extends State<FailureView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  bool _detailOpen = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.failure;
    // Someone who has asked the OS to stop animations has asked for this too.
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still && _c.isAnimating) _c.stop();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 132,
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) => CustomPaint(
                  painter: _FailureArt(
                    kind: f.kind,
                    t: still ? 0.5 : Curves.easeInOut.transform(_c.value),
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(height: 26),
            Text(f.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 19,
                    height: 1.2,
                    letterSpacing: -0.3,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 9),
            Text(f.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 13,
                    height: 1.5,
                    color: AppColors.textMuted)),
            const SizedBox(height: 24),
            if (f.kind == FailureKind.session && widget.onSignIn != null)
              _button('Sign in again', widget.onSignIn!)
            else if (f.retryable && widget.onRetry != null)
              _button('Try again', widget.onRetry!),
            if (Diagnostics.showRawErrors) ...[
              const SizedBox(height: 18),
              _detail(f),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(String label, VoidCallback onTap) => Pressable(
        haptic: PressFx.medium,
        onTap: onTap,
        child: Container(
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(25),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                  color: AppColors.onAccent)),
        ),
      );

  /// Developer-only, and it says so. Collapsed by default: when it is open by
  /// default you stop reading it, and the point of this build being different
  /// from a user's is lost.
  Widget _detail(Failure f) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pressable(
            haptic: PressFx.light,
            onTap: () => setState(() => _detailOpen = !_detailOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              child: Row(
                children: [
                  const Icon(Icons.bug_report_outlined,
                      size: 14, color: AppColors.textFaint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('DEBUG · ${f.kind.name}',
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 9.5,
                            letterSpacing: 0.8,
                            color: AppColors.textFaint)),
                  ),
                  Icon(
                      _detailOpen
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: AppColors.textFaint),
                ],
              ),
            ),
          ),
          if (_detailOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 13, 12),
              child: SelectableText(f.detail,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      height: 1.45,
                      color: AppColors.textSecondary)),
            ),
        ],
      ),
    );
  }
}

/// A barbell that says which failure this is by how it is loaded.
///
/// One drawing, four states, because a lifter should recognise the shape
/// instantly and read the difference second: an empty bar for a lost
/// connection, a bar bent under its plates for a server fault, a bar racked
/// and locked for a dead session. [t] runs 0..1 and back for a slow breath —
/// enough to feel alive, not enough to demand attention on a screen that is
/// already bad news.
class _FailureArt extends CustomPainter {
  final FailureKind kind;
  final double t;
  const _FailureArt({required this.kind, required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final bar = math.min(size.width * 0.62, 190.0);
    final dim = AppColors.textFaint;
    final accent = AppColors.accent;

    // The bar sags under load for a server fault, and drifts for the rest.
    final sag = kind == FailureKind.server ? 7.0 + t * 3 : 0.0;
    final drift = kind == FailureKind.server ? 0.0 : (t - 0.5) * 6;
    final y = cy + drift;

    final barPaint = Paint()
      ..color = dim
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()..moveTo(cx - bar / 2, y);
    path.quadraticBezierTo(cx, y + sag * 2, cx + bar / 2, y);
    canvas.drawPath(path, barPaint);

    // Plates, or the absence of them.
    if (kind != FailureKind.offline) {
      final plate = Paint()
        ..color = kind == FailureKind.server
            ? AppColors.warn.withValues(alpha: 0.75)
            : dim
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      for (final side in [-1.0, 1.0]) {
        final px = cx + side * (bar / 2 - 16);
        final h = 30.0 + (kind == FailureKind.server ? 6 : 0);
        canvas.drawLine(
            Offset(px, y + sag - h / 2), Offset(px, y + sag + h / 2), plate);
        canvas.drawLine(Offset(px + side * 9, y + sag - h / 3),
            Offset(px + side * 9, y + sag + h / 3), plate);
      }
    }

    switch (kind) {
      case FailureKind.offline:
        // A broken line where the connection should be: two ends, a gap.
        final p = Paint()
          ..color = accent.withValues(alpha: 0.35 + t * 0.35)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
            Offset(cx - 34, y - 34), Offset(cx - 12, y - 34), p);
        canvas.drawLine(
            Offset(cx + 12, y - 34), Offset(cx + 34, y - 34), p);
        canvas.drawCircle(Offset(cx, y - 34), 2.5, Paint()..color = accent);

      case FailureKind.session:
        // A closed shackle above the bar: locked out, not broken.
        final p = Paint()
          ..color = accent.withValues(alpha: 0.55 + t * 0.3)
          ..strokeWidth = 3.4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(
            Rect.fromCenter(
                center: Offset(cx, y - 40), width: 26, height: 26),
            math.pi,
            math.pi,
            false,
            p);
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromCenter(
                    center: Offset(cx, y - 26), width: 34, height: 22),
                const Radius.circular(6)),
            Paint()..color = accent.withValues(alpha: 0.55 + t * 0.3));

      case FailureKind.server:
        // The bar is bending. Nothing else needs saying.
        break;

      case FailureKind.unknown:
        final p = Paint()
          ..color = accent.withValues(alpha: 0.4 + t * 0.3)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(
            Rect.fromCenter(
                center: Offset(cx, y - 40), width: 22, height: 22),
            -math.pi,
            math.pi * 1.35,
            false,
            p);
        canvas.drawCircle(
            Offset(cx, y - 22), 2.4, Paint()..color = accent.withValues(alpha: 0.8));
    }
  }

  @override
  bool shouldRepaint(_FailureArt old) => old.t != t || old.kind != kind;
}
