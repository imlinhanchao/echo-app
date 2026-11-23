import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../offline/offline_store.dart' show formatBytes;
import '../settings/standalone_config_store.dart';
import 'download_keepalive_service.dart';
import 'resumable_downloader.dart';
import 'tts_model_catalog.dart';
import 'wav_encoder.dart';

/// 已安装且通过完整性校验的端侧模型本地路径集合。
@immutable
class ResolvedTtsModelPaths {
  const ResolvedTtsModelPaths({
    required this.spec,
    required this.rootDir,
    required this.modelPath,
    required this.tokensPath,
    this.decoderPath = '',
    this.voicesPath = '',
    this.vocoderPath = '',
    this.lexiconPath = '',
    this.dataDir = '',
    this.dictDir = '',
    this.ruleFsts = '',
    this.referenceAudioPath = '',
    this.referenceText = '',
    this.systemEnginePackage = '',
    this.systemVoiceName = '',
  });

  final TtsModelSpec spec;
  final String rootDir;
  final String modelPath;
  final String tokensPath;
  final String decoderPath;
  final String voicesPath;
  final String vocoderPath;
  final String lexiconPath;
  final String dataDir;
  final String dictDir;
  final String ruleFsts;
  final String referenceAudioPath;
  final String referenceText;
  final String systemEnginePackage;
  final String systemVoiceName;

  /// 用于判定引擎是否需要重载配置的唯一指纹。
  String get cacheKey => <String>[
    spec.id,
    modelPath,
    decoderPath,
    vocoderPath,
    tokensPath,
    ruleFsts,
    referenceAudioPath,
    referenceText,
    systemEnginePackage,
    systemVoiceName,
  ].join('|');
}

enum ModelInstallStatus {
  notInstalled,
  downloading,
  paused,
  extracting,
  installed,
}

@immutable
class TtsModelStatusEntry {
  const TtsModelStatusEntry({
    required this.spec,
    this.status = ModelInstallStatus.notInstalled,
    this.progress = 0.0,
    this.statusText = '',
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.installedBytes = 0,
    this.resolvedPaths,
    this.error,
  });

  final TtsModelSpec spec;
  final ModelInstallStatus status;
  final double progress;
  final String statusText;
  final int downloadedBytes;
  final int totalBytes;
  final int installedBytes;
  final ResolvedTtsModelPaths? resolvedPaths;
  final String? error;

  bool get isInstalled =>
      status == ModelInstallStatus.installed && resolvedPaths != null;
  bool get isBusy =>
      status == ModelInstallStatus.downloading ||
      status == ModelInstallStatus.extracting;
  bool get isPaused => status == ModelInstallStatus.paused;

