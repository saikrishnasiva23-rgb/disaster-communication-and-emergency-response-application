// The app's entry point is RoleSelectionScreen (not the stock counter app).

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/main.dart';
import 'package:disaster_communication_app/services/local_store.dart';
import 'package:disaster_communication_app/services/mesh/mesh_service.dart';
import 'package:disaster_communication_app/state/theme_controller.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // Real file I/O never completes inside a widget test's fake-async zone.
    LocalStore.useMemoryForTesting();
    // The native Android GATT server does not exist on the test host:
    // AndroidPeripheralTransport reports "unsupported" there, so the
    // screen's honest failure path is exercised deterministically.
  });

  testWidgets('App boots to the role selection screen', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Emergency Response Network'), findsOneWidget);
    expect(find.text('Affected Person'), findsOneWidget);
    expect(find.text('Rescue Team'), findsOneWidget);
  });

  testWidgets('Theme follows the saved choice: system by default, dark on request',
      (tester) async {
    final theme = ThemeController();
    await tester.pumpWidget(MyApp(themeController: theme));
    await tester.pumpAndSettle();

    var app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme?.brightness, Brightness.light);
    expect(app.darkTheme?.brightness, Brightness.dark);

    await tester.runAsync(() => theme.setMode(ThemeMode.dark));
    await tester.pumpAndSettle();
    app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    // Persisted: a fresh controller restores it.
    final restored = ThemeController();
    await tester.runAsync(restored.load);
    expect(restored.mode, ThemeMode.dark);
  });

  testWidgets(
    'Affected Person screen shows the real (not connected) link state, never '
    'a fake connected state',
    (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Affected Person'));
      await tester.pumpAndSettle();

      // With no Bluetooth on the test host the status honestly reports
      // offline, and nothing claims a connection.
      expect(find.text('Emergency Status'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('No devices connected'), findsOneWidget);

      // The SOS action is on the home screen.
      await tester.scrollUntilVisible(find.text('SEND SOS'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('SEND SOS'), findsOneWidget);
      expect(find.text('Hold to send'), findsOneWidget);
      expect(find.text('Saved and sent when a device connects'), findsOneWidget);

      // Nearby tab: no invented devices.
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Nearby')));
      await tester.pumpAndSettle();
      expect(find.text('No devices connected'), findsWidgets);
      expect(find.text('Connected'), findsNothing);

      // Messages tab: sending is disabled while no Rescue Team is connected.
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Messages')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rescue Team not connected'), findsOneWidget);
      final send = tester.widget<IconButton>(
          find.ancestor(of: find.byIcon(Icons.send), matching: find.byType(IconButton)));
      expect(send.onPressed, isNull);

      // Settings tab: theme selector and the relay preference are present.
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Settings')));
      await tester.pumpAndSettle();
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Relay nearby alerts'), findsOneWidget);

      // Leave the screen, then release the app-lifetime mesh node.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => MeshService.instance.resetForTesting());
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
