import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/update/update_models.dart';
import '../../core/update/update_service.dart';
import '../../design/echo_tokens.dart';
import '../update/update_dialog.dart';

/// 版本更新与下载镜像设置页
class UpdateSettingsPage extends ConsumerStatefulWidget {
  const UpdateSettingsPage({
    super.key,
    this.currentVersion = '0.4.3',
  });

  final String currentVersion;

  @override
  ConsumerState<UpdateSettingsPage> createState() => _UpdateSettingsPageState();
}

class _UpdateSettingsPageState extends ConsumerState<UpdateSettingsPage> {
  late final TextEditingController _customPrefixCtrl;
  bool _isChecking = false;
  String? _detectedCountry;
  bool _isDetectingIp = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(standaloneConfigProvider);
    _customPrefixCtrl = TextEditingController(
      text: config.customUpdateMirrorPrefix,
    );
    _detectIpRegion();
  }

  @override
  void dispose() {
    _customPrefixCtrl.dispose();
    super.dispose();
  }

  Future<void> _detectIpRegion() async {
    if (!mounted) return;
    setState(() => _isDetectingIp = true);
    try {
      final code = await ref.read(updateServiceProvider).detectCountryCode();
      if (mounted) {
        setState(() {
          _detectedCountry = code;
          _isDetectingIp = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isDetectingIp = false);
    }
  }

  Future<void> _triggerCheck() async {
    if (_isChecking) return;
    setState(() => _isChecking = true);
    final scaffold = ScaffoldMessenger.of(context);
    try {
      final config = ref.read(standaloneConfigProvider);
      final info = await ref.read(updateServiceProvider).checkForUpdates(
            currentVersion: widget.currentVersion,
            config: config,
            explicitCountryCode: _detectedCountry,
          );
      if (!mounted) return;
      setState(() => _isChecking = false);
      showUpdateResultDialog(context, info: info);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isChecking = false);
      scaffold.showSnackBar(
        SnackBar(content: Text('检查更新失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>();
    final textTheme = Theme.of(context).textTheme;
    final config = ref.watch(standaloneConfigProvider);
    final mirrorMode = UpdateMirrorMode.fromId(config.updateMirrorMode);

    final bgSurface = tokens?.surfaceBase ?? Theme.of(context).scaffoldBackgroundColor;
    final cardBg = tokens?.surfaceElevated ?? Theme.of(context).cardColor;
    final accent = tokens?.primary ?? Theme.of(context).colorScheme.primary;
    final textPrimary = tokens?.textPrimary ?? Colors.black87;
    final textSecondary = tokens?.textSecondary ?? Colors.black54;

    return Scaffold(
      backgroundColor: bgSurface,
      appBar: AppBar(
        title: const Text('软件更新与镜像设置'),
        backgroundColor: bgSurface,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 顶部版本状态卡片
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        color: accent, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      '当前版本：v${widget.currentVersion}',
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '支持自动获取 GitHub Releases 最新发布，支持根据用户 IP 归属地自动匹配国内镜像或海外直连。',
                  style: textTheme.bodySmall?.copyWith(
                    color: textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    key: const Key('check_update_now_button'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: _isChecking ? null : _triggerCheck,
                    icon: _isChecking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: Text(_isChecking ? '正在检查...' : '立即检查更新'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 镜像配置分区
          Text(
            '下载镜像网络设置',
            style: textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  key: const Key('update_mirror_ip_tile'),
                  leading: Icon(Icons.public_rounded,
                      size: 20, color: textPrimary),
                  title: const Text('当前 IP 探测归属'),
                  subtitle: Text(
                    _isDetectingIp
                        ? '正在探测 IP 归属地区...'
                        : (_detectedCountry != null
                            ? '探测结果：$_detectedCountry（${_detectedCountry == "CN" ? "中国大陆地区，自动模式推荐走镜像" : "非大陆地区，自动模式走直连"}）'
                            : '探测失败（自动模式将安全回退直连）'),
                    style: textTheme.bodySmall?.copyWith(fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    tooltip: '重新探测 IP',
                    onPressed: _isDetectingIp ? null : _detectIpRegion,
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '更新包下载通道',
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<UpdateMirrorMode>(
                        key: const Key('update_mirror_dropdown'),
                        initialValue: mirrorMode,
                        isExpanded: true,
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: UpdateMirrorMode.values
                            .map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text(
                                  m.label,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: textPrimary,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (mode) {
                          if (mode == null) return;
                          ref
                              .read(standaloneConfigProvider.notifier)
                              .setUpdateMirrorMode(mode.id);
                        },
                      ),
                    ],
                  ),
                ),
                if (mirrorMode == UpdateMirrorMode.custom) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '自定义加速前缀',
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          key: const Key('update_custom_mirror_input'),
                          controller: _customPrefixCtrl,
                          decoration: InputDecoration(
                            hintText: '例如: https://mirror.example.com/',
                            hintStyle: textTheme.bodySmall?.copyWith(
                              color: tokens?.textDisabled ?? Colors.grey,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ElevatedButton(
                            key: const Key('update_custom_mirror_save'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              ref
                                  .read(standaloneConfigProvider.notifier)
                                  .setCustomUpdateMirrorPrefix(
                                    _customPrefixCtrl.text.trim(),
                                  );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已保存自定义加速前缀')),
                              );
                            },
                            child: const Text('保存前缀'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
