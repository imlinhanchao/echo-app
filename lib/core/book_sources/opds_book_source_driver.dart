import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'book_source_driver.dart';
import 'book_source_models.dart';
import 'mirror_pool_manager.dart';

/// Native OPDS 1.2 (Atom XML + OpenSearch) and OPDS 2.0 (JSON) book source driver.
class OpdsBookSourceDriver implements BookSourceDriver {
  OpdsBookSourceDriver({
    required MirrorPoolManager mirrorPool,
    Duration downloadRetryBaseDelay = const Duration(milliseconds: 500),
  }) : _mirrorPool = mirrorPool,
       _downloadRetryBaseDelay = downloadRetryBaseDelay;

  final MirrorPoolManager _mirrorPool;
  final Duration _downloadRetryBaseDelay;

  final Map<String, String> _discoveredSearchTemplates = <String, String>{};
  final Map<String, List<String>> _nextPageUrlCache = <String, List<String>>{};

  @override
  Future<BookSourceSearchPage> search(
    ResolvedBookSource source,
    BookSourceSearchRequest request,
  ) async {
    final trimmedQuery = request.query.trim();
    if (trimmedQuery.isEmpty) {
      throw const BookSourceException(
        code: 'INVALID_INPUT',
        message: '请输入搜索关键词',
      );
    }

    final origins = _mirrorPool.candidateOrigins(source);
    if (origins.isEmpty) {
      throw const BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: 'OPDS 书库未配置地址',
      );
    }

    final catalogUrl = origins.first;
    final authHeaders = _buildAuthHeaders(source);
    final preferFormats =
        source.definition.opds?.preferFormats ?? const <String>['epub', 'txt'];

    final page = request.page < 1 ? 1 : request.page;
    final cacheKey = '${source.id}|$trimmedQuery|${request.filterSignature}';

    String targetUrl = '';
    var localFilterMode = false;

    if (page > 1) {
      final cachedPages = _nextPageUrlCache[cacheKey];
      if (cachedPages != null && page - 2 < cachedPages.length) {
        targetUrl = cachedPages[page - 2];
      } else {
        final tpl = await _resolveSearchTemplate(
          source,
          catalogUrl: catalogUrl,
          authHeaders: authHeaders,
        );
        if (tpl.isEmpty) {
          return BookSourceSearchPage(
            books: const <BookSourceSearchBook>[],
            page: page,
            totalPages: page,
            provider: source.id,
          );
        }
        targetUrl = _expandSearchTemplate(
          tpl,
          catalogUrl: catalogUrl,
          query: trimmedQuery,
          page: page,
          limit: request.limit,
        );
      }
    } else {
      final tpl = await _resolveSearchTemplate(
        source,
        catalogUrl: catalogUrl,
        authHeaders: authHeaders,
      );
      if (tpl.isNotEmpty) {
        targetUrl = _expandSearchTemplate(
          tpl,
          catalogUrl: catalogUrl,
          query: trimmedQuery,
          page: page,
          limit: request.limit,
        );
      } else {
        targetUrl = catalogUrl;
        localFilterMode = true;
      }
    }

    await _mirrorPool.throttle(source);
    final resp = await _mirrorPool.sendWithRedirects(
      url: targetUrl,
      originUsed: catalogUrl,
      headers: <String, String>{
        'Accept':
            'application/atom+xml,application/opds+json,application/json,application/xml,text/xml,*/*',
        ...source.definition.headers,
        ...authHeaders,
      },
      authHeaderNames: authHeaders.keys.toSet(),
      sameOriginCredentials:
          source.definition.auth?.inject.sameOriginOnly ?? true,
      proxyPrefix: source.proxyPrefix,
    );

    _throwIfErrorStatus(resp);
    _mirrorPool.markHealthy(source.id, catalogUrl);

    final parsed = _parseFeed(
      rawBody: resp.bodyText,
      baseUrl: resp.finalUri.toString(),
      source: source,
      preferFormats: preferFormats,
    );

