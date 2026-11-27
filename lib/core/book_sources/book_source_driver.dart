import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'book_source_models.dart';
import 'mirror_pool_manager.dart';

/// Unified contract for `rule`, `opds`, and `ebook_api` book source drivers.
abstract class BookSourceDriver {
  Future<BookSourceSearchPage> search(
    ResolvedBookSource source,
    BookSourceSearchRequest request,
  );

  Future<BookSourceSearchBook> getBookDetail(
    ResolvedBookSource source,
    String ref, {
    BookSourceSearchBook? baseBook,
  });

  Future<BookSourceDownloadedFile> downloadBook(
    ResolvedBookSource source, {
    required String ref,
    required String savePath,
    BookSourceSearchBook? meta,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  });

  Future<BookSourceCredentials> authenticate(
    ResolvedBookSource source, {
    required String modeId,
    required Map<String, String> inputs,
  });

  Future<BookSourceAccountStatus> verify(ResolvedBookSource source);

  Future<List<MirrorProbeResult>> probeDomains(ResolvedBookSource source);
}

/// Shared streaming download, retry, stall protection, and filename hygiene
/// utilities used across `RuleBookSourceDriver` and `OpdsBookSourceDriver`.
abstract final class BookSourceDownloadHelper {
  static const Map<String, String> contentTypeExtensions = <String, String>{
    'application/pdf': 'pdf',
    'application/epub+zip': 'epub',
    'application/x-mobipocket-ebook': 'mobi',
    'application/vnd.amazon.ebook': 'azw3',
    'application/x-fictionbook+xml': 'fb2',
    'application/x-fictionbook': 'fb2',
    'application/x-djvu': 'djvu',
    'image/vnd.djvu': 'djvu',
    'application/rtf': 'rtf',
    'text/plain': 'txt',
    'text/html': 'html',
    'application/zip': 'zip',
    'application/x-rar-compressed': 'rar',
    'application/msword': 'doc',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        'docx',
  };

