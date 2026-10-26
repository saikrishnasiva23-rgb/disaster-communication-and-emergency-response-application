import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/audit_event.dart';
import '../state/audit_log_state.dart';

/// TAMPER-EVIDENT BLOCKCHAIN-INSPIRED EVENT LOG -- a local SHA-256 hash
/// chain (see AuditLogState), not a decentralized blockchain network.
///
/// Fed by actual app actions (rescue authentication, SOS
/// created/transmitted/received, rescue assigned/started/completed).
/// Previously this screen had 3 hardcoded seed rows, a button that
/// inserted the same fake string regardless of what had actually
/// happened, and a "Verified" badge that was a hardcoded literal with no
/// hash behind it at all. The verification shown here now comes from
/// actually recomputing and checking the chain (AuditLogState.verifyChain).
class BlockchainLogScreen extends StatelessWidget {
  const BlockchainLogScreen({super.key});

  /// Confirmed bug: this button used to call simulateTamperingForDemo()
  /// directly with no confirmation step, on the single shared production
  /// AuditLogState instance the whole app writes real events into. A
  /// single accidental tap during an actual incident permanently
  /// corrupted the real tamper-evident record with no undo. Now requires
  /// an explicit, clearly-worded confirmation naming exactly what it does.
  Future<void> _confirmTamperDemo(
    BuildContext context,
    AuditLogState auditLog,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Simulate tampering?"),
        content: const Text(
          "This permanently corrupts the oldest entry in this device's "
          "REAL event log so the chain verification can be shown "
          "catching it. This is not reversible and is not a sandboxed "
          "copy -- it affects the actual log this session has recorded. "
          "Only do this as a deliberate demonstration.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Corrupt oldest entry"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      auditLog.simulateTamperingForDemo();
    }
  }

  String _label(AuditEventType type) {
    switch (type) {
      case AuditEventType.sosCreated:
        return "SOS Created";
      case AuditEventType.sosTransmitted:
        return "SOS Transmitted";
      case AuditEventType.sosReceived:
        return "SOS Received (BLE)";
      case AuditEventType.sosAcknowledged:
        return "SOS Acknowledged";
      case AuditEventType.messageSent:
        return "Message Sent";
      case AuditEventType.messageReceived:
        return "Message Received";
      case AuditEventType.locationShared:
        return "Location Shared";
      case AuditEventType.rescueAuthenticated:
        return "Rescue Team Authenticated";
      case AuditEventType.rescueAssigned:
        return "Rescue Assigned";
      case AuditEventType.rescueStarted:
        return "Rescue Started";
      case AuditEventType.rescueCompleted:
        return "Rescue Completed";
      case AuditEventType.sosQueued:
        return "SOS Queued (no link yet)";
      case AuditEventType.relayReceived:
        return "Relay Received SOS";
      case AuditEventType.relayForwarded:
        return "Relay Forwarded SOS";
      case AuditEventType.ackForwarded:
        return "Rescue ACK Forwarded";
      case AuditEventType.statusForwarded:
        return "Rescue Status Forwarded";
      case AuditEventType.rescueAckSent:
        return "Rescue ACK Sent";
      case AuditEventType.statusSent:
        return "Rescue Status Sent";
      case AuditEventType.packetRejected:
        return "Packet Rejected";
      case AuditEventType.cloudSynced:
        return "Cloud Synced";
    }
  }

  String _shortHash(String? hash) {
    if (hash == null) return "--";
    return "${hash.substring(0, 12)}...";
  }

  @override
  Widget build(BuildContext context) {
    final auditLog = context.watch<AuditLogState>();
    final events = auditLog.events;
    final chainIntact = auditLog.verifyChain();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Event Log"),
        actions: [
          if (auditLog.isTamperDemoActive)
            IconButton(
              tooltip: "Undo the tamper demo",
              icon: const Icon(Icons.restore),
              onPressed: auditLog.restoreAfterTamperDemo,
            ),
          IconButton(
            tooltip: "Simulate tampering (demo, in memory only)",
            icon: const Icon(Icons.warning_amber),
            onPressed: events.isEmpty
                ? null
                : () => _confirmTamperDemo(context, auditLog),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.blueGrey.shade50,
            padding: const EdgeInsets.all(12),
            child: const Text(
              "Tamper-evident, blockchain-inspired event log: each entry "
              "below is chained by a real SHA-256 hash and saved on this "
              "device. This is a local hash chain, not a distributed "
              "blockchain network.",
              style: TextStyle(fontSize: 12, color: Colors.blueGrey),
            ),
          ),
          Container(
            width: double.infinity,
            color: chainIntact ? Colors.green.shade100 : Colors.red.shade100,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  chainIntact ? Icons.verified : Icons.error,
                  color: chainIntact ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chainIntact
                        ? "Chain verified: all ${events.length} entries "
                            "intact."
                        : "TAMPERING DETECTED: the hash chain no longer "
                            "verifies.",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: chainIntact ? Colors.green.shade900 : Colors.red.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: events.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        "No events recorded yet. Events appear here as "
                        "real actions happen: authentication, SOS, and "
                        "rescue status changes.",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: events.length,
                    itemBuilder: (context, index) {
                      final event = events[index];

                      return Card(
                        margin: const EdgeInsets.all(10),
                        child: ListTile(
                          leading: Icon(
                            Icons.receipt_long,
                            color: chainIntact ? Colors.blueGrey : Colors.red,
                          ),
                          title: Text(_label(event.type)),
                          subtitle: Text(
                            "${event.details}\n"
                            "${event.actorId} -- ${event.timestamp.toLocal()}\n"
                            "hash: ${_shortHash(event.hash)}  prev: "
                            "${_shortHash(event.previousHash)}",
                          ),
                          isThreeLine: true,
                          trailing: Icon(
                            chainIntact ? Icons.link : Icons.link_off,
                            color: chainIntact ? Colors.green : Colors.red,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
