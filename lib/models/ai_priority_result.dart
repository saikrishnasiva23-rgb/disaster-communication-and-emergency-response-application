enum AiPriorityLevel { low, medium, high, critical, unknown }

AiPriorityLevel aiPriorityFromString(String value) {
  switch (value.toLowerCase()) {
    case 'low':
      return AiPriorityLevel.low;
    case 'medium':
      return AiPriorityLevel.medium;
    case 'high':
      return AiPriorityLevel.high;
    case 'critical':
      return AiPriorityLevel.critical;
    default:
      return AiPriorityLevel.unknown;
  }
}

/// Where a priority result came from. Surfaced in the UI so the app never
/// silently presents an offline local guess as the real backend ML model's
/// output -- see item 7 of the architecture decision (local fallback must
/// be honest about not being the RandomForest model).
enum AiPrioritySource { backendModel, localFallback }

class AiPriorityResult {
  final AiPriorityLevel level;
  final double confidence; // 0-100
  final String reason;
  final AiPrioritySource source;
  final DateTime computedAt;

  const AiPriorityResult({
    required this.level,
    required this.confidence,
    required this.reason,
    required this.source,
    required this.computedAt,
  });
}
