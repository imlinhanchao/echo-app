import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/offline/offline_store.dart' show formatBytes;
import '../../core/reader/reading_store.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/translation/translation_cache_store.dart';
import '../../core/translation/translation_engine.dart';
import '../../core/translation/translation_model_manager.dart';
import '../../core/translation/translation_models.dart';
import '../../core/translation/translation_scheduler.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';

/// 离线翻译模型与缓存管理页（HY-MT1.5-1.8B · STQ1_0 / GGUF）。
class TranslationModelPage extends ConsumerStatefulWidget {
  const TranslationModelPage({super.key});

  @override
  ConsumerState<TranslationModelPage> createState() =>
      _TranslationModelPageState();
}

class _TranslationModelPageState extends ConsumerState<TranslationModelPage> {
  late final TextEditingController _customMirrorCtrl;
  int _cacheBytes = 0;
  bool _testingInference = false;
  String? _testResultText;
  String? _customMirrorError;

  @override
  void initState() {
    super.initState();
    _customMirrorCtrl = TextEditingController(
      text: ref.read(standaloneConfigProvider).customTranslationMirrorPrefix,
    );
    _refreshCacheBytes();
  }

  @override
  void dispose() {
    _customMirrorCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshCacheBytes() async {
    final bytes = await ref
        .read(translationCacheStoreProvider)
        .computeTotalCacheBytes();
    if (mounted) {
      setState(() => _cacheBytes = bytes);
    }
  }

  Future<void> _importLocalGguf() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['gguf'],
    );
    final filePath = picked?.files.single.path;
    if (filePath == null || filePath.isEmpty) return;

