import 'package:flutter/material.dart';
import '../services/haptics.dart';
import '../theme/app_colors.dart';

/// A ruler you drag past a fixed marker, the way a luggage scale or a tailor's
/// tape reads.
///
/// Replaces a slider plus a pair of +/- buttons plus a caption explaining that
/// you drag for a rough number and tap to land it exactly. A ruler needs no
/// caption: the ticks say how far a drag moves you, the marker says what is
/// selected, and fine adjustment is just a slower drag.
class RulerPicker extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;

  /// Logical pixels between ticks. Wider reads calmer and drags coarser.
  final double tickSpacing;

  const RulerPicker({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.tickSpacing = 11,
  });

  @override
  State<RulerPicker> createState() => _RulerPickerState();
}

class _RulerPickerState extends State<RulerPicker> {
  ScrollController? _ctrl;
  double _lastHaptic = double.nan;

  int get _count => ((widget.max - widget.min) / widget.step).round() + 1;
  double _offsetFor(double v) =>
      ((v - widget.min) / widget.step) * widget.tickSpacing;

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _ensure(double pad) {
    if (_ctrl != null) return;
    _ctrl = ScrollController(initialScrollOffset: _offsetFor(widget.value))
      ..addListener(_onScroll);
  }

  void _onScroll() {
    final c = _ctrl;
    if (c == null || !c.hasClients) return;
    final raw = widget.min + (c.offset / widget.tickSpacing) * widget.step;
    final snapped =
        (raw / widget.step).round() * widget.step;
    final clamped = snapped.clamp(widget.min, widget.max);
    if (clamped != widget.value) widget.onChanged(clamped);
    // One tick of feedback per tick passed, so the ruler feels mechanical
    // rather than like a value silently changing under the thumb.
    if (clamped != _lastHaptic) {
      _lastHaptic = clamped;
      Haptics.selection();
    }
  }

  @override
  void didUpdateWidget(covariant RulerPicker old) {
    super.didUpdateWidget(old);
    // Only chase an external change (a unit switch), never the user's own drag.
    final c = _ctrl;
    if (c != null && c.hasClients && !c.position.isScrollingNotifier.value) {
      final want = _offsetFor(widget.value);
      if ((c.offset - want).abs() > widget.tickSpacing / 2) c.jumpTo(want);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final pad = box.maxWidth / 2;
        _ensure(pad);
        return SizedBox(
          height: 54,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ListView.builder(
                controller: _ctrl,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: pad),
                itemCount: _count,
                itemExtent: widget.tickSpacing,
                itemBuilder: (_, i) {
                  final v = widget.min + i * widget.step;
                  // A taller tick every fifth step gives the eye something to
                  // count by without printing a number under each one.
                  final major = (v / widget.step).round() % 5 == 0;
                  return Center(
                    child: Container(
                      width: 1.5,
                      height: major ? 26 : 14,
                      decoration: BoxDecoration(
                        color: major ? AppColors.borderStrong : AppColors.border,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  );
                },
              ),
              IgnorePointer(
                child: Container(
                  width: 3,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Where a BMI sits, drawn as a band rather than announced as a verdict.
///
/// Uses the WHO Asian cut-offs (healthy tops out at 22.9, overweight at 23,
/// obese at 27.5) rather than the familiar 25/30. WHO recommended these for
/// Asian populations in 2004; NICE adopted them in 2023 and ICMR uses them in
/// India. On the standard bands most of this app's users would be told they
/// are a category lighter than the guidance for their population says.
class BmiBand extends StatelessWidget {
  final double bmi;
  const BmiBand({super.key, required this.bmi});

  static const _lo = 15.0, _hi = 35.0;

  /// Cut-offs in ascending order with the colour each band carries.
  static const _bands = <(double, Color)>[
    (18.5, AppColors.textMuted),
    (23.0, AppColors.accent),
    (27.5, Color(0xFFD9A441)),
    (_hi, AppColors.warn),
  ];

  static String label(double bmi) => bmi < 18.5
      ? 'Under'
      : bmi < 23
          ? 'Healthy'
          : bmi < 27.5
              ? 'Above'
              : 'Well above';

  @override
  Widget build(BuildContext context) {
    final t = ((bmi.clamp(_lo, _hi) - _lo) / (_hi - _lo));
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        var start = _lo;
        return SizedBox(
          height: 30,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 11,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      for (final (end, color) in _bands)
                        Builder(builder: (_) {
                          final flex = ((end - start) * 10).round();
                          start = end;
                          return Expanded(
                            flex: flex,
                            child: Container(height: 8, color: color.withValues(alpha: 0.55)),
                          );
                        }),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: (w * t) - 7,
                top: 4,
                child: Container(
                  width: 14,
                  height: 22,
                  decoration: BoxDecoration(
                    color: AppColors.page,
                    border: Border.all(color: AppColors.textPrimary, width: 2.5),
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
