import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/net_log.dart';
import '../theme/app_theme.dart';
import '../widgets/state_views.dart';

/// Diagnostics: the tagged step log ([BLE] / [RELAY] / [RESCUE] / [SOS] /
/// [SYNC] / [STORE]) of this device, newest first. Used on the physical
/// test devices to see every Advertise -> Scan -> Connect -> GATT -> Relay
/// -> ACK step as it happens. Contains packet ids and device names only --
/// never message text, coordinates or credentials.
class NetworkLogScreen extends StatefulWidget {
  const NetworkLogScreen({super.key});

  @override
  State<NetworkLogScreen> createState() => _NetworkLogScreenState();
}

class _NetworkLogScreenState extends State<NetworkLogScreen> {
  String? _tag;

  static const _tags = ['BLE', 'RELAY', 'RESCUE', 'SOS', 'SYNC', 'STORE'];

  static const _mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Consolas', 'Menlo', 'Courier New'],
  );

  Color _colorFor(BuildContext context, String tag) {
    final scheme = Theme.of(context).colorScheme;
    final s = context.status;
    return switch (tag) {
      'BLE' => s.info,
      'RELAY' => scheme.tertiary,
      'RESCUE' => s.success,
      'SOS' => s.danger,
      'SYNC' => scheme.secondary,
      _ => s.neutral,
    };
  }

  Future<void> _copyLog() async {
    final text = NetLog.entries.value.reversed.map((e) => e.toString()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network Log'),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy),
            onPressed: _copyLog,
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.max(
            AppSpacing.page,
            (constraints.maxWidth - 1100) / 2,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(side, AppSpacing.xs, side, AppSpacing.sm),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: const Text('All'),
                      selected: _tag == null,
                      onSelected: (_) => setState(() => _tag = null),
                    ),
                    for (final tag in _tags) ...[
                      const SizedBox(width: AppSpacing.sm),
                      ChoiceChip(
                        label: Text(tag),
                        selected: _tag == tag,
                        onSelected: (_) => setState(() => _tag = tag),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ValueListenableBuilder<List<NetLogEntry>>(
                  valueListenable: NetLog.entries,
                  builder: (context, entries, _) {
                    final shown = _tag == null
                        ? entries
                        : entries.where((e) => e.tag == _tag).toList();
                    if (shown.isEmpty) {
                      return AppEmptyView(
                        icon: Icons.receipt_long_outlined,
                        title: _tag == null ? 'No log entries yet' : 'No $_tag entries',
                      );
                    }
                    return ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        side,
                        AppSpacing.xs,
                        side,
                        AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _LogRow(
                        entry: shown[i],
                        color: _colorFor(context, shown[i].tag),
                        mono: _mono,
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry, required this.color, required this.mono});

  final NetLogEntry entry;
  final Color color;
  final TextStyle mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = entry.time.toIso8601String().substring(11, 19);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 64),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              entry.tag,
              textAlign: TextAlign.center,
              style: mono.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.message,
                  style: mono.copyWith(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  time,
                  style: mono.copyWith(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
