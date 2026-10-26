/// Thin typed wrapper around a discovered BLE device, decoupling app state
/// and UI from flutter_blue_plus's own ScanResult/BluetoothDevice types.
class BleDeviceInfo {
  final String remoteId;
  final String name;
  final int rssi;
  final bool connectable;

  const BleDeviceInfo({
    required this.remoteId,
    required this.name,
    required this.rssi,
    this.connectable = true,
  });

  BleDeviceInfo copyWith({String? name, int? rssi, bool? connectable}) {
    return BleDeviceInfo(
      remoteId: remoteId,
      name: name ?? this.name,
      rssi: rssi ?? this.rssi,
      connectable: connectable ?? this.connectable,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BleDeviceInfo && other.remoteId == remoteId);

  @override
  int get hashCode => remoteId.hashCode;
}
