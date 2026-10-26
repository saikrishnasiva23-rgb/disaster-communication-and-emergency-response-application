import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/sos_packet.dart';
import '../state/emergency_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/state_views.dart';
import '../widgets/status_badge.dart';
import 'sos_details_screen.dart';

/// Real, local view of this device's own SOS history.
class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sosHistory = context.watch<EmergencyState>().sosHistory;

    return Scaffold(
      appBar: AppBar(title: const Text('SOS History')),
      body: sosHistory.isEmpty
          ? const AppEmptyView(
              icon: Icons.history,
              title: 'No SOS sent yet',
              subtitle: 'Your SOS alerts will appear here.',
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final side = math.max(
                  AppSpacing.page,
                  (constraints.maxWidth - 720) / 2,
                );
                return ListView.separated(
                  padding: EdgeInsets.fromLTRB(
                    side,
                    AppSpacing.sm,
                    side,
                    AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: sosHistory.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final packet = sosHistory[index];
                    return _SosHistoryCard(
                      packet: packet,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SosDetailsScreen(packetId: packet.id),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class _SosHistoryCard extends StatelessWidget {
  const _SosHistoryCard({required this.packet, required this.onTap});

  final SosPacket packet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = packet.status;
    final time = sosTimeLabel(context, packet.timestamp);

    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconBadge(icon: Icons.sos, color: AppColors.brand),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  packet.emergencyType,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                if (packet.message.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    packet.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusBadge(
                      label: status.displayLabel,
                      tone: status.tone,
                      icon: status.icon,
                    ),
                    Text(time, style: theme.textTheme.bodySmall),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
