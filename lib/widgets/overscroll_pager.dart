import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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

  /// The pull as of the last update the *finger* caused.
  ///
  /// This used to settle on the furthest the pull ever reached, to survive
  /// iOS springing the list back before the gesture ended. It over-corrected:
  /// a peak that only ever grows cannot tell "the physics decayed it" from
  /// "the lifter pulled back because they changed their mind", so dragging
  /// back to neutral still turned the page. Worse, the peak tracked the
  /// largest magnitude in *either* direction, so pulling up and then further
  /// down flipped it negative and jumped to the previous lift.
  ///
  /// Reading dragDetails separates the two properly: it is non-null only
  /// while the finger is driving, so the spring-back is ignored without
  /// having to guess, and this value is simply where the lifter left it.
  double _userDrag = 0;

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
    final goNext = _userDrag > threshold && _canNext;
    final goPrev = _userDrag < -threshold && _canPrev;
    _userDrag = 0;
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
              _userDrag = 0;
              _accum = 0;
              _armed = false;
              return false;
            }

            // The finger has come off. Settle now rather than waiting for
            // ScrollEndNotification, which on iOS only arrives once the
            // spring-back animation has finished — a visible pause with the
            // page held open.
            if (n is UserScrollNotification &&
                n.direction == ScrollDirection.idle) {
              if (_drag != 0) _settle(h);
              return false;
            }

            if (n is ScrollEndNotification) {
              if (_drag != 0) _settle(h);
              return false;
            }

            // Only the finger moves the page. Momentum and the bounce-back
            // are the scroll view's business, and letting them write here is
            // what made a deliberate change of mind unreportable.
            final driving = switch (n) {
              ScrollUpdateNotification u => u.dragDetails != null,
              OverscrollNotification o => o.dragDetails != null,
              _ => false,
            };
            if (!driving) return false;

            if (n is OverscrollNotification) _accum += n.overscroll;

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
              _userDrag = allowed;
              final armed = allowed.abs() > h * widget.snapFraction;
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