  TtsModelStatusEntry copyWith({
    ModelInstallStatus? status,
    double? progress,
    String? statusText,
    int? downloadedBytes,
    int? totalBytes,
    int? installedBytes,
    ResolvedTtsModelPaths? resolvedPaths,
    bool clearPaths = false,
    String? error,
    bool clearError = false,
  }) {
    return TtsModelStatusEntry(
      spec: spec,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      statusText: statusText ?? this.statusText,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      installedBytes: installedBytes ?? this.installedBytes,
      resolvedPaths: clearPaths ? null : (resolvedPaths ?? this.resolvedPaths),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

@immutable
class TtsModelsState {
  const TtsModelsState({
    this.entries = const <String, TtsModelStatusEntry>{},
    this.initialized = false,
    this.legacyModelIds = const <String>[],
    this.legacyModelsSizeBytes = 0,
  });

  final Map<String, TtsModelStatusEntry> entries;
  final bool initialized;
  final List<String> legacyModelIds;
  final int legacyModelsSizeBytes;

  List<TtsModelStatusEntry> get orderedEntries => TtsModelCatalog.all
      .map((s) => entries[s.id] ?? TtsModelStatusEntry(spec: s))
      .toList();

  List<TtsModelStatusEntry> get installedEntries =>
      orderedEntries.where((e) => e.isInstalled).toList();

  TtsModelStatusEntry? entryOf(String id) => entries[id];
}

/// 端侧 TTS 模型管理器：
/// - Android 前台服务保活（防止锁屏/切后台断流）
/// - HTTP Range 断点续传与多镜像自动切换
/// - 切回前台自动恢复因网络中断的下载
/// - Isolate 解压、完整性校验、本地导入与删除
class TtsModelManager extends StateNotifier<TtsModelsState> {
  TtsModelManager(
    this._configController, {
    Dio? dio,
    Directory? rootDirOverride,
    DownloadKeepAliveService? keepAliveService,
    ResumableFileDownloader? downloader,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(minutes: 20),
             ),
           ),
       _rootDirOverride = rootDirOverride,
       _keepAlive = keepAliveService ?? const PlatformDownloadKeepAliveService(),
       _downloader = downloader ?? const ResumableFileDownloader(),
       super(const TtsModelsState()) {
    refresh();
  }

  final StandaloneConfigController _configController;
  final Dio _dio;
  final Directory? _rootDirOverride;
  final DownloadKeepAliveService _keepAlive;
  final ResumableFileDownloader _downloader;
  final Map<String, CancelToken> _cancelTokens = <String, CancelToken>{};
  final Set<String> _autoResumeModelIds = <String>{};
  final Set<String> _userPausedModelIds = <String>{};

  TtsModelsState get currentState => state;

  Future<Directory> _modelsRoot() async {
    if (_rootDirOverride != null) {
      await _rootDirOverride.create(recursive: true);
      return _rootDirOverride;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'echo_tts_models'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> refresh() async {
    final Directory root;
    try {
      root = await _modelsRoot();
    } catch (_) {
      // 无平台通道（如纯 Widget 单测环境）时保持未安装空态，不抛未捕获异常。
      if (!mounted) return;
      state = TtsModelsState(
        entries: <String, TtsModelStatusEntry>{
          for (final spec in TtsModelCatalog.all)
            spec.id: TtsModelStatusEntry(spec: spec),
        },
        initialized: true,
      );
      return;
    }
    final map = <String, TtsModelStatusEntry>{};
    for (final spec in TtsModelCatalog.all) {
      if (spec.isSystemTts) {
        map[spec.id] = TtsModelStatusEntry(spec: spec);
        continue;
      }
      final existing = state.entries[spec.id];
      if (existing != null && existing.isBusy) {
        map[spec.id] = existing;
        continue;
      }
      final modelDir = Directory(p.join(root.path, spec.id));
      final resolved = await _resolveInstalledModel(spec, modelDir);
      if (resolved != null) {
        final bytes = _dirSizeSync(modelDir);
        map[spec.id] = TtsModelStatusEntry(
          spec: spec,
          status: ModelInstallStatus.installed,
          progress: 1.0,
          installedBytes: bytes,
          resolvedPaths: resolved,
        );
      } else {
        final tmpDir = Directory(p.join(root.path, '.tmp_${spec.id}'));
        final partial = _scanPartialSummary(spec, tmpDir);
        if (partial.downloadedBytes > 0) {
          map[spec.id] = TtsModelStatusEntry(
            spec: spec,
            status: ModelInstallStatus.paused,
            progress: partial.progress,
            downloadedBytes: partial.downloadedBytes,
            totalBytes: partial.totalBytes,
            statusText: _pausedStatusText(
              partial.downloadedBytes,
              partial.totalBytes,
            ),
          );
        } else {
          map[spec.id] = TtsModelStatusEntry(spec: spec);
        }
      }
    }

    final foundLegacyIds = <String>[];
    var legacyBytes = 0;
    for (final legacyId in TtsModelCatalog.legacyModelIds) {
      var dirBytes = 0;
      final d1 = Directory(p.join(root.path, legacyId));
      final d2 = Directory(p.join(root.path, '.tmp_$legacyId'));
      if (d1.existsSync()) dirBytes += _dirSizeSync(d1);
      if (d2.existsSync()) dirBytes += _dirSizeSync(d2);
      if (d1.existsSync() || d2.existsSync()) {
        foundLegacyIds.add(legacyId);
        legacyBytes += dirBytes;
      }
    }

    if (!mounted) return;
    state = TtsModelsState(
      entries: map,
      initialized: true,
      legacyModelIds: List<String>.unmodifiable(foundLegacyIds),
      legacyModelsSizeBytes: legacyBytes,
    );

    // 若当前尚未选定模型或选中的旧模型已下架且无安装，自动切换到第一个可用模型或清空无效 ID。
    final activeId = _configController.state.activeTtsModelId;
    final activeInvalidOrMissing =
        activeId.isEmpty || !(map[activeId]?.isInstalled ?? false);
    if (activeInvalidOrMissing) {
      final firstInstalled = map.values
          .cast<TtsModelStatusEntry?>()
          .firstWhere((e) => e?.isInstalled == true, orElse: () => null);
      if (firstInstalled != null) {
        await _configController.setActiveTtsModel(
          firstInstalled.spec.id,
          speakerId: firstInstalled.spec.speakers.first.id,
        );
      } else if (activeId.isNotEmpty && TtsModelCatalog.byId(activeId) == null) {
        await _configController.setActiveTtsModel('', speakerId: 0);
      }
    }
  }

  void _updateEntry(
    String modelId,
    TtsModelStatusEntry Function(TtsModelStatusEntry) transform,
  ) {
    if (!mounted) return;
    final spec = TtsModelCatalog.byId(modelId);
    if (spec == null) return;
    final cur = state.entries[modelId] ?? TtsModelStatusEntry(spec: spec);
    state = TtsModelsState(
      entries: <String, TtsModelStatusEntry>{
        ...state.entries,
        modelId: transform(cur),
      },
      initialized: state.initialized,
      legacyModelIds: state.legacyModelIds,
      legacyModelsSizeBytes: state.legacyModelsSizeBytes,
    );
  }

  /// 下载或从断点续传安装指定模型（严格使用用户所选单一镜像 + 前台服务保活）。
  Future<String?> downloadModel(
    String modelId, {
    String? mirrorIdOverride,
    String? customPrefixOverride,
  }) async {
    final spec = TtsModelCatalog.byId(modelId);
    if (spec == null) return '未知模型：$modelId';
    if (spec.isSystemTts) return null;
    if (state.entries[modelId]?.isBusy == true) return null;

    final mirrorId = mirrorIdOverride ?? _configController.state.ttsDownloadMirror;
    final customPrefix =
        customPrefixOverride ?? _configController.state.customTtsMirrorPrefix;
    if (mirrorId == TtsModelCatalog.mirrorCustom) {
      final err = TtsModelCatalog.validateCustomMirrorPrefix(customPrefix);
      if (err != null) {
        _updateEntry(modelId, (cur) => cur.copyWith(error: err));
        return err;
      }
    }
    final mirrorOpt = TtsModelCatalog.mirrorById(mirrorId);

    _userPausedModelIds.remove(modelId);
    _autoResumeModelIds.remove(modelId);

    final cancelToken = CancelToken();
    _cancelTokens[modelId] = cancelToken;

    final root = await _modelsRoot();
    final modelDir = Directory(p.join(root.path, spec.id));
    final tmpDir = Directory(p.join(root.path, '.tmp_${spec.id}'));

    await tmpDir.create(recursive: true);
    await modelDir.create(recursive: true);

    final initialPartial = _scanPartialSummary(spec, tmpDir);
    _updateEntry(
      modelId,
      (e) => e.copyWith(
        status: ModelInstallStatus.downloading,
        progress: initialPartial.progress,
        downloadedBytes: initialPartial.downloadedBytes,
        totalBytes: initialPartial.totalBytes,
        statusText: initialPartial.downloadedBytes > 0
            ? '正在通过 ${mirrorOpt.label} 从断点续传（已下载 ${formatBytes(initialPartial.downloadedBytes)}）...'
            : '正在连接 ${mirrorOpt.label}...',
        clearError: true,
      ),
    );

    unawaited(
      _keepAlive.startOrUpdate(
        title: '正在下载 ${spec.name}',
        text: initialPartial.downloadedBytes > 0
            ? '正在从断点续传...'
            : '准备下载...',
        progress: (initialPartial.progress * 100).round(),
        max: 100,
      ),
    );

    var lastNotifAt = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      final totalAssets = spec.assets.length;
      for (var idx = 0; idx < totalAssets; idx++) {
        final asset = spec.assets[idx];
        final urls = asset.urlsForMirror(
          mirrorId: mirrorId,
          customPrefix: customPrefix,
        );
        final destFile = File(p.join(tmpDir.path, asset.filename));

        await _downloader.download(
          dio: _dio,
          urls: urls,
          destFile: destFile,
          cancelToken: cancelToken,
          onProgress: (received, total, mirrorIdx, mirrorCount) {
            final assetFrac = total > 0 ? (received / total) : 0.0;
            final overall = ((idx + assetFrac) / totalAssets) * 0.88;
            final pct = (overall * 100).round().clamp(0, 88);
            final text = total > 0
                ? '下载中 ${(assetFrac * 100).toStringAsFixed(0)}% · ${formatBytes(received)} / ${formatBytes(total)}（${mirrorOpt.label}）'
                : '下载中 ${formatBytes(received)}（${mirrorOpt.label}）';

            _updateEntry(
              modelId,
              (e) => e.copyWith(
                status: ModelInstallStatus.downloading,
                progress: overall.clamp(0.0, 0.88),
                downloadedBytes: received,
                totalBytes: total,
                statusText: text,
                clearError: true,
              ),
            );

            final now = DateTime.now();
            if (now.difference(lastNotifAt).inMilliseconds >= 500) {
              lastNotifAt = now;
              unawaited(
                _keepAlive.startOrUpdate(
                  title: '正在下载 ${spec.name}',
                  text: text,
                  progress: pct,
                  max: 100,
                ),
              );
            }
          },
        );

        if (asset.isArchive) {
          _updateEntry(
            modelId,
            (e) => e.copyWith(
              status: ModelInstallStatus.extracting,
              progress: 0.90,
              statusText: '正在解压模型文件，请稍候...',
            ),
          );
          unawaited(
            _keepAlive.startOrUpdate(
              title: '正在安装 ${spec.name}',
              text: '正在解压模型文件...',
              progress: 90,
              max: 100,
            ),
          );
          await _extractArchiveInIsolate(destFile.path, modelDir.path);
        } else {
          final target = File(p.join(modelDir.path, asset.filename));
          await destFile.copy(target.path);
        }
      }

      final resolved = await _resolveInstalledModel(spec, modelDir);
      if (resolved == null) {
        throw Exception('模型文件不完整，校验未通过');
      }

      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }

      final bytes = _dirSizeSync(modelDir);
      _updateEntry(
        modelId,
        (e) => e.copyWith(
          status: ModelInstallStatus.installed,
          progress: 1.0,
          statusText: '已安装',
          downloadedBytes: bytes,
          totalBytes: bytes,
          installedBytes: bytes,
          resolvedPaths: resolved,
          clearError: true,
        ),
      );

      if (_configController.state.activeTtsModelId.isEmpty) {
        await _configController.setActiveTtsModel(
          spec.id,
          speakerId: spec.speakers.first.id,
        );
      }
      return null;
    } on DioException catch (e) {
      final isCancelled =
          e.type == DioExceptionType.cancel || cancelToken.isCancelled;
      final partial = _scanPartialSummary(spec, tmpDir);
      if (isCancelled) {
        final hasPart = partial.downloadedBytes > 0;
        _updateEntry(
          modelId,
          (cur) => cur.copyWith(
            status: hasPart
                ? ModelInstallStatus.paused
                : ModelInstallStatus.notInstalled,
            progress: partial.progress,
            downloadedBytes: partial.downloadedBytes,
            totalBytes: partial.totalBytes,
            statusText: hasPart
                ? _pausedStatusText(partial.downloadedBytes, partial.totalBytes)
                : '',
            clearError: true,
          ),
        );
        return hasPart ? '已暂停下载（已保留断点）' : '已取消下载';
      }

      // 网络异常中断：保留断点并标记回到前台自动续传
      _autoResumeModelIds.add(modelId);
      final hasPart = partial.downloadedBytes > 0;
      final errMsg = hasPart
          ? '「${mirrorOpt.label}」下载中断（已保留断点），可切换上方镜像或切回前台继续下载'
          : '「${mirrorOpt.label}」下载失败，请切换上方下载镜像后重试：${e.message}';
      _updateEntry(
        modelId,
        (cur) => cur.copyWith(
          status: hasPart
              ? ModelInstallStatus.paused
              : ModelInstallStatus.notInstalled,
          progress: partial.progress,
          downloadedBytes: partial.downloadedBytes,
          totalBytes: partial.totalBytes,
          statusText: hasPart
              ? _pausedStatusText(partial.downloadedBytes, partial.totalBytes)
              : '',
          error: errMsg,
        ),
      );
      return errMsg;
    } catch (e) {
      final partial = _scanPartialSummary(spec, tmpDir);
      final hasPart = partial.downloadedBytes > 0;
      if (hasPart && !_userPausedModelIds.contains(modelId)) {
        _autoResumeModelIds.add(modelId);
      }
      final rawMsg = e.toString().replaceFirst('Exception: ', '');
      final msg = hasPart
          ? '「${mirrorOpt.label}」下载中断（已保留断点），可切换上方镜像或切回前台继续下载'
          : '「${mirrorOpt.label}」下载失败，请切换上方下载镜像后重试：$rawMsg';
      _updateEntry(
        modelId,
        (cur) => cur.copyWith(
          status: hasPart
              ? ModelInstallStatus.paused
              : ModelInstallStatus.notInstalled,
          progress: partial.progress,
          downloadedBytes: partial.downloadedBytes,
          totalBytes: partial.totalBytes,
          statusText: hasPart
              ? _pausedStatusText(partial.downloadedBytes, partial.totalBytes)
              : '',
          error: msg,
        ),
      );
      return msg;
    } finally {
      _cancelTokens.remove(modelId);
      final stillBusy = state.entries.values.any((e) => e.isBusy);
      if (!stillBusy) {
        unawaited(_keepAlive.stop());
      }
    }
  }

  /// 暂停当前下载并保留磁盘上的 `.part` 断点文件。
  void pauseDownload(String modelId) {
    _userPausedModelIds.add(modelId);
    _autoResumeModelIds.remove(modelId);
    _cancelTokens[modelId]?.cancel('user_paused');
  }

  /// 兼容旧调用名称，默认执行保断点暂停。
  void cancelDownload(String modelId) => pauseDownload(modelId);

  /// 清除某模型的未完成断点文件并恢复初始未安装状态。
  Future<void> clearPartialDownload(String modelId) async {
    _userPausedModelIds.remove(modelId);
    _autoResumeModelIds.remove(modelId);
    _cancelTokens[modelId]?.cancel('user_cleared');

    final root = await _modelsRoot();
    final tmpDir = Directory(p.join(root.path, '.tmp_$modelId'));
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
    _updateEntry(
      modelId,
      (e) => e.copyWith(
        status: ModelInstallStatus.notInstalled,
        progress: 0,
        downloadedBytes: 0,
        totalBytes: 0,
        statusText: '',
        clearError: true,
      ),
    );
  }

  /// 应用回到前台时，自动继续先前因锁屏/断网中断的模型下载任务。
  Future<void> onAppResumed() async {
    if (_autoResumeModelIds.isEmpty) return;
    final ids = List<String>.of(_autoResumeModelIds);
    for (final id in ids) {
      if (_userPausedModelIds.contains(id)) continue;
      final entry = state.entries[id];
      if (entry == null || entry.isInstalled || entry.isBusy) continue;
      unawaited(downloadModel(id));
    }
  }

  /// 清理已下架的旧模型（Kokoro / Piper）目录与断点缓存，释放手机存储空间。
  Future<int> cleanupLegacyModels() async {
    final root = await _modelsRoot();
    var freed = 0;
    for (final legacyId in TtsModelCatalog.legacyModelIds) {
      for (final dir in <Directory>[
        Directory(p.join(root.path, legacyId)),
        Directory(p.join(root.path, '.tmp_$legacyId')),
      ]) {
        if (await dir.exists()) {
          freed += _dirSizeSync(dir);
          await dir.delete(recursive: true);
        }
      }
    }
    if (mounted) {
      state = TtsModelsState(
        entries: state.entries,
        initialized: state.initialized,
        legacyModelIds: const <String>[],
        legacyModelsSizeBytes: 0,
      );
    }
    return freed;
  }

  /// 为 ZipVoice 导入自定义参考音频（WAV + 对应文本），持久化拷贝后刷新路径配置。
  Future<String?> importZipVoiceReferenceAudio(
    File wavFile,
    String referenceText,
  ) async {
    final trimmedText = referenceText.trim();
    if (trimmedText.isEmpty) {
      return '请填写参考音频中朗读的文字内容';
    }
    if (!await wavFile.exists()) {
      return '所选 WAV 文件不存在';
    }
    try {
      final bytes = await wavFile.readAsBytes();
      final decoded = decodeWavToFloat32(bytes);
      final durS =
          decoded.sampleRate > 0 ? decoded.samples.length / decoded.sampleRate : 0.0;
      if (durS < 1.0) {
        return '参考音频过短（不足 1 秒），请选择 3-10 秒清晰人声 WAV';
      }
      if (durS > 25.0) {
        return '参考音频过长（${durS.toStringAsFixed(1)} 秒），请裁剪至 3-15 秒以保证手机推理速度';
      }
      final root = await _modelsRoot();
      final dest = File(p.join(root.path, 'zipvoice_custom_ref.wav'));
      await dest.writeAsBytes(bytes, flush: true);
      await _configController.setZipvoiceReference(
        audioPath: dest.path,
        text: trimmedText,
      );
      await refresh();
      return null;
    } catch (e) {
      return '参考音频校验失败：$e';
    }
  }

  /// 恢复 ZipVoice 内置默认参考音频与文本。
  Future<void> resetZipVoiceReferenceAudio() async {
    final root = await _modelsRoot();
    final customFile = File(p.join(root.path, 'zipvoice_custom_ref.wav'));
    if (await customFile.exists()) {
      try {
        await customFile.delete();
      } catch (_) {}
    }
    await _configController.setZipvoiceReference(audioPath: '', text: '');
    await refresh();
  }

  /// 从手机本地压缩包（`.tar.bz2` / `.tar.gz` / `.zip`）或单文件（如 `.onnx` vocoder）导入模型。
  Future<String?> importLocalArchive(String modelId, File archiveFile) async {
    final spec = TtsModelCatalog.byId(modelId);
    if (spec == null) return '未知模型：$modelId';
    final root = await _modelsRoot();
    final modelDir = Directory(p.join(root.path, spec.id));
    await modelDir.create(recursive: true);

    _updateEntry(
      modelId,
      (e) => e.copyWith(
        status: ModelInstallStatus.extracting,
        progress: 0.5,
        statusText: '正在导入本地模型包...',
        clearError: true,
      ),
    );

    try {
      final lower = archiveFile.path.toLowerCase();
      if (lower.endsWith('.onnx')) {
        await archiveFile.copy(
          p.join(modelDir.path, p.basename(archiveFile.path)),
        );
      } else {
        await _extractArchiveInIsolate(archiveFile.path, modelDir.path);
      }

      final resolved = await _resolveInstalledModel(spec, modelDir);
      if (resolved == null) {
        final msg = spec.vocoderFile.isNotEmpty
            ? '导入未完成：请确认压缩包包含模型文件，且同时导入 ${spec.vocoderFile}'
            : '压缩包缺少必需的模型文件（.onnx / tokens.txt）';
        _updateEntry(
          modelId,
          (e) => e.copyWith(
            status: ModelInstallStatus.notInstalled,
            progress: 0,
            statusText: '',
            error: msg,
          ),
        );
        return msg;
      }

      _updateEntry(
        modelId,
        (e) => e.copyWith(
          status: ModelInstallStatus.installed,
          progress: 1.0,
          statusText: '已安装',
          installedBytes: _dirSizeSync(modelDir),
          resolvedPaths: resolved,
          clearError: true,
        ),
      );
      if (_configController.state.activeTtsModelId.isEmpty) {
        await _configController.setActiveTtsModel(
          spec.id,
          speakerId: spec.speakers.first.id,
        );
      }
      return null;
    } catch (e) {
      final msg = '本地导入失败：$e';
      _updateEntry(
        modelId,
        (e) => e.copyWith(
          status: ModelInstallStatus.notInstalled,
          progress: 0,
          statusText: '',
          error: msg,
        ),
      );
      return msg;
    }
  }

  /// 删除已安装的本地模型释放空间（同时清理未完成的临时断点目录）。
  Future<void> deleteModel(String modelId) async {
    pauseDownload(modelId);
    _userPausedModelIds.remove(modelId);
    _autoResumeModelIds.remove(modelId);
    final root = await _modelsRoot();
    final modelDir = Directory(p.join(root.path, modelId));
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
    }
    final tmpDir = Directory(p.join(root.path, '.tmp_$modelId'));
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
    _updateEntry(
      modelId,
      (e) => e.copyWith(
        status: ModelInstallStatus.notInstalled,
        progress: 0,
        downloadedBytes: 0,
        totalBytes: 0,
        statusText: '',
        installedBytes: 0,
        clearPaths: true,
        clearError: true,
      ),
    );
    if (_configController.state.activeTtsModelId == modelId) {
      final fallback = state.installedEntries.firstOrNull;
      await _configController.setActiveTtsModel(
        fallback?.spec.id ?? '',
        speakerId: fallback?.spec.speakers.first.id ?? 0,
      );
    }
  }

  /// 获取当前激活模型的已解析路径（若无则回退任一已安装模型）。
  ResolvedTtsModelPaths? get activeModelPaths {
    final activeId = _configController.state.activeTtsModelId;
    final active = state.entries[activeId];
    if (active != null && active.isInstalled) return active.resolvedPaths;
    return state.installedEntries.firstOrNull?.resolvedPaths;
  }

  ({int downloadedBytes, int totalBytes, double progress}) _scanPartialSummary(
    TtsModelSpec spec,
    Directory tmpDir,
  ) {
    if (!tmpDir.existsSync()) {
      return (downloadedBytes: 0, totalBytes: 0, progress: 0.0);
    }
    var sumDownloaded = 0;
    var sumTotal = 0;
    var fractionSum = 0.0;
    for (final asset in spec.assets) {
      final st = ResumableFileDownloader.readPartialState(
        File(p.join(tmpDir.path, asset.filename)),
      );
      sumDownloaded += st.downloadedBytes;
      sumTotal += st.totalBytes;
      if (st.isComplete) {
        fractionSum += 1.0;
      } else if (st.totalBytes > 0) {
        fractionSum += (st.downloadedBytes / st.totalBytes).clamp(0.0, 1.0);
      }
    }
    final progress = spec.assets.isEmpty
        ? 0.0
        : ((fractionSum / spec.assets.length) * 0.88).clamp(0.0, 0.88);
    return (
      downloadedBytes: sumDownloaded,
      totalBytes: sumTotal,
      progress: progress,
    );
  }

  String _pausedStatusText(int downloadedBytes, int totalBytes) {
    if (totalBytes > 0) {
      return '已暂停 · 已下载 ${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)}';
    }
    return '已暂停 · 已下载 ${formatBytes(downloadedBytes)}';
  }

  Future<ResolvedTtsModelPaths?> _resolveInstalledModel(
    TtsModelSpec spec,
    Directory modelDir,
  ) async {
    if (!await modelDir.exists()) return null;

    // 兼容解压后存在一层同名子目录的情况
    Directory searchRoot = modelDir;
    final nested = Directory(p.join(modelDir.path, spec.id));
    if (await nested.exists()) {
      searchRoot = nested;
    }

    String? findFile(String name) {
      if (name.isEmpty) return '';
      final direct = File(p.join(searchRoot.path, name));
      if (direct.existsSync()) return direct.path;
      final inRoot = File(p.join(modelDir.path, name));
      if (inRoot.existsSync()) return inRoot.path;
      return null;
    }

    String findDir(String name) {
      if (name.isEmpty) return '';
      final direct = Directory(p.join(searchRoot.path, name));
      if (direct.existsSync()) return direct.path;
      final inRoot = Directory(p.join(modelDir.path, name));
      if (inRoot.existsSync()) return inRoot.path;
      return '';
    }

    String? modelPath;
    for (final candidate in spec.modelFileCandidates) {
      modelPath = findFile(candidate);
      if (modelPath != null) break;
    }
    if (modelPath == null) return null;

    var decoderPath = '';
    if (spec.decoderFileCandidates.isNotEmpty) {
      String? foundDecoder;
      for (final candidate in spec.decoderFileCandidates) {
        foundDecoder = findFile(candidate);
        if (foundDecoder != null) break;
      }
      if (foundDecoder == null) return null;
      decoderPath = foundDecoder;
    }

    final tokensPath = findFile(spec.tokensFile);
    if (tokensPath == null) return null;

    final voicesPath = spec.voicesFile.isEmpty
        ? ''
        : findFile(spec.voicesFile);
    if (spec.voicesFile.isNotEmpty && voicesPath == null) return null;

    final vocoderPath = spec.vocoderFile.isEmpty
        ? ''
        : findFile(spec.vocoderFile);
    if (spec.vocoderFile.isNotEmpty && vocoderPath == null) return null;

    final lexicons = <String>[];
    for (final lex in spec.lexiconFiles) {
      final found = findFile(lex);
      if (found != null && found.isNotEmpty) lexicons.add(found);
    }

    final ruleFsts = <String>[];
    for (final fst in spec.ruleFstFiles) {
      final found = findFile(fst);
      if (found != null && found.isNotEmpty) ruleFsts.add(found);
    }

    var refAudioPath = '';
    var refText = '';
    if (spec.kind == TtsModelKind.zipvoice) {
      final customPath = _configController.state.zipvoiceRefAudioPath;
      final customText = _configController.state.zipvoiceRefText;
      if (customPath.isNotEmpty &&
          customText.isNotEmpty &&
          File(customPath).existsSync()) {
        refAudioPath = customPath;
        refText = customText;
      } else {
        refAudioPath = findFile(spec.defaultReferenceAudio) ?? '';
        if (refAudioPath.isEmpty) {
          for (final dir in <Directory>[
            Directory(p.join(searchRoot.path, 'test_wavs')),
            Directory(p.join(modelDir.path, 'test_wavs')),
          ]) {
            if (dir.existsSync()) {
              final wav = dir
                  .listSync()
                  .whereType<File>()
                  .firstWhere(
                    (f) => f.path.toLowerCase().endsWith('.wav'),
                    orElse: () => File(''),
                  );
              if (wav.path.isNotEmpty) {
                refAudioPath = wav.path;
                break;
              }
            }
          }
        }
        refText = spec.defaultReferenceText;
      }
    }

    return ResolvedTtsModelPaths(
      spec: spec,
      rootDir: searchRoot.path,
      modelPath: modelPath,
      decoderPath: decoderPath,
      tokensPath: tokensPath,
      voicesPath: voicesPath ?? '',
      vocoderPath: vocoderPath ?? '',
      lexiconPath: lexicons.join(','),
      dataDir: findDir(spec.dataDirName),
      dictDir: findDir(spec.dictDirName),
      ruleFsts: ruleFsts.join(','),
      referenceAudioPath: refAudioPath,
      referenceText: refText,
    );
  }

  int _dirSizeSync(Directory dir) {
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += entity.lengthSync();
      }
    }
    return total;
  }
}

