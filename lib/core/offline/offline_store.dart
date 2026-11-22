import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../api/echo_api.dart';
import '../api/models.dart';
import '../../features/auth/auth_controller.dart';

/// 单本有声书的离线存储统计。
@immutable
class OfflineBookEntry {
  const OfflineBookEntry({
    required this.audiobookId,
    required this.chunks,
    required this.bytes,
  });

  final int audiobookId;
  final int chunks;
  final int bytes;
}

/// 全部离线内容的存储汇总。
@immutable
class OfflineSummary {
  const OfflineSummary({
    this.entries = const <OfflineBookEntry>[],
    this.totalChunks = 0,
    this.totalBytes = 0,
  });

  final List<OfflineBookEntry> entries;
  final int totalChunks;
  final int totalBytes;

  bool get isEmpty => entries.isEmpty;
}

/// 将字节数格式化为人类可读的体积文本（B / KB / MB / GB）。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

/// 离线文件定位：音频块与 SRT 字幕落在应用私有目录。
///
/// 播放器载入分块时先查本地文件，命中即离线播放（不依赖网络）。
abstract final class OfflineFiles {
  static Directory? _root;

  /// 应用启动时调用一次：解析离线根目录。
  /// 播放路径只读这个缓存值，避免在播放/单测中触发插件调用。
  static Future<void> init() async {
    try {
      await root();
    } catch (_) {
      _root = null;
    }
  }

  /// 供测试注入临时离线根目录，避免依赖 path_provider 平台通道。
  @visibleForTesting
  static void setRootForTest(Directory? dir) {
    _root = dir;
  }

  static bool get initialized => _root != null;

