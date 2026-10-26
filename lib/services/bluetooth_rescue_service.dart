import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../models/emergency_message.dart';
import '../models/sos_packet.dart';
import 'ble_protocol.dart';
import 'rescue_comms_channel.dart';

/// Real BLE peripheral/GATT-server service -- the Rescue Team side. It
/// advertises, accepts a connection, and receives bytes from an Affected
/// Person's phone. Received packets are decoded, validated, deduplicated,
/// and published on [onSosReceived]; callers (screens) subscribe and push
/// results into EmergencyState/AuditLogState. This file has no dependency
/// on Provider/UI state so it stays testable in isolation.
///
/// Implements [RescueCommsChannel] (the platform communication layer) --
/// see that file for why the same class is used on both Android and
/// Windows rather than a separate Windows implementation.
class BluetoothRescueService implements RescueCommsChannel {
  BluetoothRescueService._();

  static final BluetoothRescueService instance =
      BluetoothRescueService._();

  final FlutterBlePeripheral peripheral =
      FlutterBlePeripheral();

  /// The single shared rescue service UUID (defined once, in BleProtocol).
  static const String serviceUuid = BleProtocol.serviceUuid;

  StreamSubscription<Uint8List>? _dataSubscription;

  bool _isStarted = false;

  @override
  bool get isStarted => _isStarted;

  final StreamController<SosPacket> _sosController =
      StreamController<SosPacket>.broadcast();

  /// Real, validated SOS packets received over BLE. This is the only
  /// intended way a received emergency reaches the rest of the app --
  /// previously it only ever reached a print() statement.
  @override
  Stream<SosPacket> get onSosReceived => _sosController.stream;

  final StreamController<EmergencyMessage> _messageController =
      StreamController<EmergencyMessage>.broadcast();

  /// Real chat-style messages received over BLE (distinguished from an
  /// SOS packet by the wire payload's `type` field).
  @override
  Stream<EmergencyMessage> get onMessageReceived => _messageController.stream;

  /// Ids already processed, so a retransmitted/duplicate packet is not
  /// turned into a second emergency or message. Shared across both kinds
  /// since ids are unique regardless of packet type. Capped so it cannot
  /// grow unbounded over a long rescue session.
  final Set<String> _processedPacketIds = {};
  static const int _maxProcessedIds = 500;

  @override
  Future<bool> startRescueMode() async {
    try {
      final supported = await peripheral.isSupported;

      if (!supported) {
        debugPrint("BLE peripheral mode is not supported.");
        return false;
      }

      var permission = await peripheral.hasPermission();

      if (permission != PeripheralBluetoothState.granted &&
          permission != PeripheralBluetoothState.ready) {
        permission = await peripheral.requestPermission();
      }

      if (permission ==
          PeripheralBluetoothState.permanentlyDenied) {
        debugPrint("Bluetooth permission permanently denied.");
        return false;
      }

      if (permission ==
          PeripheralBluetoothState.turnedOff) {
        final enabled =
            await peripheral.enableBluetooth();

        if (!enabled) {
          debugPrint("Bluetooth could not be enabled.");
          return false;
        }
      }

      await _dataSubscription?.cancel();

      _dataSubscription =
          peripheral.onDataReceived.listen(
        (Uint8List bytes) {
          _handleEmergencyRequest(bytes);
        },
      );

      await peripheral.start(
        advertiseData: const AdvertiseDataCore(
          serviceUuid: serviceUuid,
        ),
        gattServer: const GattServerSettings(),
      );

      _isStarted = true;

      debugPrint("================================");
      debugPrint("BLE RESCUE MODE STARTED");
      debugPrint("Waiting for affected phones...");
      debugPrint("================================");

      return true;
    } catch (e) {
      debugPrint("BLE Rescue Error: $e");
      return false;
    }
  }

  @override
  Future<void> stopRescueMode() async {
    try {
      await peripheral.stop();

      await _dataSubscription?.cancel();
      _dataSubscription = null;

      _isStarted = false;

      debugPrint("BLE Rescue Mode stopped.");
    } catch (e) {
      debugPrint("BLE Stop Error: $e");
    }
  }

