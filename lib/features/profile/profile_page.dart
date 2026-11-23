import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/offline/offline_store.dart';
import '../../core/stats/stats_store.dart';
import '../../core/settings/server_address_store.dart';
import '../../core/settings/theme_mode_controller.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../providers/provider_account_page.dart';
import '../settings/server_address_page.dart';
import 'offline_manager_page.dart';
import 'playback_settings_page.dart';

/// 我的 Tab（高保真对齐 ui-mobile-profile.png）：
/// 顶部用户信息 → 3 张独立统计卡（含微光装饰线/进度条/点阵）→ 离线内容管理分区 → 设置分组。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, required this.user});

  final EchoUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final hasPlayer = ref.watch(
      chunkedPlayerProvider.select((s) => s.hasBook),
    );

    return ListView(
      key: const Key('profile_page'),
      padding: EdgeInsets.fromLTRB(
        EchoMetrics.space3,
        EchoMetrics.space3,
        EchoMetrics.space3,
        hasPlayer ? 104 : EchoMetrics.space4,
      ),
      children: [
        // 顶部头像 + 邮箱 + 标识
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: <Color>[tokens.primary, tokens.accent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(Icons.person, color: tokens.textOnPrimary, size: 30),
            ),
            const SizedBox(width: EchoMetrics.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.email,
                    key: const Key('echo_user_email'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleLarge?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Echo · 用户 #${user.id}',
                      style: textTheme.labelSmall?.copyWith(
                        color: tokens.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: EchoMetrics.space3),

        // 三张独立统计卡片（对齐设计图 ui-mobile-profile.png）
        _StatsCard(),
        const SizedBox(height: EchoMetrics.space3),

        // 离线内容管理独立分区
        Text(
          '离线内容管理',
          style: textTheme.titleMedium?.copyWith(
            color: tokens.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: EchoMetrics.space1),
        const _OfflineOverviewCard(),
        const SizedBox(height: EchoMetrics.space3),

        // 设置分组卡片
        Container(
          decoration: echoElevatedCardDecoration(context, radius: 16),
          child: Column(
            children: [
              ValueListenableBuilder<String>(
                valueListenable: ServerAddressStore.current,
                builder: (context, address, _) => ListTile(
                  key: const Key('profile_server_address'),
                  leading: Icon(Icons.dns_outlined, color: tokens.textPrimary),
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
              const Divider(height: 1, indent: 56),
              // 亮/暗模式（dark-first：默认深色）。
              ValueListenableBuilder<bool>(
                valueListenable: ThemeModeController.darkMode,
                builder: (context, dark, _) => ListTile(
                  key: const Key('profile_dark_mode'),
                  leading: Icon(
                    dark ? Icons.dark_mode : Icons.light_mode,
                    color: tokens.textPrimary,
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
              const Divider(height: 1, indent: 56),
              ListTile(
                key: const Key('profile_providers'),
                leading: Icon(Icons.source_outlined, color: tokens.textPrimary),
                title: const Text('书源账号'),
                subtitle: const Text('zlib 镜像 / 邮箱密码 / Cookie 导入'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ProviderAccountPage(),
                  ),
                ),
              ),
              const Divider(height: 1, indent: 56),
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
                      color: tokens.textPrimary,
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
              const Divider(height: 1, indent: 56),
              ListTile(
                key: const Key('profile_notification_settings'),
                leading: Icon(
                  Icons.notifications_active_outlined,
                  color: tokens.textPrimary,
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
              const Divider(height: 1, indent: 56),
              ListTile(
                key: const Key('profile_about'),
                leading: Icon(Icons.info_outline, color: tokens.textPrimary),
                title: const Text('关于'),
                subtitle: const Text('回声 v0.3.7'),
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

/// 三张独立统计卡（对齐设计图 ui-mobile-profile.png）：本周时长 / 连续天数 / 读完本数。
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
      if (ms < 60000) return '${(ms / 1000).round()}s';
      final minutes = ms ~/ 60000;
      if (minutes < 60) return '$minutes分';
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return rest == 0 ? '$hours时' : '$hours时$rest分';
    }

    Widget statTile({
      required Key key,
      required String label,
      required String value,
      required Widget accent,
    }) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: echoElevatedCardDecoration(context, radius: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelSmall?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              key: key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(
                color: tokens.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(height: 12, child: accent),
          ],
        ),
      ),
    );

    return Row(
      key: const Key('profile_stats_card'),
      children: [
        statTile(
          key: const Key('stat_week_listen'),
          label: '本周收听',
          value: formatMs(stats.weekListenMs),
          accent: CustomPaint(
            size: const Size(double.infinity, 12),
            painter: _TrendLinePainter(tokens.primary),
          ),
        ),
        const SizedBox(width: EchoMetrics.space1),
        statTile(
          key: const Key('stat_streak'),
          label: '连续天数',
          value: '${stats.streakDays} 天',
          accent: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: LinearGradient(
                  colors: <Color>[tokens.primary, tokens.primaryHover],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: EchoMetrics.space1),
        statTile(
          key: const Key('stat_finished'),
          label: '读完本数',
          value: '${stats.finishedCount} 本',
          accent: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List<Widget>.generate(
              7,
              (i) => Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < (stats.finishedCount.clamp(1, 7))
                      ? tokens.primary
                      : tokens.surfaceSubtle,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TrendLinePainter extends CustomPainter {
  const _TrendLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0, size.height * 0.85)
      ..cubicTo(
        size.width * 0.35,
        size.height * 0.85,
        size.width * 0.55,
        size.height * 0.2,
        size.width,
        size.height * 0.15,
      );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TrendLinePainter oldDelegate) =>
      oldDelegate.color != color;
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
    final textTheme = Theme.of(context).textTheme;
    final trailingMeta = _summary.isEmpty
        ? '暂无缓存'
        : '${_summary.totalChunks}章 · ${formatBytes(_summary.totalBytes)}';
    return Container(
      key: const Key('profile_offline_card'),
      decoration: echoElevatedCardDecoration(context, radius: 16),
      child: ListTile(
        key: const Key('profile_offline_entry'),
        leading: Icon(Icons.cloud_download_outlined, color: tokens.textPrimary),
        title: const Text('下载管理'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              trailingMeta,
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: tokens.textSecondary),
          ],
        ),
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