  static Future<Directory> root() async {
    final cached = _root;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/echo_offline');
    if (!dir.existsSync()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  static Future<Directory> dirFor(int audiobookId) async {
    final base = await root();
    final dir = Directory('${base.path}/$audiobookId');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 本地音频文件（不存在或环境不可用返回 null）。
  static Future<File?> audioFile(int audiobookId, int chunkN) async {
    final root = _root;
    if (root == null) return null; // 未初始化（如单测环境）
    try {
      final file = File('${root.path}/$audiobookId/$chunkN.audio');
      return file.existsSync() && file.lengthSync() > 0 ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 本地字幕文件（不存在或环境不可用返回 null）。
  static Future<File?> srtFile(int audiobookId, int chunkN) async {
    final root = _root;
    if (root == null) return null;
    try {
      final file = File('${root.path}/$audiobookId/$chunkN.srt');
      return file.existsSync() && file.lengthSync() > 0 ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 保存/读取章节清单（离线播放必需，否则断网无法得知分块结构）。
  static Future<void> saveManifest(int audiobookId, String json) async {
    try {
      final base = _root ?? await root();
      final dir = Directory('${base.path}/$audiobookId');
      if (!dir.existsSync()) await dir.create(recursive: true);
      await File('${dir.path}/manifest.json').writeAsString(json, flush: true);
    } catch (_) {
      // 忽略：不影响主流程
    }
  }

  static Future<String?> readManifest(int audiobookId) async {
    final root = _root;
    if (root == null) return null;
    try {
      final file = File('${root.path}/$audiobookId/manifest.json');
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 某本有声书已下载的分块数量与总体积。
  static Future<({int chunks, int bytes})> stats(int audiobookId) async {
    try {
      final dir = await dirFor(audiobookId);
      var count = 0;
      var bytes = 0;
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity is File) {
            bytes += entity.lengthSync();
            if (entity.path.endsWith('.audio')) count += 1;
          }
        }
      }
      return (chunks: count, bytes: bytes);
    } catch (_) {
      return (chunks: 0, bytes: 0);
    }
  }

  /// 扫描全部离线缓存目录，汇总各本有声书的章节数与占用体积（按体积倒序）。
  static Future<OfflineSummary> scanAll() async {
    try {
      final base = _root;
      if (base == null || !base.existsSync()) {
        return const OfflineSummary();
      }
      final entries = <OfflineBookEntry>[];
      var totalChunks = 0;
      var totalBytes = 0;
      for (final entity in base.listSync()) {
        if (entity is! Directory) continue;
        final name = entity.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .lastOrNull;
        final id = int.tryParse(name ?? '');
        if (id == null) continue;
        var count = 0;
        var bytes = 0;
        for (final child in entity.listSync()) {
          if (child is File) {
            bytes += child.lengthSync();
            if (child.path.endsWith('.audio')) count += 1;
          }
        }
        if (bytes > 0 || count > 0) {
          entries.add(
            OfflineBookEntry(audiobookId: id, chunks: count, bytes: bytes),
          );
          totalChunks += count;
          totalBytes += bytes;
        }
      }
      entries.sort((a, b) => b.bytes.compareTo(a.bytes));
      return OfflineSummary(
        entries: entries,
        totalChunks: totalChunks,
        totalBytes: totalBytes,
      );
    } catch (_) {
      return const OfflineSummary();
    }
  }

  static Future<void> removeAudiobook(int audiobookId) async {
    final base = _root ?? await root();
    final dir = Directory('${base.path}/$audiobookId');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// 清空全部离线缓存目录。
  static Future<void> clearAll() async {
    final base = _root;
    if (base == null || !base.existsSync()) return;
    for (final entity in base.listSync()) {
      try {
        if (entity.existsSync()) {
          entity.deleteSync(recursive: true);
        }
      } catch (_) {
        // 单个目录删除失败不中断其余清理
      }
    }
  }
}

/// 离线状态。
enum OfflineStatus { idle, downloading, done, failed }

@immutable
class OfflineState {
  const OfflineState({
    this.status = OfflineStatus.idle,
    this.progress = 0,
    this.error,
    this.chunks = 0,
  });

  final OfflineStatus status;
  final double progress;
  final String? error;
  final int chunks;

  OfflineState copyWith({
    OfflineStatus? status,
    double? progress,
    String? error,
    int? chunks,
    bool clearError = false,
  }) => OfflineState(
    status: status ?? this.status,
    progress: progress ?? this.progress,
    error: clearError ? null : (error ?? this.error),
    chunks: chunks ?? this.chunks,
  );
}

/// 离线下载管理器：按分块下载音频 + SRT，供播放器离线播放。
class OfflineStore extends StateNotifier<Map<int, OfflineState>> {
  OfflineStore(this._api) : super(const <int, OfflineState>{}) {
    _restore();
  }

  final EchoApi _api;
  final Set<int> _running = <int>{};
  final Map<int, CancelToken> _cancelTokens = <int, CancelToken>{};

  OfflineState stateOf(int audiobookId) =>
      state[audiobookId] ?? const OfflineState();

  /// 启动时扫描已下载内容。
  Future<void> _restore() async {
    // 无法枚举所有有声书目录，按需在 stateOf 读取时再判断；
    // 这里只做一次轻量预热（目录可能为空）。
  }

  /// 取消指定有声书的正在进行的下载。
  void cancelDownload(int audiobookId) {
    final token = _cancelTokens.remove(audiobookId);
    token?.cancel('用户取消下载');
    _running.remove(audiobookId);
    _set(audiobookId, const OfflineState(status: OfflineStatus.idle));
  }

  /// 刷新某本有声书的离线状态（判断本地是否已有全部分块）。
  Future<void> refreshStatus(AudiobookInfo audio) async {
    if (!audio.isReady) return;
    try {
      final manifest = await _api.getAudiobookChapters(audio.id);
      var downloaded = 0;
      for (final chunk in manifest.chunks) {
        final file = await OfflineFiles.audioFile(audio.id, chunk.n);
        if (file != null) downloaded += 1;
      }
      final done =
          manifest.chunks.isNotEmpty && downloaded == manifest.chunks.length;
      state = <int, OfflineState>{
        ...state,
        audio.id: OfflineState(
          status: done
              ? OfflineStatus.done
              : (downloaded > 0 ? OfflineStatus.idle : OfflineStatus.idle),
          progress: manifest.chunks.isEmpty
              ? 0
              : downloaded / manifest.chunks.length,
          chunks: downloaded,
        ),
      };
    } on ApiException {
      // 离线状态下无法请求清单：保留现状
    }
  }

  /// 下载整本有声书（所有分块的音频 + SRT，支持断点跳过已存在分块）。
  Future<String?> download(AudiobookInfo audio) async {
    if (!audio.isReady || _running.contains(audio.id)) return null;
    _running.add(audio.id);
    final cancelToken = CancelToken();
    _cancelTokens[audio.id] = cancelToken;
    _set(
      audio.id,
      const OfflineState(status: OfflineStatus.downloading, progress: 0),
    );
    try {
      // 先取原始 JSON 存到本地，供断网时离线播放使用
      final rawManifest = await _api.fetchText(
        '/api/audiobooks/${audio.id}/chapters',
      );
      if (rawManifest.isNotEmpty) {
        await OfflineFiles.saveManifest(audio.id, rawManifest);
      }
      final manifest = await _api.getAudiobookChapters(audio.id);
      if (manifest.chunks.isEmpty) {
        _set(
          audio.id,
          const OfflineState(status: OfflineStatus.failed, error: '无可下载分块'),
        );
        return '无可下载分块';
      }
      final dir = await OfflineFiles.dirFor(audio.id);
      final headers = await _api.authHeaders();
      final dio = Dio();
      final total = manifest.chunks.length;

      for (var i = 0; i < total; i++) {
        if (cancelToken.isCancelled) break;
        final chunk = manifest.chunks[i];
        final audioFile = File('${dir.path}/${chunk.n}.audio');
        final srtFile = File('${dir.path}/${chunk.n}.srt');
        final audioDone = audioFile.existsSync() && audioFile.lengthSync() > 0;
        final srtDone =
            chunk.srtUrl.isEmpty ||
            (srtFile.existsSync() && srtFile.lengthSync() > 0);

        if (!audioDone) {
          await _downloadTo(
            dio,
            _api.resolveUri(chunk.audioUrl),
            audioFile,
            headers,
            cancelToken: cancelToken,
          );
        }
        if (!srtDone && chunk.srtUrl.isNotEmpty) {
          await _downloadTo(
            dio,
            _api.resolveUri(chunk.srtUrl),
            srtFile,
            headers,
            cancelToken: cancelToken,
          );
        }
        _set(
          audio.id,
          OfflineState(
            status: OfflineStatus.downloading,
            progress: (i + 1) / total,
            chunks: i + 1,
          ),
        );
      }
      if (cancelToken.isCancelled) {
        _set(audio.id, const OfflineState(status: OfflineStatus.idle));
        return '已取消下载';
      }
      _set(
        audio.id,
        OfflineState(status: OfflineStatus.done, progress: 1, chunks: total),
      );
      return null;
    } catch (e) {
      if (cancelToken.isCancelled) {
        _set(audio.id, const OfflineState(status: OfflineStatus.idle));
        return '已取消下载';
      }
      final message = '下载失败：$e';
      _set(
        audio.id,
        OfflineState(status: OfflineStatus.failed, error: message),
      );
      return message;
    } finally {
      _running.remove(audio.id);
      _cancelTokens.remove(audio.id);
    }
  }

  Future<void> _downloadTo(
    Dio dio,
    Uri uri,
    File target,
    Map<String, String> headers, {
    CancelToken? cancelToken,
  }) async {
    final response = await dio.get<List<int>>(
      uri.toString(),
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.bytes,
        headers: headers,
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw StateError('空响应');
    }
    await target.writeAsBytes(bytes, flush: true);
  }

  /// 删除离线文件。
  Future<void> remove(AudiobookInfo audio) => removeById(audio.id);

  /// 按有声书 ID 删除离线文件。
  Future<void> removeById(int audiobookId) async {
    await OfflineFiles.removeAudiobook(audiobookId);
    _set(audiobookId, const OfflineState());
  }

  /// 清空全部离线缓存。
  Future<void> clearAll() async {
    await OfflineFiles.clearAll();
    state = const <int, OfflineState>{};
  }

  void _set(int id, OfflineState value) {
    state = <int, OfflineState>{...state, id: value};
  }
}

final StateNotifierProvider<OfflineStore, Map<int, OfflineState>>
offlineStoreProvider =
    StateNotifierProvider<OfflineStore, Map<int, OfflineState>>((ref) {
      return OfflineStore(ref.watch(echoApiProvider));
    });
