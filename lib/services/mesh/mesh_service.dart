import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/audit_event.dart';
import '../../state/audit_log_state.dart';
import '../affected_identity_service.dart';
import '../rescue_identity_service.dart';
import 'mesh_node.dart';

/// Owns the app's MeshNode (one per role) and records its important events
/// in the tamper-evident audit chain.
class MeshService {
  MeshService._();
  static final MeshService instance = MeshService._();

  MeshNode? _affected;
  MeshNode? _rescue;
  AuditLogState? _audit;
  final Map<MeshNode, StreamSubscription<MeshEvent>> _auditSubs = {};

  /// Affected-person phone node (Android).
  Future<MeshNode> affectedNode() async {
    final node = _affected ??= MeshNode(
      role: MeshRole.affected,
      storePrefix: 'mesh_affected',
      identity: () async => MeshIdentity(
        deviceId: await AffectedIdentityService.getOrCreateId(),
        deviceName: await AffectedIdentityService.getDisplayName(),
      ),
    );
    await node.init();
    _bind(node);
    return node;
  }

  /// Rescue Team console node (Windows).
  Future<MeshNode> rescueNode() async {
    final node = _rescue ??= MeshNode(
      role: MeshRole.rescue,
      storePrefix: 'mesh_rescue',
      identity: () async => MeshIdentity(
        deviceId: await RescueIdentityService.getOrCreateId(),
        deviceName: RescueIdentityService.displayName,
      ),
    );
    await node.init();
    _bind(node);
    return node;
  }

  MeshNode? get currentAffected => _affected;
  MeshNode? get currentRescue => _rescue;

  /// Disposes the nodes (their retry timers live as long as the app).
  @visibleForTesting
  Future<void> resetForTesting() async {
    for (final sub in _auditSubs.values) {
      await sub.cancel();
    }
    _auditSubs.clear();
    await _affected?.dispose();
    await _rescue?.dispose();
    _affected = null;
    _rescue = null;
    _audit = null;
  }

  void bindAudit(AuditLogState audit) {
    _audit = audit;
    for (final node in [_affected, _rescue]) {
      if (node != null) _bind(node);
    }
  }

  void _bind(MeshNode node) {
    if (_audit == null || _auditSubs.containsKey(node)) return;
    _auditSubs[node] = node.events.listen((event) => _record(node, event));
  }

  void _record(MeshNode node, MeshEvent event) {
    final type = _auditTypeFor(event);
    if (type == null) return;
    final at = event.at ?? DateTime.now();
    _audit?.addEvent(AuditEvent(
      id: '${event.packetId ?? 'mesh'}_${event.type.name}_${at.microsecondsSinceEpoch}',
      type: type,
      actorId: node.identity.deviceId,
      timestamp: at,
      details: event.packetId == null
          ? event.detail
          : 'SOS ${event.packetId}: ${event.detail}',
    ));
  }

  /// Only facts worth a tamper-evident record; link churn and retries stay
  /// in the network log.
  static AuditEventType? _auditTypeFor(MeshEvent event) {
    switch (event.type) {
      case MeshEventType.sosCreated:
        return AuditEventType.sosCreated;
      case MeshEventType.sosQueued:
        return AuditEventType.sosQueued;
      case MeshEventType.sosSent:
        return AuditEventType.sosTransmitted;
      case MeshEventType.rescueAckReceived:
      case MeshEventType.statusReceived:
        return AuditEventType.sosAcknowledged;
      case MeshEventType.relayReceived:
      case MeshEventType.relayNotForwarded:
        return AuditEventType.relayReceived;
      case MeshEventType.relayForwarded:
        return event.detail.startsWith('Forwarded') ? AuditEventType.relayForwarded : null;
      case MeshEventType.ackForwarded:
        return AuditEventType.ackForwarded;
      case MeshEventType.statusForwarded:
        return AuditEventType.statusForwarded;
      case MeshEventType.rescueReceived:
        return AuditEventType.sosReceived;
      case MeshEventType.rescueAckSent:
        return event.detail.startsWith('ACK delivered') ? AuditEventType.rescueAckSent : null;
      case MeshEventType.statusSent:
        return AuditEventType.statusSent;
      case MeshEventType.packetRejected:
        return AuditEventType.packetRejected;
      case MeshEventType.hopAckReceived:
      case MeshEventType.relayDuplicate:
      case MeshEventType.rescueDuplicate:
      case MeshEventType.linkReady:
      case MeshEventType.linkLost:
      case MeshEventType.storageError:
        return null;
    }
  }
}
