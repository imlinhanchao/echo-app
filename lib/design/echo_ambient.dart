import 'package:flutter/material.dart';

import 'echo_tokens.dart';

/// 全局深空靛蓝氛围背景（对齐 `generated/` 视觉设计稿）：
/// 深色模式下在 `surfaceBase` 之上叠加柔和的深靛蓝径向微光渐变，消除纯黑平面的沉闷感；
/// 亮色模式下保持纯净 `surfaceBase`。
class EchoAmbientBackground extends StatelessWidget {
  const EchoAmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!isDark) {
      return ColoredBox(color: tokens.surfaceBase, child: child);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        gradient: RadialGradient(
          center: const Alignment(0.0, -0.55),
          radius: 1.15,
          colors: <Color>[
            tokens.primary.withValues(alpha: 0.22),
            tokens.surfaceElevated.withValues(alpha: 0.65),
            tokens.surfaceBase,
          ],
          stops: const <double>[0.0, 0.48, 1.0],
        ),
      ),
      child: child,
    );
  }
}

/// 设计稿高光细描边卡片装饰（暗模式下提供微妙玻璃边界层次）。
BoxDecoration echoElevatedCardDecoration(
  BuildContext context, {
  double radius = 16,
  Color? color,
}) {
  final tokens = Theme.of(context).extension<EchoTokens>()!;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: color ?? tokens.surfaceElevated.withValues(alpha: isDark ? 0.82 : 1),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: isDark
          ? Colors.white.withValues(alpha: 0.09)
          : tokens.surfaceSubtle,
    ),
  );
}
