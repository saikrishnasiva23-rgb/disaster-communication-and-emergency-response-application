import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/rescue_case.dart';
import '../services/rescue_workflow.dart';
import '../state/audit_log_state.dart';
import '../state/auth_state.dart';
import '../state/emergency_state.dart';
import '../theme/app_colors.dart';

/// The rescue workflow: PENDING -> ASSIGNED -> IN_PROGRESS -> RESCUED.
/// Reads the same EmergencyState.rescueCases list the command center
/// populates from BLE; transitions go through RescueWorkflow so both
/// screens record identical audit events.
class RescueDashboardScreen extends StatelessWidget {
  const RescueDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final rescueCases = context.watch<EmergencyState>().rescueCases;

    return Scaffold(
      appBar: AppBar(title: const Text("Rescue Status")),
      body: rescueCases.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "No active cases yet. Cases received over BLE or "
                  "submitted via the backend appear here.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
              ),
            )
          : ListView.builder(
              itemCount: rescueCases.length,
              itemBuilder: (context, index) {
                final rescueCase = rescueCases[index];
                final next = RescueWorkflow.next(rescueCase.status);
                final rescued = rescueCase.status == RescueStatus.rescued;

                return Card(
                  margin: const EdgeInsets.all(10),
                  child: ListTile(
                    leading: Icon(
                      rescued ? Icons.check_circle : Icons.warning,
                      color: rescued ? AppColors.success : AppColors.emergency,
                    ),
                    title: Text(rescueCase.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rescueCase.emergencyType),
                        Text(
                          rescueCase.source == RescueCaseSource.ble
                              ? "Source: BLE (offline)"
                              : "Source: Backend",
                        ),
                        Text(
                          "Status: ${RescueWorkflow.statusLabel(rescueCase.status)}",
                        ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: ElevatedButton(
                      onPressed: next == null
                          ? null
                          : () => RescueWorkflow.advance(
                                emergencyState: context.read<EmergencyState>(),
                                auditLog: context.read<AuditLogState>(),
                                actorId: context.read<AuthState>().rescueId ??
                                    'rescue_team',
                                rescueCase: rescueCase,
                              ),
                      child: Text(RescueWorkflow.actionLabel(rescueCase.status)),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
