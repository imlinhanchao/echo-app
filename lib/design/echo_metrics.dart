import 'package:flutter/material.dart';

/// 静态尺度 Token：间距（8pt 网格）、圆角、动效时长与曲线。
/// 与 assets/design-tokens.json 的 spacing / radius / motion 段保持同步；
/// 颜色不在本类（运行时载入，见 EchoTokens），尺度为编译期常量。
abstract final class EchoMetrics {
  /// 8pt 网格：4 / 8 / 16 / 24 / 32 / 48。
  static const List<double> spacingScale = [4, 8, 16, 24, 32, 48];

  static const double spaceHalf = 4;
  static const double space1 = 8;
  static const double space2 = 16;
  static const double space3 = 24;
  static const double space4 = 32;
  static const double space5 = 48;

  /// 页面水平统一留白（20dp）
  static const double pagePadding = 20;

  static const double radiusCard = 16;
  static const double radiusControl = 12;
  static const double radiusInput = 12;
  static const double radiusSheet = 24;
  static const double radiusPill = 999;

  static const Duration motionFast = Duration(milliseconds: 150);
  static const Duration motionBase = Duration(milliseconds: 250);
  static const Duration motionSheet = Duration(milliseconds: 300);

  static const Curve easeEnter = Curves.easeOut;
  static const Curve easeExit = Curves.easeIn;
}
