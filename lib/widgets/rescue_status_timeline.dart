import 'package:flutter/material.dart';

import '../models/rescue_case.dart';
import '../theme/app_theme.dart';

/// Renders the app's REAL RescueStatus (pending/assigned/inProgress/
/// rescued) as a vertical timeline. Only ever shows the status a
/// RescueCase actually has -- there is no independent "demo" state here.
class RescueStatusTimeline extends StatelessWidget {
  final RescueStatus current;

  const RescueStatusTimeline({super.key, required this.current});

  static const List<(RescueStatus, String, IconData)> _steps = [
    (RescueStatus.pending, 'SOS Received', Icons.sos),
    (RescueStatus.assigned, 'Rescue Assigned', Icons.assignment_ind_outlined),
    (RescueStatus.inProgress, 'Rescue Started', Icons.directions_run),
    (RescueStatus.rescued, 'Person Rescued', Icons.check_circle_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final currentIndex = _steps.indexWhere((s) => s.$1 == current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _steps.length; i++)
          _TimelineStep(
            icon: _steps[i].$3,
            label: _steps[i].$2,
            isDone: i <= currentIndex,
            isCurrent: i == currentIndex,
            isLast: i == _steps.length - 1,
            // The line below a step is "done" once the next step is reached.
            nextDone: i + 1 <= currentIndex,
          ),
      ],
    );
  }
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.icon,
    required this.label,
    required this.isDone,
    required this.isCurrent,
    required this.isLast,
    required this.nextDone,
  });

  final IconData icon;
  final String label;
  final bool isDone;
  final bool isCurrent;
  final bool isLast;
  final bool nextDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = context.status.success;
    final idle = theme.colorScheme.outlineVariant;
    final idleText = theme.colorScheme.onSurfaceVariant;
    final color = isDone ? done : idleText;

    return Semantics(
      label: '$label, ${isCurrent ? 'current step' : isDone ? 'done' : 'not reached'}',
      excludeSemantics: true,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone ? done.withValues(alpha: 0.14) : Colors.transparent,
                    border: Border.all(
                      color: isDone ? done : idle,
                      width: isCurrent ? 2 : 1.5,
                    ),
                  ),
                  child: Icon(icon, color: color, size: 18),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      constraints: const BoxConstraints(minHeight: AppSpacing.md),
                      color: nextDone ? done.withValues(alpha: 0.6) : idle,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  top: 6,
                  bottom: isLast ? 0 : AppSpacing.lg,
                ),
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: isCurrent
                        ? FontWeight.w700
                        : isDone
                            ? FontWeight.w600
                            : FontWeight.w400,
                    color: isDone ? theme.colorScheme.onSurface : idleText,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
