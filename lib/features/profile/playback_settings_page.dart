import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';

/// 通知与后台播控自检页。
///
/// 华为 HarmonyOS / 小米等系统的锁屏媒体控件依赖两件事：
/// 1) 通知权限已开启（Android 13+ 需运行时授权）；
/// 2) 应用允许后台运行（否则锁屏后前台服务被清理，锁屏卡片随之消失）。
class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  bool? _notificationsEnabled;
  bool? _batteryOptimized;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!Platform.isAndroid) return;
    final notif = await Permission.notification.isGranted;
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = notif;
      // ignoreBatteryOptimizations 已授权 = 未受限
      _batteryOptimized = !battery;
    });
  }

  Future<void> _requestNotifications() async {
    await Permission.notification.request();
    await _refresh();
  }

  Future<void> _requestIgnoreBattery() async {
    await Permission.ignoreBatteryOptimizations.request();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    Widget statusRow({
      required Key key,
      required String title,
      required String subtitle,
      required bool? ok,
      required VoidCallback onFix,
      required String fixLabel,
    }) {
      final good = ok == true;
      return Card(
        key: key,
        child: ListTile(
          leading: Icon(
            good ? Icons.check_circle : Icons.error_outline,
            color: good ? tokens.success : tokens.warning,
          ),
          title: Text(
            title,
            style: textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
          ),
          subtitle: Text(
            '${ok == null ? '检测中…' : (good ? '已开启' : '未开启')}· $subtitle',
            style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          trailing: good
              ? null
              : FilledButton.tonal(
                  onPressed: onFix,
                  child: Text(fixLabel),
                ),
        ),
      );
    }

    return Scaffold(
      key: const Key('playback_settings_page'),
      appBar: AppBar(title: const Text('通知与锁屏播控')),
      body: ListView(
        padding: const EdgeInsets.all(EchoMetrics.space2),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              EchoMetrics.space1,
              0,
              EchoMetrics.space1,
              EchoMetrics.space2,
            ),
            child: Text(
              '锁屏与通知栏的播放控件依赖系统媒体会话。'
              '如果锁屏上没有出现播放卡片，通常是下面两项被系统限制了。',
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
          ),
          statusRow(
            key: const Key('playback_settings_notifications'),
            title: '通知权限',
            subtitle: '媒体播放控件以通知形式展示',
            ok: _notificationsEnabled,
            onFix: _requestNotifications,
            fixLabel: '开启',
          ),
          const SizedBox(height: EchoMetrics.space1),
          statusRow(
            key: const Key('playback_settings_battery'),
            title: '允许后台运行',
            subtitle: '关闭电池优化，避免锁屏后播放服务被清理',
            ok: _batteryOptimized == null ? null : !_batteryOptimized!,
            onFix: _requestIgnoreBattery,
            fixLabel: '允许',
          ),
          const SizedBox(height: EchoMetrics.space3),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(EchoMetrics.space2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '华为 / 荣耀机型额外设置',
                    style: textTheme.titleSmall
                        ?.copyWith(color: tokens.textPrimary),
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  Text(
                    '1. 设置 → 应用 → 应用管理 → Echo → 耗电详情：改为「允许后台活动」\n'
                    '2. 设置 → 通知 → Echo：允许通知，并开启「锁屏通知」\n'
                    '3. 最近任务里下拉 Echo 卡片加锁，防止一键清理时被结束',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  OutlinedButton.icon(
                    key: const Key('playback_settings_open_settings'),
                    onPressed: openAppSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('打开系统应用设置'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
