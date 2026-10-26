import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/ai_priority_result.dart';
import '../services/ai_priority_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/priority_badge.dart';
import '../widgets/section_header.dart';

/// Shares the scoring core of AiPriorityService with the Rescue Team side,
/// so the same input signals produce the same verdict everywhere in the
/// app. The result names its source honestly: a local estimate is never
/// presented as the backend model's output.
class AIAlertScreen extends StatefulWidget {
  const AIAlertScreen({super.key});

  @override
  State<AIAlertScreen> createState() => _AIAlertScreenState();
}

class _AIAlertScreenState extends State<AIAlertScreen> {
  final TextEditingController controller = TextEditingController();

  AiPriorityResult? result;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void analyzeMessage() {
    final text = controller.text.trim();
    if (text.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() {
      result = AiPriorityService.classifyFreeText(text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = result;

    return Scaffold(
      appBar: AppBar(title: const Text('AI Priority')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.max(
            AppSpacing.page,
            (constraints.maxWidth - 720) / 2,
          );
          return ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              side,
              AppSpacing.sm,
              side,
              AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Describe the emergency',
                  hintText: 'What is happening? Is anyone hurt?',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) => FilledButton.icon(
                  onPressed: value.text.trim().isEmpty ? null : analyzeMessage,
                  icon: const Icon(Icons.psychology_alt_outlined),
                  label: const Text('Check Priority'),
                ),
              ),
              if (current != null) ...[
                const SizedBox(height: AppSpacing.xl),
                const SectionHeader(title: 'Result'),
                _ResultCard(result: current),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final AiPriorityResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final color = PriorityBadge.colorOf(context, result.level);
    final reasons = result.reason
        .split(';')
        .map((r) => r.trim())
        .where((r) => r.isNotEmpty)
        .toList();
    final fromModel = result.source == AiPrioritySource.backendModel;
    final showConfidence = fromModel && result.confidence > 0;

    return AppCard(
      borderColor: color.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Priority', style: theme.textTheme.bodySmall),
          const SizedBox(height: AppSpacing.xs),
          PriorityBadge(level: result.level, large: true),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.check, size: 16, color: muted),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '${reason[0].toUpperCase()}${reason.substring(1)}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: AppSpacing.sm),
          const Divider(),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    fromModel ? Icons.cloud_done_outlined : Icons.phone_android,
                    size: 16,
                    color: muted,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      fromModel ? 'AI model' : 'Local estimate (offline)',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (showConfidence)
                Text(
                  'Confidence ${result.confidence.round()}%',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
