import 'package:flutter/material.dart';

import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// 由语义 Token 构建 Material 3 主题。
/// 组件层只消费 Token：所有颜色来自 [EchoTokens]，所有尺度来自 [EchoMetrics]。
/// 深色为品牌基准态（dark-first），亮色由同一函数以 light Token 构建。
ThemeData buildEchoTheme(Brightness brightness, EchoTokens tokens) {
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
    outlineVariant: tokens.focusRing,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.surfaceBase,
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.surfaceBase,
      foregroundColor: tokens.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: tokens.surfaceElevated,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.surfaceSubtle,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        borderSide: BorderSide(color: tokens.focusRing, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.primary,
        foregroundColor: tokens.textOnPrimary,
        disabledBackgroundColor: tokens.surfaceSubtle,
        disabledForegroundColor: tokens.textDisabled,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(EchoMetrics.radiusSheet),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: tokens.surfaceSubtle, thickness: 1),
    extensions: [tokens],
  );
}
