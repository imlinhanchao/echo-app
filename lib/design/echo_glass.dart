import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'echo_tokens.dart';

/// 玻璃拟态容器（对齐设计系统 §3.2：`backdrop-filter: blur(20px) + 70% 透明 surface`）。
///
/// 用于桌面侧边栏、迷你悬浮播放条等需要层次透视的浮层组件；
/// 当系统开启"减少动态效果"（`MediaQuery.disableAnimationsOf`）时自动降级为
/// 高不透明度纯色表面，兼顾无障碍偏好与低端设备性能。
class EchoGlassSurface extends StatelessWidget {
  const EchoGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.boxShadow,
    this.padding,
    this.surfaceColor,
    this.opacity = 0.70,
    this.blurSigma = 20.0,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;
  final EdgeInsetsGeometry? padding;

  /// 基底表面色；默认取 `tokens.surfaceElevated`。
  final Color? surfaceColor;
  final double opacity;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final baseColor = surfaceColor ?? tokens.surfaceElevated;
    final effectiveColor = baseColor.withValues(
      alpha: reduceMotion ? 0.94 : opacity,
    );

    final decorated = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: borderRadius,
        border: border,
        boxShadow: boxShadow,
      ),
      child: child,
    );

    if (reduceMotion) {
      return ClipRRect(borderRadius: borderRadius, child: decorated);
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: decorated,
      ),
    );
  }
}
