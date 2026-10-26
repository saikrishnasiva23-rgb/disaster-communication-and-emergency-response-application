import 'dart:convert';

/// Delivery state of an SOS on the phone that created it. Ordered: a state
/// only ever moves forward (see [rank]), so a late hop ACK can never
/// downgrade "received by the Rescue Team".
enum SosStatus {
  /// Packet built on this phone.
  created,

  /// Saved in the outbox; no Bluetooth link to send it on yet (or waiting
  /// to retry). It is sent automatically when a link becomes ready.
  queued,

  /// Transmitted to the next device (a relay phone or the rescue laptop);
  /// that device has not confirmed it yet.
  sentToRelay,

  /// A relay phone confirmed it has the packet and will forward it. NOT
  /// the Rescue Team's confirmation.
  relayed,

  /// The Rescue Team's endpoint stored the SOS and its authenticated ACK
  /// travelled back to this phone (possibly through relays).
  receivedByRescue,

  /// A rescuer acknowledged / acted on the SOS (STATUS routed back).
  acknowledged,

  /// Could not be delivered (expired without any rescue ACK, or invalid).
  failed;

  int get rank => switch (this) {
        SosStatus.created => 0,
        SosStatus.queued => 1,
        SosStatus.sentToRelay => 2,
        SosStatus.relayed => 3,
        SosStatus.receivedByRescue => 4,
        SosStatus.acknowledged => 5,
        // Failed may replace any state below receivedByRescue, nothing above.
        SosStatus.failed => 3,
      };

  /// Reached the Rescue Team (end to end).
  bool get reachedRescue =>
      this == SosStatus.receivedByRescue || this == SosStatus.acknowledged;

  /// Forward-only transitions. FAILED never overrides an end-to-end
  /// confirmation, and a late rescue ACK still rescues a FAILED packet.
  bool canMoveTo(SosStatus next) {
    if (next == this) return false;
    if (next == SosStatus.failed) return !reachedRescue;
    if (this == SosStatus.failed) return next.reachedRescue;
    return next.rank > rank;
  }
}

SosStatus sosStatusFromString(String value) {
  for (final s in SosStatus.values) {
    if (s.name == value) return s;
  }
  // Names used by builds before protocol v3.
  return switch (value) {
    'pending' => SosStatus.queued,
    'sending' || 'sent' => SosStatus.sentToRelay,
    'delivered' => SosStatus.relayed,
    _ => SosStatus.queued,
  };
}

/// Destination of an SOS: the Rescue Team's endpoint (laptop).
const String destinationRescue = 'RESCUE_LAPTOP';

/// The canonical SOS payload, sent as JSON over BLE (see BleProtocol /
/// BleFrameCodec for framing), relayed hop by hop, and synced to the cloud.
///
/// Origin-owned fields (id, senderId, timestamp, GPS, message, type...) are
/// covered by [mac] and are never changed by a relay; only the relay
/// bookkeeping ([hopCount], [ttl], [path], [relayedBy]) changes per hop.
class SosPacket {
  /// 3 = relay path, hop limit, GPS accuracy, message authentication.
  static const int currentProtocolVersion = 3;

  /// Unique packet id; constant across hops and retransmissions, so it is
  /// the dedup and ACK key everywhere (BLE, relays, laptop, cloud).
  final String id;
  final String type;

  /// Logical message id. An SOS is one message, so it equals [id]; kept
  /// separate on the wire so later message types can group packets.
  final String messageId;

  /// Stable per-install id of the ORIGINAL sender (originDeviceId). A relay
  /// hop never changes it.
  final String senderId;

  /// Human-readable name of the original sending device, sent on the wire
  /// as `deviceName`. Empty only for packets from very old builds.
  final String senderDisplayName;

  /// When the SOS was created on the origin phone.
  final DateTime timestamp;

  /// Real GPS fix from the ORIGIN phone, or null when no fix was available.
  /// Relays never replace it with their own position.
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;

  /// When that fix was taken (may be earlier than [timestamp] when the
  /// phone used its last known position).
  final DateTime? fixTime;

  final String message;
  final String emergencyType;
  final int numberOfPeople;
  final bool injured;
  String priority;
  SosStatus status;

  /// Hops still allowed (counts down per relay).
  final int ttl;

  /// Hop limit set by the origin; a relay never forwards once
  /// [hopCount] reaches it.
  final int maxHops;

  /// Relay hops actually taken so far (0 = direct).
  final int hopCount;

  /// Device ids of every relay that forwarded this packet, oldest first.
  final List<String> path;

  /// The relay that most recently forwarded it (currentRelayDeviceId), or
  /// null if it has never been relayed.
  final String? relayedBy;
  final String? relayedByName;

  final String destinationType;
  final bool requiresAck;

  final int sequence;
  DateTime? acknowledgedAt;

  /// Wire format version of the sender.
  final int protocolVersion;

  /// MeshAuth HMAC over the origin-owned fields, or null (older build).
  final String? mac;

