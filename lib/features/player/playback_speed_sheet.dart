import 'package:flutter/material.dart';

import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';

/// 朗读/听书常用倍速预设档位。
const List<double> kPlaybackSpeedPresets = <double>[
  0.75,
  1.0,
  1.25,
  1.5,
  1.75,
  2.0,
];

/// 将播放倍速格式化为简洁等宽标签（如 `1.0x`、`1.25x`、`1.5x`）。
String formatPlaybackSpeed(double speed) {
  final pct = (speed * 100).round();
  if (pct % 10 == 0) {
    return '${(pct / 100).toStringAsFixed(1)}x';
  }
  return '${(pct / 100).toStringAsFixed(2)}x';
}

/// 紧凑单行倍速胶囊按钮（供阅读器底栏与迷你朗读条共用）。
Widget buildCompactSpeedPill({
  Key? key,
  required double speed,
  required Color accentColor,
  required Color textColor,
  required Color borderColor,
  required VoidCallback onTap,
  String tooltip = '调整语速',
}) {
  final isCustom = (speed - 1.0).abs() >= 0.01;
  return Material(
    type: MaterialType.transparency,
    child: Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 28),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: isCustom
                ? accentColor.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
            border: Border.all(
              color: isCustom
                  ? accentColor.withValues(alpha: 0.72)
                  : borderColor,
              width: 0.9,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            formatPlaybackSpeed(speed),
            maxLines: 1,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.1,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              color: isCustom ? accentColor : textColor,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 打开语速调节底部面板：支持快捷档位点选、0.05x 步进微调与一键重置 `1.0x`。
Future<void> showPlaybackSpeedSheet(
  BuildContext context, {
  required double initialSpeed,
  required ValueChanged<double> onChanged,
  double minSpeed = 0.5,
  double maxSpeed = 2.5,
  double step = 0.05,
  String title = '朗读语速',
  Color? backgroundColor,
  Color? foregroundColor,
  Color? secondaryColor,
}) {
  final tokens = Theme.of(context).extension<EchoTokens>();
  final bg =
      backgroundColor ??
      tokens?.surfaceElevated ??
      Theme.of(context).colorScheme.surface;
  final fg =
      foregroundColor ??
      tokens?.textPrimary ??
      Theme.of(context).colorScheme.onSurface;
  final sec =
      secondaryColor ??
      tokens?.textSecondary ??
      Theme.of(context).colorScheme.onSurfaceVariant;
  final accent = tokens?.primary ?? Theme.of(context).colorScheme.primary;
  final divisions = ((maxSpeed - minSpeed) / step).round();

  double normalize(double raw) {
    final stepped = ((raw.clamp(minSpeed, maxSpeed)) / step).round() * step;
    final clean = (stepped.clamp(minSpeed, maxSpeed) * 100).round() / 100.0;
    return clean;
  }

  var current = normalize(initialSpeed);

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(EchoMetrics.radiusSheet),
      ),
    ),
    builder: (sheetCtx) {
      final textTheme = Theme.of(sheetCtx).textTheme;
      return StatefulBuilder(
        builder: (context, setSheetState) {
          void apply(double nextRaw) {
            final next = normalize(nextRaw);
            if ((next - current).abs() < 0.001) return;
            setSheetState(() => current = next);
            onChanged(next);
          }

          final isDefault = (current - 1.0).abs() < 0.01;
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.space3,
                EchoMetrics.space1,
                EchoMetrics.space3,
                EchoMetrics.space3,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: EchoMetrics.space2),
                      decoration: BoxDecoration(
                        color: sec.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(
                          EchoMetrics.radiusPill,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: textTheme.titleMedium?.copyWith(color: fg),
                        ),
                      ),
                      Text(
                        formatPlaybackSpeed(current),
                        key: const Key('speed_sheet_value'),
                        style: textTheme.titleLarge?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      if (!isDefault) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          key: const Key('speed_sheet_reset'),
                          style: TextButton.styleFrom(
                            foregroundColor: sec,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => apply(1.0),
                          child: const Text('重置'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  Row(
                    children: [
                      IconButton(
                        key: const Key('speed_sheet_decrease'),
                        tooltip: '减慢 0.05x',
                        onPressed: current > minSpeed + 0.001
                            ? () => apply(current - step)
                            : null,
                        icon: Icon(
                          Icons.remove_circle_outline,
                          color: current > minSpeed + 0.001
                              ? fg
                              : sec.withValues(alpha: 0.35),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          key: const Key('speed_sheet_slider'),
                          value: current,
                          min: minSpeed,
                          max: maxSpeed,
                          divisions: divisions,
                          activeColor: accent,
                          inactiveColor: sec.withValues(alpha: 0.22),
                          label: formatPlaybackSpeed(current),
                          onChanged: apply,
                        ),
                      ),
                      IconButton(
                        key: const Key('speed_sheet_increase'),
                        tooltip: '加快 0.05x',
                        onPressed: current < maxSpeed - 0.001
                            ? () => apply(current + step)
                            : null,
                        icon: Icon(
                          Icons.add_circle_outline,
                          color: current < maxSpeed - 0.001
                              ? fg
                              : sec.withValues(alpha: 0.35),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in kPlaybackSpeedPresets)
                        () {
                          final selected = (current - preset).abs() < 0.01;
                          final label = formatPlaybackSpeed(preset);
                          return InkWell(
                            key: Key('speed_preset_$label'),
                            borderRadius: BorderRadius.circular(
                              EchoMetrics.radiusPill,
                            ),
                            onTap: () => apply(preset),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? accent.withValues(alpha: 0.16)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(
                                  EchoMetrics.radiusPill,
                                ),
                                border: Border.all(
                                  color: selected
                                      ? accent
                                      : sec.withValues(alpha: 0.26),
                                  width: selected ? 1.2 : 0.8,
                                ),
                              ),
                              child: Text(
                                label,
                                style: textTheme.labelMedium?.copyWith(
                                  color: selected ? accent : fg,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }(),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
