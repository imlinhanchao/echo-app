import 'package:flutter/material.dart';

import 'echo_ambient.dart';
import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// Echo 全站统一按钮尺寸规范：46dp 高 + 12dp 圆角。
abstract final class EchoButtonMetrics {
  static const double height = 46;
  static const double radius = EchoMetrics.radiusControl;
}

/// 克制高对比纯色主按钮（去除浓烈紫渐变，凸显温润香槟金质感）。
class EchoPrimaryButton extends StatelessWidget {
  const EchoPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final radius = BorderRadius.circular(EchoButtonMetrics.radius);
    final disabled = onPressed == null || busy;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        color: disabled
            ? tokens.primary.withValues(alpha: 0.42)
            : tokens.primary,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: disabled ? null : onPressed,
          child: SizedBox(
            height: EchoButtonMetrics.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tokens.textOnPrimary,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, color: tokens.textOnPrimary, size: 18),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: tokens.textOnPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 极细描边次按钮（46dp 高 + 12dp 圆角，与主按钮完全齐平且层次分明）。
class EchoSecondaryButton extends StatelessWidget {
  const EchoSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final radius = BorderRadius.circular(EchoButtonMetrics.radius);
    final disabled = onPressed == null;

    return DecoratedBox(
      decoration: echoElevatedCardDecoration(
        context,
        radius: EchoButtonMetrics.radius,
        color: tokens.surfaceElevated,
        borderColor: echoHairlineColor(context, darkAlpha: 0.10),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: SizedBox(
            height: EchoButtonMetrics.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        color: disabled
                            ? tokens.textDisabled
                            : tokens.textPrimary,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: disabled
                              ? tokens.textDisabled
                              : tokens.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 46×46 圆角矩形图标按钮（12dp 圆角 + 极细描边，与左右 46dp 主次按钮完全齐平）。
class EchoSquareIconButton extends StatelessWidget {
  const EchoSquareIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final radius = BorderRadius.circular(EchoButtonMetrics.radius);

    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: echoElevatedCardDecoration(
          context,
          radius: EchoButtonMetrics.radius,
          color: tokens.surfaceElevated,
          borderColor: echoHairlineColor(context, darkAlpha: 0.10),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: onPressed,
            child: SizedBox(
              width: EchoButtonMetrics.height,
              height: EchoButtonMetrics.height,
              child: Icon(
                icon,
                color: onPressed == null
                    ? tokens.textDisabled
                    : tokens.textPrimary,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
