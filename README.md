# AI-Enabled Decentralized Disaster Communication Network

A final-year B.Tech project: a two-role Flutter app (Affected Person / Rescue
Team) built around real Bluetooth Low Energy communication, with an optional
Flask + SQLite + RandomForest backend as a secondary channel when network
connectivity happens to be available.

**Read this before assuming any feature works.** Every claim below is labeled
IMPLEMENTED, PARTIALLY IMPLEMENTED, or REQUIRES TESTING, not just "done" --
see [Honest feature status](#honest-feature-status).

## Architecture

```
Flutter UI (lib/screens)
    |
    | Provider (lib/state) -- BleState, EmergencyState, AuthState, AuditLogState
    |
    +-- lib/services/ble_central_service.dart    (BLE central/scanner -- flutter_blue_plus)
    +-- lib/services/bluetooth_rescue_service.dart (BLE peripheral/GATT server -- flutter_ble_peripheral)
    +-- lib/services/auth_service.dart           (Rescue ID/password -- flutter_secure_storage)
    +-- lib/services/ai_priority_service.dart    (local rule-based priority, offline fallback)
    |
    +-- HTTP (lib/config/backend_config.dart) --> backend/app.py (Flask + SQLite + RandomForest)
```

BLE is the **primary** channel and is designed to work with no network at
all. The Flask backend is a **secondary** channel used only when reachable --
nothing on the BLE path depends on it.

`android/.../MainActivity.kt`'s MethodChannel (`disaster_communication/mesh`)
is vestigial: it's called once at startup for a debug log and is not part of
the real communication path. All real BLE work happens in Dart via
`flutter_blue_plus` (central) and `flutter_ble_peripheral` (peripheral),
which itself serves a Nordic UART Service GATT profile.

## Honest feature status

| Feature | Status |
|---|---|
| Role selection, navigation | IMPLEMENTED |
| Rescue Team authentication (secure storage, no hardcoded password) | IMPLEMENTED |
| GPS location (Affected + Rescue side) | IMPLEMENTED |
| Google Maps live location | IMPLEMENTED |
| Hospitals (Google Places API, live) | IMPLEMENTED |
| Relief Camps (GPS/distance real; camp list is a static 4-entry sample) | PARTIALLY IMPLEMENTED |
| Request Rescue -> Flask backend -> RandomForest priority | IMPLEMENTED |
| BLE scan/advertise/connect (central + peripheral) | IMPLEMENTED, REQUIRES TESTING on physical hardware |
| BLE GATT characteristic write (SOS/message send) | IMPLEMENTED, REQUIRES TESTING on physical hardware |
| SOS acknowledgement over BLE | IMPLEMENTED, REQUIRES TESTING on physical hardware |
| Emergency chat over BLE | IMPLEMENTED, REQUIRES TESTING on physical hardware |
| Duplicate detection / packet validation | IMPLEMENTED |
| AI priority (backend RandomForest) | IMPLEMENTED (requires backend reachable) |
| AI priority (local rule-based fallback, offline) | IMPLEMENTED -- explicitly NOT a trained model, labeled as such in the UI |
| Rescue workflow (PENDING -> ASSIGNED -> IN_PROGRESS -> RESCUED) | IMPLEMENTED |
| Tamper-evident event log (local SHA-256 hash chain) | IMPLEMENTED -- see note below |
| Mesh relay (multi-hop, Phone A -> B -> C) | NOT IMPLEMENTED (deliberately deferred) |
| Physical two-phone SOS demo | REQUIRES TESTING -- blocked on Android SDK not being installed on the primary dev machine as of this writing |

**On "tamper-evident event log":** this is a local SHA-256 hash chain
(`lib/state/audit_log_state.dart`), not a distributed blockchain network.
Every event links to the previous one's hash; `verifyChain()` recomputes and
checks the whole chain, and a "Simulate tampering" button in the Event Log
screen demonstrates it actually catching a corrupted entry. Do not describe
this to anyone as a decentralized blockchain -- it isn't one.

## Project structure

```
lib/
  models/     Typed data: SosPacket, EmergencyMessage, RescueCase, AuditEvent, ...
  state/      Provider ChangeNotifiers: BleState, EmergencyState, AuthState, AuditLogState
  services/   BleCentralService, BluetoothRescueService, AuthService, AiPriorityService
  config/     BackendConfig -- single source of truth for the backend URL
  screens/    One screen per file; role_selection_screen.dart is the entry point
backend/
  app.py              Flask REST API (POST /api/rescue-request, GET /api/rescue-requests)
  ai/priority_model.py RandomForestClassifier trained at import time on a small synthetic dataset
  requirements.txt
test/
  *_test.dart  Unit + widget tests -- run these before and after any change
```

## Running the Flutter app

```bash
flutter pub get
flutter analyze   # should report 0 errors
flutter test      # should report all passing
```

To run against a specific backend address (see [Backend](#running-the-backend)):

```bash
flutter run --dart-define=BACKEND_BASE_URL=http://<your-lan-ip>:5000
```

Without this flag it defaults to `http://192.168.31.250:5000`, which is very
likely **not** your machine's actual address -- set it explicitly for testing.

**Physical device testing requires the Android SDK**, which is not installed
on the machine this project has been developed on so far. Install Android
Studio (https://developer.android.com/studio), let it install the SDK on
first launch, then `flutter devices` should list a connected phone.

## Running the backend

```bash
cd backend
pip install -r requirements.txt
python app.py
```

Starts on `0.0.0.0:5000`. Find your machine's LAN IP (`ipconfig` / `ifconfig`)
and pass it to the Flutter app via `--dart-define=BACKEND_BASE_URL` above --
`127.0.0.1` only works if the backend runs on the same device as the app,
which defeats testing across two phones.

## Two-phone test plan (once Android SDK is available)

1. Install the app on both phones (`flutter run` or a built APK).
2. Phone A: Role Selection -> Affected Person -> Nearby Devices -> Bluetooth
   on -> Scan.
3. Phone B: Role Selection -> Rescue Team -> set up Rescue ID/password (first
   run) -> Rescue dashboard starts advertising automatically.
4. Phone A: find Phone B in the scan list -> Connect.
5. Phone A: SOS screen -> Send SOS. Watch for the real GPS permission prompt,
   then the BLE write, then the acknowledgement wait (8s timeout).
6. Phone B: the SOS should appear under "Live BLE Alerts" within a few
   seconds, with a local AI priority estimate attached.
7. Confirm on Phone A that the SOS status updates to "acknowledged" once
   Phone B's ack round-trips.

If any step fails, check `flutter logs` on both devices -- every BLE
operation in this app logs via `debugPrint`, including rejected/duplicate
packets and ack failures.
