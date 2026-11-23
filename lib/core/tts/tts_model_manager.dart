import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../settings/standalone_config_store.dart';
import 'tts_model_catalog.dart';

/// 已安装且通过完整性校验的端侧模型本地路径集合。
@immutable
class ResolvedTtsModelPaths {
  const ResolvedTtsModelPaths({
    required this.spec,
    required this.rootDir,
    required this.modelPath,
    required this.tokensPath,
    this.voicesPath = '',
    this.vocoderPath = '',
    this.lexiconPath = '',
    this.dataDir = '',
    this.dictDir = '',
  });

  final TtsModelSpec spec;
  final String rootDir;
  final String modelPath;
  final String tokensPath;
  final String voicesPath;
  final String vocoderPath;
  final String lexiconPath;
  final String dataDir;
  final String dictDir;
}

enum ModelInstallStatus { notInstalled, downloading, extracting, installed }

@immutable
class TtsModelStatusEntry {
  const TtsModelStatusEntry({
    required this.spec,
    this.status = ModelInstallStatus.notInstalled,
    this.progress = 0.0,
    this.statusText = '',
    this.installedBytes = 0,
    this.resolvedPaths,
    this.error,
  });

  final TtsModelSpec spec;
  final ModelInstallStatus status;
  final double progress;
  final String statusText;
  final int installedBytes;
  final ResolvedTtsModelPaths? resolvedPaths;
  final String? error;

  bool get isInstalled =>
      status == ModelInstallStatus.installed && resolvedPaths != null;
  bool get isBusy =>
      status == ModelInstallStatus.downloading ||
      status == ModelInstallStatus.extracting;

  TtsModelStatusEntry copyWith({
    ModelInstallStatus? status,
    double? progress,
    String? statusText,
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
  });

  final Map<String, TtsModelStatusEntry> entries;
  final bool initialized;

  List<TtsModelStatusEntry> get orderedEntries => TtsModelCatalog.all
      .map((s) => entries[s.id] ?? TtsModelStatusEntry(spec: s))
      .toList();

  List<TtsModelStatusEntry> get installedEntries =>
      orderedEntries.where((e) => e.isInstalled).toList();

  TtsModelStatusEntry? entryOf(String id) => entries[id];
}

/// 端侧 TTS 模型管理器：多镜像下载、Isolate 解压、完整性校验、本地导入与删除。
class TtsModelManager extends StateNotifier<TtsModelsState> {
  TtsModelManager(
    this._configController, {
    Dio? dio,
    Directory? rootDirOverride,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(minutes: 20),
             ),
           ),
       _rootDirOverride = rootDirOverride,
       super(const TtsModelsState()) {
    refresh();
  }

