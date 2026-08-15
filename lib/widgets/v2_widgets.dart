import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Standard v2 card: surface fill, hairline border, 18px radius.
class V2Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  const V2Card({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(15),
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        border: Border.all(color: borderColor ?? AppColors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: child,
    );
  }
}

/// A status token: colour + icon + word, never colour alone (the design's
/// contrast rule — ~8% of men have a red/green deficiency).
class StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const StatusChip({super.key, required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  fontSize: 10.5,
                  color: color)),
        ],
      ),
    );
  }
}
