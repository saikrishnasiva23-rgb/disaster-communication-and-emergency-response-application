import 'dart:async';

import '../models/affected_device_connection.dart';
import '../models/emergency_message.dart';
import '../models/rescue_case.dart';
import '../models/sos_packet.dart';
import '../state/audit_log_state.dart';
import '../state/emergency_state.dart';
import 'ai_priority_service.dart';
import 'ble_protocol.dart';
import 'cloud_sync_service.dart';
import 'local_store.dart';
import 'mesh/mesh_link.dart';
import 'mesh/mesh_node.dart';
import 'mesh/mesh_service.dart';
import 'mesh/windows_central_transport.dart';
import 'net_log.dart';

/// An SOS as it physically arrived: the packet (original sender identity
/// intact, even if relayed) plus the BLE link it came in on.
class InboundSos {
  const InboundSos({
    required this.packet,
    required this.address,
    required this.linkName,
  });

  final SosPacket packet;

  /// BLE address of the link it arrived on (diagnostics only).
  final String address;

  /// Human-readable name of that link's device (origin or last relay).
  final String linkName;
}

class AckResult {
  const AckResult({required this.packetId, required this.delivered, this.error});

  final String packetId;
  final bool delivered;
  final String? error;
}

/// The Rescue Team's Windows console: the destination of the mesh.
///
/// It runs a rescue-role MeshNode over WindowsCentralTransport
/// (flutter_ble_central, WinRT). Every SOS -- direct or relayed -- is
/// stored in the node's persistent inbox BEFORE the end-to-end ACK is sent,
/// turned into a RescueCase here (not in a screen, so nothing is lost when
/// no screen is open), and queued for cloud sync. Rescue STATUS updates are
/// routed back along the path the SOS took (relays included).
class WindowsBleCentralService {
  WindowsBleCentralService._();
  static final WindowsBleCentralService instance = WindowsBleCentralService._();

  static const String _caseStateDocument = 'rescue_case_state';

  WindowsCentralTransport? _transport;
  MeshNode? _node;
  EmergencyState? _emergencyState;
  Future<void>? _binding;
  final FallbackDeviceNamer _namer = FallbackDeviceNamer();

  StreamSubscription<RescueDelivery>? _deliverySub;
  StreamSubscription<Map<String, dynamic>>? _messageSub;
  Timer? _ackWatch;

  /// Per-link SOS counters (by BLE address) for the device list.
  final Map<String, ({int count, String lastId, DateTime at, double? lat, double? lon})>
      _linkSos = {};

  /// Persisted per-case console state: workflow status + ACK delivery.
  final Map<String, Map<String, dynamic>> _caseState = {};

  final StreamController<List<AffectedDeviceConnection>> _devicesController =
      StreamController<List<AffectedDeviceConnection>>.broadcast();
  final StreamController<InboundSos> _sosController =
      StreamController<InboundSos>.broadcast();
  final StreamController<EmergencyMessage> _messageController =
      StreamController<EmergencyMessage>.broadcast();
  final StreamController<AckResult> _ackController =
      StreamController<AckResult>.broadcast();

  List<AffectedDeviceConnection> _currentDevices = const [];

  Stream<List<AffectedDeviceConnection>> get devices => _devicesController.stream;
  List<AffectedDeviceConnection> get currentDevices => _currentDevices;

  /// New SOS (already stored and turned into a case).
  Stream<InboundSos> get onSosReceived => _sosController.stream;
  Stream<EmergencyMessage> get onMessageReceived => _messageController.stream;

  /// Whether each SOS's end-to-end ACK reached the next device.
  Stream<AckResult> get onAckResult => _ackController.stream;

  bool get isScanning => _transport?.status.value.isActive ?? false;

  String? _lastScanError;
  String? get lastScanError => _lastScanError;

  MeshNode? get node => _node;

