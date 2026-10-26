import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One tile in a quick-action grid. Purely presentational: the caller
/// supplies the real destination in [onTap].
class QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  const QuickActionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = iconColor ?? theme.colorScheme.primary;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            // Centred when the row is taller than this tile's own content
            // (the row takes its tallest tile's height).
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, size: 24, color: color),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(fontSize: 13),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays out tiles in rows whose column count follows the available width
/// and the user's font size. Each row is as tall as its tallest tile, so a
/// tile never overflows.
class ResponsiveTileGrid extends StatelessWidget {
  const ResponsiveTileGrid({
    super.key,
    required this.children,
    this.minTileWidth = 96,
    this.maxColumns = 4,
    this.spacing = 10,
  });

  final List<Widget> children;
  final double minTileWidth;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
        final tileWidth = minTileWidth * textScale;
        final columns = ((constraints.maxWidth + spacing) / (tileWidth + spacing))
            .floor()
            .clamp(2, maxColumns)
            .toInt();

        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += columns) {
          final rowTiles = children.sublist(i, (i + columns).clamp(0, children.length));
          rows.add(Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : spacing),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < columns; c++) ...[
                    if (c > 0) SizedBox(width: spacing),
                    Expanded(
                      child: c < rowTiles.length ? rowTiles[c] : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      },
    );
  }
}
