import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/settings/theme_mode_controller.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../design/echo_glass.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';

/// 桌面端完整侧边栏（宽度 > 1024dp，对齐设计图 ui-desktop-main）。
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
    final syncState = ref.watch(progressSyncServiceProvider);

    final navItems = <({IconData icon, IconData activeIcon, String label})>[
      (icon: Icons.home_outlined, activeIcon: Icons.home, label: '我的书架'),
      (icon: Icons.search, activeIcon: Icons.manage_search, label: '发现探索'),
      (
        icon: Icons.grid_view_outlined,
        activeIcon: Icons.grid_view,
        label: '任务中心',
      ),
      (icon: Icons.person_outline, activeIcon: Icons.person, label: '账号设置'),
    ];

    return SizedBox(
      key: const Key('desktop_sidebar'),
      width: 240,
      child: EchoGlassSurface(
        surfaceColor: tokens.surfaceBase,
        border: Border(right: BorderSide(color: tokens.surfaceSubtle)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部 Logo
            Padding(
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.space2,
                EchoMetrics.space3,
                EchoMetrics.space2,
                EchoMetrics.space2,
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: tokens.primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(
                        EchoMetrics.radiusInput,
                      ),
                    ),
                    child: Icon(
                      Icons.graphic_eq,
                      color: tokens.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: EchoMetrics.space1),
                  Expanded(
                    child: Text(
                      'Echo · 回声',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: EchoMetrics.space2),

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
                    selected: selectedIndex == i,
                    selectedTileColor: tokens.primary.withValues(alpha: 0.14),
                    selectedColor: tokens.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        EchoMetrics.radiusInput,
                      ),
                    ),
                    leading: Icon(
                      selectedIndex == i
                          ? navItems[i].activeIcon
                          : navItems[i].icon,
                      color: selectedIndex == i
                          ? tokens.primary
                          : tokens.textSecondary,
                    ),
                    title: Text(
                      navItems[i].label,
                      style: textTheme.labelLarge?.copyWith(
                        color: selectedIndex == i
                            ? tokens.primary
                            : tokens.textPrimary,
                        fontWeight: selectedIndex == i
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    ),
                    onTap: () => onSelect(i),
                  ),
                ),
              ),
            ],

            const Spacer(),

            // 底部：用户信息 + 云同步指示 + 深浅色切换
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space2),
              margin: const EdgeInsets.all(EchoMetrics.space2),
              decoration: BoxDecoration(
                color: tokens.surfaceElevated.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
                border: Border.all(color: tokens.surfaceSubtle),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: tokens.primary.withValues(alpha: 0.2),
                    child: Icon(Icons.person, color: tokens.primary, size: 18),
                  ),
                  const SizedBox(width: EchoMetrics.space1),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          user.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
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
                                color: syncState.status == SyncStatus.syncing
                                    ? tokens.accent
                                    : tokens.success,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              syncState.status == SyncStatus.syncing
                                  ? '同步中'
                                  : '已同步',
                              style: textTheme.labelSmall?.copyWith(
                                color: tokens.textSecondary,
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
                      icon: Icon(dark ? Icons.dark_mode : Icons.light_mode),
                      onPressed: ThemeModeController.toggle,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
