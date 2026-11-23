import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 磁盘上某下载目标文件的断点状态。
typedef PartialDownloadState = ({
  int downloadedBytes,
  int totalBytes,
  bool isComplete,
});

/// 进度回调：`(已下载字节, 总字节, 当前镜像序号 0-based, 镜像总数)`。
typedef ResumableProgressCallback =
    void Function(int receivedBytes, int totalBytes, int mirrorIndex, int mirrorCount);

/// 支持 HTTP `Range` 断点续传、超时重连与多镜像降级的下载器。
///
/// 下载过程写入 `<dest>.part` 与 `<dest>.meta.json`，仅在字节完整校验通过后才原子重命名为 `<dest>`。
/// 若中途断网、锁屏挂起或用户手动暂停，已落盘字节将完整保留，下次继续从断点偏移续传。
class ResumableFileDownloader {
  const ResumableFileDownloader({
    this.maxRetriesPerUrl = 2,
    this.retryBaseDelay = const Duration(seconds: 1),
  });

  final int maxRetriesPerUrl;
  final Duration retryBaseDelay;

  static File partFileFor(File destFile) => File('${destFile.path}.part');
  static File metaFileFor(File destFile) => File('${destFile.path}.meta.json');

  /// 读取目标文件当前已完成的字节与已知总字节数（供刷新列表与断点展示使用）。
  static PartialDownloadState readPartialState(File destFile) {
    try {
      if (destFile.existsSync()) {
        final len = destFile.lengthSync();
        if (len > 0) {
          return (downloadedBytes: len, totalBytes: len, isComplete: true);
        }
      }
      final part = partFileFor(destFile);
      final downloaded = part.existsSync() ? part.lengthSync() : 0;
      final total = _readMetaTotalBytes(metaFileFor(destFile));
      return (
        downloadedBytes: downloaded,
        totalBytes: total,
        isComplete: false,
      );
    } catch (_) {
      return (downloadedBytes: 0, totalBytes: 0, isComplete: false);
    }
  }

  /// 执行（或继续）下载，按 [urls] 顺序尝试，每条链接最多自动重连 [maxRetriesPerUrl] 次。
  Future<void> download({
    required Dio dio,
    required List<String> urls,
    required File destFile,
    CancelToken? cancelToken,
    Duration chunkTimeout = const Duration(seconds: 30),
    int? maxRetriesPerUrl,
    ResumableProgressCallback? onProgress,
  }) async {
    final retries = maxRetriesPerUrl ?? this.maxRetriesPerUrl;
    if (destFile.existsSync() && destFile.lengthSync() > 0) {
      final len = destFile.lengthSync();
      onProgress?.call(len, len, 0, urls.isEmpty ? 1 : urls.length);
      return;
    }
    if (urls.isEmpty) {
      throw ArgumentError('urls 不能为空');
    }

    await destFile.parent.create(recursive: true);

    Object? lastError;
    for (var u = 0; u < urls.length; u++) {
      final url = urls[u];
      for (var attempt = 0; attempt <= retries; attempt++) {
        _throwIfCancelled(cancelToken, url);
        try {
          await _downloadSingleAttempt(
            dio: dio,
            url: url,
            destFile: destFile,
            cancelToken: cancelToken,
            chunkTimeout: chunkTimeout,
            mirrorIndex: u,
            mirrorCount: urls.length,
            onProgress: onProgress,
          );
          return;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel ||
              (cancelToken?.isCancelled ?? false)) {
            rethrow;
          }
          lastError = e.message ?? e.toString();
        } catch (e) {
          lastError = e;
        }

        if (attempt < retries) {
          _throwIfCancelled(cancelToken, url);
          final waitDuration = retryBaseDelay * (attempt + 1);
          if (waitDuration > Duration.zero) {
            await _delayWithCancel(waitDuration, cancelToken, url);
          }
        }
      }
    }

