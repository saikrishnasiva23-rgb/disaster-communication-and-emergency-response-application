import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/ai_priority_result.dart';
import '../models/sos_packet.dart';
import '../services/sos_service.dart';
import '../state/emergency_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/info_row.dart';
import '../widgets/priority_badge.dart';
import '../widgets/section_header.dart';
import '../widgets/state_views.dart';
import '../widgets/status_badge.dart';

/// How a [SosStatus] is shown to the person who sent the SOS. Shared by
/// the SOS History list and the details screen so both use the same words.
///
/// Saved (local outbox) -> Sent (handed to the next device) -> Relayed (a
/// relay phone confirmed it) -> Received (the Rescue Team's end-to-end
/// ACK) -> Acknowledged (a rescuer acted on it). These are never merged.
extension SosStatusDisplay on SosStatus {
  String get displayLabel => switch (this) {
        SosStatus.created || SosStatus.queued => 'Saved',
        SosStatus.sentToRelay => 'Sent',
        SosStatus.relayed => 'Relayed',
        SosStatus.receivedByRescue => 'Received',
        SosStatus.acknowledged => 'Acknowledged',
        SosStatus.failed => 'Not delivered',
      };

  StatusTone get tone => switch (this) {
        SosStatus.created || SosStatus.queued => StatusTone.warning,
        SosStatus.sentToRelay => StatusTone.warning,
        SosStatus.relayed => StatusTone.info,
        SosStatus.receivedByRescue => StatusTone.success,
        SosStatus.acknowledged => StatusTone.success,
        SosStatus.failed => StatusTone.danger,
      };

  IconData get icon => switch (this) {
        SosStatus.created || SosStatus.queued => Icons.save_outlined,
        SosStatus.sentToRelay => Icons.north_east,
        SosStatus.relayed => Icons.alt_route,
        SosStatus.receivedByRescue => Icons.check_circle_outline,
        SosStatus.acknowledged => Icons.verified_outlined,
        SosStatus.failed => Icons.error_outline,
      };

  /// One short line under the status.
  String get hint => switch (this) {
        SosStatus.created || SosStatus.queued => 'Sends when a device connects',
        SosStatus.sentToRelay => 'Waiting for confirmation',
        SosStatus.relayed => 'On its way to the Rescue Team',
        SosStatus.receivedByRescue => 'The Rescue Team has your SOS',
        SosStatus.acknowledged => 'The Rescue Team responded',
        SosStatus.failed => 'Could not be delivered',
      };

  /// Index into [sosProgressSteps] reached, or -1 for [SosStatus.failed].
  int get progressStep => switch (this) {
        SosStatus.created || SosStatus.queued => 0,
        SosStatus.sentToRelay => 1,
        SosStatus.relayed => 2,
        SosStatus.receivedByRescue => 3,
        SosStatus.acknowledged => 4,
        SosStatus.failed => -1,
      };
}

const List<String> sosProgressSteps = [
  'Saved',
  'Sent',
  'Relayed',
  'Received',
  'Acknowledged',
];

/// "Today, 14:05", "Yesterday, 09:12", "Mar 3, 18:40" or a full date.
String sosTimeLabel(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final l10n = MaterialLocalizations.of(context);
  final clock = l10n.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  final now = DateTime.now();
  if (DateUtils.isSameDay(local, now)) return 'Today, $clock';
  if (DateUtils.isSameDay(local, DateUtils.addDaysToDate(now, -1))) {
    return 'Yesterday, $clock';
  }
  if (local.year == now.year) return '${l10n.formatShortMonthDay(local)}, $clock';
  return '${l10n.formatShortDate(local)}, $clock';
}

/// One SOS this device sent, with live delivery updates.
class SosDetailsScreen extends StatelessWidget {
  const SosDetailsScreen({super.key, required this.packetId});

  final String packetId;

  @override
  Widget build(BuildContext context) {
    final packet = context.watch<EmergencyState>().sosById(packetId);

    return Scaffold(
      appBar: AppBar(title: const Text('SOS Details')),
      body: packet == null
          ? const AppEmptyView(
              icon: Icons.search_off,
              title: 'SOS not found',
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final side = math.max(
                  AppSpacing.page,
                  (constraints.maxWidth - 720) / 2,
                );
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    side,
                    AppSpacing.sm,
                    side,
                    AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    _StatusCard(packet: packet),
                    const SizedBox(height: AppSpacing.lg),
                    const SectionHeader(title: 'Details'),
                    _DetailsCard(packet: packet),
                    _RescueSection(packet: packet),
                    const SizedBox(height: AppSpacing.lg),
                    _TechnicalDetails(packet: packet),
                  ],
                );
              },
            ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.packet});

  final SosPacket packet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = packet.status;
    final color = status.tone.color(context);

    return AppCard(
      borderColor: color.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(icon: status.icon, color: color),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 2),
                    Text(
                      status.displayLabel,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: color, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(status.hint, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.lg),
          _SosProgress(status: status),
        ],
      ),
    );
  }
}

/// The five delivery steps, filled up to the real status. A failed SOS is
/// shown as saved on this phone, then "Not delivered" -- never as sent.
class _SosProgress extends StatelessWidget {
  const _SosProgress({required this.status});

