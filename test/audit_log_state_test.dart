import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/models/audit_event.dart';
import 'package:disaster_communication_app/state/audit_log_state.dart';

void main() {
  test('hash chain verifies when intact', () {
    final log = AuditLogState();

    log.addEvent(AuditEvent(
      id: '1',
      type: AuditEventType.rescueAuthenticated,
      actorId: 'rescue1',
      timestamp: DateTime.utc(2026, 1, 1, 10, 0),
      details: 'Rescue Team authenticated',
    ));

    log.addEvent(AuditEvent(
      id: '2',
      type: AuditEventType.sosCreated,
      actorId: 'affected_person',
      timestamp: DateTime.utc(2026, 1, 1, 10, 1),
      details: 'SOS abc created',
    ));

    log.addEvent(AuditEvent(
      id: '3',
      type: AuditEventType.sosReceived,
      actorId: 'rescue1',
      timestamp: DateTime.utc(2026, 1, 1, 10, 2),
      details: 'SOS abc received over BLE',
    ));

    expect(log.events.length, 3);
    expect(log.verifyChain(), isTrue);

    // Each event's previousHash must equal the PRIOR event's hash --
    // events[] is newest-first, so events[i].previousHash == events[i+1].hash.
    expect(log.events[0].previousHash, equals(log.events[1].hash));
    expect(log.events[1].previousHash, equals(log.events[2].hash));
    expect(log.events[2].previousHash, equals(AuditLogState.genesisHash));

    // No two hashes collide, and none is left null.
    final hashes = log.events.map((e) => e.hash).toSet();
    expect(hashes.length, 3);
    expect(hashes.contains(null), isFalse);
  });

  test('verifyChain fails after simulated tampering', () {
    final log = AuditLogState();

    log.addEvent(AuditEvent(
      id: '1',
      type: AuditEventType.rescueAuthenticated,
      actorId: 'rescue1',
      timestamp: DateTime.utc(2026, 1, 1, 10, 0),
      details: 'Rescue Team authenticated',
    ));

    log.addEvent(AuditEvent(
      id: '2',
      type: AuditEventType.sosCreated,
      actorId: 'affected_person',
      timestamp: DateTime.utc(2026, 1, 1, 10, 1),
      details: 'SOS abc created',
    ));

    expect(log.verifyChain(), isTrue);

    log.simulateTamperingForDemo();

    expect(log.verifyChain(), isFalse);
  });

  test('verifyChain is true for an empty log', () {
    final log = AuditLogState();
    expect(log.verifyChain(), isTrue);
  });

  test('same event content produces a different hash with a different previousHash',
      () {
    final logA = AuditLogState();
    final logB = AuditLogState();

    final event = AuditEvent(
      id: 'same-id',
      type: AuditEventType.sosCreated,
      actorId: 'affected_person',
      timestamp: DateTime.utc(2026, 1, 1, 10, 0),
      details: 'identical details',
    );

    // logB has a prior event, logA does not -- so even identical event
    // content must hash differently once chained.
    logB.addEvent(AuditEvent(
      id: 'earlier',
      type: AuditEventType.rescueAuthenticated,
      actorId: 'rescue1',
      timestamp: DateTime.utc(2026, 1, 1, 9, 0),
      details: 'earlier event',
    ));

    logA.addEvent(event);
    logB.addEvent(AuditEvent(
      id: event.id,
      type: event.type,
      actorId: event.actorId,
      timestamp: event.timestamp,
      details: event.details,
    ));

    expect(logA.events.first.hash, isNot(equals(logB.events.first.hash)));
  });
}
