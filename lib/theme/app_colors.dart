import 'package:flutter/material.dart';

/// The app's colour tokens. Screens read colours from the theme
/// (`Theme.of(context).colorScheme` and `context.status`) so light and dark
/// mode both work; these constants are the source values behind them.
///
/// Semantic colours always mean the same thing wherever they appear.
class AppColors {
  AppColors._();

  // Brand accent: the SOS action, primary buttons, active navigation,
  // selected controls.
  static const Color brand = Color(0xFFFF5A3D);
  static const Color brandDark = Color(0xFFE0442A);

  // Semantic status colours (light-mode values; dark-mode values live in
  // StatusColors.dark).
  static const Color emergency = Color(0xFFD32F2F); // critical / error
  static const Color emergencyDark = Color(0xFFB71C1C);
  static const Color success = Color(0xFF2E7D32); // connected / confirmed
  static const Color warning = Color(0xFFB26A00); // waiting / degraded
  static const Color info = Color(0xFF1565C0); // in progress
  static const Color offline = Color(0xFF6B7280); // unknown / neutral

  // Priority levels (AiPriorityLevel).
  static const Color priorityCritical = Color(0xFFB71C1C);
  static const Color priorityHigh = Color(0xFFE8590C);
  static const Color priorityMedium = Color(0xFFB26A00);
  static const Color priorityLow = Color(0xFF2E7D32);

  // Kept for the few places that still need a fixed dark accent.
  static const Color navy = Color(0xFF0B2545);

  // Neutrals -- light.
  static const Color backgroundLight = Color(0xFFF6F7F9);
  static const Color surfaceLight = Colors.white;
  static const Color surfaceVariantLight = Color(0xFFF0F2F5);
  static const Color borderLight = Color(0xFFE3E6EB);
  static const Color textLight = Color(0xFF111827);
  static const Color mutedLight = Color(0xFF5B6472);

  // Neutrals -- dark.
  static const Color backgroundDark = Color(0xFF0E1320);
  static const Color surfaceDark = Color(0xFF171E2E);
  static const Color surfaceVariantDark = Color(0xFF1F2738);
  static const Color borderDark = Color(0xFF2B3446);
  static const Color textDark = Color(0xFFF3F4F6);
  static const Color mutedDark = Color(0xFFA3ABB9);
}
