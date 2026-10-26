import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// What a status means, independent of the colour used to show it.
enum StatusTone { success, warning, info, danger, neutral, brand }

extension StatusToneColor on StatusTone {
  Color color(BuildContext context) {
    final s = context.status;
    switch (this) {
      case StatusTone.success:
        return s.success;
      case StatusTone.warning:
        return s.warning;
      case StatusTone.info:
        return s.info;
      case StatusTone.danger:
        return s.danger;
      case StatusTone.neutral:
        return s.neutral;
      case StatusTone.brand:
        return AppColors.brand;
    }
  }
}

/// A small pill: icon + text, so status is never shown by colour alone.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = tone.color(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// A coloured dot with a text label beside it.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.tone, this.size = 10});

  final StatusTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tone.color(context), shape: BoxShape.circle),
    );
  }
}
