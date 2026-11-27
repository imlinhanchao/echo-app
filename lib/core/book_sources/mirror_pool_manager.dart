import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'book_source_models.dart';

/// Raw HTTP response returned by [MirrorPoolManager].
class MirrorHttpResponse {
  const MirrorHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bytes,
    required this.finalUri,
    required this.originUsed,
  });

  final int statusCode;
  final Headers headers;
  final Uint8List bytes;
  final Uri finalUri;
  final String originUsed;

  String get bodyText => utf8.decode(bytes, allowMalformed: true);
}

/// Streaming HTTP response returned by [MirrorPoolManager.openStreamWithRedirects].
class MirrorStreamResponse {
  const MirrorStreamResponse({
    required this.statusCode,
    required this.headers,
    required this.stream,
    required this.finalUri,
  });

  final int statusCode;
  final Headers headers;
  final Stream<Uint8List> stream;
  final Uri finalUri;
}

/// Manages per-source mirror health caching, failover order, throttling, proxy
/// rewriting, domain probing, and cross-origin redirect credential stripping.
class MirrorPoolManager {
  MirrorPoolManager({
    Dio? dio,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.healthTtl = const Duration(minutes: 10),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 45),
               sendTimeout: const Duration(seconds: 15),
             ),
           ),
       _now = now ?? (() => DateTime.now().toUtc()),
       _delay = delay ?? Future<void>.delayed;

  final Dio _dio;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final Duration healthTtl;

  final Map<String, Map<String, DateTime>> _healthyUntil =
      <String, Map<String, DateTime>>{};
  final Map<String, String> _preferredOrigin = <String, String>{};
  final Map<String, DateTime> _lastRequestBySource = <String, DateTime>{};

  static const int maxRedirects = 10;

  /// Returns candidate origins ordered by priority:
  /// 1. user customDomain
  /// 2. user preferredDomain
  /// 3. in-memory healthy preferred origin (within 10m TTL)
  /// 4. other in-memory healthy origins (within TTL)
  /// 5. source.definition.domains order
  List<String> candidateOrigins(ResolvedBookSource source) {
    final now = _now();
    final sourceHealth = _healthyUntil[source.id];
    final out = <String>[];

    void add(String raw) {
      final norm = normalizeOriginUrl(raw);
      if (norm.isNotEmpty && !out.contains(norm)) {
        out.add(norm);
      }
    }

    if (source.customDomain.isNotEmpty) {
      add(source.customDomain);
    }
    if (source.preferredDomain.isNotEmpty) {
      add(source.preferredDomain);
    }

    final cachedPreferred = _preferredOrigin[source.id];
    if (cachedPreferred != null && cachedPreferred.isNotEmpty) {
      final expiry = sourceHealth?[cachedPreferred];
      if (expiry != null && now.isBefore(expiry)) {
        add(cachedPreferred);
      } else {
        _preferredOrigin.remove(source.id);
      }
    }

    if (sourceHealth != null) {
      for (final entry in sourceHealth.entries) {
        if (now.isBefore(entry.value)) {
          add(entry.key);
        }
      }
    }

    for (final d in source.definition.domains) {
      add(d);
    }

    return out;
  }

  void markHealthy(String sourceId, String origin) {
    final norm = normalizeOriginUrl(origin);
    if (norm.isEmpty) return;
    final map = _healthyUntil.putIfAbsent(
      sourceId,
      () => <String, DateTime>{},
    );
    map[norm] = _now().add(healthTtl);
    _preferredOrigin[sourceId] = norm;
  }

  void markUnhealthy(String sourceId, String origin) {
    final norm = normalizeOriginUrl(origin);
    if (norm.isEmpty) return;
    _healthyUntil[sourceId]?.remove(norm);
    if (_preferredOrigin[sourceId] == norm) {
      _preferredOrigin.remove(sourceId);
    }
  }

  bool isHealthyCached(String sourceId, String origin) {
    final norm = normalizeOriginUrl(origin);
    final expiry = _healthyUntil[sourceId]?[norm];
    return expiry != null && _now().isBefore(expiry);
  }

  /// Throttles requests according to `minRequestIntervalMs`.
  Future<void> throttle(ResolvedBookSource source) async {
    final gapMs = source.definition.minRequestIntervalMs;
    if (gapMs <= 0) return;
    final last = _lastRequestBySource[source.id];
    final now = _now();
    if (last != null) {
      final elapsed = now.difference(last);
      final requiredGap = Duration(milliseconds: gapMs);
      if (elapsed < requiredGap) {
        await _delay(requiredGap - elapsed);
      }
    }
    _lastRequestBySource[source.id] = _now();
  }

  /// Rewrites a full HTTP(S) target URL using [proxyPrefix] when configured.
  static String rewriteWithProxy(String targetUrl, String proxyPrefix) {
    final trimmedPrefix = proxyPrefix.trim();
    if (trimmedPrefix.isEmpty) return targetUrl;
    final safeTarget = resolveSafeBookSourceUrl(targetUrl, targetUrl);
    if (safeTarget.isEmpty) return targetUrl;
    if (trimmedPrefix.contains('{url}')) {
      return trimmedPrefix.replaceAll(
        '{url}',
        Uri.encodeComponent(safeTarget),
      );
    }
    final normalizedPrefix = trimmedPrefix.endsWith('/')
        ? trimmedPrefix
        : '$trimmedPrefix/';
    return '$normalizedPrefix$safeTarget';
  }

  /// Returns whether two URIs share the same scheme, host, and effective port.
  static bool isSameOrigin(Uri a, Uri b) {
    if (a.scheme.toLowerCase() != b.scheme.toLowerCase()) return false;
    if (a.host.toLowerCase() != b.host.toLowerCase()) return false;
    int portOf(Uri u) {
      if (u.hasPort) return u.port;
      return u.scheme.toLowerCase() == 'https' ? 443 : 80;
    }

    return portOf(a) == portOf(b);
  }

  /// Sends a buffered HTTP request following up to 10 redirects manually,
  /// stripping credentials whenever jumping across origins.
  Future<MirrorHttpResponse> sendWithRedirects({
    required String url,
    required String originUsed,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    Object? body,
    String? contentType,
    Set<String> authHeaderNames = const <String>{},
    bool sameOriginCredentials = true,
    String proxyPrefix = '',
    Duration? timeout,
    CancelToken? cancelToken,
  }) async {
    var currentUrl = url;
    var currentMethod = method.toUpperCase();
    var currentBody = body;
    var currentContentType = contentType;
    var currentHeaders = <String, String>{...headers};
    final originUri = Uri.tryParse(originUsed);

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final unproxiedUri = Uri.parse(currentUrl);
      if (sameOriginCredentials &&
          originUri != null &&
          !isSameOrigin(unproxiedUri, originUri)) {
        currentHeaders = _stripSensitiveHeaders(
          currentHeaders,
          authHeaderNames,
        );
      }

      final requestUrl = rewriteWithProxy(currentUrl, proxyPrefix);
      final resp = await _dio.request<List<int>>(
        requestUrl,
        data: currentBody,
        cancelToken: cancelToken,
        options: Options(
          method: currentMethod,
          headers: currentHeaders,
          contentType: currentContentType,
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (_) => true,
          connectTimeout: timeout ?? const Duration(seconds: 15),
          receiveTimeout: timeout ?? const Duration(seconds: 45),
          sendTimeout: timeout ?? const Duration(seconds: 15),
        ),
      );

      final status = resp.statusCode ?? 0;
      if (_isRedirectStatus(status)) {
        final loc = resp.headers.value('location')?.trim() ?? '';
        if (loc.isEmpty) {
          return MirrorHttpResponse(
            statusCode: status,
            headers: resp.headers,
            bytes: Uint8List.fromList(resp.data ?? const <int>[]),
            finalUri: unproxiedUri,
            originUsed: originUsed,
          );
        }
        final nextUrl = resolveSafeBookSourceUrl(loc, currentUrl);
        if (nextUrl.isEmpty) {
          throw const BookSourceException(
            code: 'PROVIDER_ERROR',
            message: '重定向目标地址不安全或无效',
          );
        }
        currentUrl = nextUrl;
        if (status == 301 || status == 302 || status == 303) {
          currentMethod = 'GET';
          currentBody = null;
          currentContentType = null;
        }
        continue;
      }

      return MirrorHttpResponse(
        statusCode: status,
        headers: resp.headers,
        bytes: Uint8List.fromList(resp.data ?? const <int>[]),
        finalUri: unproxiedUri,
        originUsed: originUsed,
      );
    }

    throw const BookSourceException(
      code: 'PROVIDER_ERROR',
      message: '请求重定向次数过多',
    );
  }

  /// Opens a streaming HTTP response following up to 10 redirects manually,
  /// stripping credentials whenever redirecting to another origin.
  Future<MirrorStreamResponse> openStreamWithRedirects({
    required String url,
    required String originUsed,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    Set<String> authHeaderNames = const <String>{},
    bool sameOriginCredentials = true,
    String proxyPrefix = '',
    Duration? connectTimeout,
    Duration? receiveTimeout,
    CancelToken? cancelToken,
  }) async {
    var currentUrl = url;
    var currentMethod = method.toUpperCase();
    var currentHeaders = <String, String>{...headers};
    final originUri = Uri.tryParse(originUsed);

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final unproxiedUri = Uri.parse(currentUrl);
      if (sameOriginCredentials &&
          originUri != null &&
          !isSameOrigin(unproxiedUri, originUri)) {
        currentHeaders = _stripSensitiveHeaders(
          currentHeaders,
          authHeaderNames,
        );
      }

      final requestUrl = rewriteWithProxy(currentUrl, proxyPrefix);
      final resp = await _dio.request<ResponseBody>(
        requestUrl,
        cancelToken: cancelToken,
        options: Options(
          method: currentMethod,
          headers: currentHeaders,
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          connectTimeout: connectTimeout ?? const Duration(seconds: 20),
          receiveTimeout: receiveTimeout ?? const Duration(minutes: 10),
        ),
      );

      final status = resp.statusCode ?? 0;
      final body = resp.data;
      if (_isRedirectStatus(status)) {
        final loc = resp.headers.value('location')?.trim() ?? '';
        await _drainStreamQuietly(body);
        if (loc.isEmpty) {
          throw BookSourceException(
            code: 'PROVIDER_ERROR',
            message: '下载重定向缺少 Location（HTTP $status）',
            statusCode: status,
          );
        }
        final nextUrl = resolveSafeBookSourceUrl(loc, currentUrl);
        if (nextUrl.isEmpty) {
          throw const BookSourceException(
            code: 'PROVIDER_ERROR',
            message: '下载重定向目标地址不安全或无效',
          );
        }
        currentUrl = nextUrl;
        if (status == 301 || status == 302 || status == 303) {
          currentMethod = 'GET';
        }
        continue;
      }

      return MirrorStreamResponse(
        statusCode: status,
        headers: resp.headers,
        stream: body?.stream ?? const Stream<Uint8List>.empty(),
        finalUri: unproxiedUri,
      );
    }

    throw const BookSourceException(
      code: 'PROVIDER_ERROR',
      message: '下载重定向次数过多',
    );
  }

  /// Probes all candidate domains of [source] concurrently and updates health cache.
  Future<List<MirrorProbeResult>> probeAll(ResolvedBookSource source) async {
    final probeCfg = source.definition.probe ?? const BookSourceProbeConfig();
    final origins = source.effectiveDomains;
    if (origins.isEmpty) return const <MirrorProbeResult>[];

    final results = await Future.wait(
      origins.map((origin) async {
        final target = resolveSafeBookSourceUrl(probeCfg.path, origin);
        if (target.isEmpty) {
          return MirrorProbeResult(
            domain: origin,
            ok: false,
            latencyMs: 0,
            error: '无效探测地址',
          );
        }
        final sw = Stopwatch()..start();
        try {
          final resp = await sendWithRedirects(
            url: target,
            originUsed: origin,
            method: probeCfg.method,
            headers: source.definition.headers,
            proxyPrefix: source.proxyPrefix,
            timeout: Duration(milliseconds: probeCfg.timeoutMs),
          );
          sw.stop();
          final ok = probeCfg.expectStatus.contains(resp.statusCode);
          if (ok) {
            markHealthy(source.id, origin);
          } else {
            markUnhealthy(source.id, origin);
          }
          return MirrorProbeResult(
            domain: origin,
            ok: ok,
            latencyMs: sw.elapsedMilliseconds,
            statusCode: resp.statusCode,
            error: ok ? '' : 'HTTP ${resp.statusCode}',
          );
        } on DioException catch (e) {
          sw.stop();
          markUnhealthy(source.id, origin);
          return MirrorProbeResult(
            domain: origin,
            ok: false,
            latencyMs: sw.elapsedMilliseconds,
            statusCode: e.response?.statusCode,
            error: e.message ?? '连接失败',
          );
        } catch (e) {
          sw.stop();
          markUnhealthy(source.id, origin);
          return MirrorProbeResult(
            domain: origin,
            ok: false,
            latencyMs: sw.elapsedMilliseconds,
            error: e.toString(),
          );
        }
      }),
    );
    return results;
  }

  static bool _isRedirectStatus(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static Future<void> _drainStreamQuietly(ResponseBody? body) async {
    if (body == null) return;
    try {
      await body.stream.drain<void>();
    } catch (_) {}
  }

  static Map<String, String> _stripSensitiveHeaders(
    Map<String, String> headers,
    Set<String> authHeaderNames,
  ) {
    final lowerStrip = <String>{
      'cookie',
      'authorization',
      'referer',
      for (final name in authHeaderNames) name.toLowerCase(),
    };
    final out = <String, String>{};
    for (final entry in headers.entries) {
      if (!lowerStrip.contains(entry.key.toLowerCase())) {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }
}
