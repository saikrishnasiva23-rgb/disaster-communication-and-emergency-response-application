import 'dart:convert';

class EmergencyMessage {
  final String id;
  final String type;
  final String senderId;
  final String text;
  final DateTime timestamp;
  final bool fromLocalUser;
  bool delivered;

  EmergencyMessage({
    required this.id,
    this.type = 'MESSAGE',
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.fromLocalUser,
    this.delivered = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'senderId': senderId,
        'text': text,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  factory EmergencyMessage.fromJson(
    Map<String, dynamic> json, {
    required bool fromLocalUser,
  }) {
    return EmergencyMessage(
      id: json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      type: json['type'] as String? ?? 'MESSAGE',
      senderId: json['senderId'] as String? ?? 'unknown',
      text: json['text'] as String? ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
              DateTime.now(),
      fromLocalUser: fromLocalUser,
      delivered: true,
    );
  }

  /// Wire format for the BLE GATT characteristic -- matches the shape
  /// BluetoothRescueService's receive handler dispatches on `type` for.
  String toWireBytes() => jsonEncode(toJson());
}
