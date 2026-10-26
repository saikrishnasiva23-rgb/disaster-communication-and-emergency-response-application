// LOGIC TESTS of the mesh routing (MeshNode) over a SIMULATED radio
// (test/support/fake_mesh_transport.dart). They prove the routing, custody,
// ACK and dedup logic end to end. They are NOT Bluetooth hardware tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/models/sos_packet.dart';
import 'package:disaster_communication_app/services/ble_protocol.dart';
import 'package:disaster_communication_app/services/local_store.dart';
import 'package:disaster_communication_app/services/mesh/mesh_link.dart';
import 'package:disaster_communication_app/services/mesh/mesh_node.dart';

import 'support/fake_mesh_transport.dart';

Future<void> settle([int rounds = 60]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Net {
  Net({int payloadSize = 20, bool ackChannel = true})
      : radio = FakeRadio(payloadSize: payloadSize, ackChannel: ackChannel);

  final FakeRadio radio;
  DateTime now = DateTime.now().toUtc();
  final Map<String, MeshNode> nodes = {};
  final Map<String, List<FakeTransport>> transports = {};
  final List<MeshEvent> events = [];
  final List<RescueDelivery> deliveries = [];

  String idOf(String name) => 'device-$name';

  Future<MeshNode> phone(String name,
      {bool relay = false, bool persist = false, String? prefix}) async {
    final node = MeshNode(
      role: MeshRole.affected,
      identity: () async => MeshIdentity(deviceId: idOf(name), deviceName: 'Phone $name'),
      clock: () => now,
      persist: persist,
      storePrefix: prefix ?? 'node_$name',
      tickInterval: const Duration(hours: 1),
    );
    await node.init();
    node.events.listen(events.add);
    // Every phone is BOTH roles: advertiser/peripheral AND scanner/central.
    // [relay] only switches forwarding of other phones' packets.
    final peripheral = FakeTransport(radio, name, LinkSide.peripheral, idOf(name));
    node.attach(peripheral);
    await peripheral.start();
    final central = FakeTransport(radio, name, LinkSide.central, idOf(name));
    node.attach(central);
    await central.start();
    if (relay) await node.setRelayEnabled(true);
    transports[name] = [peripheral, central];
    nodes[name] = node;
    return node;
  }

  Future<MeshNode> laptop(String name) async {
    final node = MeshNode(
      role: MeshRole.rescue,
      identity: () async => MeshIdentity(deviceId: idOf(name), deviceName: 'Rescue $name'),
      clock: () => now,
      persist: false,
      tickInterval: const Duration(hours: 1),
    );
    await node.init();
    node.events.listen(events.add);
    node.rescueDeliveries.listen(deliveries.add);
    final central = FakeTransport(radio, name, LinkSide.central, idOf(name));
    node.attach(central);
    await central.start();
    transports[name] = [central];
    nodes[name] = node;
    return node;
  }

  void range(String a, String b) => radio.inRange(a, b);

  /// Scanners see each other, links come up, HELLOs are exchanged.
  Future<void> discover() async {
    radio.advertise();
    await settle(120);
  }

  Future<void> advance(Duration d) async {
    now = now.add(d);
    for (final n in nodes.values) {
      await n.tickForTest();
    }
    await settle(120);
  }

  SosPacket sos(String from, {String message = 'Need help', int maxHops = 5}) => SosPacket(
        id: '$from-${now.microsecondsSinceEpoch}',
        senderId: idOf(from),
        senderDisplayName: 'Phone $from',
        timestamp: now,
        latitude: 11.941612,
        longitude: 79.808301,
        accuracyMeters: 12.5,
        fixTime: now,
        message: message,
        emergencyType: 'Flood Emergency',
        priority: 'HIGH',
        sequence: 0,
        maxHops: maxHops,
        ttl: maxHops,
        protocolVersion: SosPacket.currentProtocolVersion,
      );

  int count(MeshEventType type, {String? startsWith}) => events
      .where((e) => e.type == type && (startsWith == null || e.detail.startsWith(startsWith)))
      .length;

  Future<void> dispose() async {
    for (final n in nodes.values) {
      await n.dispose();
    }
    for (final list in transports.values) {
      for (final t in list) {
        await t.close();
      }
    }
  }
}

void main() {
  group('Mesh routing (logic tests, simulated radio -- not hardware)', () {
    test('1 DIRECT: phone -> laptop, end-to-end ACK back', () async {
      final net = Net();
      final a = await net.phone('A');
      final l = await net.laptop('L');
      net.range('A', 'L');
      await net.discover();

      final entry = await a.originate(net.sos('A'));
      await settle(200);

      expect(l.inbox, hasLength(1));
      final delivered = net.deliveries.single;
      expect(delivered.isDuplicate, isFalse);
      expect(delivered.entry.authenticated, isTrue);
      expect(delivered.entry.packet.hopCount, 0);
      expect(entry.status, SosStatus.receivedByRescue);
      expect(entry.rescueAck, isNotNull);
      await net.dispose();
    });

    test('2 RELAY: A -> B(relay) -> laptop; origin, GPS and path preserved', () async {
      final net = Net();
      final a = await net.phone('A');
      await net.phone('B', relay: true);
      final l = await net.laptop('L');
      net
        ..range('A', 'B')
        ..range('B', 'L');
      await net.discover();

      final statuses = <SosStatus>[];
      a.outboxChanges.listen((e) => statuses.add(e.status));
      final entry = await a.originate(net.sos('A'));
      await settle(300);

      expect(l.inbox, hasLength(1));
      final p = l.inbox.single.packet;
      expect(p.senderId, net.idOf('A'));
      expect(p.senderDisplayName, 'Phone A');
      expect(p.hopCount, 1);
      expect(p.path, [net.idOf('B')]);
      expect(p.relayedBy, net.idOf('B'));
      expect(p.relayedByName, 'Phone B');
      expect(p.latitude, 11.941612);
      expect(p.longitude, 79.808301);
      expect(p.accuracyMeters, 12.5);
      expect(l.inbox.single.authenticated, isTrue);

      expect(entry.status, SosStatus.receivedByRescue);
      expect(statuses, containsAllInOrder([
        SosStatus.sentToRelay,
        SosStatus.relayed,
        SosStatus.receivedByRescue,
      ]));
      expect(net.count(MeshEventType.ackForwarded), 1);
      await net.dispose();
    });

    test('3 REVERSE STATUS: laptop -> B -> A', () async {
      final net = Net();
      final a = await net.phone('A');
      await net.phone('B', relay: true);
      final l = await net.laptop('L');
      net
        ..range('A', 'B')
        ..range('B', 'L');
      await net.discover();
      final entry = await a.originate(net.sos('A'));
      await settle(300);

      final delivered = await l.sendStatus(entry.packet.id, 'ASSIGNED');
      await settle(200);

      expect(delivered, isTrue);
      expect(entry.status, SosStatus.acknowledged);
      expect(entry.rescueStatus, 'ASSIGNED');
      expect(net.count(MeshEventType.statusForwarded), 1);
      await net.dispose();
    });

    test('4 THREE HOPS: A -> B -> C -> laptop and back', () async {
      final net = Net();
      final a = await net.phone('A');
      await net.phone('B', relay: true);
      await net.phone('C', relay: true);
      final l = await net.laptop('L');
      net
        ..range('A', 'B')
        ..range('B', 'C')
        ..range('C', 'L');
      await net.discover();

      final entry = await a.originate(net.sos('A'));
      await settle(400);

      expect(l.inbox, hasLength(1));
      final p = l.inbox.single.packet;
      expect(p.hopCount, 2);
      expect(p.path, [net.idOf('B'), net.idOf('C')]);
      expect(p.senderId, net.idOf('A'));
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('5 STORE-AND-FORWARD: relay holds the SOS until the laptop appears', () async {
      final net = Net();
      final a = await net.phone('A');
      final b = await net.phone('B', relay: true);
      final l = await net.laptop('L');
      net.range('A', 'B');
      await net.discover();

      final entry = await a.originate(net.sos('A'));
      await settle(200);
      expect(entry.status, SosStatus.relayed);
      b.publishNow();
      expect(b.stats.value.relayHeld, 1);
      expect(b.stats.value.relayAwaitingNextHop, 1);
      expect(l.inbox, isEmpty);

      net.range('B', 'L');
      await net.discover();
      await settle(200);

      expect(l.inbox, hasLength(1));
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('6 BROKEN REVERSE PATH: pending ACK delivered after A reconnects', () async {
      final net = Net();
      final a = await net.phone('A');
      await net.phone('B', relay: true);
      final l = await net.laptop('L');
      net.range('A', 'B');
      await net.discover();
      final entry = await a.originate(net.sos('A'));
      await settle(200);
      expect(entry.status, SosStatus.relayed);

      // A walks away before the laptop arrives.
      net.radio.outOfRange('A', 'B');
      await settle(50);
      net.range('B', 'L');
      await net.discover();
      await settle(200);
      expect(l.inbox, hasLength(1));
      expect(entry.status, SosStatus.relayed, reason: 'ACK cannot reach A yet');

      // A comes back: B reconnects (after its backoff) and delivers the ACK.
      net.range('A', 'B');
      await net.advance(const Duration(seconds: 30));
      await net.discover();
      await settle(200);
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('7 DUPLICATES: two relay paths, one record; retries never re-forwarded', () async {
      final net = Net();
      final a = await net.phone('A');
      final b = await net.phone('B', relay: true);
      final c = await net.phone('C', relay: true);
      final l = await net.laptop('L');
      net
        ..range('A', 'B')
        ..range('A', 'C')
        ..range('B', 'L')
        ..range('C', 'L');
      await net.discover();

      final entry = await a.originate(net.sos('A'));
      await settle(400);

      expect(l.inbox, hasLength(1), reason: 'the laptop stores the SOS once');
      expect(net.deliveries.where((d) => !d.isDuplicate), hasLength(1));
      expect(entry.status, SosStatus.receivedByRescue);

      // Origin retransmissions after a long time (repoke) are recognised.
      final forwardedBefore =
          (b.relayEntry(entry.packet.id)?.forwardedCount ?? 0) +
              (c.relayEntry(entry.packet.id)?.forwardedCount ?? 0);
      await net.advance(const Duration(minutes: 5));
      final forwardedAfter =
          (b.relayEntry(entry.packet.id)?.forwardedCount ?? 0) +
              (c.relayEntry(entry.packet.id)?.forwardedCount ?? 0);
      expect(forwardedAfter, forwardedBefore, reason: 'no re-forwarding after delivery');
      expect(l.inbox, hasLength(1));
      await net.dispose();
    });

    test('8 HOP LIMIT: maxHops 1 stops at the second relay', () async {
      final net = Net();
      final a = await net.phone('A');
      await net.phone('B', relay: true);
      final c = await net.phone('C', relay: true);
      final l = await net.laptop('L');
      net
        ..range('A', 'B')
        ..range('B', 'C')
        ..range('C', 'L');
      await net.discover();

      final entry = await a.originate(net.sos('A', maxHops: 1));
      await settle(400);

      final atC = c.relayEntry(entry.packet.id);
      expect(atC, isNotNull, reason: 'C keeps it');
      expect(atC!.canForward, isFalse, reason: 'hop budget spent at C');
      expect(l.inbox, isEmpty, reason: 'never forwarded beyond the limit');
      expect(net.count(MeshEventType.relayNotForwarded), 1);
      expect(entry.status.reachedRescue, isFalse);
      await net.dispose();
    });

    test('9 LOOP SAFETY: a fully linked relay triangle stays bounded', () async {
      final net = Net();
      final a = await net.phone('A', relay: true);
      await net.phone('B', relay: true);
      await net.phone('C', relay: true);
      final l = await net.laptop('L');
      net
        ..range('A', 'B')
        ..range('B', 'C')
        ..range('A', 'C')
        ..range('C', 'L');
      await net.discover();

      final entry = await a.originate(net.sos('A'));
      await settle(500);
      for (var i = 0; i < 10; i++) {
        await net.advance(const Duration(seconds: 30));
      }

      expect(l.inbox, hasLength(1));
      expect(entry.status, SosStatus.receivedByRescue);
      final sosMessages = net.radio.messagesByType['SOS'] ?? 0;
      expect(sosMessages, lessThanOrEqualTo(8),
          reason: 'bounded: each node forwards at most once per peer');
      await net.dispose();
    });

    test('10a SECURITY: a packet altered after signing is rejected', () async {
      final net = Net();
      final l = await net.laptop('L');
      // A rogue device the laptop is linked to.
      final rogue = FakeTransport(net.radio, 'X', LinkSide.peripheral, 'device-X');
      await rogue.start();
      net.range('X', 'L');
      await net.discover();
      final link = LinkInfo.idFor(LinkSide.peripheral, 'C-L');

      Future<void> sendJson(Map<String, dynamic> json) async {
        final frames = BleFrameCodec.encode(BleProtocol.encodeJson(json), messageId: 9);
        for (final f in frames) {
          await rogue.send(link, MeshChannel.data, f);
        }
        await settle(60);
      }

      await sendJson(BleProtocol.hello(role: 'relay', deviceName: 'Rogue', senderId: 'device-X'));
      final signed = net.sos('A').withMac(MeshAuth.instance.sign(net.sos('A')));
      final tampered = signed.toTransportJson()..['message'] = 'Everyone is fine, cancel';
      await sendJson(tampered);

      expect(l.inbox, isEmpty);
      expect(net.events.any((e) =>
          e.type == MeshEventType.packetRejected && e.detail.contains('authentication')), isTrue);
      await rogue.close();
      await net.dispose();
    });

    test('10b SECURITY: forged / unsigned rescue ACKs do not count', () async {
      final net = Net();
      final a = await net.phone('A');
      await net.phone('B', relay: true);
      net.range('A', 'B');
      await net.discover();
      final entry = await a.originate(net.sos('A'));
      await settle(200);
      expect(entry.status, SosStatus.relayed);

      final rogue = FakeTransport(net.radio, 'X', LinkSide.central, 'device-X');
      await rogue.start();
      net.range('X', 'A');
      final link = LinkInfo.idFor(LinkSide.central, 'P-A');
      await rogue.connect(link);
      await settle(60);
      Future<void> sendJson(Map<String, dynamic> json) async {
        for (final f in BleFrameCodec.encode(BleProtocol.encodeJson(json), messageId: 3)) {
          await rogue.send(link, MeshChannel.ack, f);
        }
        await settle(60);
      }

      await sendJson(BleProtocol.hello(role: 'rescue', deviceName: 'Fake Rescue', senderId: 'device-X'));
      await sendJson({'type': 'ACK', 'id': entry.packet.id, 'k': 'RESCUE', 'by': 'rescue',
          'origin': net.idOf('A'), 'from': 'device-X', 'at': net.now.toIso8601String(), 'mac': 'AAAA'});
      await sendJson({'type': 'ACK', 'id': entry.packet.id, 'by': 'rescue'}); // v2 style, unsigned
      await sendJson({'type': 'ACK', 'id': entry.packet.id}); // no 'by': HOP, never rescue

      expect(entry.status.reachedRescue, isFalse);
      expect(entry.rescueAck, isNull);
      await rogue.close();
      await net.dispose();
    });

    test('11 PERSISTENCE: relay restart keeps custody and dedup', () async {
      final dir = await Directory.systemTemp.createTemp('mesh_test_');
      LocalStore.useDirectoryForTesting(dir);
      try {
        final net = Net();
        final a = await net.phone('A');
        final b1 = await net.phone('B', relay: true, persist: true, prefix: 'relayB');
        final l = await net.laptop('L');
        net.range('A', 'B');
        await net.discover();
        final entry = await a.originate(net.sos('A'));
        await settle(200);
        expect(b1.relayEntry(entry.packet.id), isNotNull);

        // "Phone B restarts": its node and radio go away.
        for (final t in net.transports['B']!) {
          await t.stop();
        }
        await b1.dispose();
        await settle(50);

        final b2 = await net.phone('B', relay: true, persist: true, prefix: 'relayB');
        expect(b2.relayEntry(entry.packet.id), isNotNull, reason: 'custody survived');

        net.range('B', 'L');
        await net.advance(const Duration(seconds: 30));
        await net.discover();
        await settle(300);
        expect(l.inbox, hasLength(1));
        expect(entry.status, SosStatus.receivedByRescue);
        expect(b2.relayEntry(entry.packet.id)!.forwardedCount, 1);
        await net.dispose();
      } finally {
        LocalStore.useDirectoryForTesting(null);
        await dir.delete(recursive: true);
      }
    });

    for (final (size, ack) in [(20, true), (185, true), (20, false)]) {
      test('12 FRAMES: payload $size B, ACK channel $ack', () async {
        final net = Net(payloadSize: size, ackChannel: ack);
        final a = await net.phone('A');
        await net.phone('B', relay: true);
        final l = await net.laptop('L');
        net
          ..range('A', 'B')
          ..range('B', 'L');
        await net.discover();
        final entry = await a.originate(net.sos('A', message: 'x' * 300));
        await settle(400);
        expect(l.inbox.single.packet.message, 'x' * 300);
        expect(entry.status, SosStatus.receivedByRescue);
        await net.dispose();
      });
    }

    test('13 QUEUED: no link at all -> queued, then sent when one appears', () async {
      final net = Net();
      final a = await net.phone('A');
      final entry = await a.originate(net.sos('A'));
      await settle(50);
      expect(entry.status, SosStatus.queued);

      final l = await net.laptop('L');
      net.range('A', 'L');
      await net.discover();
      await settle(200);
      expect(l.inbox, hasLength(1));
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('ACK JSON never claims rescue without a valid MAC (unit)', () {
      final ack = BleProtocol.rescueAck(
        packetId: 'p1', originId: 'o1', fromId: 'r1', at: DateTime.utc(2026), auth: MeshAuth.instance);
      expect(MeshAuth.instance.verifyAck(ack), isTrue);
      final forged = Map<String, dynamic>.of(ack)..['origin'] = 'someone-else';
      expect(MeshAuth.instance.verifyAck(forged), isFalse);
      expect(BleProtocol.ackKindOf({'type': 'ACK', 'id': 'x'}), BleProtocol.ackKindHop);
      expect(jsonEncode(ack), contains('"k":"RESCUE"'));
    });
  });

  group('Four-phone offline mesh (logic tests, simulated radio -- not hardware)', () {
    Set<String> phonePeers(MeshNode n) => {
          for (final v in n.links.value)
            if (v.isIdentified && v.peer!.isPhone) v.peer!.id,
        };

    test('1 node: an SOS with no other device stays queued, nothing is sent', () async {
      final net = Net();
      final a = await net.phone('A', relay: true);
      final entry = await a.originate(net.sos('A'));
      await net.advance(const Duration(minutes: 5));
      expect(entry.status, SosStatus.queued);
      expect(net.radio.framesSent, 0);
      await net.dispose();
    });

    test('2 nodes: ONE link per pair, data flows both ways over it', () async {
      final net = Net();
      final a = await net.phone('A', relay: true);
      final b = await net.phone('B', relay: true);
      net.range('A', 'B');
      await net.discover();
      // Even after the tie-break grace both phones see each other, still one link.
      await net.advance(const Duration(seconds: 30));
      await net.discover();
      expect(net.radio.linksBetween('A', 'B'), 1);

      final fromA = await a.originate(net.sos('A'));
      final fromB = await b.originate(net.sos('B'));
      await settle(200);
      // A -> B SOS and B -> A hop ACK, and the reverse, on the same link.
      expect(b.relayEntry(fromA.packet.id), isNotNull);
      expect(a.relayEntry(fromB.packet.id), isNotNull);
      expect(fromA.status, SosStatus.relayed);
      expect(fromB.status, SosStatus.relayed);
      expect(net.radio.linksBetween('A', 'B'), 1);
      await net.dispose();
    });

    test('HELLO exchanges identity + capabilities (not the BLE address)', () async {
      final net = Net();
      final a = await net.phone('A', relay: true);
      await net.phone('B', relay: true);
      net.range('A', 'B');
      await net.discover();
      a.publishNow();
      final peer = a.links.value.firstWhere((v) => v.isIdentified).peer!;
      expect(peer.id, net.idOf('B'));
      expect(peer.role, BleProtocol.roleRelay);
      expect(peer.protocolVersion, SosPacket.currentProtocolVersion);
      expect(peer.capabilities, containsAll(['SOS', 'ACK', 'STATUS', 'HELLO']));
      await net.dispose();
    });

    test('3 phones: Phone 1 -> Phone 2 -> Phone 3 -> Rescue', () async {
      final net = Net();
      final p1 = await net.phone('P1');
      await net.phone('P2', relay: true);
      await net.phone('P3', relay: true);
      final l = await net.laptop('L');
      net
        ..range('P1', 'P2')
        ..range('P2', 'P3')
        ..range('P3', 'L');
      await net.discover();
      final entry = await p1.originate(net.sos('P1'));
      await settle(400);
      expect(l.inbox.single.packet.path, [net.idOf('P2'), net.idOf('P3')]);
      expect(l.inbox.single.packet.senderId, net.idOf('P1'));
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('4 phones: P1 -> P2 -> P3 -> P4 -> Rescue, ACK + STATUS back to P1', () async {
      final net = Net();
      final p1 = await net.phone('P1');
      await net.phone('P2', relay: true);
      await net.phone('P3', relay: true);
      await net.phone('P4', relay: true);
      final l = await net.laptop('L');
      net
        ..range('P1', 'P2')
        ..range('P2', 'P3')
        ..range('P3', 'P4')
        ..range('P4', 'L');
      await net.discover();

      final entry = await p1.originate(net.sos('P1'));
      await settle(600);
      final p = l.inbox.single.packet;
      expect(p.senderId, net.idOf('P1'), reason: 'original sender is P1, not P4');
      expect(p.hopCount, 3);
      expect(p.path, [net.idOf('P2'), net.idOf('P3'), net.idOf('P4')]);
      expect(p.relayedBy, net.idOf('P4'));
      expect(p.mac, isNotNull);
      expect(l.inbox.single.authenticated, isTrue);
      expect(entry.status, SosStatus.receivedByRescue,
          reason: 'Rescue -> P4 -> P3 -> P2 -> P1 end-to-end ACK');
      expect(net.count(MeshEventType.ackForwarded), 3);

      await l.sendStatus(entry.packet.id, 'IN_PROGRESS');
      await settle(400);
      expect(entry.rescueStatus, 'IN_PROGRESS');
      expect(entry.status, SosStatus.acknowledged);
      expect(net.count(MeshEventType.statusForwarded), 3);
      await net.dispose();
    });

    test('square topology P1-P2, P1-P3, P2-P4, P3-P4, P4-Rescue: delivered once', () async {
      final net = Net();
      final p1 = await net.phone('P1');
      for (final n in ['P2', 'P3', 'P4']) {
        await net.phone(n, relay: true);
      }
      final l = await net.laptop('L');
      net
        ..range('P1', 'P2')
        ..range('P1', 'P3')
        ..range('P2', 'P4')
        ..range('P3', 'P4')
        ..range('P4', 'L');
      await net.discover();
      final entry = await p1.originate(net.sos('P1'));
      await settle(600);
      expect(l.inbox, hasLength(1));
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('multiple simultaneous SOS from three phones: each delivered once, each ACKed', () async {
      final net = Net();
      final phones = <MeshNode>[];
      for (final n in ['P1', 'P2', 'P3', 'P4']) {
        phones.add(await net.phone(n, relay: true));
      }
      final l = await net.laptop('L');
      net
        ..range('P1', 'P2')
        ..range('P2', 'P3')
        ..range('P3', 'P4')
        ..range('P4', 'L');
      await net.discover();
      final entries = await Future.wait([
        phones[0].originate(net.sos('P1')),
        phones[1].originate(net.sos('P2')),
        phones[2].originate(net.sos('P3')),
      ]);
      await settle(800);
      expect(l.inbox, hasLength(3));
      for (final e in entries) {
        expect(e.status, SosStatus.receivedByRescue, reason: e.packet.id);
      }
      await net.dispose();
    });

    test('relay disconnect: P2 keeps custody, forwards when P3 is back', () async {
      final net = Net();
      final p1 = await net.phone('P1');
      await net.phone('P2', relay: true);
      await net.phone('P3', relay: true);
      final l = await net.laptop('L');
      net
        ..range('P1', 'P2')
        ..range('P2', 'P3')
        ..range('P3', 'L');
      await net.discover();
      net.radio.outOfRange('P2', 'P3'); // P2 --X-- P3
      await settle(50);

      final entry = await p1.originate(net.sos('P1'));
      await settle(300);
      expect(entry.status, SosStatus.relayed, reason: 'held by P2');
      expect(l.inbox, isEmpty);

      net.range('P2', 'P3');
      await net.advance(const Duration(seconds: 40));
      await net.discover();
      await settle(300);
      expect(l.inbox, hasLength(1));
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('alternate route: when P2 cannot reach Rescue, P3 does', () async {
      final net = Net();
      final p1 = await net.phone('P1');
      await net.phone('P2', relay: true);
      await net.phone('P3', relay: true);
      final l = await net.laptop('L');
      net
        ..range('P1', 'P2')
        ..range('P1', 'P3')
        ..range('P3', 'L');
      await net.discover();
      final entry = await p1.originate(net.sos('P1'));
      await settle(400);
      expect(l.inbox, hasLength(1));
      expect(l.inbox.single.packet.path, [net.idOf('P3')]);
      expect(entry.status, SosStatus.receivedByRescue);
      await net.dispose();
    });

    test('mesh maximum: with 5 phones in range no phone links with more than 3 others', () async {
      final net = Net();
      final names = ['P1', 'P2', 'P3', 'P4', 'P5'];
      final nodes = <MeshNode>[];
      for (final n in names) {
        nodes.add(await net.phone(n, relay: true));
      }
      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          net.range(names[i], names[j]);
        }
      }
      await net.discover();
      for (var round = 0; round < 3; round++) {
        await net.advance(const Duration(seconds: 30));
        await net.discover();
      }
      var linkedPhones = 0;
      for (final n in nodes) {
        n.publishNow();
        final peers = phonePeers(n).length;
        expect(peers, lessThanOrEqualTo(3), reason: n.identity.deviceName);
        if (peers > 0) linkedPhones++;
      }
      // Not vacuous: the mesh did form (at least 4 phones linked, and as
      // many links as a full 4-phone mesh).
      expect(linkedPhones, greaterThanOrEqualTo(4));
      expect(net.radio.liveLinks.length, greaterThanOrEqualTo(6));
      // ignore: avoid_print
      print('5-phone mesh links: ${net.radio.liveLinks}');
      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          expect(net.radio.linksBetween(names[i], names[j]), lessThanOrEqualTo(1));
        }
      }
      await net.dispose();
    });

    test('four phones all in range form a full mesh: 6 links, 3 peers each', () async {
      final net = Net();
      final names = ['P1', 'P2', 'P3', 'P4'];
      final nodes = <MeshNode>[];
      for (final n in names) {
        nodes.add(await net.phone(n, relay: true));
      }
      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          net.range(names[i], names[j]);
        }
      }
      await net.discover();
      await net.advance(const Duration(seconds: 30));
      await net.discover();
      expect(net.radio.liveLinks, hasLength(6));
      for (final n in nodes) {
        n.publishNow();
        expect(phonePeers(n), hasLength(3));
      }
      await net.dispose();
    });

    test('relay OFF phone: still sends its own SOS, never carries others', () async {
      final net = Net();
      final p1 = await net.phone('P1');
      final p2 = await net.phone('P2'); // relay off
      final l = await net.laptop('L');
      net
        ..range('P1', 'P2')
        ..range('P2', 'L');
      await net.discover();
      final own = await p2.originate(net.sos('P2'));
      final other = await p1.originate(net.sos('P1'));
      await settle(300);
      expect(own.status, SosStatus.receivedByRescue);
      expect(other.status, SosStatus.queued, reason: 'P2 does not accept custody');
      expect(p2.relayEntry(other.packet.id), isNull);
      expect(l.inbox, hasLength(1));
      await net.dispose();
    });

    test('INTERNET DISABLED: the whole mesh path never touches the network', () async {
      var httpClients = 0;
      await HttpOverrides.runZoned(() async {
        final net = Net();
        final p1 = await net.phone('P1');
        await net.phone('P2', relay: true);
        await net.phone('P3', relay: true);
        final l = await net.laptop('L');
        net
          ..range('P1', 'P2')
          ..range('P2', 'P3')
          ..range('P3', 'L');
        await net.discover();
        final entry = await p1.originate(net.sos('P1'));
        await settle(400);
        await l.sendStatus(entry.packet.id, 'ASSIGNED');
        await settle(300);
        expect(entry.status, SosStatus.acknowledged);
        await net.dispose();
      }, createHttpClient: (_) {
        httpClients++;
        throw StateError('the BLE mesh must not use the internet');
      });
      expect(httpClients, 0);
    });
  });
}
