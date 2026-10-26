import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/models/sos_packet.dart';

void main() {
  group('SosPacket.toWireBytesTruncated (max BLE packet size handling)', () {
    test('a normal-size packet is unaffected', () {
      final packet = SosPacket(
        id: 'sos-size-1',
        senderId: 'affected-1',
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 11.0,
        longitude: 79.0,
        message: 'Need help',
        sequence: 0,
      );

      expect(packet.toWireBytesTruncated(), packet.toWireBytes());
    });

    test('an oversized message is truncated until the packet fits, without '
        'dropping any other field', () {
      final packet = SosPacket(
        id: 'sos-size-2',
        senderId: 'affected-1',
        senderDisplayName: 'Affected Person (1234)',
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 11.9416,
        longitude: 79.8083,
        message: 'x' * 2000,
        sequence: 0,
      );

      final encoded = packet.toWireBytesTruncated();
      expect(utf8.encode(encoded).length,
          lessThanOrEqualTo(SosPacket.maxWireBytes));

      final decoded = SosPacket.fromWireBytes(encoded);
      expect(decoded.id, 'sos-size-2');
      expect(decoded.senderId, 'affected-1');
      expect(decoded.senderDisplayName, 'Affected Person (1234)');
      expect(decoded.latitude, 11.9416);
      expect(decoded.longitude, 79.8083);
      expect(decoded.message.length, lessThan(2000));
    });
  });

  group('SosPacket wire round-trip', () {
    test('toWireBytes -> fromWireBytes preserves every field', () {
      final original = SosPacket(
        id: 'sos-1',
        senderId: 'affected_person',
        timestamp: DateTime.utc(2026, 3, 5, 14, 30),
        latitude: 11.9416,
        longitude: 79.8083,
        message: 'Trapped under debris',
        emergencyType: 'Trapped Person',
        numberOfPeople: 3,
        injured: true,
        priority: 'HIGH',
        status: SosStatus.sentToRelay,
        ttl: 4,
        sequence: 7,
      );

      final decoded = SosPacket.fromWireBytes(original.toWireBytes());

      expect(decoded.id, original.id);
      expect(decoded.type, 'SOS');
      expect(decoded.senderId, original.senderId);
      expect(
        decoded.timestamp.isAtSameMomentAs(original.timestamp),
        isTrue,
      );
      expect(decoded.latitude, original.latitude);
      expect(decoded.longitude, original.longitude);
      expect(decoded.message, original.message);
      expect(decoded.emergencyType, original.emergencyType);
      expect(decoded.numberOfPeople, original.numberOfPeople);
      expect(decoded.injured, original.injured);
      expect(decoded.priority, original.priority);
      expect(decoded.status, original.status);
      expect(decoded.ttl, original.ttl);
      expect(decoded.sequence, original.sequence);
    });

    test('fromJson defaults missing optional fields safely', () {
      final decoded = SosPacket.fromJson({
        'id': 'sos-2',
        'latitude': 11.0,
        'longitude': 79.0,
      });

      expect(decoded.senderId, 'unknown');
      expect(decoded.message, '');
      expect(decoded.emergencyType, 'General Emergency');
      expect(decoded.numberOfPeople, 1);
      expect(decoded.injured, isFalse);
      expect(decoded.status, SosStatus.created);
      expect(decoded.ttl, 5);
    });

    test('fromWireBytes throws (not silently accepts) malformed JSON', () {
      expect(
        () => SosPacket.fromWireBytes('not json at all'),
        throwsFormatException,
      );
    });

    // Requirement change: an SOS must still be sent when the phone has no
    // GPS fix, with latitude/longitude = null -- never blocked, never
    // given made-up coordinates. (This test used to assert a TypeError.)
    test('missing lat/long decode as null (GPS unavailable), not as 0,0', () {
      final decoded = SosPacket.fromWireBytes('{"id": "sos-3"}');

      expect(decoded.latitude, isNull);
      expect(decoded.longitude, isNull);
      expect(decoded.hasLocation, isFalse);
    });

    test('non-numeric coordinates still throw instead of being guessed', () {
      expect(
        () => SosPacket.fromWireBytes('{"id": "sos-4", "latitude": "north"}'),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('SosPacket.toBackendJson', () {
    test('maps onto the exact field names backend/app.py expects', () {
      final packet = SosPacket(
        id: 'sos-4',
        senderId: 'Jane Doe',
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 10.0,
        longitude: 20.0,
        message: 'Need water',
        emergencyType: 'Medical Emergency',
        numberOfPeople: 2,
        injured: true,
        sequence: 0,
      );

      final backendJson = packet.toBackendJson();

      expect(backendJson, {
        'name': 'Jane Doe',
        'emergencyType': 'Medical Emergency',
        'numberOfPeople': 2,
        'injured': 'Yes',
        'latitude': 10.0,
        'longitude': 20.0,
        'message': 'Need water',
      });
    });

    test('injured=false maps to the string "No", not the boolean false', () {
      final packet = SosPacket(
        id: 'sos-5',
        senderId: 'x',
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 0,
        longitude: 0,
        message: '',
        injured: false,
        sequence: 0,
      );

      expect(packet.toBackendJson()['injured'], 'No');
    });
  });

  group('SosPacket.forRelay (Phase 5 store-and-forward)', () {
    test('preserves the original sender identity -- never becomes the relay', () {
      final original = SosPacket(
        id: 'sos-relay-1',
        senderId: 'affected-p1',
        senderDisplayName: 'Affected Person (p1)',
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 11.0,
        longitude: 79.0,
        message: 'Trapped',
        ttl: 5,
        sequence: 0,
      );

      final relayed = original.forRelay(
        relayerId: 'affected-p2',
        relayerName: 'Affected Person (p2)',
      );

      // The packet identity and original-sender fields are untouched --
      // Person 1 must never appear to become Person 2.
      expect(relayed.id, original.id);
      expect(relayed.senderId, 'affected-p1');
      expect(relayed.senderDisplayName, 'Affected Person (p1)');
      expect(relayed.message, original.message);
      expect(relayed.latitude, original.latitude);
      expect(relayed.longitude, original.longitude);

      // Only the relay bookkeeping changes.
      expect(relayed.relayedBy, 'affected-p2');
      expect(relayed.relayedByName, 'Affected Person (p2)');
      expect(relayed.hopCount, 1);
      expect(relayed.ttl, 4);
    });

    test('a second relay hop decrements TTL and increments hopCount again', () {
      final original = SosPacket(
        id: 'sos-relay-2',
        senderId: 'affected-p1',
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 0,
        longitude: 0,
        message: '',
        ttl: 2,
        sequence: 0,
      );

      final afterFirstHop =
          original.forRelay(relayerId: 'p2', relayerName: 'P2');
      final afterSecondHop =
          afterFirstHop.forRelay(relayerId: 'p3', relayerName: 'P3');

      expect(afterFirstHop.ttl, 1);
      expect(afterFirstHop.hopCount, 1);
      expect(afterSecondHop.ttl, 0);
      expect(afterSecondHop.hopCount, 2);
      // Still the original sender, even after two hops.
      expect(afterSecondHop.senderId, 'affected-p1');
      expect(afterSecondHop.relayedBy, 'p3');
    });

    test('round-trips relay fields over the wire', () {
      final relayed = SosPacket(
        id: 'sos-relay-3',
        senderId: 'affected-p1',
        senderDisplayName: 'Affected Person (p1)',
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: 1,
        longitude: 2,
        message: 'help',
        sequence: 0,
        relayedBy: 'affected-p2',
        relayedByName: 'Affected Person (p2)',
        hopCount: 1,
        ttl: 4,
      );

      final decoded = SosPacket.fromWireBytes(relayed.toWireBytes());

      expect(decoded.relayedBy, 'affected-p2');
      expect(decoded.relayedByName, 'Affected Person (p2)');
      expect(decoded.hopCount, 1);
      expect(decoded.ttl, 4);
      expect(decoded.senderId, 'affected-p1');
    });
  });
}
