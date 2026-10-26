enum AuditEventType {
  sosCreated,
  sosTransmitted,
  sosReceived,
  sosAcknowledged,
  messageSent,
  messageReceived,
  locationShared,
  rescueAuthenticated,
  rescueAssigned,
  rescueStarted,
  rescueCompleted,

  /// SOS stored in the outbox with no Bluetooth link available yet.
  sosQueued,

  /// A relay phone took custody of another phone's SOS.
  relayReceived,

  /// A relay phone forwarded an SOS to the next device.
  relayForwarded,

  /// A relay phone passed the Rescue Team's ACK back toward the origin.
  ackForwarded,

  /// A relay phone passed a rescue STATUS back toward the origin.
  statusForwarded,

  /// The rescue endpoint sent its end-to-end ACK.
  rescueAckSent,

  /// The rescue endpoint sent a workflow STATUS toward the origin.
  statusSent,

  /// A received packet was rejected (malformed, replayed, tampered).
  packetRejected,

  /// Records uploaded to the cloud backend.
  cloudSynced,
}

AuditEventType? auditEventTypeFromName(String? name) {
  for (final t in AuditEventType.values) {
    if (t.name == name) return t;
  }
  return null;
}

/// One entry in the tamper-evident event log.
///
/// `hash` / `previousHash` are filled in by AuditLogState's SHA-256 chain.
class AuditEvent {
  final String id;
  final AuditEventType type;
  final String actorId;
  final DateTime timestamp;
  final String details;
  String? previousHash;
  String? hash;

  AuditEvent({
    required this.id,
    required this.type,
    required this.actorId,
    required this.timestamp,
    required this.details,
    this.previousHash,
    this.hash,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'actorId': actorId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'details': details,
        'previousHash': previousHash,
        'hash': hash,
      };

  static AuditEvent? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final type = auditEventTypeFromName(raw['type'] as String?);
    final timestamp = DateTime.tryParse(raw['timestamp'] as String? ?? '');
    if (type == null || timestamp == null || raw['id'] is! String) return null;
    return AuditEvent(
      id: raw['id'] as String,
      type: type,
      actorId: raw['actorId'] as String? ?? '',
      timestamp: timestamp,
      details: raw['details'] as String? ?? '',
      previousHash: raw['previousHash'] as String?,
      hash: raw['hash'] as String?,
    );
  }
}