  /// Streams [url] to [savePath] with exponential backoff retries, stall
  /// timeout, byte cap, and cross-origin credential stripping.
  static Future<BookSourceDownloadedFile> streamToFile({
    required MirrorPoolManager mirrorPool,
    required String url,
    required String originUsed,
    required String savePath,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    Set<String> authHeaderNames = const <String>{},
    bool sameOriginCredentials = true,
    String proxyPrefix = '',
    int retries = 3,
    int stallTimeoutSeconds = kDefaultBookSourceStallTimeoutSeconds,
    int maxBytes = kDefaultBookSourceMaxDownloadBytes,
    Duration retryBaseDelay = const Duration(milliseconds: 500),
    Future<void> Function(Duration)? delay,
    BookSourceSearchBook? meta,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    BookSourceException? Function(int status, Headers headers)?
    customStatusErrorMapper,
  }) async {
    final sleep = delay ?? Future<void>.delayed;
    final stallDuration = Duration(
      seconds: stallTimeoutSeconds > 0
          ? stallTimeoutSeconds
          : kDefaultBookSourceStallTimeoutSeconds,
    );

    BookSourceException? lastErr;
    var waitDelay = retryBaseDelay;

    for (var attempt = 0; attempt <= retries; attempt++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const BookSourceException(code: 'CANCELLED', message: '下载已取消');
      }
      if (attempt > 0) {
        await sleep(waitDelay);
        waitDelay *= 2;
      }

      if (cancelToken?.isCancelled ?? false) {
        throw const BookSourceException(code: 'CANCELLED', message: '下载已取消');
      }

      MirrorStreamResponse resp;
      try {
        resp = await mirrorPool.openStreamWithRedirects(
          url: url,
          originUsed: originUsed,
          method: method,
          headers: headers,
          authHeaderNames: authHeaderNames,
          sameOriginCredentials: sameOriginCredentials,
          proxyPrefix: proxyPrefix,
          cancelToken: cancelToken,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          throw const BookSourceException(code: 'CANCELLED', message: '下载已取消');
        }
        lastErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '下载请求失败：${e.message ?? e.type.name}',
          statusCode: e.response?.statusCode,
        );
        continue;
      } on BookSourceException {
        rethrow;
      } catch (e) {
        lastErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '下载连接异常：$e',
        );
        continue;
      }

      if (_isRetryableStatus(resp.statusCode)) {
        await _drainQuietly(resp.stream);
        lastErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '书源下载服务暂不可用（HTTP ${resp.statusCode}）',
          statusCode: resp.statusCode,
        );
        continue;
      }

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        await _drainQuietly(resp.stream);
        final mapped = customStatusErrorMapper?.call(
          resp.statusCode,
          resp.headers,
        );
        if (mapped != null) throw mapped;
        throw classifyDownloadHttpStatus(resp.statusCode, resp.headers);
      }

      final total =
          int.tryParse(resp.headers.value('content-length') ?? '') ?? -1;
      if (maxBytes > 0 && total > maxBytes) {
        await _drainQuietly(resp.stream);
        throw BookSourceException(
          code: 'PROVIDER_ERROR',
          message: '文件体积过大（$total 字节），超过限制 ($maxBytes 字节)',
        );
      }

      final targetFile = File(savePath);
      await targetFile.parent.create(recursive: true);
      final partFile = File('$savePath.part');
      if (await partFile.exists()) {
        await partFile.delete();
      }

      IOSink? sink;
      var committed = false;
      var written = 0;

      try {
        sink = partFile.openWrite();
        onProgress?.call(0, total);
        final iterator = StreamIterator(resp.stream);
        try {
          while (true) {
            if (cancelToken?.isCancelled ?? false) {
              throw const BookSourceException(
                code: 'CANCELLED',
                message: '下载已取消',
              );
            }
            final hasNext = await iterator.moveNext().timeout(
              stallDuration,
              onTimeout: () => throw TimeoutException('download stalled'),
            );
            if (!hasNext) break;
            final chunk = iterator.current;
            if (chunk.isEmpty) continue;
            written += chunk.length;
            if (maxBytes > 0 && written > maxBytes) {
              throw BookSourceException(
                code: 'PROVIDER_ERROR',
                message: '文件下载超出最大允许大小 ($maxBytes 字节)',
              );
            }
            sink.add(chunk);
            onProgress?.call(written, total);
          }
        } finally {
          await iterator.cancel();
        }
        await sink.flush();
        await sink.close();
        sink = null;

        if (await targetFile.exists()) {
          await targetFile.delete();
        }
        await partFile.rename(savePath);
        committed = true;

        final resolved = resolveDownloadMeta(
          headers: resp.headers,
          finalUri: resp.finalUri,
          meta: meta,
        );

        return BookSourceDownloadedFile(
          savePath: savePath,
          filename: resolved.filename,
          format: resolved.format,
          sizeBytes: total > 0 ? total : written,
        );
      } on TimeoutException {
        lastErr = BookSourceException(
          code: 'TIMEOUT',
          message: '下载长时间无响应（超过 ${stallDuration.inSeconds} 秒）',
        );
        continue;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          throw const BookSourceException(code: 'CANCELLED', message: '下载已取消');
        }
        lastErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '下载中断：${e.message ?? e.type.name}',
        );
        continue;
      } on BookSourceException {
        rethrow;
      } catch (e) {
        lastErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '写入下载文件失败：$e',
        );
        continue;
      } finally {
        if (sink != null) {
          try {
            await sink.close();
          } catch (_) {}
        }
        if (!committed && await partFile.exists()) {
          try {
            await partFile.delete();
          } catch (_) {}
        }
      }
    }

    throw lastErr ??
        const BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '下载失败，请稍后重试',
        );
  }

  static bool _isRetryableStatus(int status) =>
      status == 502 || status == 503 || status == 504;

  static Future<void> _drainQuietly(Stream<List<int>> stream) async {
    try {
      await stream.drain<void>();
    } catch (_) {}
  }

  static BookSourceException classifyDownloadHttpStatus(
    int status,
    Headers headers,
  ) {
    final ct = (headers.value('content-type') ?? '').toLowerCase();
    if (status == 401 || status == 403) {
      if (ct.contains('text/html')) {
        return BookSourceException(
          code: 'PROVIDER_BLOCKED',
          message: '下载被反爬拦截（HTTP $status），请尝试切换镜像或配置反代',
          statusCode: status,
        );
      }
      return BookSourceException(
        code: 'SESSION_EXPIRED',
        message: '书源会话已失效或无下载权限（HTTP $status）',
        statusCode: status,
      );
    }
    if (status == 404) {
      return BookSourceException(
        code: 'NOT_FOUND',
        message: '下载资源不存在（HTTP 404）',
        statusCode: status,
      );
    }
    if (status == 429) {
      return BookSourceException(
        code: 'QUOTA_EXCEEDED',
        message: '今日下载额度已用尽或请求过于频繁（HTTP 429）',
        statusCode: status,
      );
    }
    if (status >= 500) {
      return BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: '书源服务端错误（HTTP $status）',
        statusCode: status,
      );
    }
    return BookSourceException(
      code: 'PROVIDER_ERROR',
      message: '下载失败（HTTP $status）',
      statusCode: status,
    );
  }

  static ({String filename, String format}) resolveDownloadMeta({
    required Headers headers,
    required Uri finalUri,
    BookSourceSearchBook? meta,
  }) {
    final xName = (headers.value('x-book-filename') ?? '').trim();
    var filename = xName.isNotEmpty
        ? _safeDecodeUriComponent(xName)
        : filenameFromDisposition(headers.value('content-disposition'));

    if (filename.isEmpty && finalUri.pathSegments.isNotEmpty) {
      final candidate = _safeDecodeUriComponent(finalUri.pathSegments.last);
      if (candidate.contains('.')) {
        filename = candidate;
      }
    }
    filename = sanitizeFilename(filename);

    var format = (headers.value('x-book-format') ?? '').trim().toLowerCase();
    if (format.isEmpty) {
      format = extensionOf(filename);
    }
    if (format.isEmpty) {
      format = extFromContentType(headers.value('content-type') ?? '');
    }
    if (format.isEmpty) {
      format = (meta?.format ?? '').trim().toLowerCase();
    }
    if (format.isEmpty) {
      format = 'bin';
    }

    if (filename.isEmpty) {
      final base = (meta?.title.trim().isNotEmpty ?? false)
          ? sanitizeFilename(meta!.title.trim())
          : sanitizeFilename(meta?.ref ?? 'download');
      final stem = base.isNotEmpty ? base : 'download';
      filename = stem.toLowerCase().endsWith('.$format')
          ? stem
          : '$stem.$format';
    }

    return (filename: filename, format: format);
  }

  static String filenameFromDisposition(String? header) {
    if (header == null || header.trim().isEmpty) return '';
    final utf8Match = RegExp(
      r"filename\*=(?:UTF-8|utf-8)''([^;\s]+)",
    ).firstMatch(header);
    if (utf8Match != null) {
      return _safeDecodeUriComponent(utf8Match.group(1) ?? '');
    }
    final basicQuoted = RegExp(r'filename="([^"]+)"').firstMatch(header);
    if (basicQuoted != null) {
      return basicQuoted.group(1) ?? '';
    }
    final basicPlain = RegExp(r'filename=([^;\s]+)').firstMatch(header);
    return basicPlain?.group(1) ?? '';
  }

  static String sanitizeFilename(String raw) {
    var name = raw.trim().replaceAll('\\', '/');
    if (name.isEmpty) return '';
    name = p.posix.basename(name);
    name = name.replaceAll(
      RegExp(r'[\x00-\x1F\x7F\u200E\u200F\u202A-\u202E\u2066-\u2069]'),
      '',
    );
    name = name.trim();
    if (name.isEmpty || name == '.' || name == '..' || name == '/') {
      return '';
    }
    if (name.length > 180) {
      final ext = p.extension(name);
      if (ext.length < 180) {
        final stem = name.substring(0, 180 - ext.length).trim();
        return stem.isEmpty ? ext : '$stem$ext';
      }
      return name.substring(0, 180);
    }
    return name;
  }

  static String extensionOf(String filename) {
    final ext = p
        .extension(filename)
        .toLowerCase()
        .replaceFirst('.', '')
        .trim();
    if (ext.isEmpty || ext.length > 12) return '';
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return '';
    return ext;
  }

  static String extFromContentType(String contentType) {
    final media = contentType.split(';').first.trim().toLowerCase();
    return contentTypeExtensions[media] ?? '';
  }

  static String _safeDecodeUriComponent(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }
}