  SosPacket({
    required this.id,
    this.type = 'SOS',
    String? messageId,
    required this.senderId,
    this.senderDisplayName = '',
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.fixTime,
    required this.message,
    this.emergencyType = 'General Emergency',
    this.numberOfPeople = 1,
    this.injured = false,
    this.priority = 'UNKNOWN',
    this.status = SosStatus.created,
    this.ttl = 5,
    this.maxHops = 5,
    this.hopCount = 0,
    List<String>? path,
    this.relayedBy,
    this.relayedByName,
    this.destinationType = destinationRescue,
    this.requiresAck = true,
    required this.sequence,
    this.acknowledgedAt,
    this.protocolVersion = 1,
    this.mac,
  })  : messageId = messageId ?? id,
        path = List.unmodifiable(path ?? const <String>[]);

  bool get hasLocation => latitude != null && longitude != null;

  bool get isRelayed => hopCount > 0 || relayedBy != null;

  /// Name to show for the original sender (never the raw BLE address).
  String get displayName =>
      senderDisplayName.isNotEmpty ? senderDisplayName : senderId;

  /// A copy of this packet as relay [relayerId] forwards it: every
  /// origin-owned field is carried over unchanged; [hopCount], [ttl],
  /// [path] and the current relay change.
  SosPacket forRelay({required String relayerId, required String relayerName}) {
    return _copy(
      ttl: ttl - 1,
      relayedBy: relayerId,
      relayedByName: relayerName,
      hopCount: hopCount + 1,
      path: [...path, relayerId],
    );
  }

  /// The same packet with [mac] set (signed by the origin).
  SosPacket withMac(String value) => _copy(mac: value);

  SosPacket _copy({
    String? message,
    int? ttl,
    String? relayedBy,
    String? relayedByName,
    int? hopCount,
    List<String>? path,
    String? mac,
  }) =>
      SosPacket(
        id: id,
        type: type,
        messageId: messageId,
        senderId: senderId,
        senderDisplayName: senderDisplayName,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        accuracyMeters: accuracyMeters,
        fixTime: fixTime,
        message: message ?? this.message,
        emergencyType: emergencyType,
        numberOfPeople: numberOfPeople,
        injured: injured,
        priority: priority,
        status: status,
        ttl: ttl ?? this.ttl,
        maxHops: maxHops,
        hopCount: hopCount ?? this.hopCount,
        path: path ?? this.path,
        relayedBy: relayedBy ?? this.relayedBy,
        relayedByName: relayedByName ?? this.relayedByName,
        destinationType: destinationType,
        requiresAck: requiresAck,
        sequence: sequence,
        acknowledgedAt: acknowledgedAt,
        protocolVersion: protocolVersion,
        mac: mac ?? (message != null ? null : this.mac),
      );

