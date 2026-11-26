import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/audio/live_tts_player_controller.dart';
import '../../core/offline/offline_store.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/settings/theme_mode_controller.dart';
import '../../core/stats/stats_store.dart';
import '../../core/tts/tts_model_catalog.dart';
import '../../core/tts/tts_model_manager.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../discover/discover_controller.dart';
import '../providers/provider_account_page.dart';
import '../settings/discover_settings_page.dart';
import '../settings/ebook_api_settings_page.dart';
import '../tts/tts_model_manager_page.dart';
import 'offline_manager_page.dart';
import 'playback_settings_page.dart';

/// 我的 Tab（极简书房 Editorial Minimalism）：
/// 克制用户信息头 → 三列极简细分割统计面板 → 离线缓存概览 → Apple Books 式分组设置面板。
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
    final hasLiveTts = ref.watch(
      liveTtsPlayerProvider.select((s) => s.hasBook),
    );

    return ListView(
      key: const Key('profile_page'),
      padding: EdgeInsets.fromLTRB(
        EchoMetrics.pagePadding,
        EchoMetrics.space3,
        EchoMetrics.pagePadding,
        (hasPlayer || hasLiveTts) ? 112 : EchoMetrics.space4,
      ),
      children: [
        // 顶部用户信息（沉稳暖金线框头像 + 用户名 + 轻徽章）
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: echoElevatedCardDecoration(
                context,
                radius: 999,
                borderColor: tokens.primary.withValues(alpha: 0.35),
              ),
              child: Icon(
                Icons.person_outline_rounded,
                color: tokens.primary,
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
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
                  const SizedBox(height: 5),
                  const EchoPillBadge(label: 'Echo · 单机模式'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: EchoMetrics.space3),

        // 统一三列细分割数据板
        const _StatsCard(),
        const SizedBox(height: EchoMetrics.space3),

        // 离线内容管理
        const EchoSectionHeader(title: '离线存储'),
        const SizedBox(height: 10),
        const _OfflineOverviewCard(),
        const SizedBox(height: EchoMetrics.space3),

        // 语音与播放组
        const EchoSectionHeader(title: '语音与播控'),
        const SizedBox(height: 10),
        EchoGroupedCard(
          children: [
            Consumer(
              builder: (context, ref, _) {
                final cfg = ref.watch(standaloneConfigProvider);
                final modelsState = ref.watch(ttsModelManagerProvider);
                final activeSpec = TtsModelCatalog.byId(cfg.activeTtsModelId);
                final installedCount = modelsState.installedEntries.length;
                final subtitle = activeSpec != null &&
                        (modelsState.entryOf(activeSpec.id)?.isInstalled ??
                            false)
                    ? (activeSpec.isSystemTts
                          ? '当前：${activeSpec.name}'
                          : '当前：${activeSpec.name}（已装 $installedCount 款）')
                    : '配置系统语音或下载离线声音引擎';
                return ListTile(
                  key: const Key('profile_tts_models'),
                  leading: Icon(
                    Icons.record_voice_over_outlined,
                    size: 21,
                    color: tokens.textPrimary,
                  ),
                  title: const Text('语音模型与引擎管理'),
                  subtitle: Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: tokens.textDisabled,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const TtsModelManagerPage(),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              key: const Key('profile_notification_settings'),
              leading: Icon(
                Icons.notifications_none_rounded,
                size: 21,
                color: tokens.textPrimary,
              ),
              title: const Text('通知与锁屏播控'),
              subtitle: Text(
                '保证华为 / 小米等机型锁屏媒体控件常驻',
                style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: tokens.textDisabled,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PlaybackSettingsPage(),
                ),
              ),
            ),
            ListTile(
              key: const Key('profile_clear_live_cache'),
              leading: Icon(
                Icons.cleaning_services_outlined,
                size: 20,
                color: tokens.textPrimary,
              ),
              title: const Text('清理临时朗读缓存'),
              subtitle: Text(
                '实时「边听边生成」产生的临时 WAV 音频缓存',
                style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: tokens.textDisabled,
              ),
              onTap: () async {
                final freed = await ref
                    .read(liveTtsPlayerProvider.notifier)
                    .clearTempCache();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已释放临时缓存 ${formatBytes(freed)}')),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: EchoMetrics.space3),

        // 书源、外观与关于组
        const EchoSectionHeader(title: '书源与外观'),
        const SizedBox(height: 10),
        EchoGroupedCard(
          children: [
            Consumer(
              builder: (context, ref, _) {
                final cfg = ref.watch(standaloneConfigProvider);
                return ListTile(
                  key: const Key('profile_server_address'),
                  leading: Icon(
                    Icons.dns_outlined,
                    size: 20,
                    color: tokens.textPrimary,
                  ),
                  title: const Text('ebook-api 书源服务'),
                  subtitle: Text(
                    cfg.hasEbookApi ? cfg.ebookApiBaseUrl : '未配置（仅使用本地导入）',
                    style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: tokens.textDisabled,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EbookApiSettingsPage(),
                    ),
                  ),
                );
              },
            ),
            Consumer(
              builder: (context, ref, _) {
                final cfg = ref.watch(standaloneConfigProvider);
                return ListTile(
                  key: const Key('profile_providers'),
                  leading: Icon(
                    Icons.source_outlined,
                    size: 20,
                    color: tokens.textPrimary,
                  ),
                  title: const Text('书源账号'),
                  subtitle: Text(
                    cfg.hasEbookApi
                        ? 'zlib 镜像 / 邮箱密码 / Cookie 凭证'
                        : '未配置书源服务（可跳过，仅使用本地导入）',
                    style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: tokens.textDisabled,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ProviderAccountPage(),
                    ),
                  ),
                );
              },
            ),
            Consumer(
              builder: (context, ref, _) {
                final dState = ref.watch(discoverControllerProvider);
                final activeSource = dState.activeSource;
                final ver = dState.snapshot?.config.configVersion ?? '';
                final subtitle = activeSource != null
                    ? '${activeSource.name}${ver.isNotEmpty ? " · v$ver" : ""}'
                    : '多荐书源与远程规则热更新';
                return ListTile(
                  key: const Key('profile_discover_settings'),
                  leading: Icon(
                    Icons.explore_outlined,
                    size: 20,
                    color: tokens.textPrimary,
                  ),
                  title: const Text('荐书源与动态规则'),
                  subtitle: Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: tokens.textDisabled,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DiscoverSettingsPage(),
                    ),
                  ),
                );
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: ThemeModeController.darkMode,
              builder: (context, dark, _) => ListTile(
                key: const Key('profile_dark_mode'),
                leading: Icon(
                  dark
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                  size: 20,
                  color: tokens.textPrimary,
                ),
                title: const Text('深色模式'),
                subtitle: Text(
                  dark ? '当前：暖墨暗色（推荐夜间听读）' : '当前：羊皮纸亮色',
                  style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
                ),
                trailing: Switch(
                  key: const Key('profile_dark_mode_switch'),
                  value: dark,
                  onChanged: (_) => ThemeModeController.toggle(),
                ),
              ),
            ),
            ListTile(
              key: const Key('profile_about'),
              leading: Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: tokens.textPrimary,
              ),
              title: const Text('关于回声'),
              subtitle: Text(
                '回声 · 单机版 v0.4.1',
                style: textTheme.bodySmall?.copyWith(fontSize: 12.5),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 三列统一细分割统计面板（本周时长 / 连续天数 / 读完本数）。
class _StatsCard extends StatefulWidget {
  const _StatsCard();

  @override
  State<_StatsCard> createState() => _StatsCardState();
}

class _StatsCardState extends State<_StatsCard> {
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final hairline = echoHairlineColor(context, darkAlpha: 0.08);
    final stats = StatsStore.instance;

    String formatMs(int ms) {
      if (ms < 60000) return '${(ms / 1000).round()}s';
      final minutes = ms ~/ 60000;
      if (minutes < 60) return '$minutes分';
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return rest == 0 ? '$hours时' : '$hours时$rest分';
    }

    Widget cell({
      required Key key,
      required String label,
      required String value,
    }) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Text(
              value,
              key: key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(
                fontSize: 20,
                color: tokens.textPrimary,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelSmall?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );

    return Container(
      key: const Key('profile_stats_card'),
      decoration: echoElevatedCardDecoration(context, radius: 16),
      child: IntrinsicHeight(
        child: Row(
          children: [
            cell(
              key: const Key('stat_week_listen'),
              label: '本周收听',
              value: formatMs(stats.weekListenMs),
            ),
            VerticalDivider(
              width: 1,
              thickness: 0.6,
              indent: 14,
              endIndent: 14,
              color: hairline,
            ),
            cell(
              key: const Key('stat_streak'),
              label: '连续天数',
              value: '${stats.streakDays} 天',
            ),
            VerticalDivider(
              width: 1,
              thickness: 0.6,
              indent: 14,
              endIndent: 14,
              color: hairline,
            ),
            cell(
              key: const Key('stat_finished'),
              label: '读完本数',
              value: '${stats.finishedCount} 本',
            ),
          ],
        ),
      ),
    );
  }
}

/// 离线内容管理概览卡：已下载章节数 + 占用空间 + 跳转管理页。
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
        leading: Icon(
          Icons.cloud_download_outlined,
          size: 21,
          color: tokens.textPrimary,
        ),
        title: const Text('下载管理'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              trailingMeta,
              style: textTheme.labelMedium?.copyWith(
                color: tokens.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: tokens.textDisabled),
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
