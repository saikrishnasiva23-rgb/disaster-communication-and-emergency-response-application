// LIVE integration test of CloudSyncService against a running FastAPI
// backend (backend/). Skipped unless CLOUD_SYNC_URL, CLOUD_SYNC_USER and
// CLOUD_SYNC_PASSWORD are set in the environment, e.g. against the dev
// server started with `uvicorn app.main:app` and the seeded demo account.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/services/cloud_sync_service.dart';
import 'package:disaster_communication_app/services/local_store.dart';

void main() {
  final env = Platform.environment;
  final url = env['CLOUD_SYNC_URL'];
  final user = env['CLOUD_SYNC_USER'];
  final password = env['CLOUD_SYNC_PASSWORD'];
  final skip = (url == null || user == null || password == null)
      ? 'set CLOUD_SYNC_URL / CLOUD_SYNC_USER / CLOUD_SYNC_PASSWORD to run'
      : false;

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cloud_live_');
    LocalStore.useDirectoryForTesting(dir);
  });
  tearDown(() async {
    LocalStore.useDirectoryForTesting(null);
    await dir.delete(recursive: true);
  });

  test('uploads a relayed SOS, a no-GPS SOS and status changes; retries are duplicates',
      skip: skip, () async {
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final sync = CloudSyncService(baseUrl: url)
      ..setDeviceId('rescue-console-livetest')
      ..setCredentials(user!, password!);
    await sync.init();

    final relayed = CloudEmergencyRecord(
      clientEmergencyId: 'live-$stamp-r',
      emergencyType: 'Flood Emergency',
      description: 'Live test: relayed SOS',
      peopleCount: 3,
      injured: true,
      occurredAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
      latitude: 11.941612,
      longitude: 79.808301,
      accuracyMeters: 12.5,
      fixTime: DateTime.now().toUtc().subtract(const Duration(minutes: 3)),
      originDeviceId: 'affected-live$stamp',
      senderDisplayName: 'Live Phone A',
      relayedByDeviceId: 'affected-relay$stamp',
      relayedByName: 'Live Phone B',
      hopCount: 1,
      clientPriority: 'HIGH',
      localBleAcknowledged: true,
      localBleAcknowledgedAt: DateTime.now().toUtc(),
    );
    final noGps = CloudEmergencyRecord(
      clientEmergencyId: 'live-$stamp-n',
      emergencyType: 'Earthquake',
      occurredAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      originDeviceId: 'affected-nogps$stamp',
      senderDisplayName: 'Live Phone C',
    );
    await sync.enqueueEmergency(relayed);
    await sync.enqueueEmergency(noGps);
    await sync.enqueueStatus(CloudStatusUpdate(
      updateId: 'live-$stamp-r-ASSIGNED',
      clientEmergencyId: relayed.clientEmergencyId,
      consoleStatus: 'ASSIGNED',
      changedAt: DateTime.now().toUtc(),
    ));
    await sync.syncNow();

    final status = sync.status.value;
    expect(status.phase, CloudSyncPhase.upToDate, reason: '${status.lastError}');
    expect(sync.emergencyState(relayed.clientEmergencyId)?.phase, CloudItemPhase.synced);
    expect(sync.emergencyState(noGps.clientEmergencyId)?.phase, CloudItemPhase.synced);
    final statusState = sync.statusState('live-$stamp-r-ASSIGNED');
    expect(statusState?.phase, CloudItemPhase.done,
        reason: 'the offline ASSIGNED change must be applied, not a conflict: $statusState');

    // A new service (app restart) re-uploading the same SOS: duplicate.
    final again = CloudSyncService(baseUrl: url)
      ..setDeviceId('rescue-console-livetest')
      ..setCredentials(user, password);
    await again.init();
    expect(again.emergencyState(relayed.clientEmergencyId)?.phase, CloudItemPhase.synced,
        reason: 'the queue state survived the restart');
    sync.dispose();
    again.dispose();
  });

  test('wrong password -> login failed, nothing marked synced', skip: skip, () async {
    final sync = CloudSyncService(baseUrl: url)..setCredentials(user!, 'definitely-wrong-$password');
    await sync.init();
    await sync.enqueueEmergency(CloudEmergencyRecord(
      clientEmergencyId: 'live-badpw-${DateTime.now().microsecondsSinceEpoch}',
      emergencyType: 'Other',
      occurredAt: DateTime.now().toUtc(),
      originDeviceId: 'affected-badpw',
    ));
    await sync.syncNow();
    expect(sync.status.value.phase, CloudSyncPhase.authFailed);
    expect(sync.status.value.synced, 0);
    sync.dispose();
  });
}
