import 'package:flutter/material.dart';

import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// 由语义 Token 构建 Material 3 主题（极简书房 Editorial Minimalism）。
/// 组件层只消费 Token：所有颜色来自 [EchoTokens]，所有尺度来自 [EchoMetrics]。
/// 深色为品牌基准态（dark-first），亮色由同一函数以 light Token 构建。
ThemeData buildEchoTheme(Brightness brightness, EchoTokens tokens) {
  final isDark = brightness == Brightness.dark;
  final hairline = isDark
      ? Colors.white.withValues(alpha: 0.08)
      : tokens.surfaceSubtle;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: tokens.primary,
    onPrimary: tokens.textOnPrimary,
    primaryContainer: tokens.surfaceElevated,
    onPrimaryContainer: tokens.textPrimary,
    secondary: tokens.accent,
    onSecondary: tokens.textOnPrimary,
    surface: tokens.surfaceBase,
    onSurface: tokens.textPrimary,
    surfaceContainerHighest: tokens.surfaceSubtle,
    onSurfaceVariant: tokens.textSecondary,
    error: tokens.error,
    onError: tokens.textOnPrimary,
    outline: hairline,
    outlineVariant: hairline,
  );

  final baseTextTheme =
      (isDark
              ? Typography.material2021().white
              : Typography.material2021().black)
          .copyWith(
            headlineMedium: TextStyle(
              fontSize: 30,
              height: 1.25,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: tokens.textPrimary,
            ),
            headlineSmall: TextStyle(
              fontSize: 24,
              height: 1.3,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.35,
              color: tokens.textPrimary,
            ),
            titleLarge: TextStyle(
              fontSize: 20,
              height: 1.35,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.25,
              color: tokens.textPrimary,
            ),
            titleMedium: TextStyle(
              fontSize: 17,
              height: 1.4,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.15,
              color: tokens.textPrimary,
            ),
            titleSmall: TextStyle(
              fontSize: 15,
              height: 1.45,
              fontWeight: FontWeight.w600,
              color: tokens.textPrimary,
            ),
            bodyLarge: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: tokens.textPrimary,
            ),
            bodyMedium: TextStyle(
              fontSize: 15.5,
              height: 1.6,
              color: tokens.textPrimary,
            ),
            bodySmall: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: tokens.textSecondary,
            ),
            labelLarge: TextStyle(
              fontSize: 14.5,
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: tokens.textPrimary,
            ),
            labelMedium: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: tokens.textSecondary,
            ),
            labelSmall: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: tokens.textSecondary,
            ),
          );

  final snackBg = isDark ? const Color(0xFF23242A) : const Color(0xFF1D1B18);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    textTheme: baseTextTheme,
    scaffoldBackgroundColor: tokens.surfaceBase,
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.surfaceBase,
      foregroundColor: tokens.textPrimary,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: baseTextTheme.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: tokens.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
        side: BorderSide(color: hairline, width: 0.8),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? tokens.surfaceElevated : tokens.surfaceElevated,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: baseTextTheme.bodySmall?.copyWith(color: tokens.textSecondary),
      hintStyle: baseTextTheme.bodySmall?.copyWith(color: tokens.textDisabled),
      prefixIconColor: tokens.textSecondary,
      suffixIconColor: tokens.textSecondary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        borderSide: BorderSide(color: hairline, width: 0.8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        borderSide: BorderSide(color: hairline, width: 0.8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        borderSide: BorderSide(color: tokens.focusRing, width: 1.3),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.primary,
        foregroundColor: tokens.textOnPrimary,
        disabledBackgroundColor: tokens.surfaceSubtle,
        disabledForegroundColor: tokens.textDisabled,
        elevation: 0,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.textPrimary,
        backgroundColor: tokens.surfaceElevated,
        side: BorderSide(color: hairline, width: 0.9),
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: tokens.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return tokens.primary.withValues(alpha: isDark ? 0.20 : 0.14);
          }
          return tokens.surfaceElevated;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return tokens.primary;
          return tokens.textSecondary;
        }),
        side: WidgetStatePropertyAll(BorderSide(color: hairline, width: 0.8)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
          ),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: tokens.surfaceElevated,
      selectedColor: tokens.primary.withValues(alpha: isDark ? 0.20 : 0.14),
      side: BorderSide(color: hairline, width: 0.8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
      ),
      labelStyle: baseTextTheme.labelMedium,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return tokens.textOnPrimary;
        return tokens.textSecondary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return tokens.primary;
        return tokens.surfaceSubtle;
      }),
      trackOutlineColor: WidgetStatePropertyAll(hairline),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(EchoMetrics.radiusSheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: hairline, width: 0.8),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: hairline, width: 0.8),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: snackBg,
      contentTextStyle: baseTextTheme.bodySmall?.copyWith(
        color: const Color(0xFFF3EFE8),
      ),
      actionTextColor: const Color(0xFFD4AE74),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        side: BorderSide(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.6,
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: tokens.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      indicatorColor: tokens.primary.withValues(alpha: isDark ? 0.16 : 0.12),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: selected ? tokens.primary : tokens.textSecondary,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? tokens.primary : tokens.textSecondary,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: tokens.surfaceElevated,
      indicatorColor: tokens.primary.withValues(alpha: isDark ? 0.16 : 0.12),
      selectedIconTheme: IconThemeData(color: tokens.primary, size: 22),
      unselectedIconTheme: IconThemeData(color: tokens.textSecondary, size: 22),
      selectedLabelTextStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: tokens.primary,
      ),
      unselectedLabelTextStyle: TextStyle(
        fontSize: 12,
        color: tokens.textSecondary,
      ),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 0.6),
    extensions: [tokens],
  );
}
