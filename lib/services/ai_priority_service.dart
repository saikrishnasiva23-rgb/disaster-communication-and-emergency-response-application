import '../models/ai_priority_result.dart';
import '../models/sos_packet.dart';

/// Produces an AiPriorityResult with no path to the Flask/RandomForest
/// backend (e.g. an SOS received purely over BLE with no network at all,
/// or free text typed directly into the standalone AI Priority screen).
/// This is a plain rule-based approximation, not a trained model --
/// AiPrioritySource.localFallback is set on every result so the UI can
/// never confuse it with a real backend prediction.
///
/// When a request goes through the backend instead (backend/app.py), the
/// *real* RandomForest result already arrives attached to that RescueCase
/// (see RescueCase.fromBackendJson) and this service is not used for it.
///
/// [classifyLocally] and [classifyFreeText] share one scoring core so the
/// standalone AI Priority screen (free text, no structured fields) and
/// the BLE-received-SOS path (structured fields) can never silently
/// diverge into two different opinions of what "high priority" means --
/// which is what happened before this refactor, when ai_alert_screen.dart
/// had its own separate 3-branch keyword match.
class AiPriorityService {
  AiPriorityService._();

  static AiPriorityResult classifyLocally(SosPacket packet) {
    return _classify(
      emergencyType: packet.emergencyType,
      injured: packet.injured,
      numberOfPeople: packet.numberOfPeople,
      message: packet.message,
    );
  }

  /// For free-text input with no structured fields behind it, such as a
  /// message typed directly into the AI Priority screen. Reads the same
  /// injury/life-threatening signals [classifyLocally] reads out of
  /// dedicated fields, out of the sentence instead.
  static AiPriorityResult classifyFreeText(String text) {
    final lower = text.toLowerCase();

    // A confirmed bug: "no one is injured" / "not injured" was matching
    // the raw substring 'injured' with no awareness of the negation in
    // front of it, scoring a safe status update as if an injury were
    // reported. This is still a plain substring check (not real NLP),
    // but it catches the common phrasings a real reporter would use.
    const negatedInjuryPhrases = [
      'no one is injured',
      'nobody is injured',
      'no one injured',
      'nobody injured',
      'not injured',
      'no injuries',
      'no injury',
      'not hurt',
      'nobody hurt',
      'no one hurt',
      "isn't hurt",
      "aren't hurt",
    ];
    final hasNegatedInjury =
        negatedInjuryPhrases.any((phrase) => lower.contains(phrase));

    final injured = !hasNegatedInjury &&
        (lower.contains('injured') ||
            lower.contains('injury') ||
            lower.contains('hurt'));

    return _classify(
      emergencyType: text,
      injured: injured,
      numberOfPeople: 1,
      message: text,
    );
  }

  static AiPriorityResult _classify({
    required String emergencyType,
    required bool injured,
    required int numberOfPeople,
    required String message,
  }) {
    final type = emergencyType.toLowerCase();
    final text = message.toLowerCase();
    final reasons = <String>[];

    var score = 0;

    if (injured) {
      score += 2;
      reasons.add('injured person reported');
    }

    if (numberOfPeople >= 5) {
      score += 2;
      reasons.add('$numberOfPeople people affected');
    } else if (numberOfPeople >= 2) {
      score += 1;
    }

    // A confirmed bug: this list was narrow enough that a plainly
    // life-threatening message ("My father is unconscious and bleeding
    // heavily, please help fast") matched nothing here and nothing in
    // `injured` either, scoring as AiPriorityLevel.low. Expanded with the
    // common ways someone would actually describe a critical medical
    // emergency, not just disaster-type keywords.
    const lifeThreatening = [
      'trapped',
      'fire',
      'flood',
      'earthquake',
      'cyclone',
      'landslide',
      'unconscious',
      'not breathing',
      'stopped breathing',
      'no pulse',
      'bleeding',
      'drowning',
      'collapsed',
      'heart attack',
      'stroke',
      'seizure',
      'chest pain',
    ];
    const medicalNeed = ['medical', 'injury', 'medicine', 'sick', 'fever'];
    const basicNeed = ['food', 'water'];

    if (lifeThreatening.any((k) => type.contains(k) || text.contains(k))) {
      score += 2;
      reasons.add('life-threatening keyword detected');
    } else if (medicalNeed.any((k) => type.contains(k) || text.contains(k))) {
      score += 1;
      reasons.add('medical-need keyword detected');
    } else if (basicNeed.any((k) => text.contains(k))) {
      reasons.add('basic-supply request detected');
    }

    final AiPriorityLevel level;
    if (score >= 5) {
      level = AiPriorityLevel.critical;
    } else if (score >= 3) {
      level = AiPriorityLevel.high;
    } else if (score >= 1) {
      level = AiPriorityLevel.medium;
    } else {
      level = AiPriorityLevel.low;
      reasons.add('no high-risk factors detected');
    }

    return AiPriorityResult(
      level: level,
      // A rule-based score is not a model confidence -- left at 0 rather
      // than fabricating a percentage that looks like real ML confidence.
      confidence: 0,
      reason: reasons.join('; '),
      source: AiPrioritySource.localFallback,
      computedAt: DateTime.now(),
    );
  }
}
