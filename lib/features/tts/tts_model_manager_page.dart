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
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';

/// 端侧语音模型管理页：支持国内镜像/官方源下载、本地压缩包导入、切换默认模型/音色与一键试听。
class TtsModelManagerPage extends ConsumerStatefulWidget {
  const TtsModelManagerPage({super.key});

  @override
  ConsumerState<TtsModelManagerPage> createState() =>
      _TtsModelManagerPageState();
}

class _TtsModelManagerPageState extends ConsumerState<TtsModelManagerPage> {
  final AudioPlayer _previewPlayer = AudioPlayer();
  String? _auditioningModelId;

  @override
  void dispose() {
    _previewPlayer.dispose();
    super.dispose();
  }

  Future<void> _audition(TtsModelStatusEntry entry, int speakerId) async {
    final paths = entry.resolvedPaths;
    if (paths == null) return;
    setState(() => _auditioningModelId = entry.spec.id);
    try {
      final engine = ref.read(onDeviceTtsEngineProvider);
      await engine.loadModel(paths);
      final speed = ref.read(standaloneConfigProvider).defaultTtsSpeed;
      final res = await engine.synthesize(
        '你好，欢迎使用回声离线语音朗读。',
        speakerId: speakerId,
        speed: speed,
      );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? '已成功导入 ${spec.name}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final modelsState = ref.watch(ttsModelManagerProvider);
    final config = ref.watch(standaloneConfigProvider);
    final configCtrl = ref.read(standaloneConfigProvider.notifier);
    final manager = ref.read(ttsModelManagerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('离线语音模型管理'),
        actions: [
          IconButton(
            tooltip: '刷新模型状态',
            onPressed: manager.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: EchoAmbientBackground(
        child: ListView(
          padding: const EdgeInsets.all(EchoMetrics.space3),
          children: [
            // 下载源设置卡片
            Container(
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: SwitchListTile(
                title: Text(
                  '优先使用国内加速镜像',
                  style: textTheme.titleSmall?.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '开启后优先从国内镜像下载模型，失败时自动回退 GitHub 官方源',
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
                value: config.preferCnMirror,
                onChanged: configCtrl.setPreferCnMirror,
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),

            // 模型列表
            for (final entry in modelsState.orderedEntries) ...[
              _ModelCard(
                entry: entry,
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
              const SizedBox(height: EchoMetrics.space2),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.entry,
    required this.isActive,
    required this.activeSpeakerId,
    required this.isAuditioning,
    required this.onDownload,
    required this.onPause,
    required this.onClearPartial,
    required this.onImportLocal,
    required this.onDelete,
    required this.onSelectActive,
    required this.onSelectSpeaker,
    required this.onAudition,
  });

  final TtsModelStatusEntry entry;
  final bool isActive;
  final int activeSpeakerId;
  final bool isAuditioning;
  final VoidCallback onDownload;
  final VoidCallback onPause;
  final VoidCallback onClearPartial;
  final VoidCallback onImportLocal;
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

    return Container(
      padding: const EdgeInsets.all(EchoMetrics.space3),
      decoration: echoElevatedCardDecoration(context, radius: 16),
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
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (isActive ? tokens.primary : tokens.accent)
                      .withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  isActive ? '当前使用' : spec.recommendedTag,
                  style: textTheme.labelSmall?.copyWith(
                    color: isActive ? tokens.primary : tokens.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            spec.subtitle,
            style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            entry.isInstalled
                ? '已安装 · 占用 ${formatBytes(entry.installedBytes)}'
                : '预计下载约 ${spec.estimatedSizeMb} MB',
            style: textTheme.labelSmall?.copyWith(color: tokens.textDisabled),
          ),

          if (entry.isBusy || entry.isPaused) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: entry.progress > 0 ? entry.progress : (entry.isPaused ? 0 : null),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.statusText,
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
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
            const SizedBox(height: 12),
            Row(
              children: [
                if (!isActive)
                  FilledButton.tonal(
                    onPressed: onSelectActive,
                    child: const Text('设为默认'),
                  ),
                if (!isActive) const SizedBox(width: 8),
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
                  icon: Icon(Icons.delete_outline, color: tokens.error),
                ),
              ],
            ),
          ] else if (!entry.isBusy) ...[
            const SizedBox(height: 12),
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
                OutlinedButton.icon(
                  onPressed: onImportLocal,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('导入本地包'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