    final err = await ref
        .read(translationModelManagerProvider.notifier)
        .importLocalGguf(File(filePath));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err ?? '已导入本地 GGUF 模型并设为当前模型')),
    );
  }

  Future<void> _runSelfCheck(String modelPath) async {
    if (_testingInference) return;
    setState(() {
      _testingInference = true;
      _testResultText = null;
    });
    final sw = Stopwatch()..start();
    try {
      final engine = ref.read(translationEngineProvider);
      await engine.ensureLoaded(modelPath);
      final target = TranslationTargetLanguage.fromCode(
        ref.read(standaloneConfigProvider).translationTargetLang,
      );
      final prompt = buildHyMtPrompt(
        sourceText:
            'The quick brown fox jumps over the lazy dog, and stories illuminate the quiet night.',
        targetLanguage: target,
      );
      final out = await engine.translate(prompt, maxTokens: 128);
      sw.stop();
      if (!mounted) return;
      setState(() {
        _testResultText =
            '推理成功（耗时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s）：$out';
      });
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        _testResultText = '自检失败：$e';
      });
    } finally {
      if (mounted) {
        setState(() => _testingInference = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final cfg = ref.watch(standaloneConfigProvider);
    final mgrState = ref.watch(translationModelManagerProvider);
    final targetLang =
        TranslationTargetLanguage.fromCode(cfg.translationTargetLang);
    final activePath = mgrState.activeModelPath;

    return Scaffold(
      backgroundColor: tokens.surfaceBase,
      appBar: AppBar(
        title: const Text('离线翻译模型（HY-MT1.5）'),
        backgroundColor: tokens.surfaceBase,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // 1. 模型能力说明与默认语种/缓存卡片
          Container(
            decoration: echoElevatedCardDecoration(
              context,
              radius: EchoMetrics.radiusCard,
            ),
            child: Padding(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.translate_rounded,
                        color: tokens.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '端侧离线双语翻译',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: tokens.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '基于腾讯 HY-MT1.5-1.8B 翻译大模型与 llama.cpp STQ1_0 极速内核，完全在手机本地离线推理，支持 33 种语言互译。推荐下载 1.25-bit 压缩版（约 440MB）。',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<TranslationTargetLanguage>(
                    key: const Key('translation_target_lang_dropdown'),
                    initialValue: targetLang,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '默认翻译目标语言',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: TranslationTargetLanguage.values
                        .map(
                          (lang) => DropdownMenuItem(
                            value: lang,
                            child: Text(lang.label),
                          ),
                        )
                        .toList(),
                    onChanged: (lang) {
                      if (lang == null) return;
                      ref
                          .read(standaloneConfigProvider.notifier)
                          .setTranslationTargetLang(lang.code);
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '本地译文缓存：${formatBytes(_cacheBytes)}',
                          style: textTheme.bodySmall?.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _cacheBytes <= 0
                            ? null
                            : () async {
                                await ref
                                    .read(translationCacheStoreProvider)
                                    .clearAllCaches();
                                ref
                                    .read(translationSchedulerProvider.notifier)
                                    .clearMemoryCache();
                                BilingualChapterPaginationCache.instance.clear();
                                await _refreshCacheBytes();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已清空本地译文缓存')),
                                );
                              },
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: const Text('清空缓存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: EchoMetrics.space3),
          const EchoSectionHeader(title: '下载通道镜像'),
          const SizedBox(height: 10),

          // 2. 下载镜像选择卡片
          Container(
            decoration: echoElevatedCardDecoration(
              context,
              radius: EchoMetrics.radiusCard,
            ),
            child: Padding(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    key: const Key('translation_mirror_dropdown'),
                    initialValue: TranslationModelCatalog.mirrorById(
                      cfg.translationDownloadMirror,
                    ).id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '模型下载镜像',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: TranslationModelCatalog.mirrors
                        .map(
                          (m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.label),
                          ),
                        )
                        .toList(),
                    onChanged: (id) {
                      if (id == null) return;
                      ref
                          .read(standaloneConfigProvider.notifier)
                          .setTranslationDownloadMirror(id);
                    },
                  ),
                  if (cfg.translationDownloadMirror ==
                      TranslationModelCatalog.mirrorCustom) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('translation_custom_mirror_input'),
                      controller: _customMirrorCtrl,
                      decoration: InputDecoration(
                        labelText: '自定义加速前缀',
                        hintText: '例如 https://hf-mirror.com',
                        errorText: _customMirrorError,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: EchoSecondaryButton(
                        label: '保存前缀',
                        icon: Icons.save_outlined,
                        onPressed: () {
                          final raw = _customMirrorCtrl.text.trim();
                          if (raw.isEmpty) {
                            setState(() => _customMirrorError = '请输入前缀地址');
                            return;
                          }
                          setState(() => _customMirrorError = null);
                          ref
                              .read(standaloneConfigProvider.notifier)
                              .setCustomTranslationMirrorPrefix(raw);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已保存翻译模型镜像前缀')),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: EchoMetrics.space3),
          const EchoSectionHeader(title: '可用量化模型'),
          const SizedBox(height: 10),

          // 3. 模型卡片列表
          for (final spec in TranslationModelCatalog.downloadablePresets) ...[
            _buildModelCard(
              context,
              entry:
                  mgrState.entries[spec.id] ??
                  TranslationModelEntry(
                    spec: spec,
                    totalBytes: spec.estimatedSizeBytes,
                  ),
              isActive: mgrState.activeModelId == spec.id,
              tokens: tokens,
              textTheme: textTheme,
            ),
            const SizedBox(height: 12),
          ],

          // 4. 本地导入 GGUF 卡片
          _buildImportedModelCard(
            context,
            entry:
                mgrState.entries[TranslationModelCatalog.modelIdImported] ??
                const TranslationModelEntry(
                  spec: TranslationModelCatalog.importedPlaceholder,
                ),
            isActive:
                mgrState.activeModelId == TranslationModelCatalog.modelIdImported,
            tokens: tokens,
            textTheme: textTheme,
          ),

          if (activePath != null) ...[
            const SizedBox(height: EchoMetrics.space3),
            const EchoSectionHeader(title: '引擎自检'),
            const SizedBox(height: 10),
            Container(
              decoration: echoElevatedCardDecoration(
                context,
                radius: EchoMetrics.radiusCard,
              ),
              child: Padding(
                padding: const EdgeInsets.all(EchoMetrics.space3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EchoPrimaryButton(
                      key: const Key('translation_engine_self_check_button'),
                      label: _testingInference ? '正在端侧推理测试...' : '测试本地翻译推理',
                      icon: Icons.play_arrow_rounded,
                      busy: _testingInference,
                      onPressed: () => _runSelfCheck(activePath),
                    ),
                    if (_testResultText != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _testResultText!,
                        style: textTheme.bodySmall?.copyWith(
                          color: _testResultText!.startsWith('自检失败')
                              ? tokens.error
                              : tokens.success,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModelCard(
    BuildContext context, {
    required TranslationModelEntry entry,
    required bool isActive,
    required EchoTokens tokens,
    required TextTheme textTheme,
  }) {
    final spec = entry.spec;
    final mgr = ref.read(translationModelManagerProvider.notifier);

    return Container(
      decoration: echoElevatedCardDecoration(
        context,
        radius: EchoMetrics.radiusCard,
      ),
      child: Padding(
        padding: const EdgeInsets.all(EchoMetrics.space3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    spec.name,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: tokens.textPrimary,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: (isActive && entry.isInstalled
                            ? tokens.success
                            : tokens.primary)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isActive && entry.isInstalled
                        ? '当前使用中'
                        : spec.recommendedTag,
                    style: textTheme.labelSmall?.copyWith(
                      color: isActive && entry.isInstalled
                          ? tokens.success
                          : tokens.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              spec.subtitle,
              style: textTheme.bodySmall?.copyWith(
                color: tokens.textSecondary,
                height: 1.4,
              ),
            ),
            if (entry.isDownloading || entry.isPaused) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: entry.progress > 0 ? entry.progress : null,
                  backgroundColor: tokens.surfaceSubtle,
                  valueColor: AlwaysStoppedAnimation(tokens.primary),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                entry.statusText.isNotEmpty
                    ? entry.statusText
                    : formatBytes(entry.downloadedBytes),
                style: textTheme.bodySmall?.copyWith(
                  color: tokens.textSecondary,
                  fontSize: 11.5,
                ),
              ),
            ],
            if (entry.error != null) ...[
              const SizedBox(height: 8),
              Text(
                entry.error!,
                style: textTheme.bodySmall?.copyWith(
                  color: tokens.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (entry.isDownloading)
                  Expanded(
                    child: EchoSecondaryButton(
                      label: '暂停下载（保留断点）',
                      icon: Icons.pause_rounded,
                      onPressed: () => mgr.pauseDownload(spec.id),
                    ),
                  )
                else if (entry.isInstalled) ...[
                  if (!isActive)
                    Expanded(
                      child: EchoPrimaryButton(
                        label: '启用此模型',
                        icon: Icons.check_rounded,
                        onPressed: () => mgr.setActiveModel(spec.id),
                      ),
                    )
                  else
                    Expanded(
                      child: EchoSecondaryButton(
                        label: '已启用（约 ${formatBytes(entry.installedBytes)}）',
                        icon: Icons.check_circle_outline_rounded,
                        onPressed: null,
                      ),
                    ),
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: '删除模型文件',
                    onPressed: () async {
                      if (ref.read(translationEngineProvider).loadedModelPath ==
                          entry.localPath) {
                        await ref.read(translationEngineProvider).unload();
                      }
                      await mgr.deleteModel(spec.id);
                    },
                    icon: Icon(Icons.delete_outline_rounded, color: tokens.error),
                  ),
                ] else ...[
                  Expanded(
                    child: EchoPrimaryButton(
                      key: Key('translation_download_${spec.id}'),
                      label: entry.isPaused
                          ? '继续断点下载'
                          : '下载模型（${formatBytes(spec.estimatedSizeBytes)}）',
                      icon: Icons.cloud_download_outlined,
                      onPressed: () => mgr.startOrResumeDownload(spec.id),
                    ),
                  ),
                  if (entry.isPaused) ...[
                    const SizedBox(width: 10),
                    IconButton(
                      tooltip: '清理未完成断点',
                      onPressed: () => mgr.deleteModel(spec.id),
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportedModelCard(
    BuildContext context, {
    required TranslationModelEntry entry,
    required bool isActive,
    required EchoTokens tokens,
    required TextTheme textTheme,
  }) {
    final mgr = ref.read(translationModelManagerProvider.notifier);

    return Container(
      decoration: echoElevatedCardDecoration(
        context,
        radius: EchoMetrics.radiusCard,
      ),
      child: Padding(
        padding: const EdgeInsets.all(EchoMetrics.space3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.spec.name,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: tokens.textPrimary,
                    ),
                  ),
                ),
                if (isActive && entry.isInstalled)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.success.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '当前使用中',
                      style: textTheme.labelSmall?.copyWith(
                        color: tokens.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              entry.isInstalled
                  ? '路径：${entry.localPath}（${formatBytes(entry.installedBytes)}）'
                  : '如果您已在电脑上下载好了 HY-MT1.5 或其他兼容 GGUF 文件，可直接从手机存储导入使用。',
              style: textTheme.bodySmall?.copyWith(
                color: tokens.textSecondary,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: EchoSecondaryButton(
                    key: const Key('translation_import_gguf_button'),
                    label: entry.isInstalled ? '重新导入 .gguf' : '从本地选择 .gguf 文件',
                    icon: Icons.folder_open_rounded,
                    onPressed: _importLocalGguf,
                  ),
                ),
                if (entry.isInstalled && !isActive) ...[
                  const SizedBox(width: 10),
                  EchoPrimaryButton(
                    label: '启用',
                    onPressed: () =>
                        mgr.setActiveModel(TranslationModelCatalog.modelIdImported),
                  ),
                ],
                if (entry.isInstalled) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: '移除导入模型',
                    onPressed: () async {
                      if (ref.read(translationEngineProvider).loadedModelPath ==
                          entry.localPath) {
                        await ref.read(translationEngineProvider).unload();
                      }
                      await mgr.deleteModel(TranslationModelCatalog.modelIdImported);
                    },
                    icon: Icon(Icons.delete_outline_rounded, color: tokens.error),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
