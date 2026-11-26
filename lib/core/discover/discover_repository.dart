import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/standalone_config_store.dart';
import '../tts/tts_model_catalog.dart';
import 'discover_cache.dart';
import 'discover_config.dart';
import 'discover_config_store.dart';
import 'discover_models.dart';
import 'discover_parser.dart';

/// 荐书仓库异常。
class DiscoverException implements Exception {
  const DiscoverException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 荐书抓取、缓存、节流与远程规则更新仓库。
class DiscoverRepository {
  DiscoverRepository({
    required Dio dio,
    required DiscoverConfigStore configStore,
    required DiscoverCacheStore cacheStore,
    required StandaloneConfig Function() readStandaloneConfig,
    DiscoverParserRegistry? parsers,
    Future<String> Function()? loadBundledAsset,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _dio = dio,
       _configStore = configStore,
       _cacheStore = cacheStore,
       _readStandaloneConfig = readStandaloneConfig,
       _parsers = parsers ?? DiscoverParserRegistry(),
       _loadBundledAsset =
           loadBundledAsset ?? (() async => kBundledDiscoverRulesJson),
       _now = now ?? (() => DateTime.now().toUtc()),
       _delay = delay ?? Future<void>.delayed;

  final Dio _dio;
  final DiscoverConfigStore _configStore;
  final DiscoverCacheStore _cacheStore;
  final StandaloneConfig Function() _readStandaloneConfig;
  final DiscoverParserRegistry _parsers;
  final Future<String> Function() _loadBundledAsset;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  final Map<String, DateTime> _lastRequestBySource = <String, DateTime>{};
  DateTime? _lastBackgroundConfigCheckAt;

  /// 读取当前生效的规则配置：优先本地缓存的远程配置，其次内置默认规则。
  Future<DiscoverConfigSnapshot> loadActiveConfig() async {
    final stored = await _configStore.read();
    if (stored != null && stored.rawJson.trim().isNotEmpty) {
      try {
        final parsed = DiscoverRulesConfig.fromJsonString(stored.rawJson);
        if (validateDiscoverRulesConfig(parsed) == null) {
          return DiscoverConfigSnapshot(
            config: parsed,
            origin: DiscoverConfigOrigin.remoteCache,
            fetchedAt: stored.fetchedAt,
            remoteUrl: stored.remoteUrl,
          );
        }
      } catch (_) {
        // 已缓存的远程规则若意外损坏，自动降级为内置规则。
      }
    }
    return _loadBundledSnapshot();
  }

  Future<DiscoverConfigSnapshot> _loadBundledSnapshot() async {
    try {
      final raw = await _loadBundledAsset();
      final parsed = DiscoverRulesConfig.fromJsonString(raw);
      if (validateDiscoverRulesConfig(parsed) == null) {
        return DiscoverConfigSnapshot(
          config: parsed,
          origin: DiscoverConfigOrigin.bundled,
        );
      }
    } catch (_) {}

    return DiscoverConfigSnapshot(
      config: DiscoverRulesConfig.bundledFallback(),
      origin: DiscoverConfigOrigin.bundled,
    );
  }

  /// 后台静默检查远程规则更新（达到 `config_ttl_hours` 才拉取；失败完全静默）。
  Future<DiscoverConfigSnapshot?> maybeRefreshRemoteConfigInBackground() async {
    final standalone = _readStandaloneConfig();
    final remoteUrl = standalone.discoverConfigUrl.trim();
    if (remoteUrl.isEmpty || validateDiscoverConfigUrl(remoteUrl) != null) {
      return null;
    }

    final now = _now();
    if (_lastBackgroundConfigCheckAt != null &&
        now.difference(_lastBackgroundConfigCheckAt!) <
            const Duration(minutes: 10)) {
      return null;
    }

    final snapshot = await loadActiveConfig();
    final stored = await _configStore.read();
    final ttl = Duration(
      hours: snapshot.config.configTtlHours > 0
          ? snapshot.config.configTtlHours
          : DiscoverConfigDefaults.defaultConfigTtlHours,
    );
    if (stored != null &&
        stored.remoteUrl == remoteUrl &&
        now.difference(stored.fetchedAt) < ttl) {
      return null;
    }

    _lastBackgroundConfigCheckAt = now;
    try {
      final res = await refreshRemoteConfig(overrideUrl: remoteUrl);
      return res.updated ? res.snapshot : null;
    } catch (_) {
      return null;
    }
  }

  /// 从远程 URL 拉取规则配置并校验；校验失败时绝不覆盖既有配置。
  Future<DiscoverConfigUpdateResult> refreshRemoteConfig({
    String? overrideUrl,
  }) async {
    final targetUrl = (overrideUrl ?? _readStandaloneConfig().discoverConfigUrl)
        .trim();
    final currentSnapshot = await loadActiveConfig();
    if (targetUrl.isEmpty) {
      return DiscoverConfigUpdateResult(
        updated: false,
        message: '未配置远程规则地址，当前使用内置默认规则',
        snapshot: currentSnapshot,
      );
    }

    final urlError = validateDiscoverConfigUrl(targetUrl);
    if (urlError != null) {
      return DiscoverConfigUpdateResult(
        updated: false,
        message: urlError,
        snapshot: currentSnapshot,
      );
    }

    final candidates = _buildRemoteConfigCandidateUrls(targetUrl);
    String? lastError;

    for (final candidate in candidates) {
      try {
        final rawBody = await _fetchText(
          candidate,
          headers: const <String, String>{
            'Accept': 'application/json,text/plain,*/*',
          },
        );
        final parsed = DiscoverRulesConfig.fromJsonString(rawBody);
        final validationErr = validateDiscoverRulesConfig(parsed);
        if (validationErr != null) {
          lastError = '规则校验失败：$validationErr';
          continue;
        }

        final now = _now();
        await _configStore.write(
          StoredRemoteDiscoverRules(
            rawJson: jsonEncode(parsed.toJson()),
            remoteUrl: targetUrl,
            fetchedAt: now,
          ),
        );
        await _cacheStore.clear();
        return DiscoverConfigUpdateResult(
          updated: true,
          message: parsed.configVersion.isNotEmpty
              ? '已更新规则 v${parsed.configVersion}（共 ${parsed.enabledSources.length} 个荐书源）'
              : '规则更新成功',
          snapshot: DiscoverConfigSnapshot(
            config: parsed,
            origin: DiscoverConfigOrigin.remoteCache,
            fetchedAt: now,
            remoteUrl: targetUrl,
          ),
        );
      } on FormatException catch (e) {
        lastError = '规则格式错误：${e.message}';
      } on DioException catch (e) {
        lastError = _describeDioError(e);
      } catch (e) {
        lastError = '规则更新失败：$e';
      }
    }

    return DiscoverConfigUpdateResult(
      updated: false,
      message: lastError ?? '规则更新失败',
      snapshot: currentSnapshot,
    );
  }

  /// 清空远程规则缓存，恢复内置默认规则。
  Future<DiscoverConfigSnapshot> resetToBundledConfig() async {
    await _configStore.clear();
    await _cacheStore.clear();
    return _loadBundledSnapshot();
  }

  /// 加载指定荐书源的某个频道（默认命中未过期缓存；失败时自动回退过期旧缓存）。
  Future<DiscoverFeedData> loadFeed(
    String sourceId,
    String feedId, {
    int page = 1,
    bool forceRefresh = false,
  }) async {
    final snapshot = await loadActiveConfig();
    final source =
        snapshot.config.sourceById(sourceId) ??
        snapshot.config.resolveDefaultSource();
    if (source == null) {
      throw const DiscoverException('当前没有可用的荐书源');
    }
    final feed = source.feedById(feedId) ?? source.feeds.first;
    final effectiveMode = feed.mode.isNotEmpty ? feed.mode : source.mode;
    final parser = _parsers.forMode(effectiveMode);
    if (parser == null) {
      throw DiscoverException('不支持的解析模式：$effectiveMode');
    }

    final cacheKey = 'feed_${source.id}_${feed.id}_p$page';
    final cached = await _cacheStore.read(cacheKey);
    final ttl = Duration(
      hours: source.cacheTtlHours > 0
          ? source.cacheTtlHours
          : DiscoverConfigDefaults.defaultCacheTtlHours,
    );
    final now = _now();
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.fetchedAt) < ttl &&
        !cached.isEmpty) {
      return _cachedResult(cached, source, isStale: false);
    }

    final pageSize = feed.pageSize > 0
        ? feed.pageSize
        : DiscoverConfigDefaults.defaultPageSize;
    final offset = (page > 0 ? page - 1 : 0) * pageSize;
    final expandedUrl = feed.url
        .replaceAll('{page}', page.toString())
        .replaceAll('{offset}', offset.toString())
        .replaceAll('{limit}', pageSize.toString());
    final targetUrl = resolveSafeHttpUrl(expandedUrl, source.baseUrl);
    if (targetUrl.isEmpty) {
      throw DiscoverException('荐书频道 ${feed.title} 地址无效');
    }

    final mergedHeaders = <String, String>{...source.headers, ...feed.headers};

    try {
      await _throttleSource(source);
      var rawBody = await _fetchText(targetUrl, headers: mergedHeaders);
      if (feed.jsonp) {
        rawBody = stripJsonpWrapper(rawBody);
      }
      final fetchedAt = _now();
      final data = feed.isBooklists
          ? DiscoverFeedData(
              sourceId: source.id,
              feedId: feed.id,
              title: feed.title,
              kind: 'booklists',
              booklists: parser.parseBooklists(rawBody, source, feed),
              fetchedAt: fetchedAt,
              fromCache: false,
            )
          : DiscoverFeedData(
              sourceId: source.id,
              feedId: feed.id,
              title: feed.title,
              kind: 'books',
              books: parser.parseBooks(rawBody, source, feed),
              fetchedAt: fetchedAt,
              fromCache: false,
            );
      if (data.isEmpty && cached != null && !cached.isEmpty) {
        return _cachedResult(cached, source, isStale: true);
      }
      if (!data.isEmpty) {
        await _cacheStore.write(cacheKey, data);
      }
      return data;
    } catch (e) {
      if (cached != null && !cached.isEmpty) {
        return _cachedResult(cached, source, isStale: true);
      }
      if (e is DiscoverException) rethrow;
      if (e is DioException) {
        throw DiscoverException(_describeDioError(e));
      }
      throw DiscoverException('拉取「${feed.title}」失败：$e');
    }
  }

