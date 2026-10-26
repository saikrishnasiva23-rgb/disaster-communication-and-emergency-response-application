import 'dart:async';
import 'dart:convert';

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart'
    show defaultRxCharacteristicUuid, defaultTxCharacteristicUuid;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/ble_device_info.dart';
import 'bluetooth_rescue_service.dart';

/// Real BLE central/scanner service, extracted from nearby_devices.dart so
/// scanning and connecting can be driven from outside a single screen and
/// reported into BleState.
///
/// Phase 6-7: this now performs a real GATT characteristic write and a
/// real notification subscription, not a placeholder. The rescue phone's
/// GATT server (BluetoothRescueService) is started with a plain
/// `GattServerSettings()`, which -- per flutter_ble_peripheral's own
/// defaults -- serves the Nordic UART Service profile: a write (RX)
/// characteristic at [defaultRxCharacteristicUuid] and a notify (TX)
/// characteristic at [defaultTxCharacteristicUuid], both under
/// [BluetoothRescueService.serviceUuid]. This service locates those same
/// two characteristics after connecting, so [sendBytes] writes to the
/// exact characteristic the peripheral is actually listening on, and
/// [onAckReceived] decodes whatever the peripheral notifies back on.
class BleCentralService {
  BleCentralService._();
  static final BleCentralService instance = BleCentralService._();

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  StreamSubscription<List<int>>? _notifySubscription;

  final StreamController<BluetoothAdapterState> _adapterStateController =
      StreamController<BluetoothAdapterState>.broadcast();
  final StreamController<List<BleDeviceInfo>> _discoveredDevicesController =
      StreamController<List<BleDeviceInfo>>.broadcast();
  final StreamController<Map<String, dynamic>> _ackController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<BluetoothAdapterState> get adapterState =>
      _adapterStateController.stream;
  Stream<List<BleDeviceInfo>> get discoveredDevices =>
      _discoveredDevicesController.stream;

  /// Decoded JSON acknowledgements notified back by the connected rescue
  /// phone after it accepts an SOS -- see BluetoothRescueService's ack
  /// send. Bytes that are not valid JSON are dropped, not thrown.
  Stream<Map<String, dynamic>> get onAckReceived => _ackController.stream;

  final Map<String, BluetoothDevice> _devicesByRemoteId = {};
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;

  /// Must be called once (e.g. from a screen's initState) before
  /// [startScan] -- mirrors the subscriptions nearby_devices.dart used to
  /// set up directly on FlutterBluePlus.
  void startListening() {
    _adapterSubscription ??=
        FlutterBluePlus.adapterState.listen((state) {
      _adapterStateController.add(state);
    });

    _scanSubscription ??= FlutterBluePlus.scanResults.listen((results) {
      _devicesByRemoteId
        ..clear()
        ..addEntries(
          results.map((r) => MapEntry(r.device.remoteId.str, r.device)),
        );

      _discoveredDevicesController.add(
        results
            .map(
              (r) => BleDeviceInfo(
                remoteId: r.device.remoteId.str,
                name: r.device.platformName.isEmpty
                    ? 'Unknown BLE Device'
                    : r.device.platformName,
                rssi: r.rssi,
              ),
            )
            .toList(),
      );
    });
  }

  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await FlutterBluePlus.stopScan();
    await FlutterBluePlus.startScan(timeout: timeout);
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  /// Connects to a previously-discovered device (by the remoteId from the
  /// last scan), performs real GATT service discovery, and locates the
  /// write and notify characteristics the rescue phone's GATT server
  /// serves.
  Future<BleDeviceInfo> connect(
    String remoteId, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final device = _devicesByRemoteId[remoteId];
    if (device == null) {
      throw StateError('Device $remoteId was not found in the last scan.');
    }

    // Disconnect whatever was previously connected first -- otherwise
    // repeated reconnects (e.g. connecting to a different discovered
    // device, or reconnecting to the same one after it drops out of
    // range) leak GATT connections that this service can no longer
    // reference or close, eventually exhausting the small number of
    // concurrent connections most BLE chipsets allow.
    if (_connectedDevice != null) {
      await disconnect();
    }

    await FlutterBluePlus.stopScan();
    await device.connect(timeout: timeout);
    final services = await device.discoverServices();

    _writeCharacteristic = null;
    _notifyCharacteristic = null;
    await _notifySubscription?.cancel();
    _notifySubscription = null;

    for (final service in services) {
      if (service.serviceUuid != Guid(BluetoothRescueService.serviceUuid)) {
        continue;
      }

      for (final characteristic in service.characteristics) {
        if (characteristic.characteristicUuid ==
            Guid(defaultRxCharacteristicUuid)) {
          _writeCharacteristic = characteristic;
        } else if (characteristic.characteristicUuid ==
            Guid(defaultTxCharacteristicUuid)) {
          _notifyCharacteristic = characteristic;
        }
      }
    }

    final notifyCharacteristic = _notifyCharacteristic;
    if (notifyCharacteristic != null) {
      await notifyCharacteristic.setNotifyValue(true);
      _notifySubscription = notifyCharacteristic.onValueReceived.listen(
        (bytes) {
          try {
            final decoded =
                jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
            _ackController.add(decoded);
          } catch (_) {
            // Not valid JSON -- malformed/unexpected notification bytes
            // must not crash the app.
          }
        },
      );
    }

    _connectedDevice = device;

    return BleDeviceInfo(
      remoteId: device.remoteId.str,
      name: device.platformName.isEmpty
          ? 'Unknown BLE Device'
          : device.platformName,
      rssi: 0,
    );
  }

  Future<void> disconnect() async {
    await _notifySubscription?.cancel();
    _notifySubscription = null;
    _writeCharacteristic = null;
    _notifyCharacteristic = null;
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
  }

  /// Real GATT characteristic write to the connected rescue phone's RX
  /// characteristic. Throws a [StateError] if no device is connected or
  /// the expected characteristic was not found on it -- callers must
  /// catch this and report it honestly rather than assume delivery.
  Future<void> sendBytes(List<int> bytes) async {
    final characteristic = _writeCharacteristic;
    if (characteristic == null) {
      throw StateError(
        'No writable rescue characteristic found. Connect to a device '
        'advertising the rescue GATT service first.',
      );
    }

    await characteristic.write(bytes, withoutResponse: false);
  }

  /// Stops scan-related listening -- called from NearbyDevicesScreen's
  /// dispose() when the user leaves that screen. This deliberately does
  /// NOT touch the connection (_connectedDevice, the characteristics, or
  /// _notifySubscription/the ack listener): a real connection is meant to
  /// keep working for SOS/Chat/Map after the user navigates away from
  /// Nearby Devices, exactly like a real Bluetooth connection would. Two
  /// confirmed bugs lived here before this fix:
  ///   1. This used to also cancel _notifySubscription and leave
  ///      BleState.connectedDevice/_writeCharacteristic pointing at a
  ///      connection whose ack listener was dead -- every future SOS
  ///      would falsely report "no acknowledgement" even if the rescue
  ///      phone genuinely acked it.
  ///   2. The two fields below were cancelled but never reset to null,
  ///      so `startListening()`'s `??=` guards silently no-op on every
  ///      subsequent visit to Nearby Devices, permanently freezing BLE
  ///      discovery for the rest of the app's life.
  /// Call [disconnect] explicitly to actually end the BLE connection.
  void dispose() {
    _scanSubscription?.cancel();
    _scanSubscription = null;
    _adapterSubscription?.cancel();
    _adapterSubscription = null;
    FlutterBluePlus.stopScan();
  }
}
