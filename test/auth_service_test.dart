import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/services/auth_service.dart';

void main() {
  // flutter_secure_storage's own test seam: swaps the platform
  // implementation for an in-memory one, so this exercises AuthService's
  // real read/write/verify logic without needing a real Keystore/DPAPI
  // backend (unavailable in a plain `flutter_test` run).
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('AuthService', () {
    test('hasCredentials is false before any credential is set', () async {
      expect(await AuthService.instance.hasCredentials(), isFalse);
    });

    test('correct credentials verify successfully', () async {
      await AuthService.instance.setCredentials('dis_comm', '123456789');

      expect(await AuthService.instance.hasCredentials(), isTrue);
      expect(await AuthService.instance.verify('dis_comm', '123456789'), isTrue);
    });

    test('wrong password fails verification', () async {
      await AuthService.instance.setCredentials('dis_comm', '123456789');

      expect(await AuthService.instance.verify('dis_comm', 'wrong'), isFalse);
    });

    test('wrong id fails verification even with the right password', () async {
      await AuthService.instance.setCredentials('dis_comm', '123456789');

      expect(
        await AuthService.instance.verify('someone_else', '123456789'),
        isFalse,
      );
    });

    test('verify fails safely when no credential has ever been set', () async {
      expect(await AuthService.instance.verify('dis_comm', '123456789'), isFalse);
    });

    test('the password is never stored in plain text', () async {
      await AuthService.instance.setCredentials('dis_comm', '123456789');

      final storage = const FlutterSecureStorage();
      final all = await storage.readAll();

      // Every stored value must differ from the raw password -- it should
      // only ever be present as a salted hash.
      for (final value in all.values) {
        expect(value, isNot('123456789'));
      }
    });

    test('clearCredentials removes the credential entirely', () async {
      await AuthService.instance.setCredentials('dis_comm', '123456789');
      await AuthService.instance.clearCredentials();

      expect(await AuthService.instance.hasCredentials(), isFalse);
      expect(await AuthService.instance.verify('dis_comm', '123456789'), isFalse);
    });

    test('seedDefaultDemoCredentialsIfNeeded provisions dis_comm/123456789 '
        'when nothing is set yet', () async {
      await AuthService.instance.seedDefaultDemoCredentialsIfNeeded();

      expect(await AuthService.instance.verify('dis_comm', '123456789'), isTrue);
    });

    test('seedDefaultDemoCredentialsIfNeeded never overwrites an existing '
        'credential', () async {
      await AuthService.instance.setCredentials('someone_else', 'their-password');

      await AuthService.instance.seedDefaultDemoCredentialsIfNeeded();

      expect(
        await AuthService.instance.verify('someone_else', 'their-password'),
        isTrue,
      );
      expect(await AuthService.instance.verify('dis_comm', '123456789'), isFalse);
    });
  });
}
