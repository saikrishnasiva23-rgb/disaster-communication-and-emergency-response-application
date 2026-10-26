/// Real connection states for a single affected-person device, as seen by
/// the Windows Rescue Team's BLE central role. Never set to [connected]
/// unless the platform's own connection-state event reported it.
enum AffectedConnectionState {
  discovered,
  connecting,
  connected,
  disconnected,
  connectionFailed,
  bluetoothDisabled,
  permissionError,
}

/// One independent connection slot per affected phone, keyed by its BLE
/// address. Every field is updated only by events tagged with that same
/// address, so Phone 1's data can never overwrite Phone 2's.
///
/// [displayName] is human-readable: the name the phone reported about
/// itself in its GATT HELLO (e.g. "OPPO A5 Pro 5G"), else an OS-reported
/// scan name, else a stable "Affected Device 01" style fallback. The
/// [address] is technical metadata only -- never the primary UI label.
class AffectedDeviceConnection {
  final String address;
  final String displayName;

  /// True once the name came from the phone itself (HELLO/SOS), so a later
  /// scan result cannot replace it with a worse one.
  final bool nameConfirmed;

  /// The phone's stable app-level device id, learned from its HELLO/SOS.
  final String? senderId;
  final int? rssi;
  final AffectedConnectionState state;

  /// True only after this laptop successfully subscribed to the phone's
  /// SOS notify characteristic -- i.e. an SOS can actually reach us.
  final bool gattReady;

  /// Human-readable reason for the most recent failure on this link.
  final String? lastError;
  final DateTime? connectedAt;

  /// Last time this device was seen at all -- a scan sighting or any
  /// received packet, whichever is more recent.
  final DateTime? lastSeenAt;
  final String? lastMessage;

  /// GPS from the most recent SOS -- null until one with a fix arrives.
  final double? lastLatitude;
  final double? lastLongitude;
  final String? lastSosId;
  final DateTime? lastSosAt;
  final int sosCount;

  /// The exact link state-machine label (DISCOVERED, CONNECTING, CONNECTED,
  /// SERVICE DISCOVERY, READY, DISCONNECTING, DISCONNECTED, ERROR).
  final String? linkState;

  /// Role the device announced in its HELLO: 'affected', 'relay', 'rescue'.
  final String? peerRole;

  /// Bytes per BLE frame on this link (negotiated MTU - 3).
  final int? payloadSize;

  /// READY and the device introduced itself (HELLO) -- usable for routing.
  final bool identified;

  const AffectedDeviceConnection({
    required this.address,
    required this.displayName,
    this.nameConfirmed = false,
    this.senderId,
    this.rssi,
    this.state = AffectedConnectionState.discovered,
    this.gattReady = false,
    this.lastError,
    this.connectedAt,
    this.lastSeenAt,
    this.lastMessage,
    this.lastLatitude,
    this.lastLongitude,
    this.lastSosId,
    this.lastSosAt,
    this.sosCount = 0,
    this.linkState,
    this.peerRole,
    this.payloadSize,
    this.identified = false,
  });

  bool get isRelay => peerRole == 'relay';

  bool get isConnected => state == AffectedConnectionState.connected;

  /// Pass `clearError: true` to remove [lastError] (e.g. after a success).
  AffectedDeviceConnection copyWith({
    String? displayName,
    bool? nameConfirmed,
    String? senderId,
    int? rssi,
    AffectedConnectionState? state,
    bool? gattReady,
    String? lastError,
    bool clearError = false,
    DateTime? connectedAt,
    DateTime? lastSeenAt,
    String? lastMessage,
    double? lastLatitude,
    double? lastLongitude,
    String? lastSosId,
    DateTime? lastSosAt,
    int? sosCount,
    String? linkState,
    String? peerRole,
    int? payloadSize,
    bool? identified,
  }) {
    return AffectedDeviceConnection(
      address: address,
      displayName: displayName ?? this.displayName,
      nameConfirmed: nameConfirmed ?? this.nameConfirmed,
      senderId: senderId ?? this.senderId,
      rssi: rssi ?? this.rssi,
      state: state ?? this.state,
      gattReady: gattReady ?? this.gattReady,
      lastError: clearError ? null : (lastError ?? this.lastError),
      connectedAt: connectedAt ?? this.connectedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastMessage: lastMessage ?? this.lastMessage,
      lastLatitude: lastLatitude ?? this.lastLatitude,
      lastLongitude: lastLongitude ?? this.lastLongitude,
      lastSosId: lastSosId ?? this.lastSosId,
      lastSosAt: lastSosAt ?? this.lastSosAt,
      sosCount: sosCount ?? this.sosCount,
      linkState: linkState ?? this.linkState,
      peerRole: peerRole ?? this.peerRole,
      payloadSize: payloadSize ?? this.payloadSize,
      identified: identified ?? this.identified,
    );
  }
}
