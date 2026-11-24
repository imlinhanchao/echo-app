import 'package:flutter/material.dart';

import 'echo_tokens.dart';

/// 极简书房背景容器：
/// - 深色模式：暖墨黑 `surfaceBase` 搭配极克制的顶部垂向明暗过渡，零圆环色带光晕；
/// - 亮色模式：纯净羊皮纸白 `surfaceBase`。
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
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color.lerp(tokens.surfaceElevated, tokens.surfaceBase, 0.35)!,
            tokens.surfaceBase,
          ],
          stops: const <double>[0.0, 0.28],
        ),
      ),
      child: child,
    );
  }
}

/// 统一的 0.7–0.8px 极细分割描边色。
Color echoHairlineColor(BuildContext context, {double darkAlpha = 0.07}) {
  final tokens = Theme.of(context).extension<EchoTokens>()!;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? Colors.white.withValues(alpha: darkAlpha) : tokens.surfaceSubtle;
}

/// 极简浮层/卡片装饰：平实表面色 + 0.8px 细描边，克制不靠浓重阴影。
BoxDecoration echoElevatedCardDecoration(
  BuildContext context, {
  double radius = 16,
  Color? color,
  Color? borderColor,
}) {
  final tokens = Theme.of(context).extension<EchoTokens>()!;
  return BoxDecoration(
    color: color ?? tokens.surfaceElevated,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: borderColor ?? echoHairlineColor(context),
      width: 0.8,
    ),
  );
}
