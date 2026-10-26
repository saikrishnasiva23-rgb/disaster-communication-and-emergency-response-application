import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/models/rescue_case.dart';
import 'package:disaster_communication_app/models/sos_packet.dart';
import 'package:disaster_communication_app/services/rescue_workflow.dart';
import 'package:disaster_communication_app/state/audit_log_state.dart';
import 'package:disaster_communication_app/state/emergency_state.dart';

SosPacket _sos(String id) => SosPacket(
      id: id,
      senderId: 'affected-1',
      timestamp: DateTime.utc(2026, 9, 30),
      latitude: 11.0,
      longitude: 79.0,
      message: 'help',
      sequence: 0,
    );

void main() {
  group('EmergencyState SOS status transitions', () {
    test('queued -> sentToRelay -> relayed -> receivedByRescue -> acknowledged', () {
      final state = EmergencyState()..addSos(_sos('s1'));

      expect(state.updateSosStatus('s1', SosStatus.queued), isTrue);
      expect(state.updateSosStatus('s1', SosStatus.sentToRelay), isTrue);
      expect(state.updateSosStatus('s1', SosStatus.relayed), isTrue);
      expect(state.updateSosStatus('s1', SosStatus.receivedByRescue), isTrue);
      expect(state.sosById('s1')!.acknowledgedAt, isNotNull);
      expect(state.updateSosStatus('s1', SosStatus.acknowledged), isTrue);
      expect(state.sosById('s1')!.status, SosStatus.acknowledged);
    });

    test('a rescue confirmation is never downgraded (late hop ACK, failure)', () {
      final state = EmergencyState()..addSos(_sos('s2'));
      state.updateSosStatus('s2', SosStatus.receivedByRescue);

      expect(state.updateSosStatus('s2', SosStatus.relayed), isFalse);
      expect(state.updateSosStatus('s2', SosStatus.sentToRelay), isFalse);
      expect(state.updateSosStatus('s2', SosStatus.failed), isFalse);
      expect(state.sosById('s2')!.status, SosStatus.receivedByRescue);
    });

    test('a hop ACK (relayed) is not the rescue confirmation', () {
      expect(SosStatus.relayed.reachedRescue, isFalse);
      expect(SosStatus.receivedByRescue.reachedRescue, isTrue);
    });

    test('a late rescue ACK still upgrades a FAILED SOS, nothing else does', () {
      final state = EmergencyState()..addSos(_sos('s3'));
      state.updateSosStatus('s3', SosStatus.failed);
      expect(state.updateSosStatus('s3', SosStatus.relayed), isFalse);
      expect(state.updateSosStatus('s3', SosStatus.receivedByRescue), isTrue);
    });

    test('an unknown id is ignored', () {
      final state = EmergencyState();
      expect(state.updateSosStatus('missing', SosStatus.sentToRelay), isFalse);
    });
  });

  group('Two phones -> two independent rescue cases', () {
    test('an SOS from each phone creates two cases; neither overwrites the other',
        () {
      final state = EmergencyState();
      final oppo = SosPacket(
        id: 'aaaa11-1',
        senderId: 'affected-aaaa11',
        senderDisplayName: 'OPPO A5 Pro 5G',
        timestamp: DateTime.utc(2026, 9, 30),
        latitude: 12.1,
        longitude: 77.1,
        message: 'Trapped',
        sequence: 0,
      );
      final redmi = SosPacket(
        id: 'bbbb22-1',
        senderId: 'affected-bbbb22',
        senderDisplayName: 'Redmi Note 13',
        timestamp: DateTime.utc(2026, 9, 30),
        latitude: 12.2,
        longitude: 77.2,
        message: 'Injured',
        sequence: 0,
      );

      state.upsertRescueCase(RescueCase.fromSosPacket(oppo,
          sourceDeviceName: 'OPPO A5 Pro 5G', sourceAddress: 'AA:01'));
      state.upsertRescueCase(RescueCase.fromSosPacket(redmi,
          sourceDeviceName: 'Redmi Note 13', sourceAddress: 'AA:02'));

      expect(state.rescueCases.length, 2);
      final byName = {for (final c in state.rescueCases) c.name: c};
      expect(byName['OPPO A5 Pro 5G']!.latitude, 12.1);
      expect(byName['OPPO A5 Pro 5G']!.sourceAddress, 'AA:01');
      expect(byName['Redmi Note 13']!.latitude, 12.2);
      expect(byName['Redmi Note 13']!.sourceAddress, 'AA:02');
    });

    test('a relayed SOS keeps the original sender, and records the relay', () {
      final original = SosPacket(
        id: 'aaaa11-2',
        senderId: 'affected-aaaa11',
        senderDisplayName: 'OPPO A5 Pro 5G',
        timestamp: DateTime.utc(2026, 9, 30),
        message: 'help',
        sequence: 0,
      );
      final relayed = original.forRelay(
        relayerId: 'affected-bbbb22',
        relayerName: 'Redmi Note 13',
      );
      final rescueCase = RescueCase.fromSosPacket(relayed,
          sourceDeviceName: 'Redmi Note 13', sourceAddress: 'AA:02');

      expect(rescueCase.name, 'OPPO A5 Pro 5G');
      expect(rescueCase.relayedByName, 'Redmi Note 13');
      expect(rescueCase.isRelayed, isTrue);
      expect(rescueCase.hasLocation, isFalse);
    });

    test('ACK delivery state is tracked per case', () {
      final state = EmergencyState();
      state.upsertRescueCase(RescueCase.fromSosPacket(_sos('c1'),
          sourceAddress: 'AA:01'));
      expect(state.rescueCases.first.ackDelivery, AckDelivery.sending);

      state.updateAckDelivery('c1', AckDelivery.sent);
      expect(state.rescueCases.first.ackDelivery, AckDelivery.sent);
    });
  });

  group('RescueWorkflow', () {
    test('PENDING -> ASSIGNED -> IN PROGRESS -> RESCUED, each audited', () {
      final state = EmergencyState();
      final audit = AuditLogState();
      state.upsertRescueCase(RescueCase.fromSosPacket(_sos('w1')));

      final expected = [
        RescueStatus.assigned,
        RescueStatus.inProgress,
        RescueStatus.rescued,
      ];
      for (final status in expected) {
        final result = RescueWorkflow.advance(
          emergencyState: state,
          auditLog: audit,
          actorId: 'dis_comm',
          rescueCase: state.rescueCases.first,
        );
        expect(result, status);
      }

      expect(
        RescueWorkflow.advance(
          emergencyState: state,
          auditLog: audit,
          actorId: 'dis_comm',
          rescueCase: state.rescueCases.first,
        ),
        isNull,
      );
      expect(audit.events.length, 3);
      expect(audit.verifyChain(), isTrue);
    });
  });
}
