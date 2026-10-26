import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the app's own Android method channel (MainActivity.kt).
/// Every call is a no-op / null off Android, so widget tests and the
/// Windows build never touch it.
class NativeBridge {
  NativeBridge._();

  static const MethodChannel _channel =
      MethodChannel('disaster_communication/mesh');

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// The phone's real user-visible name (e.g. "OPPO A5 Pro 5G"), or null.
  static Future<String?> deviceName() async {
    if (!_isAndroid) return null;
    try {
      final name = await _channel.invokeMethod<String>('deviceName');
      final trimmed = name?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } catch (e) {
      debugPrint('NativeBridge.deviceName failed: $e');
      return null;
    }
  }

  static Future<void> setKeepScreenOn(bool on) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('keepScreenOn', on);
    } catch (e) {
      debugPrint('NativeBridge.keepScreenOn failed: $e');
    }
  }
}
