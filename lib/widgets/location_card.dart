import 'package:flutter/material.dart';

import '../models/location_data.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';
import 'status_badge.dart';

/// Displays either a real LocationData (with its real freshness --
/// Live / Recent / Stale, never all shown as "live"), a loading state while
/// GPS is being acquired, or an honest error -- never invented coordinates.
class LocationCard extends StatelessWidget {
  final LocationData? location;
  final bool isLoading;
  final String? errorMessage;

  const LocationCard({
    super.key,
    this.location,
    this.isLoading = false,
    this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (isLoading) {
      return AppCard(
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Finding your location...',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    if (errorMessage != null || location == null) {
      return AppCard(
        child: Row(
          children: [
            IconBadge(icon: Icons.location_off, color: context.status.danger),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                errorMessage ?? 'Location unavailable',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    final loc = location!;
    final freshness = loc.freshnessAt(DateTime.now());
    final (String label, StatusTone tone, IconData icon) = switch (freshness) {
      LocationFreshness.live => ('Live', StatusTone.success, Icons.gps_fixed),
      LocationFreshness.recent => ('Recent', StatusTone.warning, Icons.history),
      LocationFreshness.unavailable => ('Stale', StatusTone.neutral, Icons.gps_off),
    };
    final coords =
        '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(icon: Icons.my_location, color: tone.color(context)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'My Location',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusBadge(label: label, tone: tone, icon: icon),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            label: 'Coordinates $coords',
            excludeSemantics: true,
            child: SelectableText(
              coords,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.xs,
            children: [
              if (loc.accuracy != null)
                _Meta(
                  icon: Icons.adjust,
                  text: 'Accuracy ±${loc.accuracy!.round()} m',
                ),
              _Meta(
                icon: Icons.schedule,
                text: 'Updated ${_formatAgo(loc.capturedAt)}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatAgo(DateTime t) {
    var diff = DateTime.now().difference(t);
    if (diff.isNegative) diff = Duration.zero;
    if (diff.inSeconds < 10) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.xs),
        Flexible(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}
