import 'package:flutter/foundation.dart';

import '../models/ble_device_info.dart';

enum BleConnectionStatus {
  disabled,
  permissionRequired,
  idle,
  scanning,
  connecting,
  connected,
  disconnected,
  failed,
  unsupported,
}

/// Centralized, real BLE connection state shared across every screen that
/// needs it (dashboard status chips, nearby-devices screen, chat). Nothing
/// here may be set to a "connected"-looking value unless the native BLE
/// layer actually reported it -- BleCentralService and
/// BluetoothRescueService are the only intended callers that mutate this.
class BleState extends ChangeNotifier {
  BleConnectionStatus status = BleConnectionStatus.idle;
  List<BleDeviceInfo> discoveredDevices = [];
  BleDeviceInfo? connectedDevice;
  String? lastError;

  void setStatus(BleConnectionStatus newStatus) {
    status = newStatus;
    notifyListeners();
  }

  void setDiscoveredDevices(List<BleDeviceInfo> devices) {
    discoveredDevices = devices;
    notifyListeners();
  }

  void setConnectedDevice(BleDeviceInfo? device) {
    connectedDevice = device;
    status = device != null
        ? BleConnectionStatus.connected
        : BleConnectionStatus.disconnected;
    notifyListeners();
  }

  void setError(String message) {
    lastError = message;
    status = BleConnectionStatus.failed;
    notifyListeners();
  }

  void reset() {
    status = BleConnectionStatus.idle;
    discoveredDevices = [];
    connectedDevice = null;
    lastError = null;
    notifyListeners();
  }
}
