import 'package:flutter/foundation.dart';

import '../ble_protocol.dart';

/// Per-link connection state. A link is only usable for messages in
/// [ready] -- i.e. after the GATT service and its characteristics were
/// found and the notification subscriptions were written. "Discovered" is
/// never treated as "connected".
enum LinkState {
  discovered,
  connecting,
  connected,
  serviceDiscovery,
  ready,
  disconnecting,
  disconnected,
  error,
}

extension LinkStateLabel on LinkState {
  String get label => switch (this) {
        LinkState.discovered => 'DISCOVERED',
        LinkState.connecting => 'CONNECTING',
        LinkState.connected => 'CONNECTED',
        LinkState.serviceDiscovery => 'SERVICE DISCOVERY',
        LinkState.ready => 'READY',
        LinkState.disconnecting => 'DISCONNECTING',
        LinkState.disconnected => 'DISCONNECTED',
        LinkState.error => 'ERROR',
      };

  bool get isConnectedish =>
      this == LinkState.connected ||
      this == LinkState.serviceDiscovery ||
      this == LinkState.ready;
}

/// Which GATT role THIS device plays on a link.
enum LinkSide {
  /// This device is the GATT client: it connected to the peer's server.
  central,

  /// The peer is a GATT client of this device's server.
  peripheral,
}

/// Logical channel = GATT characteristic.
enum MeshChannel {
  /// DATA notify (peripheral -> central) / DATA write (central -> peripheral).
  data,

  /// ACK characteristic (write + notify).
  ack,
}

/// Snapshot of one BLE link as the transport sees it.
@immutable
class LinkInfo {
  const LinkInfo({
    required this.linkId,
    required this.side,
    required this.address,
    required this.state,
    required this.updatedAt,
    this.name,
    this.rssi,
    this.payloadSize = BleProtocol.attPayloadSize,
    this.hasAckChannel = false,
    this.advertisement,
    this.error,
  });

  /// '${side.name}:$address' -- unique per transport connection.
  final String linkId;
  final LinkSide side;

  /// BLE address: transport metadata only, never an identity (phones
  /// rotate addresses). Identity comes from HELLO / CONTROL.
  final String address;
  final LinkState state;
  final DateTime updatedAt;

  /// Name reported by the OS/scan, if any.
  final String? name;
  final int? rssi;

  /// Max bytes per write/notification on this link (ATT MTU - 3, >= 20).
  final int payloadSize;

  /// The ACK characteristic is usable on this link (peer has it and the
  /// subscription is in place). Otherwise ACKs travel on [MeshChannel.data].
  final bool hasAckChannel;

  /// Capability record from the scan response (central side only).
  final MeshAdvertisement? advertisement;
  final String? error;

  bool get isReady => state == LinkState.ready;

  static String idFor(LinkSide side, String address) => '${side.name}:$address';

  LinkInfo copyWith({
    LinkState? state,
    String? name,
    int? rssi,
    int? payloadSize,
    bool? hasAckChannel,
    MeshAdvertisement? advertisement,
    String? error,
    bool clearError = false,
    DateTime? updatedAt,
  }) =>
      LinkInfo(
        linkId: linkId,
        side: side,
        address: address,
        state: state ?? this.state,
        updatedAt: updatedAt ?? DateTime.now(),
        name: name ?? this.name,
        rssi: rssi ?? this.rssi,
        payloadSize: payloadSize ?? this.payloadSize,
        hasAckChannel: hasAckChannel ?? this.hasAckChannel,
        advertisement: advertisement ?? this.advertisement,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  String toString() => 'LinkInfo($linkId ${state.label} mtu=$payloadSize)';
}

/// One frame received on a link.
@immutable
class InboundFrame {
  const InboundFrame(this.linkId, this.channel, this.bytes);

  final String linkId;
  final MeshChannel channel;
  final Uint8List bytes;
}

enum TransportAvailability {
  stopped,
  starting,
  active,
  unsupported,
  permissionDenied,
  bluetoothOff,
  failed,
}

@immutable
class TransportStatus {
  const TransportStatus(this.availability, [this.detail]);

  final TransportAvailability availability;

  /// Human-readable reason for a failure state.
  final String? detail;

  bool get isActive => availability == TransportAvailability.active;

  bool get isFailure =>
      availability == TransportAvailability.unsupported ||
      availability == TransportAvailability.permissionDenied ||
      availability == TransportAvailability.bluetoothOff ||
      availability == TransportAvailability.failed;

  @override
  bool operator ==(Object other) =>
      other is TransportStatus &&
      other.availability == availability &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(availability, detail);
}

/// One BLE role on one platform:
///   AndroidPeripheralTransport -- native GATT server + advertiser (Kotlin)
///   AndroidCentralTransport    -- flutter_blue_plus scanner/client (relay)
///   WindowsCentralTransport    -- flutter_ble_central (rescue laptop)
///
/// Transports move frames and report link states; they know nothing about
/// SOS, relaying or ACKs. All of that lives in MeshNode, so the same logic
/// runs on every device and is unit-tested with fake transports.
abstract class MeshTransport {
  LinkSide get side;

  ValueListenable<TransportStatus> get status;

  /// Every link state change (including scan sightings on the central side).
  Stream<LinkInfo> get links;

  Stream<InboundFrame> get frames;

  /// Requests permissions, checks the adapter, starts advertising (peripheral)
  /// or scanning (central). Returns true when active; otherwise [status]
  /// says why. Idempotent.
  Future<bool> start();

  Future<void> stop();

  /// Sends ONE frame (<= the link's payloadSize). Completes true only when
  /// the platform confirmed it (write response / notification sent);
  /// false on any failure or timeout. Never throws.
  Future<bool> send(String linkId, MeshChannel channel, Uint8List frame);

  /// Central side: connect to a discovered device. No-op on the peripheral side.
  Future<void> connect(String linkId);

  /// Disconnects one link. Never throws.
  Future<void> disconnect(String linkId);

  /// Peripheral side: the CONTROL characteristic's value. No-op elsewhere.
  Future<void> setControlValue(Uint8List value);
}
