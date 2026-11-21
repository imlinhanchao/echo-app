import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/stats/stats_store.dart';
import '../../core/settings/theme_mode_controller.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../providers/provider_account_page.dart';
import 'playback_settings_page.dart';

/// 我的 Tab：账号信息、服务地址、书源账号入口、登出。
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
                            style: textTheme.titleMedium
                                ?.copyWith(color: tokens.textPrimary),
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
        Card(
          child: Column(
            children: [
              ListTile(
                key: const Key('profile_server_address'),
                leading: Icon(Icons.dns_outlined, color: tokens.accent),
                title: const Text('服务地址'),
                subtitle: Text(kEchoBaseUrl),
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
              ListTile(
                key: const Key('profile_notification_settings'),
                leading: Icon(Icons.notifications_active_outlined,
                    color: tokens.accent),
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
                subtitle: const Text('回声 v0.2.0'),
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
                style: textTheme.bodySmall
                    ?.copyWith(color: tokens.textSecondary),
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
