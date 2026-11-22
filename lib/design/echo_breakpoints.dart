import 'package:flutter/widgets.dart';

/// 响应式三断点常量（对齐《Echo 设计规划》§2.1 与 §6.4）：
/// - Compact (< 600dp): 手机、折叠屏外屏
/// - Medium (600–1024dp): 竖屏平板、折叠屏内屏
/// - Expanded (> 1024dp): 横屏平板、桌面端（macOS/Linux/Windows）
const double kBreakpointCompact = 600.0;
const double kBreakpointExpanded = 1024.0;

enum EchoScreenType { compact, medium, expanded }

EchoScreenType screenTypeForWidth(double width) {
  if (width < kBreakpointCompact) {
    return EchoScreenType.compact;
  }
  if (width < kBreakpointExpanded) {
    return EchoScreenType.medium;
  }
  return EchoScreenType.expanded;
}

extension EchoBreakpointsContext on BuildContext {
  EchoScreenType get screenType =>
      screenTypeForWidth(MediaQuery.sizeOf(this).width);

  bool get isCompact => screenType == EchoScreenType.compact;
  bool get isMedium => screenType == EchoScreenType.medium;
  bool get isExpanded => screenType == EchoScreenType.expanded;
}