    var books = parsed.books;
    if (localFilterMode) {
      final qLower = trimmedQuery.toLowerCase();
      books = books
          .where(
            (b) =>
                b.title.toLowerCase().contains(qLower) ||
                b.authors.any((a) => a.toLowerCase().contains(qLower)) ||
                b.description.toLowerCase().contains(qLower),
          )
          .toList(growable: false);
    }

    if (parsed.nextUrl.isNotEmpty) {
      final list = _nextPageUrlCache.putIfAbsent(cacheKey, () => <String>[]);
      final idx = page - 1;
      if (idx == list.length) {
        list.add(parsed.nextUrl);
      } else if (idx < list.length) {
        list[idx] = parsed.nextUrl;
      }
    }

    final hasMore = !localFilterMode && parsed.nextUrl.isNotEmpty;
    return BookSourceSearchPage(
      books: books,
      page: page,
      totalPages: hasMore ? page + 1 : page,
      provider: source.id,
    );
  }

  @override
  Future<BookSourceSearchBook> getBookDetail(
    ResolvedBookSource source,
    String ref, {
    BookSourceSearchBook? baseBook,
  }) async {
    return baseBook ??
        BookSourceSearchBook(ref: ref, title: ref, provider: source.id);
  }

  @override
  Future<BookSourceDownloadedFile> downloadBook(
    ResolvedBookSource source, {
    required String ref,
    required String savePath,
    BookSourceSearchBook? meta,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final origins = _mirrorPool.candidateOrigins(source);
    final originUsed = origins.isNotEmpty ? origins.first : '';

    var downloadUrl = (meta?.sourceVars['download_url'] ?? '').trim();
    if (downloadUrl.isEmpty &&
        (ref.startsWith('http://') || ref.startsWith('https://'))) {
      downloadUrl = ref;
    }
    if (downloadUrl.isEmpty) {
      throw const BookSourceException(
        code: 'NOT_FOUND',
        message: '未找到该书的 OPDS 下载链接，请先在搜索结果中点选书籍',
      );
    }

    final authHeaders = _buildAuthHeaders(source);
    return BookSourceDownloadHelper.streamToFile(
      mirrorPool: _mirrorPool,
      url: downloadUrl,
      originUsed: originUsed.isNotEmpty ? originUsed : downloadUrl,
      savePath: savePath,
      headers: <String, String>{
        ...source.definition.headers,
        ...authHeaders,
      },
      authHeaderNames: authHeaders.keys.toSet(),
      sameOriginCredentials:
          source.definition.auth?.inject.sameOriginOnly ?? true,
      proxyPrefix: source.proxyPrefix,
      retryBaseDelay: _downloadRetryBaseDelay,
      meta: meta,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  @override
  Future<BookSourceCredentials> authenticate(
    ResolvedBookSource source, {
    required String modeId,
    required Map<String, String> inputs,
  }) async {
    final nextValues = <String, String>{
      for (final e in inputs.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
    final candidate = ResolvedBookSource(
      definition: source.definition,
      origin: source.origin,
      subscriptionId: source.subscriptionId,
      subscriptionName: source.subscriptionName,
      overlay: source.overlay,
      credentials: BookSourceCredentials(
        sourceId: source.id,
        modeId: modeId,
        values: nextValues,
      ),
    );
    final account = await verify(candidate);
    return BookSourceCredentials(
      sourceId: source.id,
      modeId: modeId,
      values: Map<String, String>.unmodifiable(nextValues),
      account: account,
      savedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<BookSourceAccountStatus> verify(ResolvedBookSource source) async {
    final origins = _mirrorPool.candidateOrigins(source);
    if (origins.isEmpty) {
      throw const BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: 'OPDS 书库未配置地址',
      );
    }
    final catalogUrl = origins.first;
    final authHeaders = _buildAuthHeaders(source);
    final resp = await _mirrorPool.sendWithRedirects(
      url: catalogUrl,
      originUsed: catalogUrl,
      headers: <String, String>{
        'Accept':
            'application/atom+xml,application/opds+json,application/json,application/xml,text/xml,*/*',
        ...source.definition.headers,
        ...authHeaders,
      },
      authHeaderNames: authHeaders.keys.toSet(),
      sameOriginCredentials:
          source.definition.auth?.inject.sameOriginOnly ?? true,
      proxyPrefix: source.proxyPrefix,
    );
    _throwIfErrorStatus(resp);
    return BookSourceAccountStatus(
      configured: true,
      status: 'ok',
      email: source.credentials?.values['username'] ?? '',
      lastVerifiedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<List<MirrorProbeResult>> probeDomains(ResolvedBookSource source) =>
      _mirrorPool.probeAll(source);

  // ---------------------------------------------------------------------------
  // Search Discovery & Template Expansion
  // ---------------------------------------------------------------------------

  Future<String> _resolveSearchTemplate(
    ResolvedBookSource source, {
    required String catalogUrl,
    required Map<String, String> authHeaders,
  }) async {
    final configured = (source.definition.opds?.searchUrl ?? '').trim();
    if (configured.isNotEmpty) {
      return resolveSafeBookSourceUrl(configured, catalogUrl);
    }
    final cacheKey = '${source.id}|$catalogUrl';
    final cached = _discoveredSearchTemplates[cacheKey];
    if (cached != null) return cached;

    final resp = await _mirrorPool.sendWithRedirects(
      url: catalogUrl,
      originUsed: catalogUrl,
      headers: <String, String>{
        'Accept':
            'application/atom+xml,application/opds+json,application/json,application/xml,text/xml,*/*',
        ...source.definition.headers,
        ...authHeaders,
      },
      authHeaderNames: authHeaders.keys.toSet(),
      sameOriginCredentials:
          source.definition.auth?.inject.sameOriginOnly ?? true,
      proxyPrefix: source.proxyPrefix,
    );
    _throwIfErrorStatus(resp);

    final body = resp.bodyText.trimLeft();
    String discovered = '';
    if (body.startsWith('{')) {
      discovered = await _discoverFromOpds2Json(
        body,
        baseUrl: resp.finalUri.toString(),
        originUsed: catalogUrl,
        source: source,
        authHeaders: authHeaders,
      );
    } else if (body.startsWith('<')) {
      discovered = await _discoverFromAtomXml(
        body,
        baseUrl: resp.finalUri.toString(),
        originUsed: catalogUrl,
        source: source,
        authHeaders: authHeaders,
      );
    }
    _discoveredSearchTemplates[cacheKey] = discovered;
    return discovered;
  }

  Future<String> _discoverFromAtomXml(
    String xmlText, {
    required String baseUrl,
    required String originUsed,
    required ResolvedBookSource source,
    required Map<String, String> authHeaders,
  }) async {
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } catch (_) {
      return '';
    }
    for (final link in doc.rootElement.childElements.where(
      (e) => e.name.local == 'link',
    )) {
      final rel = (link.getAttribute('rel') ?? '').trim().toLowerCase();
      if (rel != 'search') continue;
      final type = (link.getAttribute('type') ?? '').trim().toLowerCase();
      final href = (link.getAttribute('href') ?? '').trim();
      if (href.isEmpty) continue;
      if (href.contains('{searchTerms}') || href.contains('{query}')) {
        return resolveSafeBookSourceUrl(href, baseUrl);
      }
      if (type.contains('opensearchdescription') || type.contains('xml')) {
        final descUrl = resolveSafeBookSourceUrl(href, baseUrl);
        if (descUrl.isEmpty) continue;
        final descResp = await _mirrorPool.sendWithRedirects(
          url: descUrl,
          originUsed: originUsed,
          headers: <String, String>{
            ...source.definition.headers,
            ...authHeaders,
          },
          authHeaderNames: authHeaders.keys.toSet(),
          sameOriginCredentials:
              source.definition.auth?.inject.sameOriginOnly ?? true,
          proxyPrefix: source.proxyPrefix,
        );
        if (descResp.statusCode < 400) {
          final tpl = _parseOpenSearchTemplate(
            descResp.bodyText,
            baseUrl: descUrl,
          );
          if (tpl.isNotEmpty) return tpl;
        }
      }
    }
    return '';
  }

  Future<String> _discoverFromOpds2Json(
    String jsonText, {
    required String baseUrl,
    required String originUsed,
    required ResolvedBookSource source,
    required Map<String, String> authHeaders,
  }) async {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) return '';
      final links = decoded['links'] as List<dynamic>? ?? const <dynamic>[];
      for (final rawLink in links) {
        if (rawLink is! Map) continue;
        final rel = (rawLink['rel']?.toString() ?? '').toLowerCase();
        if (rel != 'search') continue;
        final href = (rawLink['href']?.toString() ?? '').trim();
        if (href.isEmpty) continue;
        final templated = rawLink['templated'] == true;
        final type = (rawLink['type']?.toString() ?? '').toLowerCase();
        if (templated || href.contains('{')) {
          return resolveSafeBookSourceUrl(href, baseUrl);
        }
        if (type.contains('opensearchdescription')) {
          final descUrl = resolveSafeBookSourceUrl(href, baseUrl);
          if (descUrl.isEmpty) continue;
          final descResp = await _mirrorPool.sendWithRedirects(
            url: descUrl,
            originUsed: originUsed,
            headers: <String, String>{
              ...source.definition.headers,
              ...authHeaders,
            },
            authHeaderNames: authHeaders.keys.toSet(),
            sameOriginCredentials:
                source.definition.auth?.inject.sameOriginOnly ?? true,
            proxyPrefix: source.proxyPrefix,
          );
          if (descResp.statusCode < 400) {
            final tpl = _parseOpenSearchTemplate(
              descResp.bodyText,
              baseUrl: descUrl,
            );
            if (tpl.isNotEmpty) return tpl;
          }
        }
      }
    } catch (_) {}
    return '';
  }

  String _parseOpenSearchTemplate(String rawXml, {required String baseUrl}) {
    try {
      final doc = XmlDocument.parse(rawXml);
      final urls = doc.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'Url')
          .toList();
      XmlElement? preferred;
      for (final u in urls) {
        final t = (u.getAttribute('type') ?? '').toLowerCase();
        if (t.contains('opds-catalog') || t.contains('atom+xml')) {
          preferred = u;
          break;
        }
      }
      preferred ??= urls.isNotEmpty ? urls.first : null;
      final tpl = (preferred?.getAttribute('template') ?? '').trim();
      if (tpl.isEmpty) return '';
      return resolveSafeBookSourceUrl(tpl, baseUrl);
    } catch (_) {
      return '';
    }
  }

  String _expandSearchTemplate(
    String template, {
    required String catalogUrl,
    required String query,
    required int page,
    required int limit,
  }) {
    final encoded = Uri.encodeQueryComponent(query);
    // Uri.toString() percent-encodes `{` and `}`; restore braces before template expansion.
    var out = template
        .replaceAll('%7B', '{')
        .replaceAll('%7b', '{')
        .replaceAll('%7D', '}')
        .replaceAll('%7d', '}');
    // Handle RFC 6570 URI template style `{?query}` / `{?query,page}`
    out = out.replaceAllMapped(RegExp(r'\{\?([^}]+)\}'), (m) {
      final keys = (m.group(1) ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
      final pairs = <String>[];
      for (final k in keys) {
        if (k == 'query' || k == 'q' || k == 'searchTerms') {
          pairs.add('$k=$encoded');
        } else if (k == 'page' || k == 'startPage') {
          pairs.add('$k=$page');
        } else if (k == 'count' || k == 'limit') {
          pairs.add('$k=$limit');
        }
      }
      return pairs.isEmpty ? '' : '?${pairs.join('&')}';
    });

    out = out
        .replaceAll('{searchTerms}', encoded)
        .replaceAll('{searchTerms?}', encoded)
        .replaceAll('{query}', encoded)
        .replaceAll('{query.q}', encoded)
        .replaceAll('{startPage}', '$page')
        .replaceAll('{startPage?}', '$page')
        .replaceAll('{page}', '$page')
        .replaceAll('{count}', '$limit')
        .replaceAll('{count?}', '$limit')
        .replaceAll('{startIndex}', '${(page - 1) * limit + 1}')
        .replaceAll('{startIndex?}', '${(page - 1) * limit + 1}');

    // Strip optional OpenSearch placeholders like {language?}.
    out = out.replaceAll(RegExp(r'\{[a-zA-Z0-9_:-]+\?\}'), '');
    return resolveSafeBookSourceUrl(out, catalogUrl);
  }

  // ---------------------------------------------------------------------------
  // OPDS 1.2 & OPDS 2.0 Parsing
  // ---------------------------------------------------------------------------

  ({List<BookSourceSearchBook> books, String nextUrl}) _parseFeed({
    required String rawBody,
    required String baseUrl,
    required ResolvedBookSource source,
    required List<String> preferFormats,
  }) {
    final trimmed = rawBody.trimLeft();
    if (trimmed.startsWith('{')) {
      return _parseOpds2Json(
        trimmed,
        baseUrl: baseUrl,
        source: source,
        preferFormats: preferFormats,
      );
    }
    return _parseOpds1Atom(
      trimmed,
      baseUrl: baseUrl,
      source: source,
      preferFormats: preferFormats,
    );
  }

  ({List<BookSourceSearchBook> books, String nextUrl}) _parseOpds1Atom(
    String rawXml, {
    required String baseUrl,
    required ResolvedBookSource source,
    required List<String> preferFormats,
  }) {
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(rawXml);
    } catch (_) {
      return (books: const <BookSourceSearchBook>[], nextUrl: '');
    }

    final root = doc.rootElement;
    var nextUrl = '';
    for (final link in root.childElements.where((e) => e.name.local == 'link')) {
      final rel = (link.getAttribute('rel') ?? '').trim().toLowerCase();
      if (rel == 'next') {
        final href = (link.getAttribute('href') ?? '').trim();
        nextUrl = resolveSafeBookSourceUrl(href, baseUrl);
        break;
      }
    }

    final books = <BookSourceSearchBook>[];
    for (final entry in root.childElements.where(
      (e) => e.name.local == 'entry',
    )) {
      String childText(String localName) {
        for (final c in entry.childElements) {
          if (c.name.local == localName) {
            final t = c.innerText.trim();
            if (t.isNotEmpty) return t;
          }
        }
        return '';
      }

      final title = _cleanText(childText('title'));
      if (title.isEmpty) continue;

      final authors = entry.childElements
          .where((e) => e.name.local == 'author')
          .map((a) {
            final nameEl = a.childElements
                .where((c) => c.name.local == 'name')
                .firstOrNull;
            return _cleanText(nameEl?.innerText ?? a.innerText);
          })
          .where((s) => s.isNotEmpty)
          .toList(growable: false);

      var coverUrl = '';
      final candidates = <({String format, String url})>[];
      var sourceUrl = '';

      for (final link in entry.childElements.where(
        (e) => e.name.local == 'link',
      )) {
        final rel = (link.getAttribute('rel') ?? '').trim().toLowerCase();
        final type = (link.getAttribute('type') ?? '').trim().toLowerCase();
        final href = (link.getAttribute('href') ?? '').trim();
        if (href.isEmpty) continue;
        final resolved = resolveSafeBookSourceUrl(href, baseUrl);
        if (resolved.isEmpty) continue;

        if (rel.contains('image') || rel.contains('cover')) {
          if (coverUrl.isEmpty || !rel.contains('thumbnail')) {
            coverUrl = resolved;
          }
          continue;
        }
        if (rel == 'alternate' && type.contains('html')) {
          sourceUrl = resolved;
          continue;
        }

        final isAcquisition =
            rel.contains('acquisition') ||
            (rel.isEmpty && _formatFromMimeOrUrl(type, resolved).isNotEmpty);
        if (isAcquisition) {
          final fmt = _formatFromMimeOrUrl(type, resolved);
          if (fmt.isNotEmpty) {
            candidates.add((format: fmt, url: resolved));
          }
        }
      }

      final picked = _pickBestFormat(candidates, preferFormats);
      final rawId = childText('id');
      final ref = rawId.isNotEmpty
          ? rawId
          : (picked?.url.isNotEmpty == true ? picked!.url : title);

      final published = childText('issued').isNotEmpty
          ? childText('issued')
          : childText('published');
      final yearMatch = RegExp(r'\b\d{4}\b').firstMatch(published);
      final year = yearMatch?.group(0) ?? '';
      final summary = _cleanText(
        childText('summary').isNotEmpty
            ? childText('summary')
            : childText('content'),
      );

      books.add(
        BookSourceSearchBook(
          provider: source.id,
          ref: ref,
          title: title,
          authors: authors,
          year: year,
          publisher: _cleanText(childText('publisher')),
          language: _cleanText(childText('language')),
          format: picked?.format ?? '',
          coverUrl: coverUrl,
          description: summary,
          sourceUrl: sourceUrl,
          imageHeaders: <String, String>{
            ...source.definition.effectiveImageHeaders,
            ..._buildAuthHeaders(source),
          },
          sourceVars: <String, String>{
            if (picked != null) 'download_url': picked.url,
          },
        ),
      );
    }

    return (books: books, nextUrl: nextUrl);
  }

  ({List<BookSourceSearchBook> books, String nextUrl}) _parseOpds2Json(
    String rawJson, {
    required String baseUrl,
    required ResolvedBookSource source,
    required List<String> preferFormats,
  }) {
    Map<String, dynamic> decoded;
    try {
      final obj = jsonDecode(rawJson);
      if (obj is! Map) {
        return (books: const <BookSourceSearchBook>[], nextUrl: '');
      }
      decoded = obj.cast<String, dynamic>();
    } catch (_) {
      return (books: const <BookSourceSearchBook>[], nextUrl: '');
    }

    var nextUrl = '';
    final rootLinks = decoded['links'] as List<dynamic>? ?? const <dynamic>[];
    for (final l in rootLinks) {
      if (l is! Map) continue;
      if ((l['rel']?.toString() ?? '').toLowerCase() == 'next') {
        nextUrl = resolveSafeBookSourceUrl(
          l['href']?.toString() ?? '',
          baseUrl,
        );
        break;
      }
    }

    final pubs = decoded['publications'] as List<dynamic>? ?? const <dynamic>[];
    final books = <BookSourceSearchBook>[];
    for (final pub in pubs) {
      if (pub is! Map) continue;
      final meta =
          (pub['metadata'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final title = _cleanText(meta['title']?.toString() ?? '');
      if (title.isEmpty) continue;

      final authors = _extractOpds2Authors(meta['author']);
      var coverUrl = '';
      final images = pub['images'] as List<dynamic>? ?? const <dynamic>[];
      for (final img in images) {
        if (img is Map && img['href'] != null) {
          coverUrl = resolveSafeBookSourceUrl(img['href'].toString(), baseUrl);
          if (coverUrl.isNotEmpty) break;
        }
      }

      final candidates = <({String format, String url})>[];
      final links = pub['links'] as List<dynamic>? ?? const <dynamic>[];
      for (final l in links) {
        if (l is! Map) continue;
        final href = (l['href']?.toString() ?? '').trim();
        if (href.isEmpty) continue;
        final resolved = resolveSafeBookSourceUrl(href, baseUrl);
        if (resolved.isEmpty) continue;
        final rel = (l['rel']?.toString() ?? '').toLowerCase();
        final type = (l['type']?.toString() ?? '').toLowerCase();
        if (rel.contains('acquisition') ||
            _formatFromMimeOrUrl(type, resolved).isNotEmpty) {
          final fmt = _formatFromMimeOrUrl(type, resolved);
          if (fmt.isNotEmpty) candidates.add((format: fmt, url: resolved));
        }
      }
      final picked = _pickBestFormat(candidates, preferFormats);

      final rawId = (meta['identifier']?.toString() ?? '').trim();
      final ref = rawId.isNotEmpty
          ? rawId
          : (picked?.url.isNotEmpty == true ? picked!.url : title);
      final pubYearMatch = RegExp(
        r'\b\d{4}\b',
      ).firstMatch(meta['published']?.toString() ?? '');

      books.add(
        BookSourceSearchBook(
          provider: source.id,
          ref: ref,
          title: title,
          authors: authors,
          year: pubYearMatch?.group(0) ?? '',
          publisher: _cleanText(meta['publisher']?.toString() ?? ''),
          language: _cleanText(meta['language']?.toString() ?? ''),
          format: picked?.format ?? '',
          coverUrl: coverUrl,
          description: _cleanText(meta['description']?.toString() ?? ''),
          imageHeaders: <String, String>{
            ...source.definition.effectiveImageHeaders,
            ..._buildAuthHeaders(source),
          },
          sourceVars: <String, String>{
            if (picked != null) 'download_url': picked.url,
          },
        ),
      );
    }

    return (books: books, nextUrl: nextUrl);
  }

  static List<String> _extractOpds2Authors(Object? raw) {
    if (raw == null) return const <String>[];
    if (raw is String) {
      final t = raw.trim();
      return t.isEmpty ? const <String>[] : <String>[t];
    }
    if (raw is Map) {
      final n = raw['name']?.toString().trim() ?? '';
      return n.isEmpty ? const <String>[] : <String>[n];
    }
    if (raw is List) {
      final out = <String>[];
      for (final item in raw) {
        out.addAll(_extractOpds2Authors(item));
      }
      return out;
    }
    return const <String>[];
  }

  static ({String format, String url})? _pickBestFormat(
    List<({String format, String url})> candidates,
    List<String> preferFormats,
  ) {
    if (candidates.isEmpty) return null;
    for (final preferred in preferFormats) {
      for (final c in candidates) {
        if (c.format == preferred) return c;
      }
    }
    return candidates.first;
  }

  static String _formatFromMimeOrUrl(String mime, String url) {
    final lowerMime = mime.split(';').first.trim().toLowerCase();
    if (lowerMime.contains('epub')) return 'epub';
    if (lowerMime == 'text/plain') return 'txt';
    if (lowerMime == 'application/pdf') return 'pdf';
    if (lowerMime.contains('mobipocket')) return 'mobi';
    if (lowerMime.contains('amazon.ebook')) return 'azw3';
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.epub')) return 'epub';
    if (path.endsWith('.txt')) return 'txt';
    if (path.endsWith('.pdf')) return 'pdf';
    if (path.endsWith('.mobi')) return 'mobi';
    if (path.endsWith('.azw3')) return 'azw3';
    return '';
  }

  Map<String, String> _buildAuthHeaders(ResolvedBookSource source) {
    final creds = source.credentials?.values ?? const <String, String>{};
    if (creds.isEmpty) return const <String, String>{};
    final username = creds['username'] ?? '';
    final password = creds['password'] ?? '';
    if (username.isNotEmpty || password.isNotEmpty) {
      return <String, String>{
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      };
    }
    final token = creds['token'] ?? '';
    if (token.isNotEmpty) {
      return <String, String>{'Authorization': 'Bearer $token'};
    }
    return const <String, String>{};
  }

  static void _throwIfErrorStatus(MirrorHttpResponse resp) {
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw BookSourceException(
        code: 'SESSION_EXPIRED',
        message: 'OPDS 书库需要登录或账号凭据无效（HTTP ${resp.statusCode}）',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode == 404) {
      throw const BookSourceException(
        code: 'NOT_FOUND',
        message: 'OPDS 目录或搜索地址不存在（HTTP 404）',
        statusCode: 404,
      );
    }
    if (resp.statusCode >= 500) {
      throw BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: 'OPDS 服务暂不可用（HTTP ${resp.statusCode}）',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode >= 400) {
      throw BookSourceException(
        code: 'PROVIDER_ERROR',
        message: 'OPDS 请求失败（HTTP ${resp.statusCode}）',
        statusCode: resp.statusCode,
      );
    }
  }

  static String _cleanText(String raw) => raw
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
