import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/update/update_models.dart';
import '../../core/update/update_service.dart';
import '../../design/echo_tokens.dart';

/// 检查更新状态控制器
class UpdateStateNotifier extends StateNotifier<AsyncValue<AppUpdateInfo?>> {
  UpdateStateNotifier(this._updateService, this._ref)
      : super(const AsyncValue.data(null));

  final UpdateService _updateService;
  final Ref _ref;

  Future<AppUpdateInfo?> check({
    required String currentVersion,
    bool force = false,
  }) async {
    state = const AsyncValue.loading();
    try {
      final config = _ref.read(standaloneConfigProvider);
      final info = await _updateService.checkForUpdates(
        currentVersion: currentVersion,
        config: config,
      );
      state = AsyncValue.data(info);
      return info;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      rethrow;
    }
  }
}

final StateNotifierProvider<UpdateStateNotifier, AsyncValue<AppUpdateInfo?>>
updateStateProvider =
    StateNotifierProvider<UpdateStateNotifier, AsyncValue<AppUpdateInfo?>>(
      (ref) => UpdateStateNotifier(ref.watch(updateServiceProvider), ref),
    );

/// 格式化字节大小
String formatFileSize(int bytes) {
  if (bytes <= 0) return '';
  final mb = bytes / (1024 * 1024);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
  if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
  return '${(bytes / 1024).round()} KB';
}

/// 打开 URL（优先系统默认浏览器）
Future<void> openExternalUrl(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.tryParse(url.trim());
  if (uri == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('无效的下载链接')),
    );
    return;
  }
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('无法自动打开浏览器，已将下载链接复制到剪贴板')),
        );
      }
    }
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('打开失败，已将下载链接复制到剪贴板')),
      );
    }
  }
}

/// 检查更新弹窗展示
void showUpdateResultDialog(
  BuildContext context, {
  required AppUpdateInfo info,
}) {
  showDialog<void>(
    context: context,
    builder: (dialogCtx) => _UpdateInfoDialog(
      info: info,
      dialogContext: dialogCtx,
    ),
  );
}

class _UpdateInfoDialog extends ConsumerWidget {
  const _UpdateInfoDialog({
    required this.info,
    required this.dialogContext,
  });

  final AppUpdateInfo info;
  final BuildContext dialogContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>();
    final textTheme = Theme.of(context).textTheme;
    final config = ref.watch(standaloneConfigProvider);
    final mirrorMode = UpdateMirrorMode.fromId(config.updateMirrorMode);

    final bgSurface = tokens?.surfaceElevated ?? Theme.of(context).cardColor;
    final cardBg = tokens?.surfaceSubtle ?? Colors.grey.withAlpha(25);
    final accent = tokens?.primary ?? Theme.of(context).colorScheme.primary;
    final textPrimary = tokens?.textPrimary ?? Colors.black87;
    final textSecondary = tokens?.textSecondary ?? Colors.black54;

    // 重新计算最新镜像模式下的下载直链
    final effectiveDownloadUrl = UpdateService.resolveDownloadUrl(
      rawUrl: info.recommendedAsset?.browserDownloadUrl ?? info.htmlUrl,
      mode: mirrorMode,
      detectedCountryCode: info.detectedCountryCode,
      customPrefix: config.customUpdateMirrorPrefix,
    );

    return AlertDialog(
      backgroundColor: bgSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            info.hasUpdate
                ? Icons.system_update_rounded
                : Icons.check_circle_outline_rounded,
            color: info.hasUpdate ? accent : textSecondary,
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              info.hasUpdate ? '发现新版本 ${info.latestVersion}' : '当前已是最新版本',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前安装：${info.currentVersion}  →  最新版本：${info.latestVersion}',
              style: textTheme.bodySmall?.copyWith(
                color: textSecondary,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 12),
            if (info.hasUpdate) ...[
              if (info.recommendedAsset != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.download_for_offline_outlined,
                          size: 18, color: accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${info.recommendedAsset!.name} (${formatFileSize(info.recommendedAsset!.size)})',
                          style: textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                '下载镜像：${mirrorMode.label}'
                '${mirrorMode == UpdateMirrorMode.auto ? (info.detectedCountryCode != null ? "（IP 归属: ${info.detectedCountryCode}）" : "") : ""}',
                style: textTheme.bodySmall?.copyWith(
                  color: textSecondary,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: 12),
              if (info.releaseNotes.isNotEmpty) ...[
                Text(
                  '更新说明：',
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: MarkdownBody(
                    data: info.releaseNotes,
                    onTapLink: (text, href, title) {
                      if (href != null && href.isNotEmpty) {
                        openExternalUrl(context, href);
                      }
                    },
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                      p: textTheme.bodySmall?.copyWith(
                        color: textPrimary,
                        fontSize: 12,
                        height: 1.4,
                      ),
                      listBullet: textTheme.bodySmall?.copyWith(
                        color: textSecondary,
                        fontSize: 12,
                      ),
                      h1: textTheme.titleMedium?.copyWith(
                        color: textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      h2: textTheme.titleSmall?.copyWith(
                        color: textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      h3: textTheme.bodyMedium?.copyWith(
                        color: textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      h4: textTheme.bodySmall?.copyWith(
                        color: textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                      ),
                      code: textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: accent,
                        backgroundColor: tokens?.surfaceSubtle ?? Colors.black12,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: tokens?.surfaceSubtle ?? Colors.black12,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ],
            ] else ...[
              Text(
                '暂无更高版本可供升级，您可以前往 GitHub Releases 查看所有发布历史与源码。',
                style: textTheme.bodySmall?.copyWith(
                  color: textPrimary,
                  fontSize: 12.5,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('update_dialog_cancel_button'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(
            '关闭',
            style: TextStyle(color: textSecondary),
          ),
        ),
        if (info.hasUpdate)
          ElevatedButton(
            key: const Key('update_dialog_download_button'),
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              openExternalUrl(context, effectiveDownloadUrl);
            },
            child: const Text('下载更新'),
          )
        else
          TextButton(
            key: const Key('update_dialog_releases_button'),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              openExternalUrl(context, info.htmlUrl);
            },
            child: Text(
              '查看 Release 页面',
              style: TextStyle(color: accent),
            ),
          ),
      ],
    );
  }
}
