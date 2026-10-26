import '../models/audit_event.dart';
import '../models/rescue_case.dart';
import '../state/audit_log_state.dart';
import '../state/emergency_state.dart';

/// The one PENDING -> ASSIGNED -> IN PROGRESS -> RESCUED workflow, shared by
/// the Windows command center and RescueDashboardScreen so both record the
/// same audit events for the same transition.
class RescueWorkflow {
  RescueWorkflow._();

  static RescueStatus? next(RescueStatus status) {
    switch (status) {
      case RescueStatus.pending:
        return RescueStatus.assigned;
      case RescueStatus.assigned:
        return RescueStatus.inProgress;
      case RescueStatus.inProgress:
        return RescueStatus.rescued;
      case RescueStatus.rescued:
        return null;
    }
  }

  static String statusLabel(RescueStatus status) {
    switch (status) {
      case RescueStatus.pending:
        return 'PENDING';
      case RescueStatus.assigned:
        return 'ASSIGNED';
      case RescueStatus.inProgress:
        return 'IN PROGRESS';
      case RescueStatus.rescued:
        return 'RESCUED';
    }
  }

  static String actionLabel(RescueStatus current) {
    switch (current) {
      case RescueStatus.pending:
        return 'ASSIGN RESCUE';
      case RescueStatus.assigned:
        return 'START RESCUE';
      case RescueStatus.inProgress:
        return 'MARK RESCUED';
      case RescueStatus.rescued:
        return 'DONE';
    }
  }

  static AuditEventType _eventFor(RescueStatus status) {
    switch (status) {
      case RescueStatus.inProgress:
        return AuditEventType.rescueStarted;
      case RescueStatus.rescued:
        return AuditEventType.rescueCompleted;
      case RescueStatus.assigned:
      case RescueStatus.pending:
        return AuditEventType.rescueAssigned;
    }
  }

  /// Advances [rescueCase] one step. Returns the new status, or null if it
  /// was already RESCUED.
  static RescueStatus? advance({
    required EmergencyState emergencyState,
    required AuditLogState auditLog,
    required String actorId,
    required RescueCase rescueCase,
  }) {
    final nextStatus = next(rescueCase.status);
    if (nextStatus == null) return null;

    emergencyState.updateRescueCaseStatus(rescueCase.id, nextStatus);
    auditLog.addEvent(
      AuditEvent(
        id: '${rescueCase.id}_${nextStatus.name}',
        type: _eventFor(nextStatus),
        actorId: actorId,
        timestamp: DateTime.now(),
        details:
            'Case ${rescueCase.id} (${rescueCase.name}) -> ${statusLabel(nextStatus)}',
      ),
    );
    return nextStatus;
  }
}
