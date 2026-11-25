import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/offline/offline_store.dart' show formatBytes;
import '../../core/settings/standalone_config_store.dart';
import '../../core/tts/sherpa_tts_engine.dart';
import '../../core/tts/tts_model_catalog.dart';
import '../../core/tts/tts_model_manager.dart';
import '../../core/tts/wav_encoder.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import 'zipvoice_reference_recorder_page.dart';

/// 端侧语音管理页（极简书房 Editorial Minimalism）：
/// - 严格单镜像下拉选择（支持自定义加速前缀）与旧 Kokoro/Piper 残留清理；
/// - Android 系统语音（含 MultiTTS 等已安装引擎）与离线 ZipVoice / MeloTTS / Matcha 管理；
/// - ZipVoice 自定义参考音频克隆、本地压缩包导入与一键试听。
class TtsModelManagerPage extends ConsumerStatefulWidget {
  const TtsModelManagerPage({super.key});

  @override
  ConsumerState<TtsModelManagerPage> createState() =>
      _TtsModelManagerPageState();
}

class _TtsModelManagerPageState extends ConsumerState<TtsModelManagerPage> {
  final AudioPlayer _previewPlayer = AudioPlayer();
  late final TextEditingController _customMirrorCtrl;
  String? _auditioningModelId;
  String? _customMirrorError;

  @override
  void initState() {
    super.initState();
    _customMirrorCtrl = TextEditingController(
      text: ref.read(standaloneConfigProvider).customTtsMirrorPrefix,
    );
  }

  @override
  void dispose() {
    _customMirrorCtrl.dispose();
    _previewPlayer.dispose();
    super.dispose();
  }

