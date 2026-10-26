import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/models/ai_priority_result.dart';
import 'package:disaster_communication_app/models/rescue_case.dart';
import 'package:disaster_communication_app/models/sos_packet.dart';

void main() {
  group('RescueCase.fromSosPacket', () {
    test('copies packet fields and tags source as ble', () {
      final packet = SosPacket(
        id: 'sos-1',
        senderId: 'Jane Doe',
        timestamp: DateTime.utc(2026, 1, 1, 9, 0),
        latitude: 11.9,
        longitude: 79.8,
        message: 'Need help',
        emergencyType: 'Fire Emergency',
        numberOfPeople: 4,
        injured: true,
        sequence: 0,
      );

      final rescueCase = RescueCase.fromSosPacket(packet);

      expect(rescueCase.id, packet.id);
      expect(rescueCase.name, packet.senderId);
      expect(rescueCase.emergencyType, packet.emergencyType);
      expect(rescueCase.numberOfPeople, packet.numberOfPeople);
      expect(rescueCase.injured, isTrue);
      expect(rescueCase.latitude, packet.latitude);
      expect(rescueCase.longitude, packet.longitude);
      expect(rescueCase.source, RescueCaseSource.ble);
      expect(rescueCase.status, RescueStatus.pending);
      // capturedAt must be the SENDER's GPS-fix time, not receipt time --
      // this is what location-freshness display depends on being honest.
      expect(rescueCase.capturedAt.isAtSameMomentAs(packet.timestamp), isTrue);
    });
  });

  group('RescueCase.fromBackendJson', () {
    test('parses the real backend/app.py row shape', () {
      final row = {
        'id': 42,
        'name': 'John Smith',
        'emergency_type': 'Medical Emergency',
        'number_of_people': '2',
        'injured': 'Yes',
        'latitude': '11.9416',
        'longitude': '79.8083',
        'message': 'Chest pain',
        'status': 'pending',
        'priority_level': 'Critical',
        'priority_score': '91.5',
      };

      final rescueCase = RescueCase.fromBackendJson(row);

      expect(rescueCase.id, '42');
      expect(rescueCase.name, 'John Smith');
      expect(rescueCase.emergencyType, 'Medical Emergency');
      expect(rescueCase.numberOfPeople, 2);
      expect(rescueCase.injured, isTrue);
      expect(rescueCase.latitude, closeTo(11.9416, 0.0001));
      expect(rescueCase.longitude, closeTo(79.8083, 0.0001));
      expect(rescueCase.source, RescueCaseSource.backend);
      expect(rescueCase.status, RescueStatus.pending);
      expect(rescueCase.aiPriority, isNotNull);
      expect(rescueCase.aiPriority!.level, AiPriorityLevel.critical);
      expect(rescueCase.aiPriority!.confidence, closeTo(91.5, 0.01));
      expect(rescueCase.aiPriority!.source, AiPrioritySource.backendModel);
    });

    test('missing/malformed fields fall back safely, never throw', () {
      final rescueCase = RescueCase.fromBackendJson({'id': 1});

      expect(rescueCase.name, 'Unknown');
      expect(rescueCase.emergencyType, 'Unknown');
      expect(rescueCase.numberOfPeople, 1);
      expect(rescueCase.injured, isFalse);
      // Missing coordinates mean "location unavailable" -- never 0,0.
      expect(rescueCase.latitude, isNull);
      expect(rescueCase.longitude, isNull);
      expect(rescueCase.hasLocation, isFalse);
      expect(rescueCase.status, RescueStatus.pending);
    });
  });

  test('rescueStatusFromString round-trips every RescueStatus value', () {
    for (final status in RescueStatus.values) {
      expect(rescueStatusFromString(status.name), status);
    }
    expect(rescueStatusFromString('in_progress'), RescueStatus.inProgress);
    expect(rescueStatusFromString('anything-unknown'), RescueStatus.pending);
  });
}
