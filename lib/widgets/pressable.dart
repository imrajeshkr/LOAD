import 'package:flutter/widgets.dart';
import '../services/haptics.dart';

/// How strong the tap feedback is — scaled to the button's importance.
/// light: chips, list rows, toggles, secondary. medium: primary CTAs.
/// strong: big moments (finish, rebuild, confirm). none: no haptic.
enum PressFx { none, light, medium, strong }

/// A drop-in tappable that adds the two things every button in the app should
/// have: a quick press-scale so a tap reads as registered, and a haptic tuned
/// to the action's weight. Use in place of a plain `GestureDetector(onTap:)`.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final PressFx haptic;
  final double scale;
  final HitTestBehavior behavior;
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.haptic = PressFx.light,
    this.scale = 0.96,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _fire() {
    switch (widget.haptic) {
      case PressFx.light:
        Haptics.selection();
      case PressFx.medium:
        Haptics.tap();
      case PressFx.strong:
        Haptics.success();
      case PressFx.none:
        break;
    }
  }

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _enabled ? (_) => _set(true) : null,
      onTapUp: _enabled ? (_) => _set(false) : null,
      onTapCancel: _enabled ? () => _set(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              _fire();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              Haptics.tap();
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
