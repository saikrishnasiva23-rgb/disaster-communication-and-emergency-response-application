import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Rescue Team credential storage and verification.
///
/// The credential is never compared as a literal string in source -- it
/// lives in Android Keystore-backed secure storage (flutter_secure_storage)
/// and is only ever read back for comparison. On first run there is no
/// stored credential; the Rescue Team must set one before authentication
/// is possible (RescueAuthScreen, wired up in Phase 2.3).
///
/// Final QA pass: the password used to be written to secure storage as
/// plain text. flutter_secure_storage is itself encrypted at rest
/// (Android Keystore / Windows DPAPI), but storing a salted SHA-256 hash
/// instead means the real password is never recoverable from storage even
/// in that layer -- only [verify] can ever confirm a match, never read the
/// password back out.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _storage = FlutterSecureStorage();
  static const _rescueIdKey = 'rescue_id';
  static const _rescuePasswordHashKey = 'rescue_password_hash';
  static const _rescuePasswordSaltKey = 'rescue_password_salt';

  Future<bool> hasCredentials() async {
    final id = await _storage.read(key: _rescueIdKey);
    return id != null && id.isNotEmpty;
  }

  /// Writes the password hash/salt FIRST and the id LAST, deliberately. If
  /// the app is killed between the writes (OS memory pressure, force-stop,
  /// a crash elsewhere), [hasCredentials] only checks the id key -- so an
  /// interruption leaves it correctly reporting "not set up yet" and the
  /// setup form simply reappears next launch. The previous ordering
  /// (id first) meant an interruption left hasCredentials() permanently
  /// true while verify() could never succeed (no password to check
  /// against), locking the Rescue Team out with no in-app recovery.
  Future<void> setCredentials(String rescueId, String password) async {
    final salt = _generateSalt();
    final hash = _hash(password, salt);

    await _storage.write(key: _rescuePasswordSaltKey, value: salt);
    await _storage.write(key: _rescuePasswordHashKey, value: hash);
    await _storage.write(key: _rescueIdKey, value: rescueId);
  }

  /// Returns true only if both the Rescue ID and password match what was
  /// stored via [setCredentials].
  Future<bool> verify(String rescueId, String password) async {
    final storedId = await _storage.read(key: _rescueIdKey);
    final storedHash = await _storage.read(key: _rescuePasswordHashKey);
    final salt = await _storage.read(key: _rescuePasswordSaltKey);

    if (storedId == null || storedHash == null || salt == null) return false;

    return storedId == rescueId && _hash(password, salt) == storedHash;
  }

  Future<void> clearCredentials() async {
    await _storage.delete(key: _rescueIdKey);
    await _storage.delete(key: _rescuePasswordHashKey);
    await _storage.delete(key: _rescuePasswordSaltKey);
  }

  /// Provisions the default development/demo credential (Rescue ID
  /// "dis_comm", password "123456789") ONLY if no credential exists yet --
  /// it never overwrites a Rescue ID/password someone has already set.
  /// Stored through the exact same hashed path as any other credential;
  /// this is not a hardcoded literal comparison anywhere in the login
  /// flow, just a convenience seed so the demo doesn't require a manual
  /// first-run setup step. Call once at app startup.
  ///
  /// This exists for development/demo convenience only -- a real
  /// production build should not auto-provision a known credential; see
  /// the FINAL INTEGRATION report for this caveat.
  Future<void> seedDefaultDemoCredentialsIfNeeded() async {
    if (await hasCredentials()) return;
    await setCredentials('dis_comm', '123456789');
  }

  String _generateSalt() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String _hash(String password, String salt) {
    return sha256.convert(utf8.encode('$salt:$password')).toString();
  }
}
