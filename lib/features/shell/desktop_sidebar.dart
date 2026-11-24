import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/settings/theme_mode_controller.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';

/// 桌面端完整侧边栏（宽度 > 1024dp，极简书房 Editorial Minimalism）。
class DesktopSidebar extends ConsumerWidget {
  const DesktopSidebar({
    super.key,
    required this.user,
    required this.selectedIndex,
    required this.onSelect,
  });

  final EchoUser user;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final hairline = echoHairlineColor(context, darkAlpha: 0.08);

    final navItems = <({IconData icon, IconData activeIcon, String label})>[
      (
        icon: Icons.auto_stories_outlined,
        activeIcon: Icons.auto_stories,
        label: '我的书架',
      ),
      (
        icon: Icons.search_rounded,
        activeIcon: Icons.manage_search_rounded,
        label: '发现探索',
      ),
      (
        icon: Icons.checklist_rounded,
        activeIcon: Icons.checklist_rtl_rounded,
        label: '任务中心',
      ),
      (
        icon: Icons.tune_rounded,
        activeIcon: Icons.tune_rounded,
        label: '模型与设置',
      ),
    ];

    return Container(
      key: const Key('desktop_sidebar'),
      width: 236,
      decoration: BoxDecoration(
        color: tokens.surfaceElevated,
        border: Border(right: BorderSide(color: hairline, width: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部品牌标识
          Padding(
            padding: const EdgeInsets.fromLTRB(
              EchoMetrics.pagePadding,
              EchoMetrics.space3,
              EchoMetrics.pagePadding,
              EchoMetrics.space2,
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: tokens.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: tokens.primary.withValues(alpha: 0.28),
                      width: 0.7,
                    ),
                  ),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    color: tokens.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Echo · 回声',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: EchoMetrics.space1),

          // 导航选项列表
          for (var i = 0; i < navItems.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: EchoMetrics.space2,
                vertical: 2,
              ),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  key: Key('desktop_nav_$i'),
                  dense: true,
                  selected: selectedIndex == i,
                  selectedTileColor: tokens.primary.withValues(alpha: 0.14),
                  selectedColor: tokens.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      EchoMetrics.radiusControl,
                    ),
                  ),
                  leading: Icon(
                    selectedIndex == i
                        ? navItems[i].activeIcon
                        : navItems[i].icon,
                    size: 20,
                    color: selectedIndex == i
                        ? tokens.primary
                        : tokens.textSecondary,
                  ),
                  title: Text(
                    navItems[i].label,
                    style: textTheme.labelLarge?.copyWith(
                      fontSize: 14,
                      color: selectedIndex == i
                          ? tokens.primary
                          : tokens.textPrimary,
                      fontWeight: selectedIndex == i
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                  onTap: () => onSelect(i),
                ),
              ),
            ),
          ],

          const Spacer(),

          // 底部：本地状态 + 深浅色切换
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.all(EchoMetrics.space2),
            decoration: echoElevatedCardDecoration(
              context,
              radius: 14,
              color: tokens.surfaceBase,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: tokens.primary.withValues(alpha: 0.16),
                  child: Icon(
                    Icons.person_outline_rounded,
                    color: tokens.primary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        user.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium?.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: tokens.success,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '本地单机版',
                            style: textTheme.labelSmall?.copyWith(
                              color: tokens.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: ThemeModeController.darkMode,
                  builder: (context, dark, _) => IconButton(
                    iconSize: 18,
                    tooltip: dark ? '切换亮色' : '切换深色',
                    color: tokens.textSecondary,
                    icon: Icon(
                      dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                    onPressed: ThemeModeController.toggle,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