  final SosStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = status == SosStatus.failed;
    // Every SOS in the history was saved on this phone first.
    final reached = failed ? 0 : status.progressStep;
    final doneColor = failed ? context.status.neutral : status.tone.color(context);
    final idleColor = theme.colorScheme.outlineVariant;
    final muted = theme.colorScheme.onSurfaceVariant;

    final rows = <Widget>[];
    for (var i = 0; i < sosProgressSteps.length; i++) {
      final done = i <= reached;
      final current = i == reached && !failed;
      rows.add(_StepRow(
        icon: done ? Icons.check_circle : Icons.radio_button_unchecked,
        iconColor: done ? doneColor : idleColor,
        label: sosProgressSteps[i],
        style: current
            ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)
            : theme.textTheme.bodyMedium?.copyWith(color: done ? null : muted),
      ));
      if (i < sosProgressSteps.length - 1) {
        rows.add(_StepConnector(color: i < reached ? doneColor : idleColor));
      }
    }
    if (failed) {
      final danger = context.status.danger;
      rows
        ..add(_StepConnector(color: danger))
        ..add(_StepRow(
          icon: Icons.cancel,
          iconColor: danger,
          label: 'Not delivered',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: danger, fontWeight: FontWeight.w700),
        ));
    }

    return Semantics(
      label: failed
          ? 'Progress: not delivered'
          : 'Progress: step ${reached + 1} of ${sosProgressSteps.length}, '
              '${sosProgressSteps[reached]}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.style,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 22, color: iconColor),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: Text(label, style: style)),
      ],
    );
  }
}

class _StepConnector extends StatelessWidget {
  const _StepConnector({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Centred under the 22 px step icon.
      padding: const EdgeInsets.only(left: 10),
      child: Container(width: 2, height: 10, color: color),
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.packet});

  final SosPacket packet;

  @override
  Widget build(BuildContext context) {
    final lat = packet.latitude;
    final lon = packet.longitude;
    final accuracy = packet.accuracyMeters;
    final location = lat != null && lon != null
        ? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
            '${accuracy != null ? '  (±${accuracy.round()} m)' : ''}'
        : 'Not included';

    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoRow(
            icon: Icons.emergency_outlined,
            label: 'Emergency type',
            value: packet.emergencyType,
          ),
          InfoRow(
            icon: Icons.chat_bubble_outline,
            label: 'Message',
            value: packet.message.isEmpty ? 'No message' : packet.message,
          ),
          InfoRow(
            icon: Icons.schedule,
            label: 'Time sent',
            value: sosTimeLabel(context, packet.timestamp),
          ),
          InfoRow(
            icon: Icons.location_on_outlined,
            label: 'Location',
            value: location,
          ),
          InfoRow(
            icon: Icons.psychology_alt_outlined,
            label: 'Priority',
            value: 'Local estimate',
            trailing: PriorityBadge(level: aiPriorityFromString(packet.priority)),
          ),
        ],
      ),
    );
  }
}

/// What the Rescue Team sent back for this SOS, if anything: the time its
/// end-to-end confirmation arrived and the latest rescue update.
class _RescueSection extends StatelessWidget {
  const _RescueSection({required this.packet});

  final SosPacket packet;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SosRequestState>(
      valueListenable: SosService.instance.current,
      builder: (context, request, _) {
        final confirmedAt =
            packet.status.reachedRescue ? packet.acknowledgedAt : null;
        final rawUpdate =
            request.packetId == packet.id ? request.rescueUpdate : null;
        final update = rawUpdate?.replaceFirst('Rescue Team update: ', '');

        if (confirmedAt == null && (update == null || update.isEmpty)) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(title: 'Rescue Team'),
              AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (confirmedAt != null)
                      InfoRow(
                        icon: Icons.verified_outlined,
                        label: 'Received by Rescue Team',
                        value: sosTimeLabel(context, confirmedAt),
                        valueColor: context.status.success,
                      ),
                    if (update != null && update.isNotEmpty)
                      InfoRow(
                        icon: Icons.campaign_outlined,
                        label: 'Latest update',
                        value: _capitalize(update),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

class _TechnicalDetails extends StatelessWidget {
  const _TechnicalDetails({required this.packet});

  final SosPacket packet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final relay = packet.relayedByName ?? packet.relayedBy;

    return AppCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        leading: const Icon(Icons.code),
        title: Text('Technical details', style: theme.textTheme.titleSmall),
        shape: const Border(),
        collapsedShape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TechRow(
            label: 'Packet ID',
            value: packet.id,
            trailing: IconButton(
              tooltip: 'Copy packet ID',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: packet.id));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Packet ID copied')),
                );
              },
            ),
          ),
          _TechRow(label: 'Status', value: packet.status.name),
          _TechRow(label: 'Hop count', value: '${packet.hopCount}'),
          _TechRow(label: 'TTL', value: '${packet.ttl}'),
          _TechRow(label: 'Max hops', value: '${packet.maxHops}'),
          if (relay != null) _TechRow(label: 'Last relay', value: relay),
          if (packet.path.isNotEmpty)
            _TechRow(label: 'Relay path', value: packet.path.join(' → ')),
          _TechRow(label: 'Protocol', value: 'v${packet.protocolVersion}'),
        ],
      ),
    );
  }
}

class _TechRow extends StatelessWidget {
  const _TechRow({required this.label, required this.value, this.trailing});

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
