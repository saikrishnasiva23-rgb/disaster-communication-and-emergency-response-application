import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/emergency_message.dart';
import '../models/sos_packet.dart';
import 'ble_protocol.dart';
import 'mesh/android_peripheral_transport.dart';
import 'mesh/mesh_link.dart';
import 'mesh/mesh_node.dart';
import 'mesh/mesh_service.dart';
import 'relay_service.dart';

/// What the phone's BLE link is actually doing -- each value is driven by a
/// real platform result/event, never assumed.
enum AffectedLinkPhase {
  stopped,
  starting,
  unsupported,
  permissionDenied,
  bluetoothOff,
  advertiseFailed,

  /// On air; no device connected yet.
  advertising,

  /// A device has opened a GATT link but has not finished setting up.
  linked,

  /// At least one device that accepts SOS (Rescue Team laptop or a relay
  /// phone) is connected, subscribed and has introduced itself.
  gattReady,

  /// Kept for compatibility (heartbeat-based detection is no longer
  /// needed: the native GATT server reports every disconnect).
  stale,
}

/// One device this phone is linked with (distinct by app-level node id; a
/// device linked in both directions appears once).
@immutable
class MeshPeerSummary {
  const MeshPeerSummary({
    required this.id,
    required this.name,
    required this.role,
    required this.outgoing,
    required this.incoming,
  });

  final String id;
  final String name;

  /// 'rescue' / 'relay' / 'affected' (a phone with relay forwarding off).
  final String role;

  /// This phone opened a link to it (GATT client) / it opened one to us.
  final bool outgoing;
  final bool incoming;

  bool get isRescue => role == BleProtocol.roleRescue;
  bool get isRelay => role == BleProtocol.roleRelay;

  String get key => '$id|$role|$outgoing|$incoming|$name';
}

@immutable
class AffectedLinkStatus {
  const AffectedLinkStatus({
    required this.phase,
    this.detail,
    this.peerRole,
    this.peerName,
    this.rescueLinks = 0,
    this.relayLinks = 0,
    this.otherLinks = 0,
    this.peers = const [],
    this.scanning = false,
    this.scanDetail,
    this.relayForwarding = false,
  });

  /// Every identified device (phones and Rescue Team), at most one entry
  /// per device.
  final List<MeshPeerSummary> peers;

  /// The central role (scanning for other mesh phones) is running.
  final bool scanning;

  /// Why scanning is not running, if it failed.
  final String? scanDetail;

  /// This phone forwards other phones' SOS (RELAY on).
  final bool relayForwarding;

  int get phonePeers => peers.where((p) => !p.isRescue).length;

  final AffectedLinkPhase phase;

  /// Human-readable reason for a failure phase.
  final String? detail;

  /// Best connected peer: 'rescue' if a Rescue Team laptop is linked, else
  /// 'relay', else 'affected'.
  final String? peerRole;
  final String? peerName;

  final int rescueLinks;
  final int relayLinks;
  final int otherLinks;

  bool get isAdvertising =>
      phase == AffectedLinkPhase.advertising ||
      phase == AffectedLinkPhase.linked ||
      phase == AffectedLinkPhase.gattReady ||
      phase == AffectedLinkPhase.stale;

  bool get isGattReady => phase == AffectedLinkPhase.gattReady;

  bool get isRescueTeamConfirmed => isGattReady && rescueLinks > 0;

  bool get isFailure =>
      phase == AffectedLinkPhase.unsupported ||
      phase == AffectedLinkPhase.permissionDenied ||
      phase == AffectedLinkPhase.bluetoothOff ||
      phase == AffectedLinkPhase.advertiseFailed;

  String get _peersKey => peers.map((p) => p.key).join(';');

  @override
  bool operator ==(Object other) =>
      other is AffectedLinkStatus &&
      other.phase == phase &&
      other.detail == detail &&
      other.peerRole == peerRole &&
      other.peerName == peerName &&
      other.rescueLinks == rescueLinks &&
      other.relayLinks == relayLinks &&
      other.otherLinks == otherLinks &&
      other.scanning == scanning &&
      other.scanDetail == scanDetail &&
      other.relayForwarding == relayForwarding &&
      other._peersKey == _peersKey;

  @override
  int get hashCode => Object.hash(phase, detail, peerRole, peerName, rescueLinks,
      relayLinks, otherLinks, scanning, scanDetail, relayForwarding, _peersKey);
}

/// The affected phone's BLE presence: the native GATT server + advertiser
/// (AndroidPeripheralTransport) attached to the shared MeshNode.
///
/// Every phone is BOTH roles at once: this peripheral (advertise + accept
/// connections) and RelayService's central (scan + connect), so phones
/// link with each other and with the Rescue Team laptop in whatever
/// topology the radios allow (max four phones per mesh). RELAY forwarding
/// (default on) decides whether it also carries other phones' packets.
///
/// Advertisement = flags + the 128-bit service UUID (21 of 31 bytes; no
/// device name -- that caused ADVERTISE_FAILED_DATA_TOO_LARGE on the OPPO).
/// The 6-byte capability record rides in the scan response.
class AffectedPeripheralService {
  AffectedPeripheralService._();

  static final AffectedPeripheralService instance =
      AffectedPeripheralService._();

  AndroidPeripheralTransport? _transport;
  MeshNode? _node;
  Future<bool>? _starting;
  VoidCallback? _detachListeners;

  final ValueNotifier<AffectedLinkStatus> status = ValueNotifier(
    const AffectedLinkStatus(phase: AffectedLinkPhase.stopped),
  );

  bool get isAdvertising => status.value.isAdvertising;