  /// Full representation (local storage, tests).
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'messageId': messageId,
        'senderId': senderId,
        'senderDisplayName': senderDisplayName,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracyMeters,
        'fixTime': fixTime?.toUtc().toIso8601String(),
        'message': message,
        'emergencyType': emergencyType,
        'numberOfPeople': numberOfPeople,
        'injured': injured,
        'priority': priority,
        'status': status.name,
        'ttl': ttl,
        'maxHops': maxHops,
        'hopCount': hopCount,
        'path': path,
        'relayedBy': relayedBy,
        'relayedByName': relayedByName,
        'destinationType': destinationType,
        'requiresAck': requiresAck,
        'sequence': sequence,
        'acknowledgedAt': acknowledgedAt?.toUtc().toIso8601String(),
        'protocolVersion': protocolVersion,
        'mac': mac,
      };

  /// What actually goes over BLE: only fields the receiver needs, defaults
  /// and nulls omitted. Sender-local fields (status, sequence,
  /// acknowledgedAt) never travel.
  Map<String, dynamic> toTransportJson() => {
        'type': type,
        'id': id,
        if (messageId != id) 'mid': messageId,
        'senderId': senderId,
        if (senderDisplayName.isNotEmpty) 'deviceName': senderDisplayName,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (latitude != null) 'latitude': _round6(latitude!),
        if (longitude != null) 'longitude': _round6(longitude!),
        if (accuracyMeters != null) 'acc': (accuracyMeters! * 10).round() / 10,
        if (fixTime != null) 'fixAt': fixTime!.toUtc().toIso8601String(),
        if (message.isNotEmpty) 'message': message,
        if (emergencyType != 'General Emergency') 'emergencyType': emergencyType,
        if (numberOfPeople != 1) 'numberOfPeople': numberOfPeople,
        if (injured) 'injured': true,
        'priority': priority,
        'ttl': ttl,
        if (maxHops != 5) 'maxHops': maxHops,
        if (hopCount > 0) 'hopCount': hopCount,
        if (path.isNotEmpty) 'path': path,
        'relayedBy': ?relayedBy,
        'relayedByName': ?relayedByName,
        if (destinationType != destinationRescue) 'dst': destinationType,
        if (!requiresAck) 'ra': false,
        'protocolVersion': protocolVersion,
        'mac': ?mac,
      };

  /// ~0.1 m precision -- keeps the real fix, drops meaningless digits.
  static double _round6(double v) => double.parse(v.toStringAsFixed(6));

  /// Lenient parser for local storage and older builds (missing fields get
  /// defaults). For packets received over the air use [fromWireJson].
  factory SosPacket.fromJson(Map<String, dynamic> json) {
    final rawPath = json['path'];
    return SosPacket(
      id: json['id'] as String,
      type: json['type'] as String? ?? 'SOS',
      messageId: (json['messageId'] ?? json['mid']) as String?,
      senderId: json['senderId'] as String? ?? 'unknown',
      senderDisplayName: (json['senderDisplayName'] as String?) ??
          (json['deviceName'] as String?) ??
          '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now().toUtc(),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      accuracyMeters: ((json['accuracy'] ?? json['acc']) as num?)?.toDouble(),
      fixTime: DateTime.tryParse(
          (json['fixTime'] ?? json['fixAt']) as String? ?? ''),
      message: json['message'] as String? ?? '',
      emergencyType: json['emergencyType'] as String? ?? 'General Emergency',
      numberOfPeople: (json['numberOfPeople'] as num?)?.toInt() ?? 1,
      injured: json['injured'] as bool? ?? false,
      priority: json['priority'] as String? ?? 'UNKNOWN',
      status: sosStatusFromString(json['status'] as String? ?? 'created'),
      ttl: (json['ttl'] as num?)?.toInt() ?? 5,
      maxHops: (json['maxHops'] as num?)?.toInt() ?? 5,
      hopCount: (json['hopCount'] as num?)?.toInt() ?? 0,
      path: rawPath is List ? rawPath.whereType<String>().toList() : null,
      relayedBy: json['relayedBy'] as String?,
      relayedByName: json['relayedByName'] as String?,
      destinationType: (json['destinationType'] ?? json['dst']) as String? ??
          destinationRescue,
      requiresAck: (json['requiresAck'] ?? json['ra']) as bool? ?? true,
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      acknowledgedAt: json['acknowledgedAt'] != null
          ? DateTime.tryParse(json['acknowledgedAt'] as String)
          : null,
      protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
      mac: json['mac'] as String?,
    );
  }

  /// Strict parser for packets received over Bluetooth: an id, an origin
  /// id and a creation timestamp are REQUIRED (no defaulting to "now" or
  /// "unknown", which would let a replayed packet look fresh). Throws
  /// [FormatException].
  factory SosPacket.fromWireJson(Map<String, dynamic> json) {
    final id = json['id'];
    final sender = json['senderId'];
    final ts = json['timestamp'];
    if (id is! String || id.isEmpty || id.length > 64) {
      throw const FormatException('missing or invalid packet id');
    }
    if (sender is! String || sender.isEmpty || sender.length > 64) {
      throw const FormatException('missing or invalid origin id');
    }
    if (ts is! String || DateTime.tryParse(ts) == null) {
      throw const FormatException('missing or invalid timestamp');
    }
    for (final key in ['latitude', 'longitude', 'acc', 'ttl', 'maxHops', 'hopCount']) {
      final v = json[key];
      if (v != null && v is! num) throw FormatException('$key is not a number');
    }
    final rawPath = json['path'];
    if (rawPath != null && (rawPath is! List || rawPath.any((e) => e is! String))) {
      throw const FormatException('invalid relay path');
    }
    final packet = SosPacket.fromJson(json);
    packet.status = SosStatus.created;
    return packet;
  }

  /// Full JSON string (see [toJson]).
  String toWireBytes() => jsonEncode(toJson());

  /// Ceiling for the full JSON form used by the legacy single-write path
  /// (the old Android rescue phone). The v3 full form carries more fields
  /// (relay path, GPS accuracy, MAC), so the ceiling grew from 500.
  static const int maxWireBytes = 900;

  /// Full JSON, shrinking [message] (the only user-controlled length) if
  /// needed to fit [maxBytes]; identity, GPS and priority are never cut.
  String toWireBytesTruncated({int maxBytes = maxWireBytes}) =>
      _encodeFitting(maxBytes, (p) => p.toWireBytes());

  /// Compact transport JSON for BLE frames. Fragmentation handles normal
  /// sizes; [maxBytes] only guards against a pathological message.
  String toTransportString({int maxBytes = 3500}) =>
      _encodeFitting(maxBytes, (p) => jsonEncode(p.toTransportJson()));

  String _encodeFitting(int maxBytes, String Function(SosPacket) encode) {
    var candidate = this;
    var encoded = encode(candidate);

    while (utf8.encode(encoded).length > maxBytes &&
        candidate.message.isNotEmpty) {
      final shorter = candidate.message.length > 20
          ? candidate.message.substring(0, candidate.message.length - 20)
          : '';
      candidate = candidate._copy(message: shorter);
      encoded = encode(candidate);
    }

    return encoded;
  }

  factory SosPacket.fromWireBytes(String raw) =>
      SosPacket.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Maps this packet onto the legacy POST /api/rescue-request body.
  Map<String, dynamic> toBackendJson() => {
        'name': displayName,
        'emergencyType': emergencyType,
        'numberOfPeople': numberOfPeople,
        'injured': injured ? 'Yes' : 'No',
        'latitude': latitude,
        'longitude': longitude,
        'message': message,
      };
}
