import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import '../models/sos_packet.dart';
import '../state/audit_log_state.dart';
import '../state/ble_state.dart';
import '../state/emergency_state.dart';
import 'affected_identity_service.dart';
import 'ai_priority_service.dart';
import 'ble_central_service.dart';
import 'ble_protocol.dart';
import 'mesh/mesh_node.dart';
import 'mesh/mesh_service.dart';
import 'net_log.dart';

/// Phases of the latest SOS on this phone, mirroring its [SosStatus].
enum SosRequestPhase {
  idle,
  locating,

  /// Saved in the outbox; no Bluetooth link yet -- sent automatically when
  /// one becomes ready.
  queued,

  /// Transmitted to the next device; not confirmed yet.
  sentToRelay,

  /// A relay phone has it (hop ACK). NOT the Rescue Team's confirmation.
  relayed,

  /// The Rescue Team's authenticated end-to-end ACK arrived.
  receivedByRescue,

  /// A rescuer acted on it (STATUS routed back).
  acknowledged,
  failed,
}

@immutable
class SosRequestState {
  const SosRequestState({
    required this.phase,
    this.packetId,
    this.headline = '',
    this.detail,
    this.locationNote,
    this.priority,
    this.rescueUpdate,
    this.backendNote,
    this.updatedAt,
    this.attempts = 0,
  });

  const SosRequestState.idle() : this(phase: SosRequestPhase.idle);

  final SosRequestPhase phase;
  final String? packetId;
  final String headline;
  final String? detail;
  final String? locationNote;
  final String? priority;

  /// Latest rescue-workflow update the Rescue Team sent back (STATUS).
  final String? rescueUpdate;
  final String? backendNote;
  final DateTime? updatedAt;

  /// Bluetooth transmissions of this SOS so far (retries included).
  final int attempts;

  bool get isBusy => phase == SosRequestPhase.locating;

  SosRequestState copyWith({
    SosRequestPhase? phase,
    String? headline,
    String? detail,
    String? rescueUpdate,
    String? backendNote,
    int? attempts,
  }) =>
      SosRequestState(
        phase: phase ?? this.phase,
        packetId: packetId,
        headline: headline ?? this.headline,
        detail: detail ?? this.detail,
        locationNote: locationNote,
        priority: priority,
        rescueUpdate: rescueUpdate ?? this.rescueUpdate,
        backendNote: backendNote ?? this.backendNote,
        updatedAt: DateTime.now(),
        attempts: attempts ?? this.attempts,
      );
}

class _Fix {
  const _Fix(this.position, this.note);
  final Position? position;
  final String? note;
}

/// The phone's SOS flow:
///   GPS (optional, real) -> signed packet -> persistent outbox in MeshNode
///   -> sent to the Rescue Team laptop or a relay phone over BLE, retried
///   until the Rescue Team's authenticated ACK travels back.
///
/// Nothing is reported as received by the Rescue Team unless that
/// end-to-end ACK arrived; a relay's hop ACK is shown as "received by a
/// relay phone" only.
class SosService {
  SosService._();
  static final SosService instance = SosService._();

  /// The origin keeps the user-typed text within this (it is signed, so it
  /// must never be shortened later on the wire).
  static const int maxMessageLength = 500;

  final ValueNotifier<SosRequestState> current =
      ValueNotifier(const SosRequestState.idle());

  StreamSubscription<OutboxEntry>? _outboxSubscription;
  EmergencyState? _emergencyState;
  MeshNode? _node;
  final Map<String, String> _locationNotes = {};
  int _sequence = 0;

