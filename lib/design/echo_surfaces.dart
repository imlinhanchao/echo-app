import 'package:flutter/material.dart';

import 'echo_ambient.dart';
import 'echo_metrics.dart';
import 'echo_tokens.dart';

/// 全站统一分区标题行（Apple Books / Readwise 式清晰留白与轻辅文）。
class EchoSectionHeader extends StatelessWidget {
  const EchoSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium?.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  subtitle!,
                  style: textTheme.labelMedium?.copyWith(
                    color: tokens.textSecondary,
                    fontWeight: FontWeight.w400,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 分组设置/信息面板容器：自动以 0.6px 极细线分隔内部列表项。
class EchoGroupedCard extends StatelessWidget {
  const EchoGroupedCard({
    super.key,
    required this.children,
    this.radius = EchoMetrics.radiusCard,
    this.dividerIndent = 52,
    this.dividerEndIndent = 16,
  });

  final List<Widget> children;
  final double radius;
  final double dividerIndent;
  final double dividerEndIndent;

  @override
  Widget build(BuildContext context) {
    final hairline = echoHairlineColor(context, darkAlpha: 0.06);
    final spaced = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      spaced.add(children[i]);
      if (i < children.length - 1) {
        spaced.add(
          Divider(
            height: 1,
            thickness: 0.6,
            indent: dividerIndent,
            endIndent: dividerEndIndent,
            color: hairline,
          ),
        );
      }
    }
    return Container(
      decoration: echoElevatedCardDecoration(context, radius: radius),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: spaced),
    );
  }
}

/// 低饱和极简胶囊徽章。
class EchoPillBadge extends StatelessWidget {
  const EchoPillBadge({
    super.key,
    required this.label,
    this.color,
    this.filled = false,
  });

  final String label;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final tone = color ?? tokens.primary;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? tone : tone.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
        border: filled
            ? null
            : Border.all(color: tone.withValues(alpha: 0.24), width: 0.6),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.labelSmall?.copyWith(
          fontSize: 11.5,
          height: 1.2,
          color: filled ? tokens.textOnPrimary : tone,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// BottomSheet 顶部极简拖拽把手。
class EchoSheetDragHandle extends StatelessWidget {
  const EchoSheetDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 12),
        decoration: BoxDecoration(
          color: tokens.textDisabled.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}