  Future<void> _audition(TtsModelStatusEntry entry, int speakerId) async {
    final paths = entry.resolvedPaths;
    if (paths == null) return;
    setState(() => _auditioningModelId = entry.spec.id);
    try {
      await _previewPlayer.stop();
      final engine = ref.read(onDeviceTtsEngineProvider);
      await engine.loadModel(paths);
      final speed = ref.read(standaloneConfigProvider).defaultTtsSpeed;
      final res = await engine.synthesize(
        '你好，欢迎使用回声离线语音朗读。',
        speakerId: speakerId,
        speed: speed,
      );
      if (res.samples.isEmpty || res.sampleRate <= 0) {
        throw StateError('未生成有效试听音频');
      }
      final wav = encodeFloat32ToWav(res.samples, sampleRate: res.sampleRate);
      final tmpDir = await getTemporaryDirectory();
      final outFile = File(p.join(tmpDir.path, 'echo_tts_audition.wav'));
      await outFile.writeAsBytes(wav, flush: true);
      await _previewPlayer.setFilePath(outFile.path);
      await _previewPlayer.play();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('试听失败：$e')));
    } finally {
      if (mounted) setState(() => _auditioningModelId = null);
    }
  }

  Future<void> _importLocal(TtsModelSpec spec) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['bz2', 'gz', 'tgz', 'zip', 'onnx'],
    );
    final filePath = picked?.files.single.path;
    if (filePath == null || filePath.isEmpty) return;
    final err = await ref
        .read(ttsModelManagerProvider.notifier)
        .importLocalArchive(spec.id, File(filePath));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(err ?? '已成功导入 ${spec.name}')));
  }

  Future<void> _importZipVoiceReference() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['wav'],
    );
    final filePath = picked?.files.single.path;
    if (filePath == null || filePath.isEmpty || !mounted) return;

    final refTextCtrl = TextEditingController(
      text: ref.read(standaloneConfigProvider).zipvoiceRefText,
    );
    final refText = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('填写参考音频对应文字'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已选择：${p.basename(filePath)}'),
            const SizedBox(height: 8),
            TextField(
              controller: refTextCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '参考音频里说的内容',
                hintText: '请准确输入该 3-10 秒 WAV 文件里的人声文字，克隆效果更自然',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(refTextCtrl.text.trim()),
            child: const Text('应用参考音色'),
          ),
        ],
      ),
    );
    refTextCtrl.dispose();
    if (refText == null || !mounted) return;

    final err = await ref
        .read(ttsModelManagerProvider.notifier)
        .importZipVoiceReferenceAudio(File(filePath), refText);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err ?? '已切换为自定义参考音色（${p.basename(filePath)}）')),
    );
  }

  Future<void> _openZipVoiceRecorder() async {
    await _previewPlayer.stop();
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const ZipVoiceReferenceRecorderPage(),
      ),
    );
  }

  Future<void> _saveCustomMirror() async {
    final raw = _customMirrorCtrl.text.trim();
    final err = TtsModelCatalog.validateCustomMirrorPrefix(raw);
    if (err != null) {
      setState(() => _customMirrorError = err);
      return;
    }
    setState(() => _customMirrorError = null);
    await ref
        .read(standaloneConfigProvider.notifier)
        .setCustomTtsMirrorPrefix(raw);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已保存自定义加速镜像前缀')));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final modelsState = ref.watch(ttsModelManagerProvider);
    final config = ref.watch(standaloneConfigProvider);
    final configCtrl = ref.read(standaloneConfigProvider.notifier);
    final manager = ref.read(ttsModelManagerProvider.notifier);

    final mirrorIds = TtsModelCatalog.downloadMirrors.map((m) => m.id).toSet();
    final selectedMirrorId = mirrorIds.contains(config.ttsDownloadMirror)
        ? config.ttsDownloadMirror
        : TtsModelCatalog.mirrorGhFast;

    return Scaffold(
      appBar: AppBar(
        title: const Text('语音模型与引擎管理'),
        actions: [
          IconButton(
            tooltip: '刷新模型状态',
            onPressed: manager.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: EchoAmbientBackground(
        child: ListView(
          padding: const EdgeInsets.all(EchoMetrics.pagePadding),
          children: [
            const EchoSectionHeader(title: '下载源'),
            const SizedBox(height: 10),
            Container(
              key: const Key('tts_mirror_card'),
              padding: const EdgeInsets.all(16),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '模型下载镜像源',
                    style: textTheme.titleSmall?.copyWith(
                      color: tokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '严格仅使用所选镜像下载，不静默跳转其他源；若失败请切换镜像后继续断点续传',
                    style: textTheme.bodySmall?.copyWith(
                      fontSize: 12.5,
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonHideUnderline(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                      ),
                      child: DropdownButton<String>(
                        key: const Key('tts_mirror_dropdown'),
                        isExpanded: true,
                        value: selectedMirrorId,
                        items: [
                          for (final opt in TtsModelCatalog.downloadMirrors)
                            DropdownMenuItem<String>(
                              value: opt.id,
                              child: Text(opt.label),
                            ),
                        ],
                        onChanged: (nextId) async {
                          if (nextId == null) return;
                          await configCtrl.setTtsDownloadMirror(nextId);
                          if (mounted) {
                            setState(() => _customMirrorError = null);
                          }
                        },
                      ),
                    ),
                  ),
                  if (selectedMirrorId == TtsModelCatalog.mirrorCustom) ...[
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('tts_custom_mirror_field'),
                            controller: _customMirrorCtrl,
                            keyboardType: TextInputType.url,
                            decoration: InputDecoration(
                              labelText: '自定义加速前缀',
                              hintText: 'https://ghfast.top/',
                              errorText: _customMirrorError,
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          key: const Key('tts_custom_mirror_save'),
                          onPressed: _saveCustomMirror,
                          child: const Text('保存前缀'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),

            // 旧模型残留清理提醒
            if (modelsState.legacyModelsSizeBytes > 0) ...[
              Container(
                key: const Key('tts_legacy_cleanup_card'),
                padding: const EdgeInsets.all(14),
                decoration: echoElevatedCardDecoration(
                  context,
                  radius: 16,
                  borderColor: tokens.warning.withValues(alpha: 0.35),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.cleaning_services_outlined,
                      color: tokens.warning,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '检测到已下架旧模型残留（${formatBytes(modelsState.legacyModelsSizeBytes)}）',
                            style: textTheme.titleSmall?.copyWith(
                              color: tokens.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Kokoro / Piper 已移除，清理后可释放手机空间',
                            style: textTheme.bodySmall?.copyWith(
                              fontSize: 12.5,
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      key: const Key('tts_legacy_cleanup_button'),
                      onPressed: () async {
                        final freed = await manager.cleanupLegacyModels();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已清理旧模型，释放 ${formatBytes(freed)}'),
                          ),
                        );
                      },
                      child: const Text('一键清理'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: EchoMetrics.space3),
            ],

            const EchoSectionHeader(title: '可用引擎与离线模型'),
            const SizedBox(height: 10),
            for (final entry in modelsState.orderedEntries) ...[
              if (entry.spec.isSystemTts)
                _SystemTtsCard(
                  entry: entry,
                  modelsState: modelsState,
                  config: config,
                  isActive: config.activeTtsModelId == entry.spec.id,
                  isAuditioning: _auditioningModelId == entry.spec.id,
                  onSelectEngine: manager.selectSystemTtsEngine,
                  onSelectVoice: manager.selectSystemTtsVoice,
                  onReloadInfo: manager.reloadSystemTtsInfo,
                  onSelectActive: () => configCtrl.setActiveTtsModel(
                    entry.spec.id,
                    speakerId: 0,
                  ),
                  onAudition: () => _audition(entry, 0),
                )
              else
                _ModelCard(
                  entry: entry,
                  config: config,
                  isActive: config.activeTtsModelId == entry.spec.id,
                  activeSpeakerId: config.activeTtsSpeakerId,
                  isAuditioning: _auditioningModelId == entry.spec.id,
                  onDownload: () async {
                    final err = await manager.downloadModel(entry.spec.id);
                    if (!context.mounted) return;
                    if (err != null) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(err)));
                    }
                  },
                  onPause: () => manager.pauseDownload(entry.spec.id),
                  onClearPartial: () =>
                      manager.clearPartialDownload(entry.spec.id),
                  onImportLocal: () => _importLocal(entry.spec),
                  onRecordZipVoiceRef: _openZipVoiceRecorder,
                  onImportZipVoiceRef: _importZipVoiceReference,
                  onResetZipVoiceRef: manager.resetZipVoiceReferenceAudio,
                  onDelete: () async {
                    await manager.deleteModel(entry.spec.id);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已删除 ${entry.spec.name}')),
                    );
                  },
                  onSelectActive: () => configCtrl.setActiveTtsModel(
                    entry.spec.id,
                    speakerId: entry.spec.speakers.first.id,
                  ),
                  onSelectSpeaker: (sid) async {
                    await configCtrl.setActiveTtsModel(
                      entry.spec.id,
                      speakerId: sid,
                    );
                  },
                  onAudition: (sid) => _audition(entry, sid),
                ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _SystemTtsCard extends StatelessWidget {
  const _SystemTtsCard({
    required this.entry,
    required this.modelsState,
    required this.config,
    required this.isActive,
    required this.isAuditioning,
    required this.onSelectEngine,
    required this.onSelectVoice,
    required this.onReloadInfo,
    required this.onSelectActive,
    required this.onAudition,
  });

  final TtsModelStatusEntry entry;
  final TtsModelsState modelsState;
  final StandaloneConfig config;
  final bool isActive;
  final bool isAuditioning;
  final ValueChanged<String> onSelectEngine;
  final ValueChanged<String> onSelectVoice;
  final VoidCallback onReloadInfo;
  final VoidCallback onSelectActive;
  final VoidCallback onAudition;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final spec = entry.spec;

    final engineItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('跟随系统默认引擎')),
      for (final eng in modelsState.systemEngines)
        DropdownMenuItem<String>(
          value: eng.packageName,
          child: Text(
            eng.isDefault ? '${eng.label}（默认）' : eng.label,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    final validEngines = engineItems.map((i) => i.value).toSet();
    final selectedEngine = validEngines.contains(config.systemTtsEngine)
        ? config.systemTtsEngine
        : '';

    final voiceItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('跟随引擎默认音色')),
      for (final v in modelsState.systemVoices)
        DropdownMenuItem<String>(
          value: v.name,
          child: Text(v.label, overflow: TextOverflow.ellipsis),
        ),
    ];
    final validVoices = voiceItems.map((i) => i.value).toSet();
    final selectedVoice = validVoices.contains(config.systemTtsVoice)
        ? config.systemTtsVoice
        : '';

    return Container(
      key: const Key('tts_system_card'),
      padding: const EdgeInsets.all(16),
      decoration: echoElevatedCardDecoration(
        context,
        radius: 16,
        borderColor: isActive
            ? tokens.primary.withValues(alpha: 0.45)
            : echoHairlineColor(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spec.name,
                  style: textTheme.titleMedium?.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              EchoPillBadge(
                label: isActive ? '当前使用' : spec.recommendedTag,
                color: isActive ? tokens.primary : tokens.textSecondary,
                filled: isActive,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            spec.subtitle,
            style: textTheme.bodySmall?.copyWith(
              fontSize: 13,
              color: tokens.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          if (!modelsState.systemTtsSupported)
            Text(
              '仅 Android 真机可用（免下载调起系统自带、MultiTTS 等语音引擎）',
              style: textTheme.labelMedium?.copyWith(color: tokens.textDisabled),
            )
          else ...[
            if (modelsState.systemTtsError != null) ...[
              Text(
                modelsState.systemTtsError!,
                style: textTheme.bodySmall?.copyWith(color: tokens.error),
              ),
              const SizedBox(height: 8),
            ],
            DropdownButtonHideUnderline(
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '本机语音引擎',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                child: DropdownButton<String>(
                  key: const Key('tts_system_engine_dropdown'),
                  isExpanded: true,
                  value: selectedEngine,
                  items: engineItems,
                  onChanged: (v) {
                    if (v != null) onSelectEngine(v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonHideUnderline(
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '引擎音色',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                child: DropdownButton<String>(
                  key: const Key('tts_system_voice_dropdown'),
                  isExpanded: true,
                  value: selectedVoice,
                  items: voiceItems,
                  onChanged: (v) {
                    if (v != null) onSelectVoice(v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (!isActive) ...[
                  FilledButton(
                    onPressed: onSelectActive,
                    child: const Text('设为默认'),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton.icon(
                  onPressed: isAuditioning ? null : onAudition,
                  icon: isAuditioning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.volume_up_outlined, size: 18),
                  label: Text(isAuditioning ? '合成中...' : '试听'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新系统引擎与音色列表',
                  color: tokens.textSecondary,
                  onPressed: onReloadInfo,
                  icon: const Icon(Icons.sync_rounded, size: 20),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.entry,
    required this.config,
    required this.isActive,
    required this.activeSpeakerId,
    required this.isAuditioning,
    required this.onDownload,
    required this.onPause,
    required this.onClearPartial,
    required this.onImportLocal,
    required this.onRecordZipVoiceRef,
    required this.onImportZipVoiceRef,
    required this.onResetZipVoiceRef,
    required this.onDelete,
    required this.onSelectActive,
    required this.onSelectSpeaker,
    required this.onAudition,
  });

  final TtsModelStatusEntry entry;
  final StandaloneConfig config;
  final bool isActive;
  final int activeSpeakerId;
  final bool isAuditioning;
  final VoidCallback onDownload;
  final VoidCallback onPause;
  final VoidCallback onClearPartial;
  final VoidCallback onImportLocal;
  final VoidCallback onRecordZipVoiceRef;
  final VoidCallback onImportZipVoiceRef;
  final VoidCallback onResetZipVoiceRef;
  final VoidCallback onDelete;
  final VoidCallback onSelectActive;
  final ValueChanged<int> onSelectSpeaker;
  final ValueChanged<int> onAudition;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final spec = entry.spec;

    final selectedSid = spec.speakers.any((s) => s.id == activeSpeakerId)
        ? activeSpeakerId
        : spec.speakers.first.id;
    final hasCustomZipVoiceRef = config.zipvoiceRefAudioPath.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: echoElevatedCardDecoration(
        context,
        radius: 16,
        borderColor: isActive
            ? tokens.primary.withValues(alpha: 0.45)
            : echoHairlineColor(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spec.name,
                  style: textTheme.titleMedium?.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              EchoPillBadge(
                label: isActive ? '当前使用' : spec.recommendedTag,
                color: isActive ? tokens.primary : tokens.textSecondary,
                filled: isActive,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            spec.subtitle,
            style: textTheme.bodySmall?.copyWith(
              fontSize: 13,
              color: tokens.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.isInstalled
                ? '已安装 · 占用 ${formatBytes(entry.installedBytes)}'
                : '预计下载约 ${spec.estimatedSizeMb} MB',
            style: textTheme.labelSmall?.copyWith(
              color: tokens.textDisabled,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),

          if (entry.isBusy || entry.isPaused) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: entry.progress > 0
                    ? entry.progress
                    : (entry.isPaused ? 0 : null),
                minHeight: 4,
                backgroundColor: tokens.surfaceSubtle,
                color: tokens.primary,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.statusText,
                    style: textTheme.labelSmall?.copyWith(
                      color: tokens.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (entry.status == ModelInstallStatus.downloading)
                  TextButton(onPressed: onPause, child: const Text('暂停')),
              ],
            ),
          ],

          if (entry.error != null) ...[
            const SizedBox(height: 8),
            Text(
              entry.error!,
              style: textTheme.bodySmall?.copyWith(color: tokens.error),
            ),
          ],

          if (entry.isInstalled) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final speaker in spec.speakers)
                  ChoiceChip(
                    label: Text(speaker.name),
                    selected: isActive && selectedSid == speaker.id,
                    onSelected: (_) => onSelectSpeaker(speaker.id),
                  ),
              ],
            ),
            if (spec.kind == TtsModelKind.zipvoice) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: echoElevatedCardDecoration(
                  context,
                  radius: 12,
                  color: tokens.surfaceBase,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasCustomZipVoiceRef
                          ? '参考音色：自定义 (${p.basename(config.zipvoiceRefAudioPath)})'
                          : '参考音色：内置默认示例（可现场录制或导入 WAV 克隆音色）',
                      style: textTheme.labelMedium?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((entry.resolvedPaths?.referenceText ?? '')
                        .isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '参考文本：${entry.resolvedPaths!.referenceText}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          key: const Key('tts_zipvoice_record_ref'),
                          onPressed: onRecordZipVoiceRef,
                          icon: const Icon(Icons.mic_rounded, size: 16),
                          label: const Text('录制参考音色'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('tts_zipvoice_import_ref'),
                          onPressed: onImportZipVoiceRef,
                          icon: const Icon(Icons.folder_open_outlined, size: 16),
                          label: const Text('导入 WAV'),
                        ),
                        if (hasCustomZipVoiceRef)
                          TextButton(
                            key: const Key('tts_zipvoice_reset_ref'),
                            onPressed: onResetZipVoiceRef,
                            child: const Text('恢复默认'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                if (!isActive) ...[
                  FilledButton(
                    onPressed: onSelectActive,
                    child: const Text('设为默认'),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton.icon(
                  onPressed: isAuditioning
                      ? null
                      : () => onAudition(selectedSid),
                  icon: isAuditioning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.volume_up_outlined, size: 18),
                  label: Text(isAuditioning ? '合成中...' : '试听'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '删除模型释放空间',
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: tokens.error,
                  ),
                ),
              ],
            ),
          ] else if (!entry.isBusy) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onDownload,
                  icon: Icon(
                    entry.isPaused
                        ? Icons.play_arrow_rounded
                        : Icons.download_outlined,
                    size: 18,
                  ),
                  label: Text(entry.isPaused ? '继续下载' : '一键下载'),
                ),
                if (entry.isPaused)
                  OutlinedButton.icon(
                    onPressed: onClearPartial,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('清除断点'),
                  ),
                EchoSecondaryButton(
                  onPressed: onImportLocal,
                  icon: Icons.folder_open_outlined,
                  label: '导入本地包',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