  /// Connects the console to app state: restores stored cases and starts
  /// turning deliveries into cases. Call once at startup (Windows).
  Future<void> bind(EmergencyState emergencyState, AuditLogState auditLog) {
    _emergencyState = emergencyState;
    MeshService.instance.bindAudit(auditLog);
    return _binding ??= _bind(emergencyState);
  }

  Future<void> _bind(EmergencyState emergencyState) async {
    final node = _node = await MeshService.instance.rescueNode();
    final saved = await LocalStore.read(_caseStateDocument);
    final cases = saved?['cases'];
    if (cases is Map) {
      for (final e in cases.entries) {
        if (e.key is String && e.value is Map<String, dynamic>) {
          _caseState[e.key as String] = e.value as Map<String, dynamic>;
        }
      }
    }

    // Restore every stored SOS as a case (oldest first so newest ends on top).
    final inbox = node.inbox.toList()..sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    for (final entry in inbox) {
      if (!emergencyState.hasRescueCase(entry.packet.id)) {
        emergencyState.upsertRescueCase(_caseFor(entry, entry.firstLinkName, null));
      }
    }
    if (inbox.isNotEmpty) NetLog.rescue('Restored ${inbox.length} stored SOS case(s)');

    _deliverySub ??= node.rescueDeliveries.listen(_onDelivery);
    _messageSub ??= node.messages.listen(_onMessage);
    node.links.addListener(_publishDevices);
    _ackWatch ??= Timer.periodic(const Duration(seconds: 2), (_) => _refreshAckStates());

    final cloud = CloudSyncService.instance;
    cloud.setDeviceId(node.identity.deviceId);
    await cloud.init();
  }

  RescueCase _caseFor(InboxEntry entry, String? linkName, String? address) {
    final packet = entry.packet;
    final state = _caseState[packet.id];
    final rescueCase = RescueCase.fromSosPacket(
      packet,
      sourceDeviceName: linkName,
      sourceAddress: address,
      receivedAt: entry.receivedAt,
      authenticated: entry.authenticated,
    )..aiPriority = AiPriorityService.classifyLocally(packet);
    rescueCase.status = rescueStatusFromString(state?['status'] as String? ?? 'pending');
    rescueCase.ackDelivery = entry.ackDelivered ? AckDelivery.sent : AckDelivery.sending;
    return rescueCase;
  }

  void _onDelivery(RescueDelivery delivery) {
    final state = _emergencyState;
    final entry = delivery.entry;
    final address = _addressOf(delivery.linkId);

    final previous = _linkSos[address];
    if (!delivery.isDuplicate) {
      final direct = entry.packet.hopCount == 0;
      _linkSos[address] = (
        count: (previous?.count ?? 0) + 1,
        lastId: entry.packet.id,
        at: DateTime.now(),
        // Only a DIRECT packet describes the phone on this link.
        lat: direct ? entry.packet.latitude : previous?.lat,
        lon: direct ? entry.packet.longitude : previous?.lon,
      );
    }

    if (state != null && !state.hasRescueCase(entry.packet.id)) {
      state.upsertRescueCase(_caseFor(entry, delivery.linkName, address));
    }
    if (!delivery.isDuplicate) {
      _sosController.add(InboundSos(
        packet: entry.packet,
        address: address,
        linkName: delivery.linkName,
      ));
      unawaited(CloudSyncService.instance.enqueueEmergency(_cloudRecord(entry)));
    }
    _publishDevices();
  }

  void _onMessage(Map<String, dynamic> json) {
    try {
      _messageController.add(EmergencyMessage.fromJson(json, fromLocalUser: false));
    } catch (_) {}
  }

