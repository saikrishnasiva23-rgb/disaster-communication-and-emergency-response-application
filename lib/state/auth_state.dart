import 'package:flutter/foundation.dart';

/// Rescue Team session state. AuthState only tracks whether a session is
/// active; the actual credential check lives in AuthService (Phase 2.2),
/// which is backed by flutter_secure_storage rather than a hardcoded
/// password in source.
class AuthState extends ChangeNotifier {
  bool isAuthenticated = false;
  String? rescueId;
  DateTime? loginAt;

  void login(String id) {
    isAuthenticated = true;
    rescueId = id;
    loginAt = DateTime.now();
    notifyListeners();
  }

  void logout() {
    isAuthenticated = false;
    rescueId = null;
    loginAt = null;
    notifyListeners();
  }
}
