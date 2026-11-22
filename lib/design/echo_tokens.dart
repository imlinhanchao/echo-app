import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Echo 语义色 Token（dark-first）。
///
/// 运行时从 assets/design-tokens.json 载入，对应设计系统的三层模型：
/// primitive（JSON 原始色板）→ semantic（本类，light/dark 双态）→ component（ThemeData）。
/// 组件代码只消费本类，禁止出现裸色值。
@immutable
class EchoTokens extends ThemeExtension<EchoTokens> {
  const EchoTokens({
    required this.primary,
    required this.primaryHover,
    required this.primaryActive,
    required this.accent,
    required this.surfaceBase,
    required this.surfaceElevated,
    required this.surfaceSubtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.textOnPrimary,
    required this.success,
    required this.error,
    required this.warning,
    required this.focusRing,
    required this.readingHighlight,
    required this.paperWarm,
    required this.paperText,
  });

  static const String assetPath = 'assets/design-tokens.json';

  final Color primary;
  final Color primaryHover;
  final Color primaryActive;
  final Color accent;

  final Color surfaceBase;
  final Color surfaceElevated;
  final Color surfaceSubtle;

  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color textOnPrimary;

  final Color success;
  final Color error;
  final Color warning;
  final Color focusRing;

  /// 阅读器专用：当前朗读句高亮 / 暖纸深底 / 纸感正文。
  final Color readingHighlight;
  final Color paperWarm;
  final Color paperText;

  /// 从设计 Token 资产载入指定亮暗模式的语义色。
  static Future<EchoTokens> load(Brightness brightness) async {
    final raw = await rootBundle.loadString(assetPath);
    final doc = jsonDecode(raw) as Map<String, dynamic>;
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final colors =
        (doc[mode]! as Map<String, dynamic>)['colors']! as Map<String, dynamic>;
    return EchoTokens.fromColors(colors, brightness);
  }

  /// 解析单个模式的 colors 节；测试亦经此入口验证解析逻辑。
  factory EchoTokens.fromColors(
    Map<String, dynamic> colors,
    Brightness brightness,
  ) {
    final primary = colors['primary']! as Map<String, dynamic>;
    final accent = colors['accent']! as Map<String, dynamic>;
    final surface = colors['surface']! as Map<String, dynamic>;
    final text = colors['text']! as Map<String, dynamic>;
    final status = colors['status']! as Map<String, dynamic>;
    final focus = colors['focus']! as Map<String, dynamic>;
    final reading = colors['reading'] as Map<String, dynamic>?;

    final primaryBase = _color(primary, 'base');
    final surfaceBase = _color(surface, 'base');
    final textPrimary = _color(text, 'primary');

    return EchoTokens(
      primary: primaryBase,
      primaryHover: _color(primary, 'hover'),
      primaryActive: _color(primary, 'active'),
      accent: _color(accent, 'base'),
      surfaceBase: surfaceBase,
      surfaceElevated: _color(surface, 'elevated'),
      surfaceSubtle: _color(surface, 'subtle'),
      textPrimary: textPrimary,
      textSecondary: _color(text, 'secondary'),
      textDisabled: _color(text, 'disabled'),
      textOnPrimary: _color(text, 'on-primary'),
      success: _color(status, 'success'),
      error: _color(status, 'error'),
      warning: _color(status, 'warning'),
      focusRing: _color(focus, 'ring'),
      readingHighlight: _parseColor(
        reading?['highlight-sentence'],
        fallback: primaryBase.withValues(alpha: 0.24),
      ),
      paperWarm: _parseColor(reading?['paper-warm'], fallback: surfaceBase),
      paperText: _parseColor(reading?['paper-text'], fallback: textPrimary),
    );
  }

  static Color _color(Map<String, dynamic> section, String key) =>
      _parseColor(section[key]);

  /// 支持 `#RRGGBB`、`#AARRGGBB` 与 `rgba(r,g,b,a)` 三种写法。
  static Color _parseColor(Object? value, {Color? fallback}) {
    final fb = fallback ?? const Color(0xFF000000);
    if (value is! String) return fb;
    final v = value.trim();
    if (v.startsWith('#')) {
      final hex = v.substring(1);
      if (hex.length == 6) return Color(int.parse(hex, radix: 16) | 0xFF000000);
      if (hex.length == 8) return Color(int.parse(hex, radix: 16));
      return fb;
    }
    final match = RegExp(
      r'rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*(?:,\s*([0-9.]+)\s*)?\)',
    ).firstMatch(v);
    if (match == null) return fb;
    return Color.fromRGBO(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      double.tryParse(match.group(4) ?? '1') ?? 1.0,
    );
  }

  @override
  EchoTokens copyWith({
    Color? primary,
    Color? primaryHover,
    Color? primaryActive,
    Color? accent,
    Color? surfaceBase,
    Color? surfaceElevated,
    Color? surfaceSubtle,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? textOnPrimary,
    Color? success,
    Color? error,
    Color? warning,
    Color? focusRing,
    Color? readingHighlight,
    Color? paperWarm,
    Color? paperText,
  }) {
    return EchoTokens(
      primary: primary ?? this.primary,
      primaryHover: primaryHover ?? this.primaryHover,
      primaryActive: primaryActive ?? this.primaryActive,
      accent: accent ?? this.accent,
      surfaceBase: surfaceBase ?? this.surfaceBase,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceSubtle: surfaceSubtle ?? this.surfaceSubtle,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      textOnPrimary: textOnPrimary ?? this.textOnPrimary,
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
      focusRing: focusRing ?? this.focusRing,
      readingHighlight: readingHighlight ?? this.readingHighlight,
      paperWarm: paperWarm ?? this.paperWarm,
      paperText: paperText ?? this.paperText,
    );
  }

  @override
  EchoTokens lerp(ThemeExtension<EchoTokens>? other, double t) {
    if (other is! EchoTokens) return this;
    return EchoTokens(
      primary: Color.lerp(primary, other.primary, t)!,
      primaryHover: Color.lerp(primaryHover, other.primaryHover, t)!,
      primaryActive: Color.lerp(primaryActive, other.primaryActive, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      surfaceBase: Color.lerp(surfaceBase, other.surfaceBase, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceSubtle: Color.lerp(surfaceSubtle, other.surfaceSubtle, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      textOnPrimary: Color.lerp(textOnPrimary, other.textOnPrimary, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      readingHighlight: Color.lerp(
        readingHighlight,
        other.readingHighlight,
        t,
      )!,
      paperWarm: Color.lerp(paperWarm, other.paperWarm, t)!,
      paperText: Color.lerp(paperText, other.paperText, t)!,
    );
  }
}
