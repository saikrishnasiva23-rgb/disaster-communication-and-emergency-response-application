enum LocationFreshness { live, recent, unavailable }

class LocationData {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime capturedAt;

  const LocationData({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    required this.capturedAt,
  });

  /// A fix older than this is no longer shown as "live".
  static const Duration liveWindow = Duration(seconds: 30);

  /// A fix older than this is no longer usable and is shown as
  /// "unavailable" rather than stale data mislabeled as live.
  static const Duration recentWindow = Duration(minutes: 10);

  LocationFreshness freshnessAt(DateTime now) {
    final age = now.difference(capturedAt);
    if (age <= liveWindow) return LocationFreshness.live;
    if (age <= recentWindow) return LocationFreshness.recent;
    return LocationFreshness.unavailable;
  }

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'capturedAt': capturedAt.toUtc().toIso8601String(),
      };

  factory LocationData.fromJson(Map<String, dynamic> json) => LocationData(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
        capturedAt: DateTime.tryParse(json['capturedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
