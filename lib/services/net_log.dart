import 'package:flutter/foundation.dart';

/// One line of the network event log.
@immutable
class NetLogEntry {
  const NetLogEntry(this.time, this.tag, this.message);

  final DateTime time;
  final String tag;
  final String message;

  @override
  String toString() {
    final t = time.toIso8601String().substring(11, 23);
    return '$t [$tag] $message';
  }
}

/// Tagged, human-readable log of every BLE / relay / rescue / sync step,
/// e.g. `[BLE] Connected`, `[RELAY] Duplicate detected`, `[SYNC] Upload
/// successful`. Printed to the console and kept in a ring buffer so the
/// app's diagnostics panel can show it on a physical test device.
///
/// Never log message text, exact coordinates, passwords or tokens: entries
/// carry packet ids, device names, counts and states only.
class NetLog {
  NetLog._();

  static const int capacity = 400;

  static final ValueNotifier<List<NetLogEntry>> entries =
      ValueNotifier(const []);

  static void ble(String message) => _add('BLE', message);
  static void relay(String message) => _add('RELAY', message);
  static void rescue(String message) => _add('RESCUE', message);
  static void sos(String message) => _add('SOS', message);
  static void sync(String message) => _add('SYNC', message);
  static void store(String message) => _add('STORE', message);

  static void _add(String tag, String message) {
    final entry = NetLogEntry(DateTime.now(), tag, message);
    debugPrint(entry.toString());
    final next = <NetLogEntry>[entry, ...entries.value];
    if (next.length > capacity) next.removeRange(capacity, next.length);
    entries.value = List.unmodifiable(next);
  }

  /// "gps ok (±12 m)" -- never the coordinates themselves.
  static String gps(double? lat, double? lon, [double? accuracy]) {
    if (lat == null || lon == null) return 'no gps';
    return accuracy == null ? 'gps ok' : 'gps ok (±${accuracy.round()} m)';
  }

  @visibleForTesting
  static void clear() => entries.value = const [];
}
