import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Pages vertically, but only once the child's own scroll has run out.
///
/// The lift screen scrolls vertically inside each page, so a plain vertical
/// PageView would compete with it for the same drag. Reading the child's
/// over-drag instead makes the gesture continuous: scroll to the bottom of a
/// lift, keep pulling, and the next one rises behind it. Release past
/// [snapFraction] of the viewport and it takes over; release short and it
/// springs back, so a lifter can see what is coming and change their mind.
///
/// It reads the over-drag off `ScrollMetrics` rather than listening for
/// `OverscrollNotification`. That notification is a ClampingScrollPhysics
/// (Android) signal; iOS defaults to BouncingScrollPhysics, which absorbs the
/// drag into its own bounce and never emits it — so the first version of this
/// widget did nothing at all on iPhone.
class OverscrollPager extends StatefulWidget {
  final int index;
  final int count;
  final IndexedWidgetBuilder builder;
  final ValueChanged<int> onPage;

  /// Fraction of the viewport the pull must reach to take over. Low because
  /// iOS bounce is heavily damped — a full-screen drag yields only a couple of
  /// hundred logical pixels of over-drag.
  final double snapFraction;

  /// Multiplies the bounce so the page tracks the finger rather than the
  /// much smaller distance iOS actually lets the list travel.
  final double amplify;

  const OverscrollPager({
    super.key,
    required this.index,
    required this.count,
    required this.builder,
    required this.onPage,
    this.snapFraction = 0.18,
    this.amplify = 1.8,
  });

  @override
  State<OverscrollPager> createState() => _OverscrollPagerState();
}

class _OverscrollPagerState extends State<OverscrollPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  )..addListener(() => setState(() {}));

  /// Signed pull in logical pixels. Positive = dragging the NEXT lift up.
  double _drag = 0;

  /// The furthest the pull reached during this gesture. Settling on the peak
  /// rather than the release value matters because iOS springs the list back
  /// before the gesture ends — by the time the finger lifts, the live value
  /// has already decayed toward zero and would never clear the threshold.
  double _peak = 0;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  bool get _canNext => widget.index < widget.count - 1;
  bool get _canPrev => widget.index > 0;

  double get _offset => _anim.isAnimating ? _drag * (1 - _anim.value) : _drag;

  void _settle(double height) {
    final threshold = height * widget.snapFraction;
    final goNext = _peak > threshold && _canNext;
    final goPrev = _peak < -threshold && _canPrev;
    _peak = 0;

    if (goNext || goPrev) {
      widget.onPage(widget.index + (goNext ? 1 : -1));
      _drag = 0;
      _anim.value = 0;
      if (mounted) setState(() {});
      return;
    }
    // Short of the threshold: spring back, nothing changed.
    _anim.forward(from: 0).whenComplete(() {
      _drag = 0;
      _anim.value = 0;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight;
        final o = _offset.clamp(-h, h);
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.axis != Axis.vertical) return false;
            final m = n.metrics;

            if (n is ScrollStartNotification) {
              _peak = 0;
              return false;
            }

            if (n is ScrollEndNotification) {
              if (_drag != 0 || _peak != 0) _settle(h);
              return false;
            }

            // How far the list has been dragged past an edge. Positive past
            // the bottom (pulling the next lift up), negative past the top.
            double over = 0;
            if (m.pixels > m.maxScrollExtent) {
              over = m.pixels - m.maxScrollExtent;
            } else if (m.pixels < m.minScrollExtent) {
              over = m.pixels - m.minScrollExtent;
            }

            final want = over * widget.amplify;
            final allowed = want > 0
                ? (_canNext ? want : 0.0)
                : (_canPrev ? want : 0.0);

            if (allowed != _drag) {
              _drag = allowed;
              if (allowed.abs() > _peak.abs()) _peak = allowed;
              setState(() {});
            }
            return false;
          },
          child: Stack(
            children: [
              Transform.translate(
                offset: Offset(0, -o),
                child: widget.builder(context, widget.index),
              ),
              if (o > 0 && _canNext)
                Transform.translate(
                  offset: Offset(0, h - o),
                  child: SizedBox(
                    height: h,
                    child: widget.builder(context, widget.index + 1),
                  ),
                ),
              if (o < 0 && _canPrev)
                Transform.translate(
                  offset: Offset(0, -h - o),
                  child: SizedBox(
                    height: math.max(h, 0),
                    child: widget.builder(context, widget.index - 1),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