/// 顶层隔离函数：仅传纯字符串路径，避免闭包捕获 [TtsModelManager] 实例（含 `CancelToken`/`Completer`）。
Future<void> _extractArchiveInIsolate(String archivePath, String destDirPath) {
  return Isolate.run(() => _extractArchiveSync(archivePath, destDirPath));
}

/// 在后台 Isolate 中流式执行 `.tar.bz2` / `.tar.gz` / `.zip` 解压，控制手机内存峰值。
void _extractArchiveSync(String archivePath, String destDirPath) {
  final lower = archivePath.toLowerCase();
  String? tempTarPath;
  InputFileStream? archiveInput;

  try {
    final Archive archive;
    if (lower.endsWith('.tar.bz2') ||
        lower.endsWith('.tbz2') ||
        lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz')) {
      tempTarPath = '$archivePath.extracted.tar';
      final compressedIn = InputFileStream(archivePath);
      final tarOut = OutputFileStream(tempTarPath);
      try {
        if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) {
          BZip2Decoder().decodeBuffer(compressedIn, output: tarOut);
        } else {
          GZipDecoder().decodeStream(compressedIn, tarOut);
        }
      } finally {
        compressedIn.closeSync();
        tarOut.closeSync();
      }
      archiveInput = InputFileStream(tempTarPath);
      archive = TarDecoder().decodeBuffer(archiveInput);
    } else if (lower.endsWith('.tar')) {
      archiveInput = InputFileStream(archivePath);
      archive = TarDecoder().decodeBuffer(archiveInput);
    } else if (lower.endsWith('.zip')) {
      archiveInput = InputFileStream(archivePath);
      archive = ZipDecoder().decodeBuffer(archiveInput);
    } else {
      throw FormatException('不支持的压缩格式：${p.basename(archivePath)}');
    }

    final canonicalRoot = p.canonicalize(destDirPath);
    for (final file in archive.files) {
      final outPath = p.normalize(p.join(destDirPath, file.name));
      final canonicalOut = p.canonicalize(outPath);
      if (!p.isWithin(canonicalRoot, canonicalOut) &&
          canonicalOut != canonicalRoot) {
        continue; // 防目录穿越
      }
      if (file.isFile) {
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        final outStream = OutputFileStream(outPath);
        try {
          file.writeContent(outStream);
        } finally {
          outStream.closeSync();
        }
      } else if (!file.isSymbolicLink) {
        Directory(outPath).createSync(recursive: true);
      }
    }
  } finally {
    archiveInput?.closeSync();
    if (tempTarPath != null) {
      final f = File(tempTarPath);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  }
}

final StateNotifierProvider<TtsModelManager, TtsModelsState>
ttsModelManagerProvider =
    StateNotifierProvider<TtsModelManager, TtsModelsState>((ref) {
      return TtsModelManager(ref.read(standaloneConfigProvider.notifier));
    });