  void _handleEmergencyRequest(Uint8List bytes) {
    late final String message;

    try {
      message = utf8.decode(bytes);
    } catch (e) {
      debugPrint("Invalid data (not valid UTF-8): $e");
      return;
    }

    debugPrint("================================");
    debugPrint("🚨 BLUETOOTH DATA RECEIVED");
    debugPrint("================================");
    debugPrint(message);

    final Map<String, dynamic> json;

    try {
      json = jsonDecode(message) as Map<String, dynamic>;
    } catch (e) {
      debugPrint("Invalid data (not valid JSON): $e");
      return;
    }

    // A chat message carries type "MESSAGE"; everything else (including
    // an SOS packet that omits `type`, since SosPacket defaults it to
    // "SOS") is treated as an SOS.
    if (json['type'] == 'MESSAGE') {
      _handleMessage(json);
    } else {
      _handleSos(json);
    }
  }

  void _handleSos(Map<String, dynamic> json) {
    final SosPacket packet;

    try {
      packet = SosPacket.fromJson(json);
    } catch (e) {
      debugPrint("Invalid emergency data (failed to parse SosPacket): $e");
      return;
    }

    final rejectionReason = _validate(packet);
    if (rejectionReason != null) {
      debugPrint("Rejected emergency packet ${packet.id}: $rejectionReason");
      return;
    }

    if (_processedPacketIds.contains(packet.id)) {
      debugPrint("Duplicate emergency packet ignored: ${packet.id}");
      return;
    }

    _markProcessed(packet.id);

    debugPrint("Accepted SOS ${packet.id} from ${packet.senderId}");

    _sosController.add(packet);
    _sendAck(packet.id);
  }

  void _handleMessage(Map<String, dynamic> json) {
    // Checked on the RAW json, before EmergencyMessage.fromJson runs --
    // fromJson synthesizes a fresh non-empty id from the current
    // timestamp whenever one is missing (by design, for locally-created
    // messages), which used to make the "missing id" check below always
    // false and silently defeat duplicate-detection for exactly the
    // malformed-packet case it exists to guard against: the same
    // id-less message sent twice would get two different synthesized
    // ids and be accepted -- and shown to the rescue team -- both times.
    final rawId = json['id'];
    if (rawId is! String || rawId.isEmpty) {
      debugPrint("Rejected message: missing id");
      return;
    }

    final EmergencyMessage message;

    try {
      message = EmergencyMessage.fromJson(json, fromLocalUser: false);
    } catch (e) {
      debugPrint("Invalid message data: $e");
      return;
    }

    if (_processedPacketIds.contains(message.id)) {
      debugPrint("Duplicate message ignored: ${message.id}");
      return;
    }

    _markProcessed(message.id);

    debugPrint("Accepted message ${message.id} from ${message.senderId}");

    _messageController.add(message);
  }

  void _markProcessed(String id) {
    _processedPacketIds.add(id);
    if (_processedPacketIds.length > _maxProcessedIds) {
      _processedPacketIds.remove(_processedPacketIds.first);
    }
  }

  /// Notifies the connected Affected Person's phone that their SOS was
  /// accepted, over the default TX (notify) characteristic --
  /// FlutterBlePeripheral.sendData delivers to whichever central is
  /// currently subscribed to it.
  ///
  /// Best-effort: if no central has subscribed yet, the plugin throws
  /// (`SEND_FAILED`); that is caught and logged here rather than
  /// propagated, since a missing subscriber just means the ack cannot be
  /// delivered right now, not that anything is broken.
  Future<void> _sendAck(String sosId) async {
    try {
      final payload = utf8.encode(jsonEncode({'type': 'ACK', 'id': sosId}));
      await peripheral.sendData(Uint8List.fromList(payload));
      debugPrint("ACK sent for SOS $sosId");
    } catch (e) {
      debugPrint("Could not send ACK for SOS $sosId (no subscriber yet?): $e");
    }
  }

  /// Returns null if the packet is valid, otherwise a human-readable
  /// rejection reason. Never throws -- malformed BLE input must not crash
  /// the app.
  String? _validate(SosPacket packet) {
    return SosValidation.rejectReason(packet);
  }

  Future<void> dispose() async {
    await stopRescueMode();
    await _sosController.close();
    await _messageController.close();
  }
}