  /// 懒加载书单详情页中的推荐图书。
  Future<DiscoverFeedData> loadBooklistDetail(
    String sourceId,
    String detailUrl, {
    String title = '书单详情',
    bool forceRefresh = false,
  }) async {
    final snapshot = await loadActiveConfig();
    final source =
        snapshot.config.sourceById(sourceId) ??
        snapshot.config.resolveDefaultSource();
    if (source == null) {
      throw const DiscoverException('当前没有可用的荐书源');
    }
    final detailRule = source.booklistDetail;
    if (detailRule == null || !detailRule.isConfigured) {
      throw const DiscoverException('当前荐书源未配置书单详情解析规则');
    }
    final parser = _parsers.forMode(source.mode);
    if (parser == null) {
      throw DiscoverException('不支持的解析模式：${source.mode}');
    }

    final resolvedUrl = resolveSafeHttpUrl(detailUrl, source.baseUrl);
    if (resolvedUrl.isEmpty) {
      throw const DiscoverException('书单详情地址无效');
    }

    final cacheKey = 'detail_${source.id}_${_stableHash(resolvedUrl)}';
    final cached = await _cacheStore.read(cacheKey);
    final ttl = Duration(
      hours: source.cacheTtlHours > 0
          ? source.cacheTtlHours
          : DiscoverConfigDefaults.defaultCacheTtlHours,
    );
    final now = _now();
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.fetchedAt) < ttl &&
        !cached.isEmpty) {
      return _cachedResult(cached, source, isStale: false);
    }

