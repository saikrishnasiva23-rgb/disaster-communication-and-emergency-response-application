import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'native_bridge.dart';

/// A stable, per-installation identity for this Affected Person device,
/// used as SosPacket/EmergencyMessage's `senderId`.
///
/// Phase 3 (multiple simultaneous affected-person connections) requires
/// that "only Person 1's identity should be associated with that SOS" and
/// that Person 1's and Person 2's state are never conflated. Before this,
/// sos_screen.dart hardcoded every device's senderId to the literal string
/// 'affected_person' -- two phones would have sent indistinguishable
/// identities, defeating exactly the separation this phase requires. This
/// generates one random id the first time a device sends anything, stores
/// it, and reuses it for the lifetime of the app install -- not fake, not
/// re-randomized per message, and never shared with another device.
class AffectedIdentityService {
  AffectedIdentityService._();

  static const _storageKey = 'affected_person_device_id';
  static const _storage = FlutterSecureStorage();

  static String? _cached;
  static Future<String>? _pending;

  /// Concurrent first calls share one future, so a first launch can never
  /// generate (and send) two different ids.
  static Future<String> getOrCreateId() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _pending ??= _loadOrCreate().whenComplete(() => _pending = null);
  }

  static Future<String> _loadOrCreate() async {
    final existing = await _storage.read(key: _storageKey);
    if (existing != null && existing.isNotEmpty) {
      _cached = existing;
      return existing;
    }

    final generated = _generateId();
    await _storage.write(key: _storageKey, value: generated);
    _cached = generated;
    return generated;
  }

  static String _generateId() {
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => '0123456789abcdef'[random.nextInt(16)],
    ).join();
    return 'affected-$suffix';
  }

  static String? _cachedDisplayName;

  /// The phone's real, user-visible name as Android reports it (e.g. "OPPO
  /// A5 Pro 5G"). This travels inside the GATT HELLO/SOS packets -- never in
  /// the BLE advertisement, which is too small for it.
  ///
  /// Only if Android provides no name at all does this fall back to a
  /// short label derived from the real generated device id, e.g.
  /// "Affected Person (3f9a)" -- clearly a fallback, never a fake model name.
  static Future<String> getDisplayName() async {
    final cached = _cachedDisplayName;
    if (cached != null) return cached;

    final native = await NativeBridge.deviceName();
    if (native != null) {
      _cachedDisplayName = native;
      return native;
    }

    final id = await getOrCreateId();
    final suffix = id.length >= 4 ? id.substring(id.length - 4) : id;
    final fallback = 'Affected Person ($suffix)';
    _cachedDisplayName = fallback;
    return fallback;
  }
}
