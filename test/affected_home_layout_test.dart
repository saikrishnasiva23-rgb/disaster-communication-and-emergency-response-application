// Layout regression test for the Affected Person screens: Home, Nearby,
// Messages and Settings must lay out without any RenderFlex overflow on
// small and large screens, with large font sizes, in light and dark mode,
// and keep their content above the bottom navigation and the system
// navigation bar (Android 15+ draws apps edge-to-edge).

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:disaster_communication_app/main.dart';
import 'package:disaster_communication_app/services/local_store.dart';
import 'package:disaster_communication_app/services/mesh/mesh_service.dart';
import 'package:disaster_communication_app/state/theme_controller.dart';

const _tools = [
  'My Location',
  'AI Priority',
  'Hospitals',
  'Relief Camps',
  'Contacts',
  'Request Rescue',
  'SOS History',
];

/// (logical width, height, font scale, dark) -- small phone, common phones,
/// the OPPO A5 Pro 5G class (393 x 873), large fonts, a tablet.
const _screens = [
  (320.0, 568.0, 1.0, false),
  (360.0, 800.0, 1.0, true),
  (360.0, 800.0, 1.3, false),
  (393.0, 873.0, 1.0, false),
  (393.0, 873.0, 1.5, true),
  (412.0, 915.0, 1.15, false),
  (800.0, 1280.0, 1.0, false),
];

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    LocalStore.useMemoryForTesting();
  });

  for (final (width, height, scale, dark) in _screens) {
    testWidgets('Affected screens lay out without overflow at '
        '${width.toInt()}x${height.toInt()} dp, font x$scale${dark ? ', dark' : ''}',
        (tester) async {
      const dpr = 2.75;
      const navigationBar = 48.0;
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(width * dpr, height * dpr);
      tester.view.padding = const FakeViewPadding(bottom: navigationBar * dpr);
      tester.view.viewPadding = const FakeViewPadding(bottom: navigationBar * dpr);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // Isolation: a previous test that failed half-way must not leave the
      // app-lifetime mesh node behind.
      await tester.runAsync(() => MeshService.instance.resetForTesting());

      await tester.pumpWidget(MyApp(
        themeController: ThemeController(initial: dark ? ThemeMode.dark : ThemeMode.light),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Affected Person'));
      await tester.pumpAndSettle();

      // Home: scroll through the whole screen; any overflow while laying
      // out a section fails the test.
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('SOS History'), 250, scrollable: list);
      await tester.drag(list, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      for (final tool in _tools) {
        expect(find.text(tool), findsOneWidget, reason: '$tool tile is missing');
      }

      // The last tile stays fully above the bottom navigation / system bar.
      final lastCard = tester.getRect(
          find.ancestor(of: find.text('SOS History'), matching: find.byType(Card)));
      final navTop = width >= 840
          ? height - navigationBar
          : tester.getRect(find.byType(NavigationBar)).top;
      expect(lastCard.bottom, lessThanOrEqualTo(navTop),
          reason: 'last tool row hidden behind the navigation bar');

      // Every tab lays out cleanly too.
      for (final tab in ['Nearby', 'Messages', 'Settings', 'Home']) {
        await tester.tap(find.descendant(
            of: find.byType(NavigationBar), matching: find.text(tab)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$tab tab overflowed');
      }

      // Tiles still navigate.
      await tester.scrollUntilVisible(find.text('SOS History'), 250, scrollable: list);
      await tester.tap(find.text('SOS History'));
      await tester.pumpAndSettle();
      expect(find.text('No SOS sent yet'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => MeshService.instance.resetForTesting());
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
