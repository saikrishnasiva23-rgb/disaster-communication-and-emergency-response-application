import 'package:flutter/material.dart';

import '../services/affected_peripheral_service.dart';
import '../services/mesh/android_peripheral_transport.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/state_views.dart';
import '../widgets/status_badge.dart';

/// Devices this phone is really connected to (identified links only), plus
/// whether it can be found and is searching. Nothing here is inferred from
/// Bluetooth merely being on.
class NearbyDevicesScreen extends StatelessWidget {
  const NearbyDevicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nearby Devices')),
      body: ValueListenableBuilder<AffectedLinkStatus>(
        valueListenable: AffectedPeripheralService.instance.status,
        builder: (context, link, _) => ListView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.sm,
            AppSpacing.page,
            AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            _SummaryCard(link: link),
            ..._problem(context, link),
            const SizedBox(height: AppSpacing.lg),
            if (link.peers.isEmpty)
              AppEmptyView(
                icon: Icons.radar,
                title: 'No devices connected',
                subtitle: link.isFailure
                    ? null
                    : 'Nearby phones and the Rescue Team connect automatically.',
              )
            else ...[
              Text('Connected', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              for (final peer in link.peers)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _PeerTile(peer: peer),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// One short notice when the user has to act.
  List<Widget> _problem(BuildContext context, AffectedLinkStatus link) {
    final s = context.status;
    Widget notice(String text, IconData icon, Color color, [Widget? action]) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md),
          child: AppNotice(message: text, icon: icon, color: color, action: action),
        );

    switch (link.phase) {
      case AffectedLinkPhase.permissionDenied:
        return [
          notice('Allow Nearby devices permission to connect.', Icons.lock_outline, s.warning,
              const TextButton(
                onPressed: AndroidPeripheralTransport.openAppSettings,
                child: Text('Allow'),
              )),
        ];
      case AffectedLinkPhase.bluetoothOff:
        return [
          notice('Bluetooth is off.', Icons.bluetooth_disabled, s.danger, TextButton(
            onPressed: () async {
              await AndroidPeripheralTransport.enableBluetooth();
              await AffectedPeripheralService.instance.start();
            },
            child: const Text('Turn on'),
          )),
        ];
      case AffectedLinkPhase.unsupported:
        return [
          notice('Bluetooth is not available on this device.', Icons.bluetooth_disabled, s.danger),
        ];
      case AffectedLinkPhase.advertiseFailed:
        return [
          notice('Other devices cannot find this phone.', Icons.visibility_off_outlined, s.warning,
              const TextButton(
                onPressed: _retry,
                child: Text('Retry'),
              )),
        ];
      default:
        if (!link.scanning && link.scanDetail != null) {
          return [
            notice('Searching is paused.', Icons.search_off, s.warning, const TextButton(
              onPressed: _retry,
              child: Text('Retry'),
            )),
          ];
        }
        return const [];
    }
  }

  static void _retry() => AffectedPeripheralService.instance.start();
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.link});

  final AffectedLinkStatus link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = link.peers.length;
    final starting =
        link.phase == AffectedLinkPhase.starting || link.phase == AffectedLinkPhase.stopped;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(
                icon: count > 0 ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                color: count > 0 ? context.status.success : context.status.info,
                size: 44,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  count == 0 ? 'No devices connected' : '$count Connected',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (starting)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              StatusBadge(
                label: link.isAdvertising ? 'Visible' : 'Not visible',
                tone: link.isAdvertising ? StatusTone.success : StatusTone.neutral,
                icon: link.isAdvertising ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              ),
              StatusBadge(
                label: link.scanning ? 'Searching' : 'Not searching',
                tone: link.scanning ? StatusTone.info : StatusTone.neutral,
                icon: link.scanning ? Icons.search : Icons.search_off,
              ),
              StatusBadge(
                label: link.relayForwarding ? 'Relaying' : 'Relay off',
                tone: link.relayForwarding ? StatusTone.info : StatusTone.neutral,
                icon: Icons.alt_route,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});

  final MeshPeerSummary peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (String role, IconData icon, Color color) = peer.isRescue
        ? ('Rescue Team', Icons.shield_outlined, context.status.success)
        : peer.isRelay
            ? ('Phone · relaying', Icons.smartphone, context.status.info)
            : ('Phone', Icons.smartphone, context.status.neutral);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          IconBadge(icon: icon, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(role, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const StatusBadge(
            label: 'Connected',
            tone: StatusTone.success,
            icon: Icons.check,
          ),
        ],
      ),
    );
  }
}