    throw Exception('所有镜像下载失败（${destFile.uri.pathSegments.last}）：$lastError');
  }

  Future<void> _downloadSingleAttempt({
    required Dio dio,
    required String url,
    required File destFile,
    required CancelToken? cancelToken,
    required Duration chunkTimeout,
    required int mirrorIndex,
    required int mirrorCount,
    required ResumableProgressCallback? onProgress,
  }) async {
    final partFile = partFileFor(destFile);
    final metaFile = metaFileFor(destFile);

    var existingBytes = partFile.existsSync() ? partFile.lengthSync() : 0;
    final headers = <String, dynamic>{};
    if (existingBytes > 0) {
      headers['Range'] = 'bytes=$existingBytes-';
    }

    final response = await dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers.isEmpty ? null : headers,
        validateStatus: (code) =>
            code != null && (code == 200 || code == 206 || code == 416),
      ),
    );

    final statusCode = response.statusCode ?? 0;
    final body = response.data;
    if (statusCode == 416) {
      await _drainQuietly(body);
      final totalFromRange = _parseRangeStarTotal(
        response.headers.value('content-range'),
      );
      if (totalFromRange > 0 && existingBytes == totalFromRange) {
        await _finalizePart(partFile, metaFile, destFile);
        onProgress?.call(
          totalFromRange,
          totalFromRange,
          mirrorIndex,
          mirrorCount,
        );
        return;
      }
      // 本地 .part 偏移失效或损坏，清空后交由上层重试从头下载
      if (partFile.existsSync()) partFile.deleteSync();
      if (metaFile.existsSync()) metaFile.deleteSync();
      throw const HttpException('断点范围失效（HTTP 416），将从头重试');
    }

    if (body == null) {
      throw const HttpException('响应体为空');
    }

    int received;
    int totalBytes;
    FileMode openMode;

    if (statusCode == 206 && existingBytes > 0) {
      final parsedRange = _parseContentRange206(
        response.headers.value('content-range'),
      );
      if (parsedRange != null && parsedRange.start != existingBytes) {
        await _drainQuietly(body);
        if (partFile.existsSync()) partFile.deleteSync();
        if (metaFile.existsSync()) metaFile.deleteSync();
        throw HttpException(
          '服务端返回 Range 起始偏移不匹配（期望 $existingBytes，实际 ${parsedRange.start}）',
        );
      }
      final contentLen = _parseContentLength(
        response.headers.value(Headers.contentLengthHeader),
      );
      if (parsedRange != null && parsedRange.total > 0) {
        totalBytes = parsedRange.total;
      } else if (contentLen > 0) {
        totalBytes = existingBytes + contentLen;
      } else {
        totalBytes = _readMetaTotalBytes(metaFile);
      }
      received = existingBytes;
      openMode = FileMode.append;
    } else {
      // 200 OK（首次下载或服务端不支持 Range 从头返回）
      received = 0;
      totalBytes = _parseContentLength(
        response.headers.value(Headers.contentLengthHeader),
      );
      openMode = FileMode.write;
    }

    if (totalBytes > 0) {
      _writeMetaTotalBytes(metaFile, totalBytes);
    }

    onProgress?.call(received, totalBytes, mirrorIndex, mirrorCount);

    final raf = partFile.openSync(mode: openMode);
    final completer = Completer<void>();
    Timer? idleTimer;
    late final StreamSubscription<Uint8List> sub;
    var lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(chunkTimeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException('网络无响应，已保存断点 $received 字节', chunkTimeout),
          );
        }
      });
    }

    unawaited(
      cancelToken?.whenCancel.then((cancelErr) {
        if (!completer.isCompleted) {
          completer.completeError(cancelErr);
        }
      }),
    );

    resetIdleTimer();
    sub = body.stream.listen(
      (chunk) {
        resetIdleTimer();
        if (chunk.isEmpty) return;
        raf.writeFromSync(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReportAt).inMilliseconds >= 180 ||
            (totalBytes > 0 && received >= totalBytes)) {
          lastReportAt = now;
          onProgress?.call(received, totalBytes, mirrorIndex, mirrorCount);
        }
      },
      onError: (Object err, StackTrace st) {
        if (!completer.isCompleted) {
          completer.completeError(err, st);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      cancelOnError: true,
    );

    try {
      await completer.future;
    } finally {
      idleTimer?.cancel();
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        raf.flushSync();
        raf.closeSync();
      } catch (_) {}
    }

    _throwIfCancelled(cancelToken, url);

    if (totalBytes > 0 && received < totalBytes) {
      throw HttpException('下载提前中断（已保存 $received / $totalBytes 字节）');
    }

    onProgress?.call(received, totalBytes, mirrorIndex, mirrorCount);
    await _finalizePart(partFile, metaFile, destFile);
  }

  Future<void> _finalizePart(
    File partFile,
    File metaFile,
    File destFile,
  ) async {
    if (destFile.existsSync()) {
      await destFile.delete();
    }
    await partFile.rename(destFile.path);
    if (metaFile.existsSync()) {
      try {
        await metaFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _drainQuietly(ResponseBody? body) async {
    if (body == null) return;
    try {
      await body.stream.drain<void>();
    } catch (_) {}
  }

  void _throwIfCancelled(CancelToken? token, String url) {
    if (token != null && token.isCancelled) {
      throw token.cancelError ??
          DioException.requestCancelled(
            requestOptions: RequestOptions(path: url),
            reason: 'cancelled',
          );
    }
  }

  Future<void> _delayWithCancel(
    Duration delay,
    CancelToken? token,
    String url,
  ) async {
    if (token == null) {
      await Future<void>.delayed(delay);
      return;
    }
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(delay),
      token.whenCancel.then((err) => throw err),
    ]);
    _throwIfCancelled(token, url);
  }

  static int _parseContentLength(String? header) {
    if (header == null || header.trim().isEmpty) return 0;
    return int.tryParse(header.trim()) ?? 0;
  }

  static ({int start, int end, int total})? _parseContentRange206(
    String? header,
  ) {
    if (header == null) return null;
    final m = RegExp(
      r'bytes\s+(\d+)-(\d+)/(\d+|\*)',
      caseSensitive: false,
    ).firstMatch(header);
    if (m == null) return null;
    final start = int.tryParse(m.group(1)!) ?? 0;
    final end = int.tryParse(m.group(2)!) ?? 0;
    final total = m.group(3) == '*' ? 0 : (int.tryParse(m.group(3)!) ?? 0);
    return (start: start, end: end, total: total);
  }

  static int _parseRangeStarTotal(String? header) {
    if (header == null) return 0;
    final m = RegExp(
      r'bytes\s+\*/(\d+)',
      caseSensitive: false,
    ).firstMatch(header);
    if (m == null) return 0;
    return int.tryParse(m.group(1)!) ?? 0;
  }

  static int _readMetaTotalBytes(File metaFile) {
    try {
      if (!metaFile.existsSync()) return 0;
      final decoded = jsonDecode(metaFile.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return (decoded['total_bytes'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  static void _writeMetaTotalBytes(File metaFile, int totalBytes) {
    try {
      metaFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'total_bytes': totalBytes,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (_) {}
  }
}