  /// Restores this phone's own SOS history from the persistent outbox and
  /// starts following delivery updates. Safe to call repeatedly.
  Future<void> bind(EmergencyState emergencyState, {AuditLogState? auditLog}) async {
    _emergencyState = emergencyState;
    if (auditLog != null) MeshService.instance.bindAudit(auditLog);
    final node = _node ??= await MeshService.instance.affectedNode();
    _outboxSubscription ??= node.outboxChanges.listen(_onOutboxChange);

    final entries = node.outbox.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final e in entries) {
      if (emergencyState.sosById(e.packet.id) == null) emergencyState.addSos(e.packet);
      if (e.packet.sequence >= _sequence) _sequence = e.packet.sequence + 1;
    }
    if (current.value.phase == SosRequestPhase.idle && entries.isNotEmpty) {
      final latest = entries.last;
      if (DateTime.now().difference(latest.createdAt) < SosValidation.maxAge) {
        _onOutboxChange(latest);
      }
    }
  }

  Future<void> send({
    required EmergencyState emergencyState,
    required AuditLogState auditLog,
    BleState? bleState,
    required String message,
    required String emergencyType,
  }) async {
    if (current.value.isBusy) return;
    await bind(emergencyState, auditLog: auditLog);
    final node = _node!;

    current.value = const SosRequestState(
      phase: SosRequestPhase.locating,
      headline: 'Getting your location...',
    );

    final fix = await _locate();
    final senderId = await AffectedIdentityService.getOrCreateId();
    final deviceName = await AffectedIdentityService.getDisplayName();
    final position = fix.position;
    final text = message.trim();

    final packet = SosPacket(
      id: _newPacketId(senderId),
      senderId: senderId,
      senderDisplayName: deviceName,
      timestamp: DateTime.now().toUtc(),
      latitude: position?.latitude,
      longitude: position?.longitude,
      accuracyMeters: position?.accuracy,
      fixTime: position?.timestamp.toUtc(),
      message: text.length > maxMessageLength ? text.substring(0, maxMessageLength) : text,
      emergencyType: emergencyType,
      sequence: _sequence++,
      maxHops: BleProtocol.defaultMaxHops,
      ttl: BleProtocol.defaultMaxHops,
      protocolVersion: SosPacket.currentProtocolVersion,
    );
    // The sender's own local (rule-based) estimate; the Rescue Team runs
    // its classifier on receipt and shows its own result.
    packet.priority =
        AiPriorityService.classifyLocally(packet).level.name.toUpperCase();

    _locationNotes[packet.id] = packet.hasLocation
        ? (fix.note ??
            'Location included${packet.accuracyMeters != null ? ' (±${packet.accuracyMeters!.round()} m)' : ''}')
        : 'Location unavailable -- ${fix.note ?? 'no GPS fix'}. SOS sent '
            'without coordinates.';

    final entry = await node.originate(packet);
    if (emergencyState.sosById(entry.packet.id) == null) {
      emergencyState.addSos(entry.packet);
    }
    _onOutboxChange(entry);

    if (bleState?.connectedDevice != null) {
      unawaited(_sendViaLegacyAndroidRescue(entry.packet, bleState!));
    }
    unawaited(_tryBackend(entry.packet));
  }

  void _onOutboxChange(OutboxEntry entry) {
    final state = _emergencyState;
    // The outbox entry's packet is the same object as the history entry,
    // so its status may already be applied: still refresh listeners.
    if (state != null && !state.updateSosStatus(entry.packet.id, entry.status)) {
      state.notifySosChanged();
    }

    final latest = current.value.packetId;
    // Follow the newest SOS; older ones still update their history entry.
    if (latest != null &&
        latest != entry.packet.id &&
        current.value.phase != SosRequestPhase.idle) {
      final currentEntry = _node?.outboxEntry(latest);
      if (currentEntry != null && currentEntry.createdAt.isAfter(entry.createdAt)) return;
    }

    final (phase, headline, fallback) = switch (entry.status) {
      SosStatus.created || SosStatus.queued => (
          SosRequestPhase.queued,
          'SOS SAVED -- WAITING FOR A BLUETOOTH LINK',
          'No Rescue Team laptop or relay phone is connected yet. Your SOS '
              'is saved on this phone and will be sent automatically the '
              'moment one connects. Keep this screen open.',
        ),
      SosStatus.sentToRelay => (
          SosRequestPhase.sentToRelay,
          'SOS SENT',
          'Waiting for the next device to confirm it...',
        ),
      SosStatus.relayed => (
          SosRequestPhase.relayed,
          'RECEIVED BY A RELAY PHONE',
          'A nearby phone has your SOS and will forward it to the Rescue '
              'Team. This is not yet the Rescue Team\'s confirmation.',
        ),
      SosStatus.receivedByRescue => (
          SosRequestPhase.receivedByRescue,
          'RECEIVED BY THE RESCUE TEAM',
          'The Rescue Team confirmed receipt.',
        ),
      SosStatus.acknowledged => (
          SosRequestPhase.acknowledged,
          'RESCUE TEAM ACKNOWLEDGED',
          'The Rescue Team is acting on your SOS.',
        ),
      SosStatus.failed => (
          SosRequestPhase.failed,
          'SOS NOT DELIVERED',
          'It could not be delivered over Bluetooth.',
        ),
    };

    var detail = entry.detail ?? fallback;
    if (entry.status == SosStatus.receivedByRescue) {
      detail = 'The Rescue Team confirmed receipt at '
          '${_clock(entry.updatedAt ?? DateTime.now())}'
          '${entry.custodyBy.isNotEmpty ? ' (delivered through a relay phone)' : ''}.';
    } else if (entry.status == SosStatus.relayed && entry.nextHopName != null) {
      detail = 'Relay phone ${entry.nextHopName} has your SOS and will forward '
          'it to the Rescue Team. This is not yet the Rescue Team\'s '
          'confirmation.';
    } else if (entry.status == SosStatus.queued) {
      detail = fallback;
    }

    current.value = SosRequestState(
      phase: phase,
      packetId: entry.packet.id,
      headline: headline,
      detail: detail,
      locationNote: _locationNotes[entry.packet.id] ??
          (entry.packet.hasLocation ? 'Location included' : 'Location unavailable'),
      priority: entry.packet.priority,
      rescueUpdate: entry.rescueStatus != null
          ? 'Rescue Team update: ${entry.rescueStatus!.replaceAll('_', ' ')}'
          : null,
      backendNote:
          current.value.packetId == entry.packet.id ? current.value.backendNote : null,
      updatedAt: entry.updatedAt ?? DateTime.now(),
      attempts: entry.attemptCount,
    );
  }

  /// Legacy secondary path: an Android phone running the old Rescue screen,
  /// connected from NearbyDevicesScreen. Reported as a note only; it never
  /// changes the mesh delivery state.
  Future<void> _sendViaLegacyAndroidRescue(SosPacket packet, BleState bleState) async {
    String note;
    try {
      final ack = BleCentralService.instance.onAckReceived
          .firstWhere((a) => a['id'] == packet.id)
          .timeout(const Duration(seconds: 15));
      await BleCentralService.instance.sendBytes(utf8.encode(packet.toWireBytes()));
      try {
        await ack;
        note = 'Also acknowledged by '
            '${bleState.connectedDevice?.name ?? 'the Android rescue phone'} (legacy link).';
      } on TimeoutException {
        note = 'Also sent to the Android rescue phone (legacy link); no ACK from it.';
      }
    } catch (_) {
      note = 'Legacy Android rescue link failed.';
    }
    if (current.value.packetId == packet.id) {
      current.value = current.value.copyWith(backendNote: note);
    }
  }

  /// Secondary channel when this phone has internet: never blocking and
  /// never changing the Bluetooth delivery state. Sends the packet id, so
  /// the server de-duplicates it against the laptop's later cloud sync.
  Future<void> _tryBackend(SosPacket packet) async {
    String note;
    try {
      final transport = packet.toTransportJson();
      final response = await http
          .post(
            Uri.parse(BackendConfig.rescueRequestEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              ...packet.toBackendJson(),
              // Same rounding as the BLE packet the laptop syncs, so the
              // server sees both copies as one emergency.
              'latitude': transport['latitude'],
              'longitude': transport['longitude'],
              'clientEmergencyId': packet.id,
              'occurredAt': packet.timestamp.toUtc().toIso8601String(),
              'originDeviceId': packet.senderId,
              'accuracy': ?packet.accuracyMeters,
            }),
          )
          .timeout(const Duration(seconds: 6));
      final decoded = response.statusCode == 200 ? jsonDecode(response.body) : null;
      final ok = decoded is Map && decoded['success'] == true;
      note = ok
          ? 'Also delivered to the rescue server over the internet.'
          : 'Rescue server rejected the request (HTTP ${response.statusCode}).';
      NetLog.sync(ok
          ? 'SOS ${packet.id} also uploaded directly from this phone'
          : 'Direct upload of ${packet.id} rejected (${response.statusCode})');
    } catch (_) {
      note = 'Rescue server not reachable -- the Bluetooth path is unaffected.';
    }

    if (current.value.packetId == packet.id) {
      current.value = current.value.copyWith(backendNote: note);
    }
  }

  Future<_Fix> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const _Fix(null, 'location services are off');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return const _Fix(null, 'location permission denied');
      }
      if (permission == LocationPermission.deniedForever) {
        return const _Fix(
            null, 'location permission permanently denied (enable in Settings)');
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );
        return _Fix(position, null);
      } on TimeoutException {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null &&
            DateTime.now().difference(last.timestamp) < const Duration(minutes: 10)) {
          return _Fix(last, 'Last known location (live GPS fix timed out)');
        }
        return const _Fix(null, 'GPS fix timed out');
      }
    } catch (e) {
      NetLog.sos('Location unavailable (${e.runtimeType})');
      return const _Fix(null, 'location unavailable');
    }
  }

  /// Unique across phones, not just across time.
  static String _newPacketId(String senderId) {
    final suffix =
        senderId.length > 6 ? senderId.substring(senderId.length - 6) : senderId;
    return '$suffix-${DateTime.now().microsecondsSinceEpoch}';
  }

  static String _clock(DateTime t) {
    final local = t.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour < 12 ? 'AM' : 'PM'}';
  }
}