  /// True while at least one device that accepts SOS is identified.
  bool get isReady => status.value.isGattReady;

  MeshNode? get node => _node;

  /// Starts the phone as a full mesh node: advertising + GATT server
  /// (peripheral) AND scanning + connecting (central). Idempotent.
  Future<bool> start() {
    final transport = _transport;
    if (transport != null && transport.status.value.isActive) {
      return Future.value(true);
    }
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    status.value = const AffectedLinkStatus(phase: AffectedLinkPhase.starting);
    final node = _node = await MeshService.instance.affectedNode();
    final transport = _transport ??= AndroidPeripheralTransport(
      manufacturerData: () => MeshAdvertisement(
        protocolVersion: SosPacket.currentProtocolVersion,
        relayCapable: true,
        idTag: MeshAdvertisement.tagFor(node.identity.deviceId),
      ).encode(),
    );
    node.attach(transport);
    _listen(node, transport);
    // Permissions are requested here first (advertise + connect + scan), so
    // the central role below starts with them in place.
    final ok = await transport.start();
    // Every phone also scans for and connects to the other mesh phones --
    // even when advertising failed, it can still reach a relay itself.
    final scanning = await RelayService.instance.startCentral();
    final scanStatus = RelayService.instance.transportStatus;
    if (scanStatus != null && _scanStatus != scanStatus) {
      _scanStatus?.removeListener(_recompute);
      _scanStatus = scanStatus..addListener(_recompute);
    }
    _recompute();
    return ok || scanning;
  }

  ValueListenable<TransportStatus>? _scanStatus;

  void _listen(MeshNode node, AndroidPeripheralTransport transport) {
    if (_detachListeners != null) return;
    transport.status.addListener(_recompute);
    node.links.addListener(_recompute);
    _detachListeners = () {
      transport.status.removeListener(_recompute);
      node.links.removeListener(_recompute);
    };
  }

  void _recompute() {
    final transport = _transport;
    final node = _node;
    if (transport == null || node == null) return;
    final ts = transport.status.value;

    AffectedLinkPhase phase;
    switch (ts.availability) {
      case TransportAvailability.stopped:
        phase = AffectedLinkPhase.stopped;
      case TransportAvailability.starting:
        phase = AffectedLinkPhase.starting;
      case TransportAvailability.unsupported:
        phase = AffectedLinkPhase.unsupported;
      case TransportAvailability.permissionDenied:
        phase = AffectedLinkPhase.permissionDenied;
      case TransportAvailability.bluetoothOff:
        phase = AffectedLinkPhase.bluetoothOff;
      case TransportAvailability.failed:
        phase = AffectedLinkPhase.advertiseFailed;
      case TransportAvailability.active:
        phase = AffectedLinkPhase.advertising;
    }

    final views = node.links.value;
    // One entry per device, however many links (directions) it has.
    final byId = <String, MeshPeerSummary>{};
    for (final v in views.where((v) => v.isIdentified)) {
      final peer = v.peer!;
      final prev = byId[peer.id];
      byId[peer.id] = MeshPeerSummary(
        id: peer.id,
        name: peer.name,
        role: peer.role,
        outgoing: (prev?.outgoing ?? false) || v.isOutgoing,
        incoming: (prev?.incoming ?? false) || !v.isOutgoing,
      );
    }
    final peers = byId.values.toList()
      ..sort((a, b) => a.isRescue == b.isRescue
          ? a.name.compareTo(b.name)
          : (a.isRescue ? -1 : 1));
    final rescue = peers.where((p) => p.isRescue).toList();
    final relays = peers.where((p) => p.isRelay).toList();
    final others = peers.length - rescue.length - relays.length;

    // A phone that is only scanning (advertising failed) is still a mesh
    // node once it has an identified link.
    if (phase == AffectedLinkPhase.advertising || peers.isNotEmpty) {
      if (rescue.isNotEmpty || relays.isNotEmpty) {
        phase = AffectedLinkPhase.gattReady;
      } else if (views.any((v) => v.state.isConnectedish)) {
        phase = AffectedLinkPhase.linked;
      }
    }

    final best = rescue.isNotEmpty ? rescue.first : (relays.isNotEmpty ? relays.first : null);
    final scan = _scanStatus?.value;
    status.value = AffectedLinkStatus(
      phase: phase,
      detail: ts.isFailure ? ts.detail : null,
      peerRole: best?.role,
      peerName: best?.name,
      rescueLinks: rescue.length,
      relayLinks: relays.length,
      otherLinks: others,
      peers: peers,
      scanning: scan?.isActive ?? false,
      scanDetail: scan != null && scan.isFailure ? scan.detail : RelayService.instance.lastError,
      relayForwarding: node.relayEnabled,
    );
  }

  /// Affected phone -> Rescue Team message over a direct link.
  Future<void> sendMessage(EmergencyMessage message) async {
    final node = _node;
    if (node == null || status.value.rescueLinks == 0) {
      throw StateError('No Rescue Team device is connected yet.');
    }
    final json = jsonDecode(message.toWireBytes()) as Map<String, dynamic>;
    final ok = await node.sendMessage(json);
    if (!ok) throw StateError('The message could not be delivered over Bluetooth.');
  }

  /// Stops advertising and scanning and drops every link. The outbox and
  /// relay store stay on disk and resume on the next start().
  Future<void> stop() async {
    final transport = _transport;
    if (transport == null) return;
    await RelayService.instance.stopCentral();
    await transport.stop();
    _recompute();
  }

  /// Re-reads node state (e.g. after RELAY forwarding was switched).
  void refresh() => _recompute();
}
