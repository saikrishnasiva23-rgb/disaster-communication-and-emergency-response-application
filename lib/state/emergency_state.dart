import 'package:flutter/foundation.dart';

import '../models/sos_packet.dart';
import '../models/emergency_message.dart';
import '../models/location_data.dart';
import '../models/rescue_case.dart';
import '../models/ai_priority_result.dart';

/// Centralized state for everything an emergency event touches: SOS
/// packets this device has sent or received, chat-style emergency
/// messages, this device's own location, the Rescue Team's merged case
/// list (BLE + backend), and the most recent AI priority result.
class EmergencyState extends ChangeNotifier {
  /// Keeps a long incident from growing the chat list without bound.
  static const int maxMessages = 500;

  final List<SosPacket> sosHistory = [];
  final List<EmergencyMessage> messages = [];
  final List<RescueCase> rescueCases = [];
  LocationData? currentLocation;
  AiPriorityResult? lastAiPriority;

  void addSos(SosPacket packet) {
    sosHistory.insert(0, packet);
    notifyListeners();
  }

  SosPacket? sosById(String id) {
    for (final packet in sosHistory) {
      if (packet.id == id) return packet;
    }
    return null;
  }

  /// Updates an SOS this device sent. Forward-only (see
  /// [SosStatus.canMoveTo]): a confirmation from the Rescue Team can never
  /// be downgraded by a late hop ACK, a backend result or a send error.
  /// Returns whether anything changed.
  bool updateSosStatus(String id, SosStatus status) {
    final index = sosHistory.indexWhere((p) => p.id == id);
    if (index == -1) return false;

    final packet = sosHistory[index];
    if (!packet.status.canMoveTo(status)) return false;

    packet.status = status;
    if (status.reachedRescue) {
      packet.acknowledgedAt ??= DateTime.now();
    }
    notifyListeners();
    return true;
  }

  /// The delivery layer updated an SOS object held in [sosHistory] in place.
  void notifySosChanged() => notifyListeners();

  void addMessage(EmergencyMessage message) {
    messages.add(message);
    if (messages.length > maxMessages) {
      messages.removeRange(0, messages.length - maxMessages);
    }
    notifyListeners();
  }

  void setLocation(LocationData location) {
    currentLocation = location;
    notifyListeners();
  }

  /// Inserts or updates a rescue case, keyed by id, regardless of whether
  /// it arrived over BLE or over the backend HTTP path.
  void upsertRescueCase(RescueCase newCase) {
    final index = rescueCases.indexWhere((c) => c.id == newCase.id);
    if (index == -1) {
      rescueCases.insert(0, newCase);
    } else {
      rescueCases[index] = newCase;
    }
    notifyListeners();
  }

  bool hasRescueCase(String id) => rescueCases.any((c) => c.id == id);

  void updateRescueCaseStatus(String id, RescueStatus status) {
    final index = rescueCases.indexWhere((c) => c.id == id);
    if (index == -1) return;
    rescueCases[index].status = status;
    notifyListeners();
  }

  void updateAckDelivery(String id, AckDelivery delivery) {
    final index = rescueCases.indexWhere((c) => c.id == id);
    if (index == -1) return;
    if (rescueCases[index].ackDelivery == delivery) return;
    rescueCases[index].ackDelivery = delivery;
    notifyListeners();
  }

  void setAiPriority(AiPriorityResult result) {
    lastAiPriority = result;
    notifyListeners();
  }
}
