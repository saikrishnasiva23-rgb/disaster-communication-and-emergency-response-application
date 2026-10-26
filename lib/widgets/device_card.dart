import 'package:flutter/material.dart';

import '../models/ble_device_info.dart';

/// A single discovered BLE device, from the app's REAL scan stream
/// (BleCentralService.discoveredDevices) -- never a hardcoded/mock list.
class DeviceCard extends StatelessWidget {
  final BleDeviceInfo device;
  final VoidCallback onConnect;
  final bool isConnecting;

  const DeviceCard({
    super.key,
    required this.device,
    required this.onConnect,
    this.isConnecting = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.bluetooth)),
        title: Text(device.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${device.remoteId}\nSignal: ${device.rssi} dBm'),
        isThreeLine: true,
        trailing: isConnecting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : ElevatedButton(onPressed: onConnect, child: const Text('Connect')),
      ),
    );
  }
}
