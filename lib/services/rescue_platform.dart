import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Decides which Rescue Team screen a device should open. Windows laptops
/// get the Rescue Command Center (lib/screens/rescue_command_center_screen.dart);
/// every other platform keeps the existing Android-oriented
/// RescueHomeScreen. `Platform.isWindows` throws on web, so [kIsWeb] is
/// checked first.
class RescuePlatform {
  RescuePlatform._();

  static bool get isWindowsRescueConsole => !kIsWeb && Platform.isWindows;
}
