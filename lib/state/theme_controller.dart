import 'package:flutter/material.dart';

import '../services/local_store.dart';

/// The user's theme choice (System / Light / Dark), saved on the device.
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeMode initial = ThemeMode.system}) : _mode = initial;

  static const _document = 'ui_prefs';
  static const _key = 'themeMode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Restores the saved choice. A missing or unreadable value keeps the
  /// current mode.
  Future<void> load() async {
    try {
      final doc = await LocalStore.read(_document);
      final saved = _parse(doc?[_key]);
      if (saved != null && saved != _mode) {
        _mode = saved;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Theme preference not loaded: $e');
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final doc = await LocalStore.read(_document) ?? <String, dynamic>{};
      doc[_key] = mode.name;
      await LocalStore.write(_document, doc);
    } catch (e) {
      debugPrint('Theme preference not saved: $e');
    }
  }

  static ThemeMode? _parse(Object? value) {
    for (final mode in ThemeMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}
