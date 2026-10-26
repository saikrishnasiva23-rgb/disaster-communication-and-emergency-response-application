import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Spacing scale used by every screen.
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  /// Horizontal page padding.
  static const double page = 16;
}

/// Corner radii.
class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;
}

/// Semantic status colours tuned for each brightness.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.success,
    required this.warning,
    required this.info,
    required this.danger,
    required this.neutral,
    required this.critical,
    required this.high,
    required this.medium,
    required this.low,
  });

  final Color success;
  final Color warning;
  final Color info;
  final Color danger;
  final Color neutral;

  // Priority levels.
  final Color critical;
  final Color high;
  final Color medium;
  final Color low;

  static const light = StatusColors(
    success: AppColors.success,
    warning: AppColors.warning,
    info: AppColors.info,
    danger: AppColors.emergency,
    neutral: AppColors.offline,
    critical: AppColors.priorityCritical,
    high: AppColors.priorityHigh,
    medium: AppColors.priorityMedium,
    low: AppColors.priorityLow,
  );

  static const dark = StatusColors(
    success: Color(0xFF5CC27A),
    warning: Color(0xFFF2B33D),
    info: Color(0xFF6CB2F5),
    danger: Color(0xFFF2675B),
    neutral: Color(0xFF9AA3B2),
    critical: Color(0xFFF2675B),
    high: Color(0xFFFF8A5C),
    medium: Color(0xFFF2B33D),
    low: Color(0xFF5CC27A),
  );

  @override
  StatusColors copyWith({
    Color? success,
    Color? warning,
    Color? info,
    Color? danger,
    Color? neutral,
    Color? critical,
    Color? high,
    Color? medium,
    Color? low,
  }) =>
      StatusColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        info: info ?? this.info,
        danger: danger ?? this.danger,
        neutral: neutral ?? this.neutral,
        critical: critical ?? this.critical,
        high: high ?? this.high,
        medium: medium ?? this.medium,
        low: low ?? this.low,
      );

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
      high: Color.lerp(high, other.high, t)!,
      medium: Color.lerp(medium, other.medium, t)!,
      low: Color.lerp(low, other.low, t)!,
    );
  }
}

extension StatusColorsContext on BuildContext {
  /// The status colours for the current theme.
  StatusColors get status =>
      Theme.of(this).extension<StatusColors>() ?? StatusColors.light;
}

/// The app's one ThemeData for light and dark mode.
class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final background = isDark ? AppColors.backgroundDark : AppColors.backgroundLight;
    final surface = isDark ? AppColors.surfaceDark : AppColors.surfaceLight;
    final surfaceVariant =
        isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariantLight;
    final border = isDark ? AppColors.borderDark : AppColors.borderLight;
    final text = isDark ? AppColors.textDark : AppColors.textLight;
    final muted = isDark ? AppColors.mutedDark : AppColors.mutedLight;
    final status = isDark ? StatusColors.dark : StatusColors.light;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: brightness,
    ).copyWith(
      primary: AppColors.brand,
      onPrimary: Colors.white,
      primaryContainer: AppColors.brand.withValues(alpha: isDark ? 0.24 : 0.12),
      onPrimaryContainer: isDark ? const Color(0xFFFFB4A4) : AppColors.brandDark,
      secondary: isDark ? const Color(0xFF9DB3D9) : const Color(0xFF2F4A73),
      onSecondary: isDark ? AppColors.backgroundDark : Colors.white,
      error: status.danger,
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: muted,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surface,
      surfaceContainer: surfaceVariant,
      surfaceContainerHigh: surfaceVariant,
      surfaceContainerHighest: surfaceVariant,
      outline: muted.withValues(alpha: 0.6),
      outlineVariant: border,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
    );

    final textTheme = base.textTheme
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall
              ?.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
          titleLarge: base.textTheme.titleLarge
              ?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
          titleMedium: base.textTheme.titleMedium
              ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
          titleSmall: base.textTheme.titleSmall
              ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 15),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
          bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12.5, color: muted),
          labelLarge: base.textTheme.labelLarge
              ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
          labelMedium: base.textTheme.labelMedium
              ?.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
        )
        .apply(bodyColor: text, displayColor: text);

    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md));

    return base.copyWith(
      scaffoldBackgroundColor: background,
      textTheme: textTheme,
      extensions: [status],
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: rounded,
          textStyle: textTheme.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(64, 48),
          shape: rounded,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 44),
          shape: rounded,
          side: BorderSide(color: border),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 44),
          shape: rounded,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
        side: BorderSide(color: border),
        backgroundColor: surface,
        selectedColor: colorScheme.primaryContainer,
        checkmarkColor: colorScheme.onPrimaryContainer,
        labelStyle: textTheme.labelMedium?.copyWith(color: text),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.brand, width: 1.6),
        ),
        hintStyle: TextStyle(color: muted),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colorScheme.primaryContainer,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected) ? colorScheme.primary : muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? colorScheme.primary : muted,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: colorScheme.primaryContainer,
        selectedIconTheme: const IconThemeData(color: AppColors.brand),
        unselectedIconTheme: IconThemeData(color: muted),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: colorScheme.primaryContainer,
          selectedForegroundColor: colorScheme.onPrimaryContainer,
          side: BorderSide(color: border),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? Colors.white : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.brand : null,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        shape: rounded,
      ),
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: rounded,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.brand),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
      ),
    );
  }
}
