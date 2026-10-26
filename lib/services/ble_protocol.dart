import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/sos_packet.dart';

/// The ONE BLE protocol shared by every role:
///   Android affected phone  = GATT server / peripheral (native MeshGattServer)
///   Windows Rescue Team     = GATT client / central    (flutter_ble_central)
///   Android relay (opt-in)  = peripheral AND central   (flutter_blue_plus)
///
/// GATT layout (one service, four characteristics):
///   DATA notify  6e400003  peripheral -> central: SOS, HELLO, MESSAGE
///   DATA write   6e400002  central -> peripheral: SOS (relay push), HELLO
///   ACK          bf277310  write + notify, both directions: ACK, STATUS
///   CONTROL      bf277311  read + notify: this node's status (role, relay,
///                          protocol version, queue length)
/// The two DATA UUIDs are the ones every earlier build used, so an older
/// phone (no ACK/CONTROL characteristic) still works: ACKs then travel on
/// the DATA characteristics, exactly as before.
///
/// Pure Dart (no plugin calls), so every rule here is unit-tested.
class BleProtocol {
  BleProtocol._();

  /// The single shared service every affected phone advertises and the
  /// Windows Rescue Team scans for.
  static const String serviceUuid = 'bf27730d-860a-4e09-889c-2d8b6a9e0fe7';

  /// Phone -> central notifications (SOS, HELLO, MESSAGE). This is
  /// flutter_ble_peripheral's default notify characteristic, which is what
  /// `GattServerSettings()` actually serves.
  static const String notifyCharacteristicUuid =
      '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  /// Central -> phone writes (ACK, HELLO, STATUS). flutter_ble_peripheral's
  /// default write characteristic.
  static const String writeCharacteristicUuid =
      '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

  /// ACK / STATUS channel (write + notify) -- keeps short control messages
  /// off the DATA channel so a long SOS transfer never delays an ACK.
  static const String ackCharacteristicUuid =
      'bf277310-860a-4e09-889c-2d8b6a9e0fe7';

  /// Read + notify: compact JSON describing this node (see [control]).
  static const String controlCharacteristicUuid =
      'bf277311-860a-4e09-889c-2d8b6a9e0fe7';

  /// Bluetooth SIG "reserved for testing" company id, used for the 6-byte
  /// capability record in the scan response (see [MeshAdvertisement]).
  static const int manufacturerId = 0xFFFF;

  /// Default hop budget for a new SOS (origin -> relays -> rescue).
  static const int defaultMaxHops = 5;

  static const String typeSos = 'SOS';
  static const String typeAck = 'ACK';
  static const String typeHello = 'HELLO';
  static const String typeStatus = 'STATUS';
  static const String typeMessage = 'MESSAGE';

  static const String roleAffected = 'affected';
  static const String roleRescue = 'rescue';
  static const String roleRelay = 'relay';

  /// Hop ACK: "the next device has your packet" (custody accepted).
  static const String ackKindHop = 'HOP';

  /// End-to-end ACK: "the Rescue Team's endpoint has stored your SOS".
  static const String ackKindRescue = 'RESCUE';

  /// Bytes per BLE write/notification. 20 = the default ATT MTU (23) minus
  /// the 3-byte ATT header, i.e. the size EVERY link supports even if no MTU
  /// exchange ever happens. flutter_ble_peripheral's sendData does not
  /// fragment, and Android truncates a notification longer than MTU-3, so
  /// sending a whole SOS in one notification would silently corrupt it on
  /// links that never negotiated a larger MTU.
  static const int attPayloadSize = 20;

  static bool sameUuid(String a, String b) =>
      normalizeUuid(a) == normalizeUuid(b);

  static String normalizeUuid(String uuid) =>
      uuid.toLowerCase().replaceAll('-', '').replaceAll('{', '').replaceAll('}', '');

