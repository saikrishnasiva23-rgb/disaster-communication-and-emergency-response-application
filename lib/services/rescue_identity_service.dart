import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stable app-level identity of this Rescue Team console (Windows laptop):
/// 'rescue-console-<8 hex>', generated once and stored. Used in its BLE
/// HELLO, as the signer of its end-to-end ACKs, as the audit actor and as
/// the cloud sync device id -- never the BLE address.
class RescueIdentityService {
  RescueIdentityService._();

  static const _storageKey = 'rescue_console_device_id';
  static const _storage = FlutterSecureStorage();
  static const String displayName = 'Rescue Command Center';

  static String? _cached;
  static Future<String>? _pending;

  static Future<String> getOrCreateId() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _pending ??= _load().whenComplete(() => _pending = null);
  }

  static Future<String> _load() async {
    String? existing;
    try {
      existing = await _storage.read(key: _storageKey);
    } catch (_) {}
    if (existing != null && existing.isNotEmpty) return _cached = existing;

    final random = Random.secure();
    final id = 'rescue-console-${List.generate(8, (_) => '0123456789abcdef'[random.nextInt(16)]).join()}';
    try {
      await _storage.write(key: _storageKey, value: id);
    } catch (_) {}
    return _cached = id;
  }
}