    try {
      await _throttleSource(source);
      final rawBody = await _fetchText(resolvedUrl, headers: source.headers);
      final books = parser.parseBooklistDetail(rawBody, source, detailRule);
      final data = DiscoverFeedData(
        sourceId: source.id,
        feedId: 'booklist:${_stableHash(resolvedUrl)}',
        title: title,
        kind: 'books',
        books: books,
        fetchedAt: _now(),
        fromCache: false,
      );
      if (data.isEmpty && cached != null && !cached.isEmpty) {
        return _cachedResult(cached, source, isStale: true);
      }
      if (!data.isEmpty) {
        await _cacheStore.write(cacheKey, data);
      }
      return data;
    } catch (e) {
      if (cached != null && !cached.isEmpty) {
        return _cachedResult(cached, source, isStale: true);
      }
      if (e is DiscoverException) rethrow;
      if (e is DioException) {
        throw DiscoverException(_describeDioError(e));
      }
      throw DiscoverException('加载书单详情失败：$e');
    }
  }

  /// 懒加载单本图书详情页（补充内容简介、封面与按规则定义的动态扩展字段）。
  Future<DiscoverBook> loadBookDetail(
    DiscoverBook book, {
    bool forceRefresh = false,
  }) async {
    final snapshot = await loadActiveConfig();
    final source = snapshot.config.sourceById(book.sourceId);
    final detailRule = source?.bookDetail;
    if (source == null ||
        detailRule == null ||
        !detailRule.isConfigured ||
        book.detailUrl.trim().isEmpty) {
      return book;
    }

    final resolvedUrl = resolveSafeHttpUrl(book.detailUrl, source.baseUrl);
    if (resolvedUrl.isEmpty) {
      return book;
    }

    final effectiveMode = detailRule.mode.isNotEmpty
        ? detailRule.mode
        : source.mode;
    final parser = _parsers.forMode(effectiveMode);
    if (parser == null) {
      throw DiscoverException('不支持的解析模式：$effectiveMode');
    }

    final cacheKey = 'book_${source.id}_${_stableHash(resolvedUrl)}';
    final cached = await _cacheStore.read(cacheKey);
    final ttl = Duration(
      hours: source.cacheTtlHours > 0
          ? source.cacheTtlHours
          : DiscoverConfigDefaults.defaultCacheTtlHours,
    );
    final now = _now();
    final cachedBook = cached != null && cached.books.isNotEmpty
        ? cached.books.first
        : null;
    final imageHeaders = source.effectiveImageHeaders;

    if (!forceRefresh &&
        cached != null &&
        cachedBook != null &&
        now.difference(cached.fetchedAt) < ttl) {
      return book.mergeDetail(cachedBook).copyWith(
        imageHeaders: imageHeaders.isNotEmpty ? imageHeaders : null,
      );
    }

    final mergedHeaders = <String, String>{
      ...source.headers,
      ...detailRule.headers,
    };

    try {
      final rawBody = await _fetchText(resolvedUrl, headers: mergedHeaders);
      final enriched = parser.parseBookDetail(
        rawBody,
        source,
        detailRule,
        baseBook: book,
      );
      await _cacheStore.write(
        cacheKey,
        DiscoverFeedData(
          sourceId: source.id,
          feedId: 'book:${_stableHash(resolvedUrl)}',
          title: enriched.title,
          kind: 'book_detail',
          books: <DiscoverBook>[enriched],
          fetchedAt: _now(),
          fromCache: false,
        ),
      );
      return enriched;
    } catch (e) {
      if (cachedBook != null) {
        return book.mergeDetail(cachedBook).copyWith(
          imageHeaders: imageHeaders.isNotEmpty ? imageHeaders : null,
        );
      }
      if (e is DiscoverException) rethrow;
      if (e is DioException) {
        throw DiscoverException(_describeDioError(e));
      }
      throw DiscoverException('加载图书详情失败：$e');
    }
  }

  DiscoverFeedData _cachedResult(
    DiscoverFeedData cached,
    DiscoverSourceConfig source, {
    required bool isStale,
  }) {
    final effectiveHeaders = source.effectiveImageHeaders;
    final updated = cached.copyWith(fromCache: true, isStale: isStale);
    if (effectiveHeaders.isEmpty) return updated;
    return updated.copyWith(
      books: updated.books
          .map((b) => b.copyWith(imageHeaders: effectiveHeaders))
          .toList(growable: false),
      booklists: updated.booklists
          .map(
            (l) => DiscoverBooklist(
              title: l.title,
              meta: l.meta,
              summary: l.summary,
              covers: l.covers,
              detailUrl: l.detailUrl,
              sourceId: l.sourceId,
              imageHeaders: effectiveHeaders,
            ),
          )
          .toList(growable: false),
    );
  }

  List<String> _buildRemoteConfigCandidateUrls(String targetUrl) {
    final uri = Uri.tryParse(targetUrl);
    if (uri == null) return <String>[targetUrl];
    final isGitHub =
        uri.host == 'raw.githubusercontent.com' || uri.host == 'github.com';
    if (!isGitHub) return <String>[targetUrl];

    final standalone = _readStandaloneConfig();
    final mirrorId = standalone.ttsDownloadMirror;
    if (mirrorId == TtsModelCatalog.mirrorGithub) {
      return <String>[targetUrl];
    }

    String prefix = '';
    if (mirrorId == TtsModelCatalog.mirrorCustom) {
      if (TtsModelCatalog.validateCustomMirrorPrefix(
            standalone.customTtsMirrorPrefix,
          ) ==
          null) {
        prefix = TtsModelCatalog.normalizeMirrorPrefix(
          standalone.customTtsMirrorPrefix,
        );
      }
    } else {
      prefix = TtsModelCatalog.normalizeMirrorPrefix(
        TtsModelCatalog.mirrorById(mirrorId).prefix,
      );
    }

    if (prefix.isEmpty) return <String>[targetUrl];
    final mirrored = '$prefix$targetUrl';
    return mirrored == targetUrl
        ? <String>[targetUrl]
        : <String>[mirrored, targetUrl];
  }

  Future<void> _throttleSource(DiscoverSourceConfig source) async {
    final minIntervalMs = source.minRequestIntervalMs;
    if (minIntervalMs <= 0) return;
    final last = _lastRequestBySource[source.id];
    final now = _now();
    if (last != null) {
      final elapsed = now.difference(last);
      final requiredGap = Duration(milliseconds: minIntervalMs);
      if (elapsed < requiredGap) {
        await _delay(requiredGap - elapsed);
      }
    }
    _lastRequestBySource[source.id] = _now();
  }

  Future<String> _fetchText(
    String url, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final resp = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    final body = resp.data;
    if (body == null || body.trim().isEmpty) {
      throw const DiscoverException('服务器返回内容为空');
    }
    return body;
  }

  String _describeDioError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '请求超时，荐书源响应过慢或网络不可达';
    }
    final status = e.response?.statusCode;
    if (status != null) {
      return '荐书源请求失败（HTTP $status）';
    }
    return '网络连接失败，请稍后重试';
  }
}

