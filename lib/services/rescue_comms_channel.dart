import '../models/emergency_message.dart';
import '../models/sos_packet.dart';

/// The platform communication layer the Rescue Team side talks to,
/// independent of which concrete BLE plugin/role implements it on a given
/// OS:
///
///   Android BLE (affected person, central)
///        v
///   Platform communication layer  <-- this interface
///        v
///   Rescue Windows BLE layer (or Rescue Android BLE layer)
///
/// [BluetoothRescueService] (lib/services/bluetooth_rescue_service.dart) is
/// the only implementation today. It already contains no Android-specific
/// code -- it only calls into `flutter_ble_peripheral`, which declares a
/// real Windows platform implementation (see
/// windows/flutter/generated_plugin_registrant.cc:
/// FlutterBlePeripheralPluginCApiRegisterWithRegistrar). That is why the
/// same class is reused for both the Android and the Windows Rescue Team
/// screens instead of duplicating it: there is nothing Android-specific to
/// swap out yet.
///
/// This interface exists so that a genuinely different Windows-side
/// implementation (e.g. one built on a different plugin, or on a future
/// full BLE mesh) can be swapped in later without changing the screens
/// that consume it. Do not add a second implementation until it is a real,
/// tested one -- an untested stub that "implements" this interface would
/// invite exactly the fake-status risk this project's honesty rules
/// prohibit.
abstract class RescueCommsChannel {
  /// Real, validated SOS packets received over this channel.
  Stream<SosPacket> get onSosReceived;

  /// Real chat-style messages received over this channel.
  Stream<EmergencyMessage> get onMessageReceived;

  /// Whether the channel is currently active (advertising/listening).
  bool get isStarted;

  /// Starts the channel. Returns whether it started successfully -- never
  /// throws, and never returns true unless the underlying platform call
  /// actually succeeded.
  Future<bool> startRescueMode();

  Future<void> stopRescueMode();
}
