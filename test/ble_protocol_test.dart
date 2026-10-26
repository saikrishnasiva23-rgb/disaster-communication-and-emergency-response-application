import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/models/sos_packet.dart';
import 'package:disaster_communication_app/services/ble_protocol.dart';

SosPacket _packet({
  String id = 'abc123-1',
  String senderId = 'affected-aaaa1111',
  String deviceName = 'OPPO A5 Pro 5G',
  double? latitude = 11.941612,
  double? longitude = 79.808301,
  String message = 'I need immediate rescue',
  DateTime? timestamp,
  int ttl = 5,
}) =>
    SosPacket(
      id: id,
      senderId: senderId,
      senderDisplayName: deviceName,
      timestamp: timestamp ?? DateTime.now().toUtc(),
      latitude: latitude,
      longitude: longitude,
      message: message,
      priority: 'HIGH',
      sequence: 0,
      ttl: ttl,
      protocolVersion: SosPacket.currentProtocolVersion,
    );

void main() {
  group('BleFrameCodec + BleFrameReassembler', () {
    test('every frame fits the smallest ATT payload (20 bytes)', () {
      final payload = utf8.encode(_packet().toTransportString());
      final frames = BleFrameCodec.encode(payload, messageId: 7);

      expect(frames.length, greaterThan(1));
      for (final frame in frames) {
        expect(frame.length, lessThanOrEqualTo(BleProtocol.attPayloadSize));
      }
    });

    test('a fragmented SOS reassembles byte-for-byte', () {
      final payload = utf8.encode(_packet().toTransportString());
      final frames = BleFrameCodec.encode(payload, messageId: 3);
      final reassembler = BleFrameReassembler();

      Uint8List? result;
      for (final frame in frames) {
        result = reassembler.add('oppo', frame);
      }

      expect(result, isNotNull);
      expect(result, equals(payload));
      final decoded = SosPacket.fromJson(BleProtocol.decodeJsonObject(result!)!);
      expect(decoded.id, 'abc123-1');
      expect(decoded.senderDisplayName, 'OPPO A5 Pro 5G');
      expect(decoded.latitude, closeTo(11.941612, 1e-9));
    });

    test('two phones interleaving frames never mix their messages', () {
      final a = utf8.encode(_packet(id: 'a-1', deviceName: 'OPPO A5 Pro 5G')
          .toTransportString());
      final b = utf8.encode(_packet(id: 'b-1', deviceName: 'Redmi Note 13')
          .toTransportString());
      final framesA = BleFrameCodec.encode(a, messageId: 1);
      final framesB = BleFrameCodec.encode(b, messageId: 1);
      final reassembler = BleFrameReassembler();

      final completed = <String, Uint8List>{};
      final longest =
          framesA.length > framesB.length ? framesA.length : framesB.length;
      for (var i = 0; i < longest; i++) {
        if (i < framesA.length) {
          final done = reassembler.add('addr-oppo', framesA[i]);
          if (done != null) completed['oppo'] = done;
        }
        if (i < framesB.length) {
          final done = reassembler.add('addr-redmi', framesB[i]);
          if (done != null) completed['redmi'] = done;
        }
      }

      expect(completed['oppo'], equals(a));
      expect(completed['redmi'], equals(b));
    });

    test('a missing frame never produces a (truncated) message', () {
      final payload = utf8.encode(_packet().toTransportString());
      final frames = BleFrameCodec.encode(payload, messageId: 9);
      final reassembler = BleFrameReassembler();

      Uint8List? result;
      for (final frame in frames.sublist(0, frames.length - 1)) {
        result = reassembler.add('oppo', frame);
      }
      expect(result, isNull);
    });

    test('a new message id discards a stale partial message', () {
      final reassembler = BleFrameReassembler();
      final first = BleFrameCodec.encode(utf8.encode('{"x":"${'a' * 40}"}'),
          messageId: 1);
      final second = BleFrameCodec.encode(utf8.encode('{"ok":true}'),
          messageId: 2);

      reassembler.add('p', first.first);
      Uint8List? done;
      for (final frame in second) {
        done = reassembler.add('p', frame);
      }
      expect(utf8.decode(done!), '{"ok":true}');
    });

    test('an unframed JSON write (older build) is accepted as-is', () {
      final raw = utf8.encode('{"type":"ACK","id":"x"}');
      final result = BleFrameReassembler().add('p', raw);
      expect(result, equals(raw));
    });

    test('an oversized message is refused rather than silently cut', () {
      final huge = List<int>.filled(BleFrameCodec.maxMessageBytes + 1, 0x41);
      expect(
        () => BleFrameCodec.encode(huge, messageId: 0),
        throwsArgumentError,
      );
    });
  });

  group('SosValidation', () {
    test('a normal SOS is accepted', () {
      expect(SosValidation.rejectReason(_packet()), isNull);
    });

    test('an SOS without GPS is accepted (location unavailable)', () {
      expect(
        SosValidation.rejectReason(_packet(latitude: null, longitude: null)),
        isNull,
      );
    });

    test('out-of-range and half-missing coordinates are rejected', () {
      expect(SosValidation.rejectReason(_packet(latitude: 91)), isNotNull);
      expect(SosValidation.rejectReason(_packet(longitude: -181)), isNotNull);
      expect(SosValidation.rejectReason(_packet(longitude: null)), isNotNull);
    });

    test('missing id or sender is rejected', () {
      expect(SosValidation.rejectReason(_packet(id: '')), isNotNull);
      expect(SosValidation.rejectReason(_packet(senderId: '')), isNotNull);
    });

    test('stale (replayed) and far-future timestamps are rejected', () {
      final now = DateTime.utc(2026, 9, 30, 12);
      expect(
        SosValidation.rejectReason(
          _packet(timestamp: now.subtract(const Duration(days: 3))),
          now: now,
        ),
        contains('too old'),
      );
      expect(
        SosValidation.rejectReason(
          _packet(timestamp: now.add(const Duration(hours: 5))),
          now: now,
        ),
        contains('future'),
      );
    });
  });

  group('Relay loop prevention (BleProtocol.shouldRelay)', () {
    test('a peer packet with hops left is relayed', () {
      expect(BleProtocol.shouldRelay(_packet(), 'affected-bbbb2222'), isTrue);
    });

    test('a phone never relays its own packet back', () {
      expect(BleProtocol.shouldRelay(_packet(), 'affected-aaaa1111'), isFalse);
    });

    test('a phone never relays a packet it already relayed', () {
      final relayed =
          _packet().forRelay(relayerId: 'affected-bbbb2222', relayerName: 'Redmi');
      expect(BleProtocol.shouldRelay(relayed, 'affected-bbbb2222'), isFalse);
    });

    test('TTL 0 stops relaying', () {
      expect(BleProtocol.shouldRelay(_packet(ttl: 0), 'affected-cccc'), isFalse);
    });
  });

  group('PacketIdCache (duplicate protection)', () {
    test('the same packet id is only new once', () {
      final cache = PacketIdCache();
      expect(cache.markIfNew('p1'), isTrue);
      expect(cache.markIfNew('p1'), isFalse);
      expect(cache.markIfNew('p2'), isTrue);
    });

    test('capacity evicts the oldest id first', () {
      final cache = PacketIdCache(capacity: 2);
      cache.markIfNew('a');
      cache.markIfNew('b');
      cache.markIfNew('c');
      expect(cache.contains('a'), isFalse);
      expect(cache.contains('c'), isTrue);
    });
  });

  group('FallbackDeviceNamer', () {
    test('gives stable, numbered names -- never the BLE address', () {
      final namer = FallbackDeviceNamer();
      final first = namer.nameFor('AA:BB:CC:DD:EE:01');
      final second = namer.nameFor('AA:BB:CC:DD:EE:02');

      expect(first, 'Affected Device 01');
      expect(second, 'Affected Device 02');
      expect(namer.nameFor('AA:BB:CC:DD:EE:01'), first);
      expect(first.contains(':'), isFalse);
    });
  });

  group('SosPacket transport format', () {
    test('uses the deviceName key and omits sender-local fields', () {
      final json = _packet().toTransportJson();

      expect(json['deviceName'], 'OPPO A5 Pro 5G');
      expect(json.containsKey('status'), isFalse);
      expect(json.containsKey('acknowledgedAt'), isFalse);
      expect(json.containsKey('sequence'), isFalse);
      expect(json['type'], 'SOS');
      expect(json['priority'], 'HIGH');
    });

    test('round-trips through fromJson with identity and GPS intact', () {
      final original = _packet();
      final decoded = SosPacket.fromJson(
        jsonDecode(original.toTransportString()) as Map<String, dynamic>,
      );

      expect(decoded.id, original.id);
      expect(decoded.senderId, original.senderId);
      expect(decoded.senderDisplayName, original.senderDisplayName);
      expect(decoded.latitude, closeTo(original.latitude!, 1e-6));
      expect(decoded.longitude, closeTo(original.longitude!, 1e-6));
      expect(decoded.message, original.message);
      expect(decoded.priority, 'HIGH');
      expect(decoded.protocolVersion, SosPacket.currentProtocolVersion);
    });

    test('a GPS-less SOS omits coordinates instead of sending 0,0', () {
      final json = _packet(latitude: null, longitude: null).toTransportJson();
      expect(json.containsKey('latitude'), isFalse);
      expect(json.containsKey('longitude'), isFalse);
    });

    test('a normal SOS stays compact (well under 24 BLE frames)', () {
      final bytes = utf8.encode(_packet().toTransportString()).length;
      expect(bytes, lessThan(24 * BleFrameCodec.chunkDataSize()));
    });
  });

  group('ACK / HELLO messages', () {
    test('ACK says who acknowledged', () {
      expect(BleProtocol.ack('p1')['by'], BleProtocol.roleRescue);
      expect(
        BleProtocol.ack('p1', by: BleProtocol.roleRelay)['by'],
        BleProtocol.roleRelay,
      );
    });

    test('HELLO carries the human-readable device name', () {
      final hello = BleProtocol.hello(
        role: BleProtocol.roleAffected,
        deviceName: 'Redmi Note 13',
        senderId: 'affected-1',
      );
      final decoded =
          BleProtocol.decodeJsonObject(BleProtocol.encodeJson(hello))!;
      expect(decoded['type'], BleProtocol.typeHello);
      expect(decoded['deviceName'], 'Redmi Note 13');
    });
  });
}
