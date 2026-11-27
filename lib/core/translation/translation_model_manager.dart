import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../offline/offline_store.dart' show formatBytes;
import '../settings/standalone_config_store.dart';
import '../tts/download_keepalive_service.dart';
import '../tts/resumable_downloader.dart';
import 'translation_models.dart';

enum TranslationModelInstallStatus {
  notInstalled,
  downloading,
  paused,
  installed,
}

@immutable
class TranslationModelEntry {
  const TranslationModelEntry({
    required this.spec,
    this.status = TranslationModelInstallStatus.notInstalled,
    this.progress = 0.0,
    this.statusText = '',
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.installedBytes = 0,
    this.localPath,
    this.error,
  });

  final TranslationModelSpec spec;
  final TranslationModelInstallStatus status;
  final double progress;
  final String statusText;
  final int downloadedBytes;
  final int totalBytes;
  final int installedBytes;
  final String? localPath;
  final String? error;

  bool get isInstalled =>
      status == TranslationModelInstallStatus.installed &&
      localPath != null &&
      localPath!.isNotEmpty;
  bool get isDownloading => status == TranslationModelInstallStatus.downloading;
  bool get isPaused => status == TranslationModelInstallStatus.paused;

  TranslationModelEntry copyWith({
    TranslationModelSpec? spec,
    TranslationModelInstallStatus? status,
    double? progress,
    String? statusText,
    int? downloadedBytes,
    int? totalBytes,
    int? installedBytes,
    String? localPath,
    bool clearLocalPath = false,
    String? error,
    bool clearError = false,
  }) {
    return TranslationModelEntry(
      spec: spec ?? this.spec,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      statusText: statusText ?? this.statusText,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      installedBytes: installedBytes ?? this.installedBytes,
      localPath: clearLocalPath ? null : (localPath ?? this.localPath),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

@immutable
class TranslationModelManagerState {
  const TranslationModelManagerState({
    this.entries = const <String, TranslationModelEntry>{},
    this.activeModelId = TranslationModelCatalog.defaultModelId,
    this.initialized = false,
  });

  final Map<String, TranslationModelEntry> entries;
  final String activeModelId;
  final bool initialized;

  TranslationModelEntry? get activeEntry => entries[activeModelId];

  String? get activeModelPath {
    final entry = activeEntry;
    if (entry != null && entry.isInstalled) return entry.localPath;
    for (final e in entries.values) {
      if (e.isInstalled) return e.localPath;
    }
    return null;
  }

  TranslationModelManagerState copyWith({
    Map<String, TranslationModelEntry>? entries,
    String? activeModelId,
    bool? initialized,
  }) {
    return TranslationModelManagerState(
      entries: entries ?? this.entries,
      activeModelId: activeModelId ?? this.activeModelId,
      initialized: initialized ?? this.initialized,
    );
  }
}

/// 校验文件是否包含合法的 GGUF 魔数头 (`"GGUF"`)。
Future<bool> isValidGgufFile(File file) async {
  try {
    if (!await file.exists()) return false;
    final len = await file.length();
    if (len < 1024 * 1024) return false; // 任何 1B+ GGUF 均远大于 1MB
    final raf = await file.open();
    try {
      final header = await raf.read(4);
      return header.length == 4 &&
          header[0] == 0x47 &&
          header[1] == 0x47 &&
          header[2] == 0x55 &&
          header[3] == 0x46;
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}

/// 端侧离线翻译模型下载、断点续传、本地 GGUF 导入与激活管理器。
class TranslationModelManager
    extends StateNotifier<TranslationModelManagerState> {
  TranslationModelManager({
    required StandaloneConfigController configController,
    Dio? dio,
    ResumableFileDownloader? downloader,
    DownloadKeepAliveService? keepAlive,
    Future<Directory> Function()? rootDirResolver,
  }) : _configController = configController,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(minutes: 60),
               followRedirects: true,
               maxRedirects: 8,
             ),
           ),
       _downloader = downloader ?? const ResumableFileDownloader(),
       _keepAlive = keepAlive ?? const PlatformDownloadKeepAliveService(),
       _rootDirResolver = rootDirResolver,
       super(
         TranslationModelManagerState(
           activeModelId: configController.state.activeTranslationModelId,
           entries: _buildInitialEntries(configController.state),
         ),
       ) {
    unawaited(refreshAll());
  }

  final StandaloneConfigController _configController;
  final Dio _dio;
  final ResumableFileDownloader _downloader;
  final DownloadKeepAliveService _keepAlive;
  final Future<Directory> Function()? _rootDirResolver;
  final Map<String, CancelToken> _cancelTokens = <String, CancelToken>{};
  Future<void>? _refreshInFlight;

  static Map<String, TranslationModelEntry> _buildInitialEntries(
    StandaloneConfig cfg,
  ) {
    final map = <String, TranslationModelEntry>{};
    for (final spec in TranslationModelCatalog.downloadablePresets) {
      map[spec.id] = TranslationModelEntry(
        spec: spec,
        totalBytes: spec.estimatedSizeBytes,
      );
    }
    map[TranslationModelCatalog.modelIdImported] = _importedEntryFromPath(
      cfg.importedTranslationModelPath,
    );
    return map;
  }

  static TranslationModelEntry _importedEntryFromPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isNotEmpty) {
      final f = File(trimmed);
      if (f.existsSync()) {
        final len = f.lengthSync();
        return TranslationModelEntry(
          spec: TranslationModelSpec(
            id: TranslationModelCatalog.modelIdImported,
            name: '本地模型 · ${p.basename(trimmed)}',
            subtitle: '用户从本地导入的自定义 GGUF 模型',
            estimatedSizeBytes: len,
            recommendedTag: '本地导入',
            hfRepo: '',
            filename: p.basename(trimmed),
            isImported: true,
          ),
          status: TranslationModelInstallStatus.installed,
          progress: 1.0,
          installedBytes: len,
          totalBytes: len,
          localPath: trimmed,
        );
      }
    }
    return const TranslationModelEntry(
      spec: TranslationModelCatalog.importedPlaceholder,
    );
  }

  Future<Directory> _modelsRootDir() async {
    if (_rootDirResolver != null) return _rootDirResolver();
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'translation_models'));
  }

  Future<File> _destFileFor(TranslationModelSpec spec) async {
    final root = await _modelsRootDir();
    return File(p.join(root.path, spec.id, spec.filename));
  }

  /// 确保已完成磁盘扫描初始化并返回当前可用模型路径（避免冷启动竞态误判未安装）。
  Future<String?> ensureInitializedAndGetActiveModelPath() async {
    final inflight = _refreshInFlight;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
    } else if (!state.initialized) {
      await refreshAll();
    }
    return state.activeModelPath;
  }

  /// 刷新所有模型当前磁盘与断点状态。
  Future<void> refreshAll() {
    final prev = _refreshInFlight;
    final run = () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      final next = <String, TranslationModelEntry>{};
      for (final spec in TranslationModelCatalog.downloadablePresets) {
        if (_cancelTokens.containsKey(spec.id)) {
          final existing = state.entries[spec.id];
          if (existing != null) {
            next[spec.id] = existing;
            continue;
          }
        }
        final dest = await _destFileFor(spec);
        final partial = ResumableFileDownloader.readPartialState(dest);
        if (partial.isComplete) {
          next[spec.id] = TranslationModelEntry(
            spec: spec,
            status: TranslationModelInstallStatus.installed,
            progress: 1.0,
            downloadedBytes: partial.downloadedBytes,
            totalBytes: partial.totalBytes,
            installedBytes: partial.downloadedBytes,
            localPath: dest.path,
          );
        } else if (partial.downloadedBytes > 0) {
          final total = partial.totalBytes > 0
              ? partial.totalBytes
              : spec.estimatedSizeBytes;
          next[spec.id] = TranslationModelEntry(
            spec: spec,
            status: TranslationModelInstallStatus.paused,
            progress: total > 0
                ? (partial.downloadedBytes / total).clamp(0.0, 1.0)
                : 0.0,
            downloadedBytes: partial.downloadedBytes,
            totalBytes: total,
            statusText:
                '已暂停 · ${formatBytes(partial.downloadedBytes)} / ${formatBytes(total)}',
          );
        } else {
          next[spec.id] = TranslationModelEntry(
            spec: spec,
            totalBytes: spec.estimatedSizeBytes,
          );
        }
      }

      next[TranslationModelCatalog.modelIdImported] = _importedEntryFromPath(
        _configController.state.importedTranslationModelPath,
      );

      if (!mounted) return;
      state = state.copyWith(
        entries: next,
        activeModelId: _configController.state.activeTranslationModelId,
        initialized: true,
      );
    }();
    _refreshInFlight = run;
    run.whenComplete(() {
      if (identical(_refreshInFlight, run)) {
        _refreshInFlight = null;
      }
    });
    return run;
  }

  void _updateEntry(String id, TranslationModelEntry entry) {
    final next = Map<String, TranslationModelEntry>.from(state.entries);
    next[id] = entry;
    state = state.copyWith(entries: next);
  }

  /// 开始或继续断点下载指定翻译模型（含前台保活）。
  Future<void> startOrResumeDownload(
    String modelId, {
    String? mirrorIdOverride,
  }) async {
    final spec = TranslationModelCatalog.byId(modelId);
    if (spec == null || spec.isImported) return;
    if (_cancelTokens.containsKey(modelId)) return;

    final dest = await _destFileFor(spec);
    final cfg = _configController.state;
    final mirrorId = mirrorIdOverride ?? cfg.translationDownloadMirror;
    final mirrorOpt = TranslationModelCatalog.mirrorById(mirrorId);
    final url = spec.downloadUrlForMirror(
      mirrorId: mirrorId,
      customPrefix: cfg.customTranslationMirrorPrefix,
    );

    final cancelToken = CancelToken();
    _cancelTokens[modelId] = cancelToken;

    final initialPartial = ResumableFileDownloader.readPartialState(dest);
    final estTotal = initialPartial.totalBytes > 0
        ? initialPartial.totalBytes
        : spec.estimatedSizeBytes;

    _updateEntry(
      modelId,
      TranslationModelEntry(
        spec: spec,
        status: TranslationModelInstallStatus.downloading,
        progress: initialPartial.downloadedBytes > 0 && estTotal > 0
            ? (initialPartial.downloadedBytes / estTotal).clamp(0.0, 1.0)
            : 0.0,
        downloadedBytes: initialPartial.downloadedBytes,
        totalBytes: estTotal,
        statusText: initialPartial.downloadedBytes > 0
            ? '正在通过 ${mirrorOpt.label} 续传（${formatBytes(initialPartial.downloadedBytes)}）...'
            : '正在连接 ${mirrorOpt.label}...',
      ),
    );

    await _keepAlive.startOrUpdate(
      title: '正在下载 ${spec.name}',
      text: '准备下载离线翻译模型...',
      progress: 0,
      max: 100,
    );

    var lastPct = -1;
    try {
      await _downloader.download(
        dio: _dio,
        urls: <String>[url],
        destFile: dest,
        cancelToken: cancelToken,
        onProgress: (received, total, _, _) {
          final effTotal = total > 0 ? total : spec.estimatedSizeBytes;
          final frac = effTotal > 0
              ? (received / effTotal).clamp(0.0, 1.0)
              : 0.0;
          final pct = (frac * 100).toInt();

          _updateEntry(
            modelId,
            TranslationModelEntry(
              spec: spec,
              status: TranslationModelInstallStatus.downloading,
              progress: frac,
              downloadedBytes: received,
              totalBytes: effTotal,
              statusText:
                  '下载中 $pct% · ${formatBytes(received)} / ${formatBytes(effTotal)}',
            ),
          );

          if (pct != lastPct) {
            lastPct = pct;
            unawaited(
              _keepAlive.startOrUpdate(
                title: '正在下载 ${spec.name}',
                text:
                    '$pct%（${formatBytes(received)} / ${formatBytes(effTotal)}）',
                progress: pct,
                max: 100,
              ),
            );
          }
        },
      );

      final valid = await isValidGgufFile(dest);
      if (!valid) {
        if (await dest.exists()) {
          await dest.delete();
        }
        throw StateError('下载文件未通过 GGUF 魔数校验，请切换下载镜像或重试');
      }

      final finalLen = await dest.length();
      _updateEntry(
        modelId,
        TranslationModelEntry(
          spec: spec,
          status: TranslationModelInstallStatus.installed,
          progress: 1.0,
          downloadedBytes: finalLen,
          totalBytes: finalLen,
          installedBytes: finalLen,
          localPath: dest.path,
        ),
      );

      await _configController.setActiveTranslationModel(modelId);
      state = state.copyWith(activeModelId: modelId);

      await _keepAlive.startOrUpdate(
        title: '${spec.name} 下载完成',
        text: '可在阅读外文图书时开启双语对照',
        progress: 100,
        max: 100,
      );
      Future<void>.delayed(const Duration(seconds: 2), () {
        _keepAlive.stop();
      });
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel || cancelToken.isCancelled) {
        final partial = ResumableFileDownloader.readPartialState(dest);
        final effTotal = partial.totalBytes > 0
            ? partial.totalBytes
            : spec.estimatedSizeBytes;
        _updateEntry(
          modelId,
          TranslationModelEntry(
            spec: spec,
            status: partial.downloadedBytes > 0
                ? TranslationModelInstallStatus.paused
                : TranslationModelInstallStatus.notInstalled,
            progress: effTotal > 0
                ? (partial.downloadedBytes / effTotal).clamp(0.0, 1.0)
                : 0.0,
            downloadedBytes: partial.downloadedBytes,
            totalBytes: effTotal,
            statusText: partial.downloadedBytes > 0
                ? '已暂停 · ${formatBytes(partial.downloadedBytes)}'
                : '',
          ),
        );
      } else {
        final partial = ResumableFileDownloader.readPartialState(dest);
        final effTotal = partial.totalBytes > 0
            ? partial.totalBytes
            : spec.estimatedSizeBytes;
        _updateEntry(
          modelId,
          TranslationModelEntry(
            spec: spec,
            status: partial.downloadedBytes > 0
                ? TranslationModelInstallStatus.paused
                : TranslationModelInstallStatus.notInstalled,
            progress: effTotal > 0
                ? (partial.downloadedBytes / effTotal).clamp(0.0, 1.0)
                : 0.0,
            downloadedBytes: partial.downloadedBytes,
            totalBytes: effTotal,
            error: '「${mirrorOpt.label}」下载失败，已保留断点，可切换镜像后重试',
          ),
        );
      }
      await _keepAlive.stop();
    } catch (e) {
      final partial = ResumableFileDownloader.readPartialState(dest);
      final effTotal = partial.totalBytes > 0
          ? partial.totalBytes
          : spec.estimatedSizeBytes;
      _updateEntry(
        modelId,
        TranslationModelEntry(
          spec: spec,
          status: partial.downloadedBytes > 0
              ? TranslationModelInstallStatus.paused
              : TranslationModelInstallStatus.notInstalled,
          progress: effTotal > 0
              ? (partial.downloadedBytes / effTotal).clamp(0.0, 1.0)
              : 0.0,
          downloadedBytes: partial.downloadedBytes,
          totalBytes: effTotal,
          error: e.toString(),
        ),
      );
      await _keepAlive.stop();
    } finally {
      _cancelTokens.remove(modelId);
    }
  }

  /// 暂停当前下载（完整保留磁盘断点 `.part` 供下次续传）。
  Future<void> pauseDownload(String modelId) async {
    _cancelTokens[modelId]?.cancel();
    await _keepAlive.stop();
  }

  /// 切换当前激活使用的翻译模型。
  Future<void> setActiveModel(String modelId) async {
    final entry = state.entries[modelId];
    if (entry == null || !entry.isInstalled) return;
    await _configController.setActiveTranslationModel(modelId);
    state = state.copyWith(activeModelId: modelId);
  }

  /// 从设备存储导入本地 `.gguf` 文件并校验 `"GGUF"` 魔数头，返回 null 表示成功。
  Future<String?> importLocalGguf(File sourceFile) async {
    try {
      if (!await sourceFile.exists()) {
        return '所选模型文件不存在';
      }
      if (!await isValidGgufFile(sourceFile)) {
        return '所选文件不是合法的 GGUF 模型文件（魔数头校验失败或文件过小）';
      }

      final root = await _modelsRootDir();
      final destDir = Directory(
        p.join(root.path, TranslationModelCatalog.modelIdImported),
      );
      await destDir.create(recursive: true);

      // 清理旧导入文件避免磁盘残留
      await for (final entity in destDir.list()) {
        if (entity is File && entity.path != sourceFile.path) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }

      final destFile = File(p.join(destDir.path, p.basename(sourceFile.path)));
      if (sourceFile.path != destFile.path) {
        await sourceFile.copy(destFile.path);
      }

      await _configController.setImportedTranslationModelPath(destFile.path);
      await _configController.setActiveTranslationModel(
        TranslationModelCatalog.modelIdImported,
      );
      await refreshAll();
      return null;
    } catch (e) {
      return '导入失败：$e';
    }
  }

  /// 删除已下载/导入的模型及残留断点文件。
  Future<void> deleteModel(String modelId) async {
    _cancelTokens[modelId]?.cancel();
    final spec = TranslationModelCatalog.byId(modelId);
    if (spec == null) return;

    if (spec.isImported) {
      final path = _configController.state.importedTranslationModelPath;
      if (path.isNotEmpty) {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      }
      await _configController.setImportedTranslationModelPath('');
    } else {
      final root = await _modelsRootDir();
      final dir = Directory(p.join(root.path, modelId));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    if (state.activeModelId == modelId) {
      // 回落选择另一已安装预设，否则保持 defaultModelId
      String nextActive = TranslationModelCatalog.defaultModelId;
      for (final e in state.entries.values) {
        if (e.spec.id != modelId && e.isInstalled) {
          nextActive = e.spec.id;
          break;
        }
      }
      await _configController.setActiveTranslationModel(nextActive);
    }

    await refreshAll();
  }
}

final StateNotifierProvider<
  TranslationModelManager,
  TranslationModelManagerState
>
translationModelManagerProvider =
    StateNotifierProvider<
      TranslationModelManager,
      TranslationModelManagerState
    >(
      (ref) => TranslationModelManager(
        configController: ref.read(standaloneConfigProvider.notifier),
      ),
    );
