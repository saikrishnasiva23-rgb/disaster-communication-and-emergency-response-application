import 'sos_packet.dart';
import 'ai_priority_result.dart';

enum RescueStatus { pending, assigned, inProgress, rescued }

RescueStatus rescueStatusFromString(String value) {
  switch (value.toLowerCase()) {
    case 'assigned':
      return RescueStatus.assigned;
    case 'in_progress':
    case 'inprogress':
      return RescueStatus.inProgress;
    case 'rescued':
      return RescueStatus.rescued;
    default:
      return RescueStatus.pending;
  }
}

/// Where this case was received from. Kept explicit so the Rescue Team
/// dashboard never blurs a BLE-received distress signal (works with no
/// internet) with one that only arrived because the Flask backend happened
/// to be reachable.
enum RescueCaseSource { ble, backend }

/// Whether the Rescue Team's BLE acknowledgement actually reached the
/// phone's GATT server. Tracked per case so the UI never implies an ACK
/// that failed to go out.
enum AckDelivery { notApplicable, sending, sent, failed }

/// A single entry on the Rescue Team dashboard, whether it arrived as a
/// live BLE SosPacket or as a row from the backend's rescue_requests table.
class RescueCase {
  final String id;

  /// Original sender's human-readable name -- never overwritten by a relay.
  final String name;
  final String emergencyType;
  final int numberOfPeople;
  final bool injured;

  /// Null when the sender had no GPS fix -- shown as "Location unavailable",
  /// never as a made-up coordinate.
  final double? latitude;
  final double? longitude;
  final String message;
  final RescueCaseSource source;
  RescueStatus status;
  AiPriorityResult? aiPriority;
  final DateTime receivedAt;

  /// When the location fix was actually captured on the sender's device
  /// -- NOT when this device received it. Feeds
  /// LocationData.freshnessAt so the UI can honestly show LIVE / RECENT /
  /// UNAVAILABLE instead of implying every received case is "live".
  final DateTime capturedAt;

  /// Set only when this SOS reached the Rescue Team via a BLE
  /// store-and-forward relay -- the display name of the phone that relayed
  /// it, distinct from [name] (the original sender).
  final String? relayedByName;
  final int hopCount;

  /// The original sender's stable device id (SosPacket.senderId).
  final String? senderId;

  /// The BLE link this case physically arrived on: that link's display
  /// name and technical address (the address is for diagnostics/write-back
  /// only, never the primary UI label).
  final String? sourceDeviceName;
  final String? sourceAddress;

  /// The sender's own priority estimate carried in the packet.
  final String senderPriority;

  AckDelivery ackDelivery;

  /// Device ids of every relay the SOS passed through, oldest first.
  final List<String> relayPath;

  /// The packet's origin MAC verified (false: older build without a MAC).
  final bool authenticated;

  /// GPS accuracy reported by the origin phone, if any.
  final double? accuracyMeters;

  RescueCase({
    required this.id,
    required this.name,
    required this.emergencyType,
    required this.numberOfPeople,
    required this.injured,
    required this.latitude,
    required this.longitude,
    required this.message,
    required this.source,
    this.status = RescueStatus.pending,
    this.aiPriority,
    required this.receivedAt,
    required this.capturedAt,
    this.relayedByName,
    this.hopCount = 0,
    this.senderId,
    this.sourceDeviceName,
    this.sourceAddress,
    this.senderPriority = 'UNKNOWN',
    this.ackDelivery = AckDelivery.notApplicable,
    this.relayPath = const [],
    this.authenticated = false,
    this.accuracyMeters,
  });

  bool get hasLocation => latitude != null && longitude != null;

  bool get isRelayed => hopCount > 0;

  factory RescueCase.fromSosPacket(
    SosPacket packet, {
    String? sourceDeviceName,
    String? sourceAddress,
    DateTime? receivedAt,
    bool authenticated = false,
  }) =>
      RescueCase(
        id: packet.id,
        // Prefer the human-readable label; fall back to the raw device id
        // for packets from a sender too old to set it (never blank).
        name: packet.displayName,
        emergencyType: packet.emergencyType,
        numberOfPeople: packet.numberOfPeople,
        injured: packet.injured,
        latitude: packet.latitude,
        longitude: packet.longitude,
        message: packet.message,
        source: RescueCaseSource.ble,
        receivedAt: receivedAt ?? DateTime.now(),
        // The GPS fix time from the sending phone (it may be an older last
        // known position), else the SOS creation time -- never receipt time.
        capturedAt: packet.fixTime ?? packet.timestamp,
        relayedByName: packet.relayedByName,
        hopCount: packet.hopCount,
        senderId: packet.senderId,
        sourceDeviceName: sourceDeviceName,
        sourceAddress: sourceAddress,
        senderPriority: packet.priority,
        ackDelivery: sourceAddress != null
            ? AckDelivery.sending
            : AckDelivery.notApplicable,
        relayPath: packet.path,
        authenticated: authenticated,
        accuracyMeters: packet.accuracyMeters,
      );

  /// `backend/app.py`'s GET /api/rescue-requests row shape: id, name,
  /// emergency_type, number_of_people, injured, latitude, longitude,
  /// message, status, priority_score, priority_level.
  factory RescueCase.fromBackendJson(Map<String, dynamic> json) => RescueCase(
        id: json['id'].toString(),
        name: json['name']?.toString() ?? 'Unknown',
        emergencyType: json['emergency_type']?.toString() ?? 'Unknown',
        numberOfPeople:
            int.tryParse(json['number_of_people']?.toString() ?? '') ?? 1,
        injured:
            (json['injured']?.toString().toLowerCase() ?? 'no') == 'yes',
        // Null stays null: a request without GPS is "location unavailable",
        // never 0,0.
        latitude: double.tryParse(json['latitude']?.toString() ?? ''),
        longitude: double.tryParse(json['longitude']?.toString() ?? ''),
        message: json['message']?.toString() ?? '',
        source: RescueCaseSource.backend,
        status:
            rescueStatusFromString(json['status']?.toString() ?? 'pending'),
        aiPriority: AiPriorityResult(
          level: aiPriorityFromString(
              json['priority_level']?.toString() ?? 'low'),
          confidence:
              double.tryParse(json['priority_score']?.toString() ?? '') ?? 0,
          reason: 'Scored by the backend RandomForest model.',
          source: AiPrioritySource.backendModel,
          computedAt: DateTime.now(),
        ),
        receivedAt: DateTime.now(),
        // The backend's rescue_requests table has no capture-time column
        // (see backend/app.py's schema) -- receipt time is the best
        // available proxy, since a backend submission normally happens
        // immediately after the affected person's phone gets a GPS fix.
        capturedAt: DateTime.now(),
      );
}
