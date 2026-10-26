import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../models/ble_device_info.dart';
import '../services/ble_central_service.dart';
import '../state/ble_state.dart';
import 'chat_screen.dart';

/// Diagnostics: the older direct link to an Android phone running the
/// legacy Rescue screen (single connection, not the emergency network).
/// Scanning here briefly replaces the network's own scan; it resumes when
/// this screen's scan ends.
class LegacyRescueLinkScreen extends StatefulWidget {
  const LegacyRescueLinkScreen({super.key});

  @override
  State<LegacyRescueLinkScreen> createState() =>
      _LegacyRescueLinkScreenState();
}

class _LegacyRescueLinkScreenState extends State<LegacyRescueLinkScreen>
    with SingleTickerProviderStateMixin {
  final _ble = BleCentralService.instance;

  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  StreamSubscription<List<BleDeviceInfo>>? _devicesSubscription;

  bool isScanning = false;
  BluetoothAdapterState bluetoothState =
      BluetoothAdapterState.unknown;

  late final AnimationController _scanAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();

    _ble.startListening();

    _adapterSubscription = _ble.adapterState.listen((state) {
      if (!mounted) return;

      setState(() {
        bluetoothState = state;
      });

      if (state != BluetoothAdapterState.on) {
        context.read<BleState>().setStatus(BleConnectionStatus.disabled);
      }
    });

    _devicesSubscription = _ble.discoveredDevices.listen((devices) {
      if (!mounted) return;
      context.read<BleState>().setDiscoveredDevices(devices);
    });

    // Deferred to after the first frame: startScan() can synchronously
    // call ScaffoldMessenger.of(context) on its very first line (when
    // Bluetooth is off), and Flutter disallows that kind of inherited
    // widget lookup while still inside initState().
    WidgetsBinding.instance.addPostFrameCallback((_) => startScan());
  }

  Future<void> startScan() async {
    if (bluetoothState != BluetoothAdapterState.on) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Please turn ON Bluetooth first."),
          ),
        );
      }
      return;
    }

    setState(() {
      isScanning = true;
    });
    _scanAnimation.repeat();
    context.read<BleState>().setStatus(BleConnectionStatus.scanning);

    try {
      await _ble.startScan(timeout: const Duration(seconds: 10));

      if (mounted) {
        setState(() {
          isScanning = false;
        });
        _scanAnimation.stop();

        if (context.read<BleState>().status ==
            BleConnectionStatus.scanning) {
          context.read<BleState>().setStatus(BleConnectionStatus.idle);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isScanning = false;
        });
        _scanAnimation.stop();

        context.read<BleState>().setError("Bluetooth scan failed: $e");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Bluetooth scan failed: $e")),
        );
      }
    }
  }

  Future<void> connectDevice(BleDeviceInfo device) async {
    context.read<BleState>().setStatus(BleConnectionStatus.connecting);

    try {
      await _ble.stopScan();

      if (mounted) {
        setState(() {
          isScanning = false;
        });
      }

      final connected = await _ble.connect(device.remoteId);

      debugPrint("Connected to: ${connected.name}");

      if (!mounted) return;

      context.read<BleState>().setConnectedDevice(connected);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Connected to ${connected.name}")),
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(device: connected),
        ),
      );
    } catch (e) {
      if (mounted) {
        context.read<BleState>().setError("Connection failed: $e");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Connection failed: $e")),
        );
      }
    }
  }

  @override
  void dispose() {
    _adapterSubscription?.cancel();
    _devicesSubscription?.cancel();
    _scanAnimation.dispose();
    _ble.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bleState = context.watch<BleState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Legacy Rescue Phone Link"),
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: isScanning ? null : startScan,
        child: Icon(
          isScanning
              ? Icons.bluetooth_searching
              : Icons.refresh,
        ),
      ),

      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: bluetoothState == BluetoothAdapterState.on
                ? Colors.green.shade100
                : Colors.red.shade100,
            child: Row(
              children: [
                Icon(
                  bluetoothState == BluetoothAdapterState.on
                      ? Icons.bluetooth
                      : Icons.bluetooth_disabled,
                ),
                const SizedBox(width: 10),
                Text(
                  bluetoothState == BluetoothAdapterState.on
                      ? "Bluetooth is ON -- ${bleState.status.name}"
                      : "Bluetooth is OFF",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          if (isScanning)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  AnimatedBuilder(
                    animation: _scanAnimation,
                    builder: (context, child) => Transform.rotate(
                      angle: _scanAnimation.value * 2 * math.pi,
                      child: child,
                    ),
                    child: const Icon(
                      Icons.radar,
                      size: 48,
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text("Scanning for nearby BLE devices..."),
                ],
              ),
            ),

          Expanded(
            child: bleState.discoveredDevices.isEmpty
                ? Center(
                    child: Text(
                      isScanning
                          ? "Searching..."
                          : "No BLE devices found.\nTap refresh to scan again.",
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18),
                    ),
                  )
                : ListView.builder(
                    itemCount: bleState.discoveredDevices.length,
                    itemBuilder: (context, index) {
                      final device = bleState.discoveredDevices[index];

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.bluetooth),
                          ),
                          title: Text(device.name),
                          subtitle: Text(
                            "${device.remoteId}\n"
                            "Signal: ${device.rssi} dBm",
                          ),
                          isThreeLine: true,
                          trailing: ElevatedButton(
                            onPressed: () => connectDevice(device),
                            child: const Text("Connect"),
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