/// 稳定无依赖的 64 位 FNV-1a 十六进制摘要（用于缓存文件名）。
String _stableHash(String input) {
  var h1 = 0x811c9dc5;
  var h2 = 0x01000193;
  for (final byte in utf8.encode(input)) {
    h1 ^= byte;
    h1 = (h1 * 0x01000193) & 0xffffffff;
    h2 = ((h2 * 31) ^ byte) & 0xffffffff;
  }
  return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
}

final Provider<DiscoverConfigStore> discoverConfigStoreProvider =
    Provider<DiscoverConfigStore>((ref) => FileDiscoverConfigStore());

final Provider<DiscoverCacheStore> discoverCacheStoreProvider =
    Provider<DiscoverCacheStore>((ref) => FileDiscoverCacheStore());

final Provider<Dio> discoverDioProvider = Provider<Dio>(
  (ref) => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  ),
);

final Provider<DiscoverRepository> discoverRepositoryProvider =
    Provider<DiscoverRepository>((ref) {
      return DiscoverRepository(
        dio: ref.watch(discoverDioProvider),
        configStore: ref.watch(discoverConfigStoreProvider),
        cacheStore: ref.watch(discoverCacheStoreProvider),
        readStandaloneConfig: () => ref.read(standaloneConfigProvider),
      );
    });
