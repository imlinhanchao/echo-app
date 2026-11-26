import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discover/discover_config.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../discover/discover_controller.dart';

/// 荐书源与远程规则动态更新设置页。
class DiscoverSettingsPage extends ConsumerStatefulWidget {
  const DiscoverSettingsPage({super.key});

  @override
  ConsumerState<DiscoverSettingsPage> createState() =>
      _DiscoverSettingsPageState();
}

class _DiscoverSettingsPageState extends ConsumerState<DiscoverSettingsPage> {
  late final TextEditingController _urlCtrl;
  String? _statusMsg;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(standaloneConfigProvider);
    _urlCtrl = TextEditingController(text: cfg.discoverConfigUrl);
    Future<void>.microtask(() {
      if (!mounted) return;
      final dState = ref.read(discoverControllerProvider);
      if (dState.snapshot == null) {
        ref.read(discoverControllerProvider.notifier).ensureConfigLoaded();
      }
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveUrl() async {
    final raw = _urlCtrl.text.trim();
    final err = validateDiscoverConfigUrl(raw);
    if (err != null) {
      setState(() {
        _statusOk = false;
        _statusMsg = err;
      });
      return;
    }
    await ref.read(standaloneConfigProvider.notifier).setDiscoverConfigUrl(raw);
    if (!mounted) return;
    setState(() {
      _statusOk = true;
      _statusMsg = raw.isEmpty ? '已清空远程配置地址（当前仅使用内置规则）' : '已保存远程配置地址';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(raw.isEmpty ? '已保存，当前仅使用内置规则' : '已保存远程配置地址'),
      ),
    );
  }

  Future<void> _refreshNow() async {
    final raw = _urlCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _statusOk = false;
        _statusMsg = '远程规则地址为空，当前使用内置默认规则；若需远程更新请先填写 JSON 地址';
      });
      return;
    }
    final err = validateDiscoverConfigUrl(raw);
    if (err != null) {
      setState(() {
        _statusOk = false;
        _statusMsg = err;
      });
      return;
    }

    await ref.read(standaloneConfigProvider.notifier).setDiscoverConfigUrl(raw);
    final result = await ref
        .read(discoverControllerProvider.notifier)
        .refreshRemoteConfig(overrideUrl: raw);
    if (!mounted) return;
    setState(() {
      _statusOk = result.updated;
      _statusMsg = result.message;
    });
  }

  Future<void> _resetToDefault() async {
    await ref.read(standaloneConfigProvider.notifier).resetDiscoverConfigUrl();
    final snapshot = await ref
        .read(discoverControllerProvider.notifier)
        .resetConfig();
    if (!mounted) return;
    _urlCtrl.text = DiscoverConfigDefaults.defaultRemoteUrl;
    setState(() {
      _statusOk = true;
      _statusMsg = snapshot.config.configVersion.isNotEmpty
          ? '已恢复内置默认规则 v${snapshot.config.configVersion}'
          : '已恢复内置默认规则';
    });
  }

  String _formatSyncTime(DateTime? dt) {
    if (dt == null) return '随应用内置';
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(discoverControllerProvider);
    final snapshot = state.snapshot;
    final enabledSources = snapshot?.config.enabledSources ?? const [];
    final busy = state.isUpdatingConfig;

    return Scaffold(
      appBar: AppBar(title: const Text('荐书源与动态规则')),
      body: EchoAmbientBackground(
        child: ListView(
          key: const Key('discover_settings_page'),
          padding: const EdgeInsets.all(EchoMetrics.pagePadding),
          children: [
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '当前规则状态',
                        style: textTheme.titleMedium?.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (snapshot != null)
                        EchoPillBadge(
                          label: snapshot.originLabel,
                          color: tokens.primary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(
                    label: '规则版本',
                    value: snapshot == null
                        ? '加载中...'
                        : (snapshot.config.configVersion.isNotEmpty
                              ? 'v${snapshot.config.configVersion}'
                              : '未标注'),
                  ),
                  const SizedBox(height: 6),
                  _InfoRow(
                    label: '上次同步',
                    value: _formatSyncTime(snapshot?.fetchedAt),
                  ),
                  const SizedBox(height: 6),
                  _InfoRow(
                    label: '已启用源',
                    value: enabledSources.isEmpty
                        ? '无'
                        : enabledSources
                              .map((s) => '${s.name}（${s.feeds.length} 频道）')
                              .join('、'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: EchoMetrics.space2),
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '远程规则配置地址',
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '通过远程 JSON 规则可免发版热更新荐书源选择器、榜单频道或切换 JSON 接口；留空则仅使用客户端内置规则。GitHub 地址会自动复用「语音模型管理」的加速镜像。',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space3),
                  TextField(
                    key: const Key('discover_config_url_field'),
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '规则 JSON URL（留空使用内置规则）',
                      hintText: 'https://echo.librejo.cn/discover-rules.json',
                      prefixIcon: Icon(Icons.link_rounded),
                    ),
                  ),
                  if (_statusMsg != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _statusMsg!,
                      key: const Key('discover_config_status_msg'),
                      style: textTheme.bodySmall?.copyWith(
                        color: _statusOk ? tokens.success : tokens.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: EchoMetrics.space3),
                  Row(
                    children: [
                      EchoSecondaryButton(
                        key: const Key('discover_config_save_button'),
                        onPressed: busy ? null : _saveUrl,
                        icon: Icons.save_outlined,
                        label: '保存地址',
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: EchoPrimaryButton(
                          key: const Key('discover_config_refresh_button'),
                          busy: busy,
                          onPressed: busy ? null : _refreshNow,
                          icon: Icons.cloud_download_outlined,
                          label: '拉取并更新规则',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      key: const Key('discover_config_reset_button'),
                      onPressed: busy ? null : _resetToDefault,
                      child: const Text('恢复内置默认规则'),
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: textTheme.bodySmall?.copyWith(
              color: tokens.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
