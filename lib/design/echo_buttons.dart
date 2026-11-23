import 'package:flutter/material.dart';

import 'echo_tokens.dart';

/// Echo 全站统一按钮尺寸规范：48dp 高 + 14dp 圆角。
abstract final class EchoButtonMetrics {
  static const double height = 48;
  static const double radius = 14;
}

/// 靛蓝紫渐变主按钮（全站主 CTA 统一 48dp 高 + 14dp 圆角）。
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
        gradient: LinearGradient(
          colors: disabled
              ? <Color>[
                  tokens.primary.withValues(alpha: 0.45),
                  const Color(0xFF7C3AED).withValues(alpha: 0.45),
                ]
              : <Color>[tokens.primary, const Color(0xFF7C3AED)],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: disabled ? 0.08 : 0.18),
        ),
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
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, color: tokens.textOnPrimary, size: 19),
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
                                    fontWeight: FontWeight.w700,
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

/// 深色半透明描边次按钮（48dp 高 + 14dp 圆角，与主按钮完全齐平且主次分明）。
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(EchoButtonMetrics.radius);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : tokens.surfaceSubtle,
        borderRadius: radius,
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.14)
              : tokens.textDisabled.withValues(alpha: 0.35),
        ),
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
                      Icon(icon, color: tokens.textPrimary, size: 18),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: tokens.textPrimary,
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

/// 48×48 圆角矩形图标按钮（14dp 圆角 + 半透明描边，与左右 48dp 主次按钮完全齐平）。
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(EchoButtonMetrics.radius);

    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : tokens.surfaceSubtle,
          borderRadius: radius,
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.14)
                : tokens.textDisabled.withValues(alpha: 0.35),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: onPressed,
            child: SizedBox(
              width: EchoButtonMetrics.height,
              height: EchoButtonMetrics.height,
              child: Icon(icon, color: tokens.textPrimary, size: 21),
            ),
          ),
        ),
      ),
    );
  }
}
