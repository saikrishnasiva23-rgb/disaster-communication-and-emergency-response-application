import 'package:flutter/material.dart';

import '../models/ai_priority_result.dart';
import '../theme/app_theme.dart';

/// Shows a real AiPriorityLevel -- never a made-up value. Colour, icon and
/// text together, so priority never depends on colour alone.
class PriorityBadge extends StatelessWidget {
  final AiPriorityLevel level;
  final bool large;

  const PriorityBadge({super.key, required this.level, this.large = false});

  static Color colorOf(BuildContext context, AiPriorityLevel level) {
    final s = context.status;
    switch (level) {
      case AiPriorityLevel.critical:
        return s.critical;
      case AiPriorityLevel.high:
        return s.high;
      case AiPriorityLevel.medium:
        return s.medium;
      case AiPriorityLevel.low:
        return s.low;
      case AiPriorityLevel.unknown:
        return s.neutral;
    }
  }

  static String labelOf(AiPriorityLevel level) {
    switch (level) {
      case AiPriorityLevel.critical:
        return 'Critical';
      case AiPriorityLevel.high:
        return 'High';
      case AiPriorityLevel.medium:
        return 'Medium';
      case AiPriorityLevel.low:
        return 'Low';
      case AiPriorityLevel.unknown:
        return 'Unknown';
    }
  }

  static IconData iconOf(AiPriorityLevel level) {
    switch (level) {
      case AiPriorityLevel.critical:
        return Icons.priority_high;
      case AiPriorityLevel.high:
        return Icons.warning_rounded;
      case AiPriorityLevel.medium:
        return Icons.error_outline;
      case AiPriorityLevel.low:
        return Icons.check_circle_outline;
      case AiPriorityLevel.unknown:
        return Icons.help_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorOf(context, level);
    return Semantics(
      label: 'Priority ${labelOf(level)}',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: large ? 14 : 10,
          vertical: large ? 7 : 4,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconOf(level), size: large ? 18 : 14, color: color),
            SizedBox(width: large ? 6 : 4),
            Text(
              labelOf(level).toUpperCase(),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: large ? 14 : 11,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
