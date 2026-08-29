import 'package:flutter/material.dart';

/// Pages vertically, but only once the child's own scroll has run out.
///
/// The lift screen scrolls vertically inside each page, so a plain vertical
/// PageView would compete with it for the same drag. Listening to overscroll
/// instead means the gesture is continuous: scroll to the bottom of a lift,
/// keep pulling, and the next one rises behind it. Release past
/// [snapFraction] of the viewport and it takes over; release short and it
/// springs back, so a lifter can see what is coming and change their mind.
class OverscrollPager extends StatefulWidget {
  final int index;
  final int count;
  final IndexedWidgetBuilder builder;
  final ValueChanged<int> onPage;
  final double snapFraction;

  const OverscrollPager({
    super.key,
    required this.index,
    required this.count,
    required this.builder,
    required this.onPage,
    this.snapFraction = 0.35,
  });

  @override
  State<OverscrollPager> createState() => _OverscrollPagerState();
}

class _OverscrollPagerState extends State<OverscrollPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(() => setState(() {}));

  /// Signed drag in logical pixels. Positive = pulling the NEXT lift up.
  double _drag = 0;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  bool get _canNext => widget.index < widget.count - 1;
  bool get _canPrev => widget.index > 0;

  double get _offset =>
      _anim.isAnimating ? _drag * (1 - _anim.value) : _drag;

  void _settle(double height) {
    final threshold = height * widget.snapFraction;
    final goNext = _drag > threshold && _canNext;
    final goPrev = _drag < -threshold && _canPrev;

    if (goNext || goPrev) {
      widget.onPage(widget.index + (goNext ? 1 : -1));
      _drag = 0;
      _anim.value = 0;
      setState(() {});
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
            if (n is OverscrollNotification) {
              final pulling = n.overscroll > 0 ? _canNext : _canPrev;
              if (pulling) {
                // Damped so the pull feels elastic rather than 1:1.
                setState(() => _drag += n.overscroll * 0.5);
              }
            } else if (n is ScrollEndNotification && _drag != 0) {
              _settle(h);
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
                    height: h,
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
