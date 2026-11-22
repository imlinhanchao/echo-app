import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/offline/offline_store.dart';
import '../../core/stats/stats_store.dart';
import '../../core/settings/server_address_store.dart';
import '../../core/settings/theme_mode_controller.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../providers/provider_account_page.dart';
import '../settings/server_address_page.dart';
import 'offline_manager_page.dart';
import 'playback_settings_page.dart';

/// 我的 Tab：账号信息、统计卡、离线内容管理、服务地址、书源账号入口、登出。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, required this.user});

  final EchoUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      key: const Key('profile_page'),
      padding: const EdgeInsets.all(EchoMetrics.space2),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(EchoMetrics.space3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: tokens.primary.withValues(alpha: 0.2),
                      child: Icon(Icons.person, color: tokens.primary),
                    ),
                    const SizedBox(width: EchoMetrics.space2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.email,
                            key: const Key('echo_user_email'),
                            style: textTheme.titleMedium?.copyWith(
                              color: tokens.textPrimary,
                            ),
                          ),
                          Text(
                            '用户 #${user.id}',
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: EchoMetrics.space2),
        _StatsCard(),
        const SizedBox(height: EchoMetrics.space2),
        const _OfflineOverviewCard(),
        const SizedBox(height: EchoMetrics.space2),
        Card(
          child: Column(
            children: [
              ValueListenableBuilder<String>(
                valueListenable: ServerAddressStore.current,
                builder: (context, address, _) => ListTile(
                  key: const Key('profile_server_address'),
                  leading: Icon(Icons.dns_outlined, color: tokens.accent),
                  title: const Text('服务地址'),
                  subtitle: Text(address),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ServerAddressPage(),
                    ),
                  ),
                ),
              ),
              // 亮/暗模式（dark-first：默认深色）。
              ValueListenableBuilder<bool>(
                valueListenable: ThemeModeController.darkMode,
                builder: (context, dark, _) => ListTile(
                  key: const Key('profile_dark_mode'),
                  leading: Icon(
                    dark ? Icons.dark_mode : Icons.light_mode,
                    color: tokens.accent,
                  ),
                  title: const Text('深色模式'),
                  subtitle: Text(dark ? '当前：深色（推荐夜间听读）' : '当前：浅色'),
                  trailing: Switch(
                    key: const Key('profile_dark_mode_switch'),
                    value: dark,
                    onChanged: (_) => ThemeModeController.toggle(),
                  ),
                ),
              ),
              ListTile(
                key: const Key('profile_providers'),
                leading: Icon(Icons.source_outlined, color: tokens.accent),
                title: const Text('书源账号'),
                subtitle: const Text('zlib 镜像 / 邮箱密码 / Cookie 导入'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ProviderAccountPage(),
                  ),
                ),
              ),
              Consumer(
                builder: (context, ref, _) {
                  final syncState = ref.watch(progressSyncServiceProvider);
                  final syncNotifier = ref.read(
                    progressSyncServiceProvider.notifier,
                  );
                  String syncSubtitle;
                  if (syncState.status == SyncStatus.syncing) {
                    syncSubtitle = '正在同步中...';
                  } else if (syncState.status == SyncStatus.error) {
                    syncSubtitle = '同步失败，点击重试';
                  } else if (syncState.lastSyncTime != null) {
                    final t = syncState.lastSyncTime!;
                    final timeStr =
                        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                    syncSubtitle = '已与云端同步 (最近 $timeStr)';
                  } else {
                    syncSubtitle = '已启用双向云同步，点击立即刷新';
                  }

                  return ListTile(
                    key: const Key('profile_cloud_sync'),
                    leading: Icon(
                      Icons.cloud_sync_outlined,
                      color: tokens.accent,
                    ),
                    title: const Text('进度云同步'),
                    subtitle: Text(syncSubtitle),
                    trailing: syncState.status == SyncStatus.syncing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            key: const Key('profile_sync_button'),
                            icon: const Icon(Icons.sync),
                            tooltip: '立即同步',
                            onPressed: syncNotifier.syncAll,
                          ),
                  );
                },
              ),
              ListTile(
                key: const Key('profile_notification_settings'),
                leading: Icon(
                  Icons.notifications_active_outlined,
                  color: tokens.accent,
                ),
                title: const Text('通知与锁屏播控'),
                subtitle: const Text('华为/小米等机型需开启通知与后台运行，才能在锁屏显示播放控件'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PlaybackSettingsPage(),
                  ),
                ),
              ),
              ListTile(
                key: const Key('profile_about'),
                leading: Icon(Icons.info_outline, color: tokens.accent),
                title: const Text('关于'),
                subtitle: const Text('回声 v0.3.4'),
              ),
            ],
          ),
        ),
        const SizedBox(height: EchoMetrics.space3),
        FilledButton.tonalIcon(
          key: const Key('echo_logout'),
          onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          icon: const Icon(Icons.logout),
          label: const Text('退出登录'),
        ),
      ],
    );
  }
}

/// 收听统计卡（设计图 ui-mobile-profile）：本周时长 / 连续天数 / 已听完本数。
class _StatsCard extends StatefulWidget {
  @override
  State<_StatsCard> createState() => _StatsCardState();
}

class _StatsCardState extends State<_StatsCard> {
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final stats = StatsStore.instance;

    String formatMs(int ms) {
      if (ms < 60000) return '${(ms / 1000).round()} 秒';
      final minutes = ms ~/ 60000;
      if (minutes < 60) return '$minutes 分钟';
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
    }

    Widget item(String value, String label, {Key? key}) => Expanded(
      child: Column(
        children: [
          Text(
            value,
            key: key,
            style: textTheme.titleLarge?.copyWith(
              color: tokens.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );

    return Card(
      key: const Key('profile_stats_card'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: EchoMetrics.space2,
          vertical: EchoMetrics.space3,
        ),
        child: Row(
          children: [
            item(
              formatMs(stats.weekListenMs),
              '本周收听',
              key: const Key('stat_week_listen'),
            ),
            item(
              '${stats.streakDays} 天',
              '连续收听',
              key: const Key('stat_streak'),
            ),
            item(
              '${stats.finishedCount} 本',
              '已听完',
              key: const Key('stat_finished'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 离线内容管理概览卡（设计图 ui-mobile-profile）：已下载章节数 + 占用空间 + 跳转管理页。
class _OfflineOverviewCard extends StatefulWidget {
  const _OfflineOverviewCard();

  @override
  State<_OfflineOverviewCard> createState() => _OfflineOverviewCardState();
}

class _OfflineOverviewCardState extends State<_OfflineOverviewCard> {
  OfflineSummary _summary = const OfflineSummary();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final summary = await OfflineFiles.scanAll();
    if (!mounted) return;
    setState(() => _summary = summary);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final subtitle = _summary.isEmpty
        ? '暂无离线下载，无网也能随时收听'
        : '已下载 ${_summary.entries.length} 本 · ${_summary.totalChunks} 章 · 占用 ${formatBytes(_summary.totalBytes)}';
    return Card(
      key: const Key('profile_offline_card'),
      child: ListTile(
        key: const Key('profile_offline_entry'),
        leading: Icon(Icons.offline_pin_outlined, color: tokens.primary),
        title: const Text('离线内容管理'),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const OfflineManagerPage()),
          );
          await _load();
        },
      ),
    );
  }
}
