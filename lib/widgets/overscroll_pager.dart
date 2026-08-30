import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../services/haptics.dart';
import '../theme/app_colors.dart';

/// Pages vertically, but only once the child's own scroll has run out.
///
/// The lift screen scrolls vertically inside each page, so a plain vertical
/// PageView would compete with it for the same drag. Reading the child's
/// over-drag instead makes the gesture continuous: scroll to the bottom of a
/// lift, keep pulling, and the next one rises behind it. Release past
/// [snapFraction] of the viewport and it takes over; release short and it
/// springs back, so a lifter can see what is coming and change their mind.
///
/// ## Why it owns its physics
///
/// The over-drag is read off `ScrollMetrics`. That only exists under
/// BouncingScrollPhysics: Clamping physics — Android's default — pins `pixels`
/// to the scroll range and reports the excess through `OverscrollNotification`
/// instead, so `pixels > maxScrollExtent` is never true there. An earlier
/// version listened only for the notification and did nothing on iPhone; the
/// fix swapped the failure to Android instead of removing it.
///
/// So the pager imposes bouncing physics on every scrollable beneath it rather
/// than hoping the caller picked the right one, and reads the notification as
/// well for any list that opts back out. It also strips the platform
/// overscroll indicator: Android's stretch fighting our own translation looked
/// like a rendering bug.
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

  /// Overscroll accumulated from notifications, for any scrollable below us
  /// that still runs clamping physics. Zeroed the moment the list is back
  /// inside its own range, because clamping physics reports the return trip as
  /// ordinary scrolling and would otherwise leave this stuck at the peak.
  double _accum = 0;

  /// Whether releasing now would turn the page. Tracked so the crossing can be
  /// announced once, in both directions — the pull-to-refresh convention, and
  /// what makes the gesture legible without watching the screen. A lifter
  /// mid-set is not looking at the phone.
  bool _armed = false;

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
    _accum = 0;
    _armed = false;

    if (goNext || goPrev) {
      // The thud of a thing landing. Heavier than the tick that armed it,
      // because arriving is a bigger event than becoming able to arrive.
      Haptics.success();
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
        final t = (_offset.abs() / (h * widget.snapFraction)).clamp(0.0, 1.0);
        return ScrollConfiguration(
          behavior: const _PagerScrollBehavior(),
          child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.axis != Axis.vertical) return false;
            final m = n.metrics;

            if (n is ScrollStartNotification) {
              _peak = 0;
              _accum = 0;
              _armed = false;
              return false;
            }

            if (n is OverscrollNotification) _accum += n.overscroll;

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
            } else {
              // Inside the range: clamping physics is scrolling normally, so
              // any accumulated overscroll is stale.
              _accum = 0;
            }
            if (over == 0) over = _accum;

            final want = over * widget.amplify;
            final allowed = want > 0
                ? (_canNext ? want : 0.0)
                : (_canPrev ? want : 0.0);

            if (allowed != _drag) {
              _drag = allowed;
              if (allowed.abs() > _peak.abs()) _peak = allowed;
              final armed = _peak.abs() > h * widget.snapFraction;
              if (armed != _armed) {
                _armed = armed;
                Haptics.selection();
              }
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
                    child: _Seam(
                      progress: t,
                      armed: _armed,
                      child: widget.builder(context, widget.index + 1),
                    ),
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
          ),
        );
      },
    );
  }
}

/// The edge of the lift being pulled into view.
///
/// Without it the incoming page slides up as an unannounced slab of the same
/// dark surface, and there is no moment where anything says "keep going and
/// this happens". The rule tracks the pull — dim and hairline at the start,
/// full accent the instant the gesture arms — so the screen says the same
/// thing the haptic does, for whoever happens to be looking at it.
class _Seam extends StatelessWidget {
  final double progress;
  final bool armed;
  final Widget child;
  const _Seam({required this.progress, required this.armed, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Container(
              height: armed ? 2.5 : 1.5,
              decoration: BoxDecoration(
                color: armed
                    ? AppColors.accent
                    : AppColors.borderStrong.withValues(alpha: 0.4 + progress * 0.6),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 14,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Bouncing physics everywhere below the pager, and no platform overscroll
/// indicator. Both are load-bearing: the gesture is read from over-drag
/// pixels that only bouncing physics produces, and Android's stretch effect
/// animating against our own translation reads as a glitch.
class _PagerScrollBehavior extends ScrollBehavior {
  const _PagerScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