  final StandaloneConfigController _configController;
  final Dio _dio;
  final Directory? _rootDirOverride;
  final Map<String, CancelToken> _cancelTokens = <String, CancelToken>{};

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
        map[spec.id] = TtsModelStatusEntry(spec: spec);
      }
    }
    if (!mounted) return;
    state = TtsModelsState(entries: map, initialized: true);

    // 若当前尚未选定模型且已有已安装模型，自动选中第一个可用模型。
    final activeId = _configController.state.activeTtsModelId;
    if (activeId.isEmpty || !(map[activeId]?.isInstalled ?? false)) {
      final firstInstalled = map.values
          .cast<TtsModelStatusEntry?>()
          .firstWhere((e) => e?.isInstalled == true, orElse: () => null);
      if (firstInstalled != null) {
        await _configController.setActiveTtsModel(
          firstInstalled.spec.id,
          speakerId: firstInstalled.spec.speakers.first.id,
        );
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
    );
  }

  /// 下载并解压安装指定模型（自动按国内镜像/官方源顺次降级）。
  Future<String?> downloadModel(String modelId, {bool? preferCnMirror}) async {
    final spec = TtsModelCatalog.byId(modelId);
    if (spec == null) return '未知模型：$modelId';
    if (state.entries[modelId]?.isBusy == true) return null;

    final useCn = preferCnMirror ?? _configController.state.preferCnMirror;
    final cancelToken = CancelToken();
    _cancelTokens[modelId] = cancelToken;

    final root = await _modelsRoot();
    final modelDir = Directory(p.join(root.path, spec.id));
    final tmpDir = Directory(p.join(root.path, '.tmp_${spec.id}'));

    try {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      await tmpDir.create(recursive: true);
      await modelDir.create(recursive: true);

      final totalAssets = spec.assets.length;
      for (var idx = 0; idx < totalAssets; idx++) {
        final asset = spec.assets[idx];
        final urls = asset.orderedUrls(preferCnMirror: useCn);
        final destFile = File(p.join(tmpDir.path, asset.filename));

        _updateEntry(
          modelId,
          (e) => e.copyWith(
            status: ModelInstallStatus.downloading,
            progress: idx / totalAssets,
            statusText: '正在下载 ${asset.filename} (${idx + 1}/$totalAssets)...',
            clearError: true,
          ),
        );

        Object? lastError;
        var downloaded = false;
        for (var u = 0; u < urls.length; u++) {
          final url = urls[u];
          try {
            if (await destFile.exists()) await destFile.delete();
            await _dio.download(
              url,
              destFile.path,
              cancelToken: cancelToken,
              onReceiveProgress: (received, total) {
                final assetFrac = total > 0 ? (received / total) : 0.0;
                final overall = ((idx + assetFrac) / totalAssets) * 0.88;
                _updateEntry(
                  modelId,
                  (e) => e.copyWith(
                    status: ModelInstallStatus.downloading,
                    progress: overall.clamp(0.0, 0.88),
                    statusText: total > 0
                        ? '下载中 ${(assetFrac * 100).toStringAsFixed(0)}%（镜像 ${u + 1}/${urls.length}）'
                        : '下载中 ${(received / (1024 * 1024)).toStringAsFixed(1)} MB...',
                  ),
                );
              },
            );
            downloaded = true;
            break;
          } on DioException catch (e) {
            if (e.type == DioExceptionType.cancel) rethrow;
            lastError = e.message ?? '网络错误';
          } catch (e) {
            lastError = e;
          }
        }
        if (!downloaded) {
          throw Exception('所有镜像下载失败（${asset.filename}）：$lastError');
        }

        if (asset.isArchive) {
          _updateEntry(
            modelId,
            (e) => e.copyWith(
              status: ModelInstallStatus.extracting,
              progress: 0.90,
              statusText: '正在解压模型文件，请稍候...',
            ),
          );
          await Isolate.run(
            () => _extractArchiveSync(destFile.path, modelDir.path),
          );
        } else {
          final target = File(p.join(modelDir.path, asset.filename));
          await destFile.copy(target.path);
        }
      }

      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);

      final resolved = await _resolveInstalledModel(spec, modelDir);
      if (resolved == null) {
        throw Exception('模型文件不完整，校验未通过');
      }

      final bytes = _dirSizeSync(modelDir);
      _updateEntry(
        modelId,
        (e) => e.copyWith(
          status: ModelInstallStatus.installed,
          progress: 1.0,
          statusText: '已安装',
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
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      final msg = e.type == DioExceptionType.cancel ? '已取消下载' : '下载失败：${e.message}';
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
    } catch (e) {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      final msg = e.toString().replaceFirst('Exception: ', '');
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
    } finally {
      _cancelTokens.remove(modelId);
    }
  }

  /// 取消正在进行的模型下载。
  void cancelDownload(String modelId) {
    _cancelTokens[modelId]?.cancel('user_cancelled');
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
        await Isolate.run(
          () => _extractArchiveSync(archiveFile.path, modelDir.path),
        );
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

  /// 删除已安装的本地模型释放空间。
  Future<void> deleteModel(String modelId) async {
    cancelDownload(modelId);
    final root = await _modelsRoot();
    final modelDir = Directory(p.join(root.path, modelId));
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
    }
    _updateEntry(
      modelId,
      (e) => e.copyWith(
        status: ModelInstallStatus.notInstalled,
        progress: 0,
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

    return ResolvedTtsModelPaths(
      spec: spec,
      rootDir: searchRoot.path,
      modelPath: modelPath,
      tokensPath: tokensPath,
      voicesPath: voicesPath ?? '',
      vocoderPath: vocoderPath ?? '',
      lexiconPath: lexicons.join(','),
      dataDir: findDir(spec.dataDirName),
      dictDir: findDir(spec.dictDirName),
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

/// 在后台 Isolate 中执行 `.tar.bz2` / `.tar.gz` / `.zip` 解压。
void _extractArchiveSync(String archivePath, String destDirPath) {
  final bytes = File(archivePath).readAsBytesSync();
  final lower = archivePath.toLowerCase();
  final Archive archive;
  if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) {
    final tarBytes = BZip2Decoder().decodeBytes(bytes);
    archive = TarDecoder().decodeBytes(tarBytes);
  } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
    final tarBytes = GZipDecoder().decodeBytes(bytes);
    archive = TarDecoder().decodeBytes(tarBytes);
  } else if (lower.endsWith('.zip')) {
    archive = ZipDecoder().decodeBytes(bytes);
  } else {
    throw FormatException('不支持的压缩格式：${p.basename(archivePath)}');
  }

  for (final file in archive.files) {
    final outPath = p.normalize(p.join(destDirPath, file.name));
    if (!p.isWithin(destDirPath, outPath) && outPath != destDirPath) {
      continue; // 防目录穿越
    }
    if (file.isFile) {
      final outFile = File(outPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(file.content as List<int>);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }
}

final StateNotifierProvider<TtsModelManager, TtsModelsState>
ttsModelManagerProvider =
    StateNotifierProvider<TtsModelManager, TtsModelsState>((ref) {
      return TtsModelManager(ref.read(standaloneConfigProvider.notifier));
    });