  /// Decodes a complete (reassembled) message into a JSON object, or null
  /// if it is not valid UTF-8 JSON. Never throws.
  static Map<String, dynamic>? decodeJsonObject(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > BleFrameCodec.maxMessageBytes) {
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List encodeJson(Map<String, dynamic> json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  /// [by] says who acknowledged: the Rescue Team itself, or a relay phone
  /// that only confirms the next hop has the packet. (v2 wire format;
  /// v3 senders use [hopAck] / [rescueAck].)
  static Map<String, dynamic> ack(String packetId, {String by = roleRescue}) =>
      {'type': typeAck, 'id': packetId, 'by': by};

  /// v3 hop ACK. [willForward] is false when this relay keeps the packet
  /// but cannot pass it on (hop budget spent), so the sender keeps trying
  /// other links.
  static Map<String, dynamic> hopAck({
    required String packetId,
    required String fromId,
    required bool willForward,
  }) =>
      {
        'type': typeAck,
        'id': packetId,
        'k': ackKindHop,
        'by': roleRelay,
        'from': fromId,
        'fwd': willForward,
      };

  /// v3 end-to-end ACK from the Rescue Team endpoint, authenticated so a
  /// relay or a stray central cannot fake "the Rescue Team has it".
  static Map<String, dynamic> rescueAck({
    required String packetId,
    required String originId,
    required String fromId,
    required DateTime at,
    required MeshAuth auth,
  }) {
    final json = <String, dynamic>{
      'type': typeAck,
      'id': packetId,
      'k': ackKindRescue,
      'by': roleRescue,
      'origin': originId,
      'from': fromId,
      'at': at.toUtc().toIso8601String(),
    };
    json['mac'] = auth.macOf(MeshAuth.ackFields(json));
    return json;
  }

  /// Packet types a v3 node understands (HELLO capability exchange).
  static const List<String> supportedTypes = [
    typeHello,
    typeSos,
    typeAck,
    typeStatus,
    typeMessage,
  ];

  /// HELLO = identity + capability exchange: app-level node id (never the
  /// BLE address), role, name, relay capability, protocol version and the
  /// packet types this node understands.
  static Map<String, dynamic> hello({
    required String role,
    required String deviceName,
    String? senderId,
    bool? relayEnabled,
    List<String>? capabilities,
    int? maxMeshNodes,
  }) =>
      {
        'type': typeHello,
        'role': role,
        'deviceName': deviceName,
        'senderId': ?senderId,
        'relay': ?relayEnabled,
        'caps': ?capabilities,
        'maxNodes': ?maxMeshNodes,
        'protocolVersion': SosPacket.currentProtocolVersion,
      };

  /// v2 STATUS (unrouted, unauthenticated). See [routedStatus].
  static Map<String, dynamic> status(String packetId, String status) =>
      {'type': typeStatus, 'id': packetId, 'status': status};

  /// v3 rescue-workflow STATUS, routed back to the origin along the path
  /// the SOS took, authenticated like [rescueAck].
  static Map<String, dynamic> routedStatus({
    required String packetId,
    required String originId,
    required String status,
    required String fromId,
    required DateTime at,
    required MeshAuth auth,
  }) {
    final json = <String, dynamic>{
      'type': typeStatus,
      'id': packetId,
      'status': status,
      'origin': originId,
      'from': fromId,
      'at': at.toUtc().toIso8601String(),
    };
    json['mac'] = auth.macOf(MeshAuth.statusFields(json));
    return json;
  }

  /// Body of the CONTROL characteristic.
  static Map<String, dynamic> control({
    required String role,
    required String deviceId,
    required String deviceName,
    required bool relayEnabled,
    required int queued,
  }) =>
      {
        'v': SosPacket.currentProtocolVersion,
        'role': role,
        'id': deviceId,
        'name': deviceName,
        'relay': relayEnabled,
        'q': queued,
      };

  /// What kind of ACK a decoded ACK message is. A v2 ACK carries only
  /// 'by'; a missing or unknown value is treated as a HOP ACK -- never as
  /// the Rescue Team's confirmation.
  static String ackKindOf(Map<String, dynamic> json) {
    final k = json['k'];
    if (k == ackKindRescue || k == ackKindHop) return k as String;
    return json['by'] == roleRescue ? ackKindRescue : ackKindHop;
  }

  /// Relay loop prevention: never re-relay a packet this phone originated
  /// or already relayed (anywhere on its path), and never relay once the
  /// hop budget is spent.
  static bool shouldRelay(SosPacket packet, String myDeviceId) =>
      packet.ttl > 0 &&
      packet.hopCount < packet.maxHops &&
      packet.senderId != myDeviceId &&
      packet.relayedBy != myDeviceId &&
      !packet.path.contains(myDeviceId);
}

/// Application-level message authentication: HMAC-SHA256 (truncated to
/// 128 bits) over the fields relays must never change.
///
/// What this does and does not give: every build of the app shares one
/// network key (MESH_NETWORK_KEY at build time; a clearly-labelled demo
/// key otherwise). It rejects packets from devices that do not run this
/// app's build and any relay modification of the origin, GPS, message or
/// ACK -- but anyone who extracts the key from the APK can forge messages.
/// Per-device public-key signatures would be the production upgrade.
class MeshAuth {
  MeshAuth(String key) : _hmac = Hmac(sha256, utf8.encode(key));

  /// Overridden at build time with --dart-define=MESH_NETWORK_KEY=...
  static const String configuredKey = String.fromEnvironment(
    'MESH_NETWORK_KEY',
    defaultValue: 'disaster-mesh-DEMO-key-not-secret',
  );

  static bool get usingDemoKey => !const bool.hasEnvironment('MESH_NETWORK_KEY');

  static final MeshAuth instance = MeshAuth(configuredKey);

  final Hmac _hmac;

  String macOf(String canonical) {
    final digest = _hmac.convert(utf8.encode(canonical)).bytes.sublist(0, 16);
    return base64Url.encode(digest).replaceAll('=', '');
  }

  bool verify(String canonical, Object? mac) {
    if (mac is! String || mac.isEmpty) return false;
    final expected = macOf(canonical);
    if (expected.length != mac.length) return false;
    var diff = 0;
    for (var i = 0; i < mac.length; i++) {
      diff |= expected.codeUnitAt(i) ^ mac.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Origin-owned SOS fields. Relay bookkeeping (hops, path, ttl, current
  /// relay) is deliberately excluded so relays can update it.
  static String sosFields(SosPacket p) => [
        'SOS',
        p.id,
        p.senderId,
        p.timestamp.toUtc().toIso8601String(),
        p.latitude?.toStringAsFixed(6) ?? '',
        p.longitude?.toStringAsFixed(6) ?? '',
        p.emergencyType,
        p.numberOfPeople,
        p.injured,
        p.message,
        p.maxHops,
      ].join('|');

  static String ackFields(Map<String, dynamic> j) =>
      ['ACK', j['id'], j['k'], j['origin'], j['from'], j['at']].join('|');

  static String statusFields(Map<String, dynamic> j) =>
      ['STATUS', j['id'], j['status'], j['origin'], j['from'], j['at']].join('|');

  String sign(SosPacket p) => macOf(sosFields(p));
  bool verifySos(SosPacket p) => verify(sosFields(p), p.mac);
  bool verifyAck(Map<String, dynamic> j) => verify(ackFields(j), j['mac']);
  bool verifyStatus(Map<String, dynamic> j) =>
      verify(statusFields(j), j['mac']);
}

/// The 6-byte capability record carried as manufacturer data in the scan
/// response: [protocolVersion, flags, 4-byte id tag]. Lets a scanner skip
/// devices that are not mesh nodes, and avoid opening a second link to a
/// phone it is already linked with, before connecting. Static only:
/// changing advertising data means restarting the advertiser.
class MeshAdvertisement {
  const MeshAdvertisement({
    required this.protocolVersion,
    required this.relayCapable,
    required this.idTag,
  });

  final int protocolVersion;
  final bool relayCapable;

  /// First 4 bytes of SHA-256(device id), hex -- not the id itself.
  final String idTag;

  static String tagFor(String deviceId) =>
      sha256.convert(utf8.encode(deviceId)).toString().substring(0, 8);

  Uint8List encode() {
    final tag = idTag.padRight(8, '0');
    return Uint8List.fromList([
      protocolVersion & 0xFF,
      relayCapable ? 0x01 : 0x00,
      for (var i = 0; i < 8; i += 2)
        int.parse(tag.substring(i, i + 2), radix: 16),
    ]);
  }

  static MeshAdvertisement? decode(List<int>? bytes) {
    if (bytes == null || bytes.length < 6) return null;
    return MeshAdvertisement(
      protocolVersion: bytes[0],
      relayCapable: (bytes[1] & 0x01) != 0,
      idTag: bytes
          .sublist(2, 6)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
    );
  }
}

/// Splits one message into BLE-sized frames and back.
///
/// Frame = [magic 0xB1][message id][chunk index][chunk count] + payload.
/// 0xB1 can never be the first byte of UTF-8 text, so an unframed JSON
/// payload (older build, single write) is still recognised and accepted.
class BleFrameCodec {
  BleFrameCodec._();

  static const int magic = 0xB1;
  static const int headerSize = 4;
  static const int maxChunks = 255;

  static int chunkDataSize([int attPayloadSize = BleProtocol.attPayloadSize]) =>
      attPayloadSize - headerSize;

  static int get maxMessageBytes => maxChunks * chunkDataSize();

  static List<Uint8List> encode(
    List<int> message, {
    required int messageId,
    int attPayloadSize = BleProtocol.attPayloadSize,
  }) {
    final chunk = chunkDataSize(attPayloadSize);
    if (message.isEmpty) {
      throw ArgumentError('Cannot frame an empty message.');
    }
    final count = (message.length / chunk).ceil();
    if (count > maxChunks) {
      throw ArgumentError(
        'Message of ${message.length} bytes needs $count frames; the '
        'protocol allows at most $maxChunks.',
      );
    }
    return [
      for (var i = 0; i < count; i++)
        Uint8List.fromList([
          magic,
          messageId & 0xFF,
          i,
          count,
          ...message.sublist(
            i * chunk,
            math.min((i + 1) * chunk, message.length),
          ),
        ]),
    ];
  }
}

/// Rebuilds framed messages, independently per source (one BLE link), so
/// two phones sending at the same time can never mix their chunks.
class BleFrameReassembler {
  BleFrameReassembler({this.staleAfter = const Duration(seconds: 20)});

  final Duration staleAfter;
  final Map<String, _PartialMessage> _partials = {};

  /// Feeds one received write/notification. Returns the complete message
  /// once its last missing chunk arrives, otherwise null.
  Uint8List? add(String sourceKey, List<int> chunk, {DateTime? now}) {
    if (chunk.isEmpty) return null;

    if (chunk[0] != BleFrameCodec.magic) {
      return Uint8List.fromList(chunk);
    }

    if (chunk.length <= BleFrameCodec.headerSize) return null;

    final messageId = chunk[1];
    final index = chunk[2];
    final count = chunk[3];
    if (count == 0 || index >= count) return null;

    final time = now ?? DateTime.now();
    var partial = _partials[sourceKey];
    if (partial == null ||
        partial.messageId != messageId ||
        partial.parts.length != count ||
        time.difference(partial.startedAt) > staleAfter) {
      partial = _PartialMessage(messageId, count, time);
      _partials[sourceKey] = partial;
    }

    partial.parts[index] = chunk.sublist(BleFrameCodec.headerSize);
    if (partial.parts.any((p) => p == null)) return null;

    _partials.remove(sourceKey);
    final builder = BytesBuilder(copy: false);
    for (final part in partial.parts) {
      builder.add(part!);
    }
    return builder.toBytes();
  }

  void clear(String sourceKey) => _partials.remove(sourceKey);

  bool hasPartial(String sourceKey) => _partials.containsKey(sourceKey);
}

class _PartialMessage {
  _PartialMessage(this.messageId, int count, this.startedAt)
      : parts = List<List<int>?>.filled(count, null);

  final int messageId;
  final DateTime startedAt;
  final List<List<int>?> parts;
}

/// Rejects inbound SOS packets that are malformed or are obvious replays.
class SosValidation {
  SosValidation._();

  /// Tolerance for a sender whose clock runs ahead.
  static const Duration maxClockSkewAhead = Duration(hours: 2);

  /// Older than this is treated as a stale/replayed packet, not a live SOS.
  static const Duration maxAge = Duration(hours: 48);

  /// Upper bound for ttl / maxHops / relay path length.
  static const int maxHopBudget = 16;

  static const int maxMessageChars = 1000;

  /// Null when the packet is acceptable, otherwise a human-readable reason.
  static String? rejectReason(SosPacket packet, {DateTime? now}) {
    if (packet.id.isEmpty) return 'missing packet id';
    if (packet.senderId.isEmpty) return 'missing sender id';

    final lat = packet.latitude;
    final lon = packet.longitude;
    if ((lat == null) != (lon == null)) return 'incomplete GPS coordinates';
    if (lat != null && (lat.isNaN || lat < -90 || lat > 90)) {
      return 'latitude out of range';
    }
    if (lon != null && (lon.isNaN || lon < -180 || lon > 180)) {
      return 'longitude out of range';
    }

    if (packet.ttl < 0) return 'negative TTL';
    if (packet.ttl > maxHopBudget) return 'TTL too large';
    if (packet.maxHops < 1 || packet.maxHops > maxHopBudget) {
      return 'invalid hop limit';
    }
    if (packet.hopCount < 0) return 'negative hop count';
    if (packet.hopCount > packet.maxHops) return 'hop limit exceeded';
    if (packet.path.length > maxHopBudget) return 'relay path too long';
    if (packet.message.length > maxMessageChars) return 'message too long';
    final acc = packet.accuracyMeters;
    if (acc != null && (acc.isNaN || acc < 0 || acc > 100000)) {
      return 'invalid GPS accuracy';
    }

    final reference = (now ?? DateTime.now()).toUtc();
    final timestamp = packet.timestamp.toUtc();
    if (timestamp.isAfter(reference.add(maxClockSkewAhead))) {
      return 'timestamp is in the future';
    }
    if (timestamp.isBefore(reference.subtract(maxAge))) {
      return 'timestamp too old (possible replay)';
    }
    return null;
  }
}

/// Bounded "already processed" set -- evicts the oldest id first, and ids
/// older than [maxAge] (an SOS that old is rejected as a replay anyway).
/// Serializable, so dedup survives an app restart.
class PacketIdCache {
  PacketIdCache({this.capacity = 1000, this.maxAge = SosValidation.maxAge});

  final int capacity;
  final Duration maxAge;
  final Map<String, int> _seenAt = <String, int>{};

  /// Returns true the first time an id is seen, false for a duplicate.
  bool markIfNew(String id, {DateTime? now}) {
    final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
    _expire(time);
    if (_seenAt.containsKey(id)) return false;
    _seenAt[id] = time;
    while (_seenAt.length > capacity) {
      _seenAt.remove(_seenAt.keys.first);
    }
    return true;
  }

  bool contains(String id) => _seenAt.containsKey(id);

  int get length => _seenAt.length;

  void _expire(int nowMs) {
    final cutoff = nowMs - maxAge.inMilliseconds;
    _seenAt.removeWhere((_, t) => t < cutoff);
  }

  Map<String, dynamic> toJson() => {'seen': Map<String, int>.of(_seenAt)};

  void loadJson(Map<String, dynamic>? json) {
    final seen = json?['seen'];
    if (seen is! Map) return;
    for (final entry in seen.entries) {
      final t = entry.value;
      if (entry.key is String && t is int) _seenAt[entry.key as String] = t;
    }
    _expire(DateTime.now().millisecondsSinceEpoch);
  }
}

/// Stable fallback labels for devices whose OS/plugin reports no name --
/// never the raw BLE address.
class FallbackDeviceNamer {
  final Map<String, String> _names = {};

  String nameFor(String address) => _names.putIfAbsent(
        address,
        () => 'Affected Device ${(_names.length + 1).toString().padLeft(2, '0')}',
      );
}

/// Rolling 1-byte message id for [BleFrameCodec]. Starts at a random value
/// so two devices that start together do not use the same id sequence.
class FrameMessageIds {
  FrameMessageIds([int? start])
      : _next = (start ?? math.Random().nextInt(256)) & 0xFF;

  int _next;

  int next() {
    final id = _next;
    _next = (_next + 1) & 0xFF;
    return id;
  }
}
