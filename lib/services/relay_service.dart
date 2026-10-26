import 'dart:async';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'mesh/android_central_transport.dart';
import 'mesh/android_peripheral_transport.dart';
import 'mesh/mesh_link.dart';
import 'mesh/mesh_node.dart';
import 'mesh/mesh_service.dart';
import 'net_log.dart';

/// The phone's BLE CENTRAL role (scanner + GATT client on flutter_blue_plus)
/// and its RELAY forwarding switch.
///
/// Every phone is a full mesh node: AffectedPeripheralService advertises and
/// accepts connections, and this class scans for and connects to the other
/// mesh phones at the same time -- no phone is permanently "server" or
/// "client". Data flows both ways over every link, whichever side opened it.
///
///   Phone 1 <-BLE-> Phone 2 <-BLE-> Phone 3 <-BLE-> Phone 4 <-BLE-> Laptop
///   SOS ---------------------------------------------------------->
///   <------------------------------------------------- ACK / STATUS
///
/// Forwarding (RELAY, on by default) decides whether this phone carries
/// OTHER phones' SOS and returns the Rescue Team's ACK/STATUS to them. With
/// forwarding off the phone still advertises, scans, connects, sends its own
/// SOS and receives its ACKs. All routing lives in MeshNode. Nothing here
/// uses the internet.
class RelayService {
  RelayService._();
  static final RelayService instance = RelayService._();

  static const String _prefsDocument = 'relay_prefs';

  AndroidCentralTransport? _transport;
  MeshNode? _node;
  bool _centralRunning = false;
  Future<bool>? _startingCentral;

  /// The scanner / GATT-client role is running.
  bool get isRunning => _centralRunning;

  /// This phone forwards other phones' packets.
  bool get forwarding => _node?.relayEnabled ?? false;

  /// Why the last start failed, for the UI.
  String? lastError;

  ValueListenable<MeshStats>? get stats => _node?.stats;
  ValueListenable<TransportStatus>? get transportStatus => _transport?.status;

  /// Starts scanning for / connecting to other mesh phones. Idempotent.
  Future<bool> startCentral() {
    if (_centralRunning) return Future.value(true);
    return _startingCentral ??= _startCentral().whenComplete(() => _startingCentral = null);
  }

  Future<bool> _startCentral() async {
    lastError = null;
    // Scanning needs BLUETOOTH_SCAN (Android 12+).
    if (await AndroidPeripheralTransport.permissionStatus() != MeshPermissionResult.granted &&
        await AndroidPeripheralTransport.requestPermissions() != MeshPermissionResult.granted) {
      lastError = 'Allow "Nearby devices" for this app so it can find other phones.';
      NetLog.ble('Scanning not started: Bluetooth permission missing');
      return false;
    }
    final node = _node = await MeshService.instance.affectedNode();
    final transport = _transport ??= AndroidCentralTransport();
    node.attach(transport);
    final ok = await transport.start();
    if (!ok) {
      lastError = transport.status.value.detail ?? 'Bluetooth scanning could not start.';
      NetLog.ble('Scanning not started: $lastError');
      return false;
    }
    _centralRunning = true;
    return true;
  }

  Future<void> stopCentral() async {
    final transport = _transport;
    _centralRunning = false;
    if (transport != null) await transport.stop();
  }

  /// RELAY forwarding on/off (remembered across restarts).
  Future<void> setForwarding(bool on, {bool remember = true}) async {
    final node = _node ??= await MeshService.instance.affectedNode();
    await node.setRelayEnabled(on);
    if (remember) await LocalStore.write(_prefsDocument, {'relayEnabled': on});
  }

  /// The user's last choice; forwarding is ON unless they turned it off.
  Future<bool> savedPreference() async {
    final doc = await LocalStore.read(_prefsDocument);
    final value = doc?['relayEnabled'];
    return value is bool ? value : true;
  }

  // -- compatibility with the earlier RELAY-mode API ------------------------

  /// Forwarding ON (and the central role running).
  Future<bool> start() async {
    await setForwarding(true);
    return startCentral();
  }

  /// Forwarding OFF. The central role keeps running: the phone still finds
  /// the mesh for its own SOS.
  Future<void> stop({bool rememberChoice = true}) =>
      setForwarding(false, remember: rememberChoice);

  Future<void> dispose() => stopCentral();
}