  /// Tracks the end-to-end ACK delivery of every case (including retries
  /// MeshNode makes after a link comes back).
  void _refreshAckStates() {
    final node = _node;
    final state = _emergencyState;
    if (node == null || state == null) return;
    for (final entry in node.inbox) {
      final delivered = entry.ackDelivered;
      final index = state.rescueCases.indexWhere((c) => c.id == entry.packet.id);
      if (index == -1) continue;
      final current = state.rescueCases[index].ackDelivery;
      final next = delivered ? AckDelivery.sent : AckDelivery.sending;
      if (current != next && current != AckDelivery.sent) {
        state.updateAckDelivery(entry.packet.id, next);
        _ackController.add(AckResult(packetId: entry.packet.id, delivered: delivered));
        if (delivered) {
          // Re-queue so the cloud record carries local_ble_acknowledged.
          unawaited(CloudSyncService.instance.enqueueEmergency(_cloudRecord(entry)));
        }
      }
    }
  }

  CloudEmergencyRecord _cloudRecord(InboxEntry entry) {
    final p = entry.packet;
    return CloudEmergencyRecord(
      clientEmergencyId: p.id,
      emergencyType: p.emergencyType,
      description: p.message,
      peopleCount: p.numberOfPeople,
      injured: p.injured,
      trapped: p.emergencyType.toLowerCase().contains('trapped'),
      occurredAt: p.timestamp,
      latitude: p.latitude,
      longitude: p.longitude,
      accuracyMeters: p.accuracyMeters,
      fixTime: p.fixTime,
      originDeviceId: p.senderId,
      senderDisplayName: p.displayName,
      relayedByDeviceId: p.relayedBy,
      relayedByName: p.relayedByName,
      hopCount: p.hopCount,
      clientPriority: const {'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'}.contains(p.priority)
          ? p.priority
          : null,
      localBleAcknowledged: entry.ackDelivered,
      localBleAcknowledgedAt: entry.ackDelivered ? entry.receivedAt : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Scanning / connections
  // ---------------------------------------------------------------------------

  /// Starts (or restarts) scanning. Returns null on success, otherwise the
  /// failure state; [lastScanError] says why.
  Future<AffectedConnectionState?> startScan() async {
    _lastScanError = null;
    if (_node == null) {
      final state = _emergencyState;
      if (state == null) {
        _lastScanError = 'Console not initialised.';
        return AffectedConnectionState.connectionFailed;
      }
      await _binding;
    }
    final node = _node!;
    final transport = _transport ??= WindowsCentralTransport();
    node.attach(transport);
    transport.status.addListener(_publishDevices);
    final ok = await transport.start();
    if (ok) return null;
    final status = transport.status.value;
    _lastScanError = status.detail ?? 'Bluetooth scanning could not start.';
    return switch (status.availability) {
      TransportAvailability.permissionDenied => AffectedConnectionState.permissionError,
      TransportAvailability.unsupported ||
      TransportAvailability.bluetoothOff =>
        AffectedConnectionState.bluetoothDisabled,
      _ => AffectedConnectionState.connectionFailed,
    };
  }

  /// Kept for API compatibility. The console keeps its links and keeps
  /// storing incoming SOS even with no screen open (nothing is ACKed that
  /// is not stored), so leaving the screen does not stop Bluetooth.
  Future<void> stopScan() async {}

  /// Fully stops Bluetooth (app shutdown).
  Future<void> shutdown() async {
    await _transport?.stop();
  }

  Future<void> connect(String address) async =>
      _node?.connect(LinkInfo.idFor(LinkSide.central, address));

  /// Operator disconnect: the device is not auto-reconnected until the
  /// operator presses Connect again (used to force the relay path in tests).
  Future<void> disconnect(String address) async =>
      _node?.disconnect(LinkInfo.idFor(LinkSide.central, address), block: true);

  bool get autoConnect => _node?.autoConnect ?? true;
  set autoConnect(bool value) {
    _node?.autoConnect = value;
  }

  /// Rescue workflow status -> routed back to the SOS's origin phone (also
  /// through relays) and queued for cloud sync. [address] is ignored (kept
  /// for compatibility): routing is by packet, along its arrival path.
  Future<bool> sendStatusUpdate(String address, String packetId, String status) async {
    final normalized = status.trim().toUpperCase().replaceAll(' ', '_');
    _caseState[packetId] = {
      'status': switch (normalized) {
        'ASSIGNED' => 'assigned',
        'IN_PROGRESS' => 'in_progress',
        'RESCUED' => 'rescued',
        _ => 'pending',
      },
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await LocalStore.write(_caseStateDocument, {'cases': _caseState});
    unawaited(CloudSyncService.instance.enqueueStatus(CloudStatusUpdate(
      updateId: '$packetId-$normalized',
      clientEmergencyId: packetId,
      consoleStatus: normalized,
      changedAt: DateTime.now().toUtc(),
    )));
    final node = _node;
    if (node == null) return false;
    final delivered = await node.sendStatus(packetId, normalized);
    NetLog.rescue('STATUS $normalized for $packetId '
        '${delivered ? 'sent toward the phone' : 'queued (no path to the phone yet)'}');
    return delivered;
  }

  // ---------------------------------------------------------------------------
  // Device list (UI)
  // ---------------------------------------------------------------------------

  static String _addressOf(String linkId) {
    final i = linkId.indexOf(':');
    return i == -1 ? linkId : linkId.substring(i + 1);
  }

  Timer? _publishDebounce;

  void _publishDevices() {
    if (_publishDebounce?.isActive ?? false) return;
    _publishDebounce = Timer(const Duration(milliseconds: 250), () {
      final node = _node;
      if (node == null) return;
      final transportOff = _transport?.status.value.availability == TransportAvailability.bluetoothOff;
      _currentDevices = [
        for (final view in node.links.value)
          if (view.info.side == LinkSide.central) _deviceFor(view, transportOff),
      ];
      if (!_devicesController.isClosed) _devicesController.add(_currentDevices);
    });
  }

  AffectedDeviceConnection _deviceFor(LinkView view, bool bluetoothOff) {
    final address = view.info.address;
    final sos = _linkSos[address];
    final state = switch (view.state) {
      LinkState.discovered => AffectedConnectionState.discovered,
      LinkState.connecting => AffectedConnectionState.connecting,
      LinkState.connected || LinkState.serviceDiscovery || LinkState.ready =>
        AffectedConnectionState.connected,
      LinkState.disconnecting || LinkState.disconnected =>
        bluetoothOff ? AffectedConnectionState.bluetoothDisabled : AffectedConnectionState.disconnected,
      LinkState.error => AffectedConnectionState.connectionFailed,
    };
    final name = view.peer?.name ??
        ((view.info.name?.trim().isNotEmpty ?? false) ? view.info.name!.trim() : _namer.nameFor(address));
    return AffectedDeviceConnection(
      address: address,
      displayName: name,
      nameConfirmed: view.peer != null,
      senderId: view.peer?.id,
      rssi: view.info.rssi,
      state: state,
      gattReady: view.isReady,
      lastError: view.blocked
          ? 'Disconnected by operator (press Connect to link again)'
          : view.info.error,
      connectedAt: view.readyAt,
      lastSeenAt: view.info.updatedAt,
      lastLatitude: sos?.lat,
      lastLongitude: sos?.lon,
      lastSosId: sos?.lastId,
      lastSosAt: sos?.at,
      sosCount: sos?.count ?? 0,
      linkState: view.state.label,
      peerRole: view.peer?.role,
      payloadSize: view.info.payloadSize,
      identified: view.isIdentified,
    );
  }

  Future<void> dispose() async {
    _ackWatch?.cancel();
    _publishDebounce?.cancel();
    await _deliverySub?.cancel();
    await _messageSub?.cancel();
    await _transport?.stop();
    await _devicesController.close();
    await _sosController.close();
    await _messageController.close();
    await _ackController.close();
  }
}
