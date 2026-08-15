import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The 16:10 exercise demo slot — a real image/animated-WebP from Supabase
/// Storage when [url] resolves, else the same placeholder the app has always
/// shown. One widget so the Guide screen and the in-session flow can't drift.
class ExerciseDemoMedia extends StatelessWidget {
  final String? url;
  const ExerciseDemoMedia({super.key, this.url});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Container(
          color: AppColors.chipFill,
          child: url == null
              ? const _DemoPlaceholder()
              : Image.network(
                  url!,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child: SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  },
                  errorBuilder: (context, error, stack) => const _DemoPlaceholder(),
                ),
        ),
      ),
    );
  }
}

class _DemoPlaceholder extends StatelessWidget {
  const _DemoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.play_circle_outline_rounded, size: 40, color: AppColors.accent),
        SizedBox(height: 10),
        Text(
          'Demo clip coming soon',
          style: TextStyle(
            fontFamily: AppTheme.fontFamily,
            fontWeight: FontWeight.w700,
            fontSize: 12,
            color: AppColors.accent,
          ),
        ),
      ],
    );
  }
}

/// White rounded card — the workhorse container from the design guide.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: body,
      ),
    );
  }
}

/// Full-width selectable row used across onboarding and settings.
///
/// Uses an intrinsic-height row rather than a fixed size so long labels
/// wrap cleanly instead of being clipped.
class SelectableRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  const SelectableRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        height: 1.3,
                        color: selected ? AppColors.onAccent : AppColors.textBody,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w600,
                          fontSize: 11.5,
                          height: 1.35,
                          color: selected
                              ? AppColors.onAccent.withValues(alpha: 0.85)
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_rounded, size: 18, color: AppColors.onAccent),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact chip for short, side-by-side choices (experience, RPE, body parts).
///
/// Sizes to its content and never wraps mid-word — the previous grid-based
/// version clipped "Intermediate" onto two lines.
class ChoiceChipButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? selectedColor;
  final Color? selectedFg;

  const ChoiceChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedColor,
    this.selectedFg,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? (selectedColor ?? AppColors.accent) : AppColors.surface;
    final fg = selected ? (selectedFg ?? AppColors.onAccent) : AppColors.textMuted;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
            style: TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
              height: 1.1,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small pill badge, e.g. the "Guide" affordance on an exercise row.
class MiniPill extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color? background;
  final Color? foreground;
  final IconData? icon;

  const MiniPill({
    super.key,
    required this.label,
    this.onTap,
    this.background,
    this.foreground,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? AppColors.chipFill,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: foreground ?? AppColors.accent),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              height: 1.1,
              color: foreground ?? AppColors.accent,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    );
  }
}

/// Section heading used above groups of content.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            text,
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Soft peach banner used for nudges and welcome-back messaging.
class SoftBanner extends StatelessWidget {
  final String? title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color? background;

  const SoftBanner({
    super.key,
    this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: background ?? AppColors.peach,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                height: 1.3,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 5),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    height: 1.45,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onAction,
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Screen header — big warm title with an optional eyebrow and trailing slot.
class ScreenHeader extends StatelessWidget {
  final String title;
  final String? eyebrow;
  final String? accentLine;
  final Widget? trailing;

  const ScreenHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.accentLine,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eyebrow != null)
            Text(
              eyebrow!,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
              ),
              ?trailing,
            ],
          ),
          if (accentLine != null) ...[
            const SizedBox(height: 4),
            Text(
              accentLine!,
              style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
                height: 1.6,
                color: AppColors.accent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Empty-state hint shown inside cards when there's no data yet.
class EmptyHint extends StatelessWidget {
  final String message;
  final IconData icon;
  const EmptyHint(this.message, {super.key, this.icon = Icons.insights_rounded});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 26, color: AppColors.textFaint),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: AppTheme.fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 12.5,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
