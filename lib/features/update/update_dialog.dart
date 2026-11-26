import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/update/app_download_manager.dart';
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

/// 统一版本号显示格式，确保以 `v` 开头
String _formatVersionTag(String version) {
  final trimmed = version.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed.startsWith('v') || trimmed.startsWith('V')
      ? 'v${trimmed.substring(1)}'
      : 'v$trimmed';
}

/// 生成精简的单行镜像描述文本
String _buildMirrorSummary(UpdateMirrorMode mode, String? countryCode) {
  if (mode == UpdateMirrorMode.auto) {
    final code = countryCode?.trim().toUpperCase();
    if (code != null && code.isNotEmpty) {
      final routeLabel = code == 'CN' ? '国内加速' : '直连';
      return '自动探测 · IP 归属 $code（$routeLabel）';
    }
    return '自动探测';
  }
  return '下载通道：${mode.label}';
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

class _UpdateInfoDialog extends ConsumerStatefulWidget {
  const _UpdateInfoDialog({
    required this.info,
    required this.dialogContext,
  });

  final AppUpdateInfo info;
  final BuildContext dialogContext;

  @override
  ConsumerState<_UpdateInfoDialog> createState() => _UpdateInfoDialogState();
}

class _UpdateInfoDialogState extends ConsumerState<_UpdateInfoDialog> {
  late final ScrollController _notesScrollController;

  @override
  void initState() {
    super.initState();
    _notesScrollController = ScrollController();
  }

  @override
  void dispose() {
    _notesScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final dialogContext = widget.dialogContext;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = theme.extension<EchoTokens>();
    final textTheme = theme.textTheme;
    final config = ref.watch(standaloneConfigProvider);
    final mirrorMode = UpdateMirrorMode.fromId(config.updateMirrorMode);

    final bgSurface = tokens?.surfaceElevated ?? theme.cardColor;
    final cardBg = tokens?.surfaceSubtle ??
        (isDark ? const Color(0xFF24262B) : const Color(0xFFE8E2D9));
    final accent = tokens?.primary ?? theme.colorScheme.primary;
    final onPrimary = tokens?.textOnPrimary ?? theme.colorScheme.onPrimary;
    final textPrimary = tokens?.textPrimary ?? theme.colorScheme.onSurface;
    final textSecondary =
        tokens?.textSecondary ?? theme.colorScheme.onSurfaceVariant;
    final successColor = tokens?.success ?? Colors.green;
    final errorColor = tokens?.error ?? theme.colorScheme.error;
    final borderHairline =
        isDark ? Colors.white.withValues(alpha: 0.08) : cardBg;

    // 重新计算最新镜像模式下的下载直链
    final effectiveDownloadUrl = UpdateService.resolveDownloadUrl(
      rawUrl: info.recommendedAsset?.browserDownloadUrl ?? info.htmlUrl,
      mode: mirrorMode,
      detectedCountryCode: info.detectedCountryCode,
      customPrefix: config.customUpdateMirrorPrefix,
    );

    final downloadState = ref.watch(appDownloadManagerProvider);
    final isDownloading = downloadState.status == AppDownloadStatus.downloading;
    final isCompleted = downloadState.status == AppDownloadStatus.completed &&
        downloadState.savePath != null;
    final isFailed = downloadState.status == AppDownloadStatus.failed;

    return Dialog(
      backgroundColor: bgSurface,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: borderHairline),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(
                info: info,
                dialogContext: dialogContext,
                textTheme: textTheme,
                accent: accent,
                textPrimary: textPrimary,
                textSecondary: textSecondary,
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (info.hasUpdate) ...[
                        _buildAssetAndMirrorSection(
                          info: info,
                          mirrorMode: mirrorMode,
                          textTheme: textTheme,
                          cardBg: cardBg,
                          accent: accent,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        if (isDownloading || isCompleted || isFailed) ...[
                          const SizedBox(height: 12),
                          _buildDownloadStatusCard(
                            downloadState: downloadState,
                            isDownloading: isDownloading,
                            isCompleted: isCompleted,
                            textTheme: textTheme,
                            accent: accent,
                            successColor: successColor,
                            errorColor: errorColor,
                            textPrimary: textPrimary,
                            textSecondary: textSecondary,
                          ),
                        ],
                        if (info.releaseNotes.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          _buildReleaseNotesSection(
                            context: context,
                            info: info,
                            textTheme: textTheme,
                            bgSurface: bgSurface,
                            cardBg: cardBg,
                            accent: accent,
                            textPrimary: textPrimary,
                            textSecondary: textSecondary,
                          ),
                        ],
                      ] else ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '暂无更高版本可供升级，您可以前往 GitHub Releases 查看所有发布历史与源码。',
                            style: textTheme.bodySmall?.copyWith(
                              color: textSecondary,
                              fontSize: 12.5,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildFooter(
                context: context,
                dialogContext: dialogContext,
                info: info,
                effectiveDownloadUrl: effectiveDownloadUrl,
                downloadState: downloadState,
                isDownloading: isDownloading,
                isCompleted: isCompleted,
                isFailed: isFailed,
                accent: accent,
                onPrimary: onPrimary,
                textPrimary: textPrimary,
                textSecondary: textSecondary,
                successColor: successColor,
                errorColor: errorColor,
                borderHairline: borderHairline,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader({
    required AppUpdateInfo info,
    required BuildContext dialogContext,
    required TextTheme textTheme,
    required Color accent,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final displayLatest = _formatVersionTag(info.latestVersion);
    final displayCurrent = _formatVersionTag(info.currentVersion);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: (info.hasUpdate ? accent : textSecondary)
                .withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            info.hasUpdate
                ? Icons.system_update_rounded
                : Icons.check_circle_outline_rounded,
            color: info.hasUpdate ? accent : textSecondary,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                info.hasUpdate ? '发现新版本 $displayLatest' : '当前已是最新版本',
                style: textTheme.titleMedium?.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              if (info.hasUpdate)
                Row(
                  children: [
                    Text(
                      displayCurrent,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: textSecondary,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        size: 12,
                        color: textSecondary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        displayLatest,
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: accent,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                )
              else
                Text(
                  '当前版本 $displayCurrent',
                  style: textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        IconButton(
          key: const Key('update_dialog_cancel_button'),
          icon: Icon(Icons.close_rounded, size: 20, color: textSecondary),
          tooltip: '关闭',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    );
  }

  Widget _buildAssetAndMirrorSection({
    required AppUpdateInfo info,
    required UpdateMirrorMode mirrorMode,
    required TextTheme textTheme,
    required Color cardBg,
    required Color accent,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final asset = info.recommendedAsset;
    final sizeLabel = asset != null ? formatFileSize(asset.size) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (asset != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 16, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    asset.name,
                    style: textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (sizeLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    sizeLabel,
                    style: textTheme.bodySmall?.copyWith(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Icon(Icons.public_rounded, size: 14, color: textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _buildMirrorSummary(mirrorMode, info.detectedCountryCode),
                style: textTheme.bodySmall?.copyWith(
                  color: textSecondary,
                  fontSize: 11.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownloadStatusCard({
    required AppDownloadState downloadState,
    required bool isDownloading,
    required bool isCompleted,
    required TextTheme textTheme,
    required Color accent,
    required Color successColor,
    required Color errorColor,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    if (isDownloading) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(accent),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '正在后台静默下载...',
                      style: textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: textPrimary,
                      ),
                    ),
                  ],
                ),
                Text(
                  downloadState.totalBytes > 0
                      ? '${(downloadState.progress * 100).toStringAsFixed(1)}%'
                      : '',
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: downloadState.totalBytes > 0
                    ? downloadState.progress
                    : null,
                backgroundColor: accent.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation(accent),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  downloadState.totalBytes > 0
                      ? '${formatFileSize(downloadState.receivedBytes)} / ${formatFileSize(downloadState.totalBytes)}'
                      : '${formatFileSize(downloadState.receivedBytes)} 已下载',
                  style: textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: textSecondary,
                  ),
                ),
                Text(
                  '通知栏保活中',
                  style: textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '可随时关闭窗口，下载完成后将自动唤起安装。',
              style: textTheme.bodySmall?.copyWith(
                fontSize: 10.5,
                color: textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    if (isCompleted) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: successColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: successColor.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: successColor, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '更新包已下载完成，正在唤起安装...',
                style: textTheme.bodySmall?.copyWith(
                  color: textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: errorColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: errorColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: errorColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '下载失败，请重试或在浏览器打开',
                  style: textTheme.bodySmall?.copyWith(
                    color: errorColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (downloadState.error != null) ...[
            const SizedBox(height: 4),
            Text(
              downloadState.error!,
              style: textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: textSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReleaseNotesSection({
    required BuildContext context,
    required AppUpdateInfo info,
    required TextTheme textTheme,
    required Color bgSurface,
    required Color cardBg,
    required Color accent,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final maxNotesHeight =
        (MediaQuery.sizeOf(context).height * 0.32).clamp(160.0, 260.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '更新内容',
          style: textTheme.bodyMedium?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          constraints: BoxConstraints(maxHeight: maxNotesHeight),
          width: double.infinity,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: ScrollbarTheme(
            data: ScrollbarThemeData(
              thickness: const WidgetStatePropertyAll(4),
              radius: const Radius.circular(4),
              thumbColor: WidgetStatePropertyAll(
                textSecondary.withValues(alpha: 0.45),
              ),
            ),
            child: Scrollbar(
              controller: _notesScrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _notesScrollController,
                padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
                child: MarkdownBody(
                  data: info.releaseNotes,
                  onTapLink: (text, href, title) {
                    if (href != null && href.isNotEmpty) {
                      openExternalUrl(context, href);
                    }
                  },
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                    blockSpacing: 8,
                    listIndent: 16,
                    p: textTheme.bodySmall?.copyWith(
                      color: textPrimary,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                    listBullet: textTheme.bodySmall?.copyWith(
                      color: accent,
                      fontSize: 12.5,
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
                      backgroundColor: bgSurface,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: bgSurface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter({
    required BuildContext context,
    required BuildContext dialogContext,
    required AppUpdateInfo info,
    required String effectiveDownloadUrl,
    required AppDownloadState downloadState,
    required bool isDownloading,
    required bool isCompleted,
    required bool isFailed,
    required Color accent,
    required Color onPrimary,
    required Color textPrimary,
    required Color textSecondary,
    required Color successColor,
    required Color errorColor,
    required Color borderHairline,
  }) {
    if (!info.hasUpdate) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              key: const Key('update_dialog_releases_button'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 42),
                foregroundColor: textPrimary,
                side: BorderSide(color: borderHairline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                openExternalUrl(context, info.htmlUrl);
              },
              child: const Text('查看 Release'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 42),
                backgroundColor: accent,
                foregroundColor: onPrimary,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                '知道了',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      );
    }

    if (isDownloading) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              key: const Key('update_dialog_background_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: onPrimary,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.notifications_active_outlined, size: 18),
              label: const Text(
                '转入后台下载',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已转入后台静默下载，通知栏可查看进度'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const Key('update_dialog_cancel_download_button'),
                  onPressed: () {
                    ref
                        .read(appDownloadManagerProvider.notifier)
                        .cancelDownload();
                  },
                  child: Text(
                    '取消下载',
                    style: TextStyle(color: errorColor, fontSize: 13),
                  ),
                ),
              ),
              Container(width: 1, height: 14, color: borderHairline),
              Expanded(
                child: TextButton.icon(
                  key: const Key('update_dialog_browser_button'),
                  icon: Icon(
                    Icons.open_in_new_rounded,
                    size: 15,
                    color: textSecondary,
                  ),
                  label: Text(
                    '浏览器打开',
                    style: TextStyle(color: textSecondary, fontSize: 13),
                  ),
                  onPressed: () {
                    openExternalUrl(context, effectiveDownloadUrl);
                  },
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (isCompleted) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              key: const Key('update_dialog_install_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: successColor,
                foregroundColor: onPrimary,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.install_mobile_rounded, size: 18),
              label: const Text(
                '立即安装',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              onPressed: () {
                if (downloadState.savePath != null) {
                  AppDownloadManager.installApk(downloadState.savePath!);
                }
              },
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                '稍后安装',
                style: TextStyle(color: textSecondary, fontSize: 13),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            key: const Key('update_dialog_download_button'),
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: onPrimary,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.cloud_download_rounded, size: 18),
            label: Text(
              isFailed ? '重试下载' : '后台下载更新',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            onPressed: () {
              ref.read(appDownloadManagerProvider.notifier).startDownload(
                    downloadUrl: effectiveDownloadUrl,
                    version: info.latestVersion,
                    fileName: info.recommendedAsset?.name,
                  );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                key: const Key('update_dialog_browser_button'),
                icon: Icon(
                  Icons.open_in_new_rounded,
                  size: 15,
                  color: textSecondary,
                ),
                label: Text(
                  '浏览器打开',
                  style: TextStyle(color: textSecondary, fontSize: 13),
                ),
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  openExternalUrl(context, effectiveDownloadUrl);
                },
              ),
            ),
            Container(width: 1, height: 14, color: borderHairline),
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(
                  '暂不更新',
                  style: TextStyle(color: textSecondary, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
