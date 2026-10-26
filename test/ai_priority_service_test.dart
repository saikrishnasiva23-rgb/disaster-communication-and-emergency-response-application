import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/models/ai_priority_result.dart';
import 'package:disaster_communication_app/models/sos_packet.dart';
import 'package:disaster_communication_app/services/ai_priority_service.dart';

SosPacket _packet({
  required bool injured,
  required int numberOfPeople,
  required String emergencyType,
}) {
  return SosPacket(
    id: 'x',
    senderId: 'x',
    timestamp: DateTime.utc(2026, 1, 1),
    latitude: 0,
    longitude: 0,
    message: '',
    emergencyType: emergencyType,
    numberOfPeople: numberOfPeople,
    injured: injured,
    sequence: 0,
  );
}

void main() {
  group('AiPriorityService.classifyLocally', () {
    test('no risk factors -> low', () {
      final result = AiPriorityService.classifyLocally(
        _packet(injured: false, numberOfPeople: 1, emergencyType: 'Other'),
      );
      expect(result.level, AiPriorityLevel.low);
    });

    test('injured alone (+2) -> medium', () {
      final result = AiPriorityService.classifyLocally(
        _packet(injured: true, numberOfPeople: 1, emergencyType: 'Other'),
      );
      expect(result.level, AiPriorityLevel.medium);
    });

    test('injured + medical type (+2+1=3) -> high', () {
      final result = AiPriorityService.classifyLocally(
        _packet(
          injured: true,
          numberOfPeople: 1,
          emergencyType: 'Medical Emergency',
        ),
      );
      expect(result.level, AiPriorityLevel.high);
    });

    test('injured + 5 people + trapped (+2+2+2=6) -> critical', () {
      final result = AiPriorityService.classifyLocally(
        _packet(
          injured: true,
          numberOfPeople: 5,
          emergencyType: 'Trapped Person',
        ),
      );
      expect(result.level, AiPriorityLevel.critical);
    });

    test('every result is honestly tagged as a local fallback, not a model', () {
      final result = AiPriorityService.classifyLocally(
        _packet(injured: true, numberOfPeople: 1, emergencyType: 'Other'),
      );
      expect(result.source, AiPrioritySource.localFallback);
      // A rule-based score must never masquerade as a model confidence.
      expect(result.confidence, 0);
      expect(result.reason, isNotEmpty);
    });
  });

  group('AiPriorityService.classifyFreeText', () {
    test('mentions "food" and "water" only -> low (no score-bearing signal)',
        () {
      final result = AiPriorityService.classifyFreeText(
        'we need food and water urgently',
      );
      expect(result.level, AiPriorityLevel.low);
    });

    test('mentions a life-threatening keyword -> at least medium', () {
      final result = AiPriorityService.classifyFreeText(
        'there is a fire spreading fast',
      );
      expect(
        result.level,
        anyOf(AiPriorityLevel.medium, AiPriorityLevel.high, AiPriorityLevel.critical),
      );
    });

    test('"injured" and "trapped" together -> high', () {
      final result = AiPriorityService.classifyFreeText(
        'I am injured and trapped under debris',
      );
      expect(result.level, AiPriorityLevel.high);
    });

    test('always local fallback, never the backend model', () {
      final result = AiPriorityService.classifyFreeText('anything');
      expect(result.source, AiPrioritySource.localFallback);
    });

    // Regression tests for two bugs an adversarial code review found and
    // independently verified before physical hardware testing began.
    test(
      'REGRESSION: "no one is injured" is not scored as if injured (negation)',
      () {
        final result = AiPriorityService.classifyFreeText(
          'We are all safe, no one is injured, please just send drinking water',
        );
        // Previously scored medium: the raw substring 'injured' matched
        // inside the negated phrase with no awareness of the negation.
        expect(result.level, AiPriorityLevel.low);
      },
    );

    test(
      'REGRESSION: an unconscious, heavily bleeding person is not scored low',
      () {
        final result = AiPriorityService.classifyFreeText(
          'My father is unconscious and bleeding heavily, please help fast',
        );
        // Previously scored low: neither 'unconscious' nor 'bleeding' was
        // in any keyword list, and 'injured'/'injury'/'hurt' don't appear
        // in this sentence either, so score stayed 0.
        expect(result.level, isNot(AiPriorityLevel.low));
      },
    );
  });
}
