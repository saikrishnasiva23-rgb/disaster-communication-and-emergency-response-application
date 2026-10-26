import 'package:flutter/material.dart';

import '../models/ai_priority_result.dart';
import '../models/location_data.dart';
import '../models/rescue_case.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';
import 'priority_badge.dart';
import 'status_badge.dart';

/// Displays a single real RescueCase (BLE-received or backend-sourced,
/// see RescueCaseSource): type, original sender, people, location, time,
/// rescue status and priority. Every value shown comes from the case
/// itself -- nothing is filled in when a field is missing.
class EmergencyCard extends StatelessWidget {
  final RescueCase rescueCase;
  final VoidCallback? onTap;
  final Widget? trailing;

  const EmergencyCard({
    super.key,
    required this.rescueCase,
    this.onTap,
    this.trailing,
  });

  /// An icon for an emergency type string (the wire values used by the
  /// affected phone and the backend). Unknown types fall back to SOS.
  static IconData iconForType(String emergencyType) {
    final type = emergencyType.toLowerCase();
    if (type.contains('medical') || type.contains('injur')) {
      return Icons.medical_services_outlined;
    }
    if (type.contains('fire')) return Icons.local_fire_department_outlined;
    if (type.contains('flood')) return Icons.flood_outlined;
    if (type.contains('trapped')) return Icons.person_pin_circle_outlined;
    if (type.contains('cyclone')) return Icons.cyclone;
    if (type.contains('landslide')) return Icons.landslide_outlined;
    if (type.contains('earthquake')) return Icons.crisis_alert;
    return Icons.sos;
  }

  /// Short label, tone and icon for a real RescueStatus.
  static (String, StatusTone, IconData) describeStatus(RescueStatus status) {
    switch (status) {
      case RescueStatus.pending:
        return ('Pending', StatusTone.warning, Icons.hourglass_empty);
      case RescueStatus.assigned:
        return ('Assigned', StatusTone.info, Icons.assignment_ind_outlined);
      case RescueStatus.inProgress:
        return ('In progress', StatusTone.info, Icons.directions_run);
      case RescueStatus.rescued:
        return ('Rescued', StatusTone.success, Icons.check_circle_outline);
    }
  }

  /// Time of day for today, otherwise date and time.
  static String formatTime(BuildContext context, DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final clock = TimeOfDay.fromDateTime(local).format(context);
    final sameDay =
        local.year == now.year && local.month == now.month && local.day == now.day;
    if (sameDay) return clock;
    return '${MaterialLocalizations.of(context).formatShortMonthDay(local)}, $clock';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final priority = rescueCase.aiPriority;
    final accent = priority != null
        ? PriorityBadge.colorOf(context, priority.level)
        : context.status.danger;
    final (statusLabel, statusTone, statusIcon) = describeStatus(rescueCase.status);
    final isBle = rescueCase.source == RescueCaseSource.ble;
    final people = rescueCase.numberOfPeople;

    // The local estimate's reason lists the real factors it found; the
    // backend's reason is a fixed technical note, so it is not shown here.
    final reason = priority != null &&
            priority.source == AiPrioritySource.localFallback &&
            priority.reason.trim().isNotEmpty
        ? _capitalize(priority.reason.trim())
        : null;

    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(icon: iconForType(rescueCase.emergencyType), color: accent),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rescueCase.emergencyType,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'From ${rescueCase.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              if (priority != null) ...[
                const SizedBox(width: AppSpacing.sm),
                PriorityBadge(level: priority.level),
              ],
            ],
          ),
          if (rescueCase.message.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              rescueCase.message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: [
              CaseMetaItem(
                icon: Icons.group_outlined,
                label: '$people ${people == 1 ? 'person' : 'people'}',
              ),
              CaseMetaItem(
                icon: Icons.healing_outlined,
                label: rescueCase.injured ? 'Injured' : 'No injuries',
                color: rescueCase.injured ? context.status.danger : null,
              ),
              CaseMetaItem(
                icon: Icons.schedule,
                label: formatTime(context, rescueCase.receivedAt),
              ),
              CaseMetaItem(
                icon: isBle ? Icons.bluetooth : Icons.cloud_outlined,
                label: isBle ? 'Bluetooth' : 'Online',
              ),
              if (rescueCase.relayedByName != null)
                CaseMetaItem(
                  icon: Icons.alt_route,
                  label: 'Relayed by ${rescueCase.relayedByName}',
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              StatusBadge(label: statusLabel, tone: statusTone, icon: statusIcon),
              _locationBadge(),
              ?_ackBadge(),
            ],
          ),
          if (reason != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(height: AppSpacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }

  /// No fix at all is "No location", never a made-up coordinate; an old
  /// fix is labelled as old rather than live.
  Widget _locationBadge() {
    if (!rescueCase.hasLocation) {
      return const StatusBadge(
        label: 'No location',
        tone: StatusTone.neutral,
        icon: Icons.location_off_outlined,
      );
    }
    final freshness = LocationData(
      latitude: rescueCase.latitude!,
      longitude: rescueCase.longitude!,
      capturedAt: rescueCase.capturedAt,
    ).freshnessAt(DateTime.now());
    switch (freshness) {
      case LocationFreshness.live:
        return const StatusBadge(
          label: 'Live location',
          tone: StatusTone.success,
          icon: Icons.my_location,
        );
      case LocationFreshness.recent:
        return const StatusBadge(
          label: 'Recent location',
          tone: StatusTone.warning,
          icon: Icons.location_on_outlined,
        );
      case LocationFreshness.unavailable:
        return const StatusBadge(
          label: 'Old location',
          tone: StatusTone.neutral,
          icon: Icons.location_on_outlined,
        );
    }
  }

  /// Only shown when an acknowledgement is actually being tracked.
  Widget? _ackBadge() {
    switch (rescueCase.ackDelivery) {
      case AckDelivery.notApplicable:
        return null;
      case AckDelivery.sending:
        return const StatusBadge(
          label: 'Sending ack',
          tone: StatusTone.neutral,
          icon: Icons.sync,
        );
      case AckDelivery.sent:
        return const StatusBadge(
          label: 'Ack sent',
          tone: StatusTone.success,
          icon: Icons.done_all,
        );
      case AckDelivery.failed:
        return const StatusBadge(
          label: 'Ack not sent',
          tone: StatusTone.danger,
          icon: Icons.error_outline,
        );
    }
  }

  static String _capitalize(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

/// A small icon + text fact on a case card (people, time, source...).
class CaseMetaItem extends StatelessWidget {
  const CaseMetaItem({
    super.key,
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;

  /// Defaults to the muted text colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: c,
              fontWeight: color != null ? FontWeight.w600 : null,
            ),
          ),
        ),
      ],
    );
  }
}
