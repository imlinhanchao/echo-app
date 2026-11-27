import 'dart:convert';

/// Supported schema version for declarative book source configurations.
const int kBookSourceSchemaVersion = 1;

/// Default TTL in hours for remote book source subscriptions.
const int kDefaultBookSourceConfigTtlHours = 24;

/// Default max download size (500 MB) matching ebook-api safeguards.
const int kDefaultBookSourceMaxDownloadBytes = 500 * 1024 * 1024;

/// Default stall timeout in seconds for streaming downloads.
const int kDefaultBookSourceStallTimeoutSeconds = 120;

/// Supported underlying book source drivers.
enum BookSourceDriverType {
  rule('rule', '规则引擎'),
  opds('opds', 'OPDS'),
  ebookApi('ebook_api', 'ebook-api');

  const BookSourceDriverType(this.wireName, this.displayLabel);

  final String wireName;
  final String displayLabel;

  static BookSourceDriverType? tryParse(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final value in values) {
      if (value.wireName == normalized) return value;
    }
    return null;
  }
}

/// Origin of a registered book source definition.
enum BookSourceOrigin {
  bundled('bundled', '内置公版'),
  subscription('subscription', '远程订阅'),
  local('local', '本地导入');

  const BookSourceOrigin(this.wireName, this.displayLabel);

  final String wireName;
  final String displayLabel;

  static BookSourceOrigin fromWire(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final value in values) {
      if (value.wireName == normalized) return value;
    }
    return BookSourceOrigin.local;
  }
}

/// Pure-Dart exception shared by all client-side book source drivers.
class BookSourceException implements Exception {
  const BookSourceException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Pure-Dart account/quota verification summary.
class BookSourceAccountStatus {
  const BookSourceAccountStatus({
    required this.configured,
    this.status = 'ok',
    this.email = '',
    this.dailyUsed = 0,
    this.dailyLimit = 0,
    this.dailyRemaining = 0,
    this.quotaKnown = false,
    this.premium = false,
    this.lastVerifiedAt,
  });

  factory BookSourceAccountStatus.fromJson(Map<String, dynamic> json) {
    return BookSourceAccountStatus(
      configured: json['configured'] as bool? ?? false,
      status: (json['status'] as String? ?? 'ok').trim(),
      email: (json['email'] as String? ?? '').trim(),
      dailyUsed: (json['daily_used'] as num?)?.toInt() ?? 0,
      dailyLimit: (json['daily_limit'] as num?)?.toInt() ?? 0,
      dailyRemaining: (json['daily_remaining'] as num?)?.toInt() ?? 0,
      quotaKnown: json['quota_known'] as bool? ?? false,
      premium: json['premium'] as bool? ?? false,
      lastVerifiedAt: DateTime.tryParse(
        json['last_verified_at'] as String? ?? '',
      )?.toUtc(),
    );
  }

  final bool configured;
  final String status;
  final String email;
  final int dailyUsed;
  final int dailyLimit;
  final int dailyRemaining;
  final bool quotaKnown;
  final bool premium;
  final DateTime? lastVerifiedAt;

  bool get needsLogin => status == 'needs_login' || status == 'error';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'configured': configured,
    'status': status,
    if (email.isNotEmpty) 'email': email,
    'daily_used': dailyUsed,
    'daily_limit': dailyLimit,
    'daily_remaining': dailyRemaining,
    'quota_known': quotaKnown,
    if (premium) 'premium': premium,
    if (lastVerifiedAt != null)
      'last_verified_at': lastVerifiedAt!.toUtc().toIso8601String(),
  };
}

/// Pure-Dart normalized search book record produced by drivers.
class BookSourceSearchBook {
  const BookSourceSearchBook({
    required this.ref,
    required this.title,
    this.provider = '',
    this.authors = const <String>[],
    this.year = '',
    this.publisher = '',
    this.language = '',
    this.format = '',
    this.size = '',
    this.isbn = '',
    this.coverUrl = '',
    this.description = '',
    this.sourceUrl = '',
    this.imageHeaders = const <String, String>{},
    this.sourceVars = const <String, String>{},
  });

  final String provider;
  final String ref;
  final String title;
  final List<String> authors;
  final String year;
  final String publisher;
  final String language;
  final String format;
  final String size;
  final String isbn;
  final String coverUrl;
  final String description;
  final String sourceUrl;
  final Map<String, String> imageHeaders;
  final Map<String, String> sourceVars;

  BookSourceSearchBook mergeDetail(BookSourceSearchBook detail) {
    return BookSourceSearchBook(
      provider: provider.isNotEmpty ? provider : detail.provider,
      ref: ref.isNotEmpty ? ref : detail.ref,
      title: detail.title.isNotEmpty ? detail.title : title,
      authors: detail.authors.isNotEmpty ? detail.authors : authors,
      year: detail.year.isNotEmpty ? detail.year : year,
      publisher: detail.publisher.isNotEmpty ? detail.publisher : publisher,
      language: detail.language.isNotEmpty ? detail.language : language,
      format: detail.format.isNotEmpty ? detail.format : format,
      size: detail.size.isNotEmpty ? detail.size : size,
      isbn: detail.isbn.isNotEmpty ? detail.isbn : isbn,
      coverUrl: detail.coverUrl.isNotEmpty ? detail.coverUrl : coverUrl,
      description: detail.description.isNotEmpty
          ? detail.description
          : description,
      sourceUrl: detail.sourceUrl.isNotEmpty ? detail.sourceUrl : sourceUrl,
      imageHeaders: detail.imageHeaders.isNotEmpty
          ? detail.imageHeaders
          : imageHeaders,
      sourceVars: <String, String>{...sourceVars, ...detail.sourceVars},
    );
  }
}

/// Pure-Dart paginated search result returned by drivers.
class BookSourceSearchPage {
  const BookSourceSearchPage({
    required this.books,
    required this.page,
    required this.totalPages,
    this.provider = '',
  });

  final List<BookSourceSearchBook> books;
  final int page;
  final int totalPages;
  final String provider;

  bool get hasMore => page < totalPages;
}

/// Pure-Dart search request passed to drivers.
class BookSourceSearchRequest {
  const BookSourceSearchRequest({
    required this.query,
    this.page = 1,
    this.limit = 20,
    this.extensions = const <String>[],
    this.languages = const <String>[],
    this.yearFrom = 0,
    this.yearTo = 0,
    this.order = '',
  });

  final String query;
  final int page;
  final int limit;
  final List<String> extensions;
  final List<String> languages;
  final int yearFrom;
  final int yearTo;
  final String order;

  String get filterSignature =>
      '${extensions.join(",")}|${languages.join(",")}|$yearFrom|$yearTo|$order|$limit';
}

/// Pure-Dart download result metadata.
class BookSourceDownloadedFile {
  const BookSourceDownloadedFile({
    required this.savePath,
    required this.filename,
    required this.format,
    required this.sizeBytes,
  });

  final String savePath;
  final String filename;
  final String format;
  final int sizeBytes;
}

/// Result of probing one mirror origin.
class MirrorProbeResult {
  const MirrorProbeResult({
    required this.domain,
    required this.ok,
    required this.latencyMs,
    this.statusCode,
    this.error = '',
  });

  final String domain;
  final bool ok;
  final int latencyMs;
  final int? statusCode;
  final String error;
}

// ---------------------------------------------------------------------------
// JSON Parsing Helpers
// ---------------------------------------------------------------------------

List<String> _parseStringList(Object? raw) {
  if (raw is! List) return const <String>[];
  return List<String>.unmodifiable(
    raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty),
  );
}

List<int> _parseIntList(Object? raw) {
  if (raw is! List) return const <int>[];
  final out = <int>[];
  for (final item in raw) {
    if (item is num) {
      out.add(item.toInt());
    } else if (item is String) {
      final parsed = int.tryParse(item.trim());
      if (parsed != null) out.add(parsed);
    }
  }
  return List<int>.unmodifiable(out);
}

Map<String, String> _parseStringMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final out = <String, String>{};
  for (final entry in raw.entries) {
    final k = entry.key.toString().trim();
    final v = entry.value?.toString() ?? '';
    if (k.isNotEmpty && v.isNotEmpty) {
      out[k] = v;
    }
  }
  return Map<String, String>.unmodifiable(out);
}

Map<String, String> _parseStringMapPreserveEmpty(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final out = <String, String>{};
  for (final entry in raw.entries) {
    final k = entry.key.toString().trim();
    if (k.isNotEmpty && entry.value != null) {
      out[k] = entry.value.toString();
    }
  }
  return Map<String, String>.unmodifiable(out);
}

Map<String, dynamic> _parseDynamicMap(Object? raw) {
  if (raw is! Map) return const <String, dynamic>{};
  final out = <String, dynamic>{};
  for (final entry in raw.entries) {
    final k = entry.key.toString().trim();
    if (k.isNotEmpty && entry.value != null) {
      out[k] = entry.value;
    }
  }
  return Map<String, dynamic>.unmodifiable(out);
}

/// Validates and normalizes an origin URL (no trailing slash, http/https only).
String normalizeOriginUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  final parsed = Uri.tryParse(value);
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty) {
    return '';
  }
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// Resolves [rawUrl] against [baseUrl] while blocking non-HTTP schemes (e.g. javascript:, data:).
String resolveSafeBookSourceUrl(String rawUrl, String baseUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('javascript:')) return '';

  final baseUri = Uri.tryParse(baseUrl.trim());
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return '';

  Uri resolved;
  if (parsed.hasScheme) {
    resolved = parsed;
  } else if (baseUri != null && baseUri.hasScheme && baseUri.host.isNotEmpty) {
    try {
      resolved = baseUri.resolveUri(parsed);
    } catch (_) {
      return '';
    }
  } else {
    return '';
  }

  if ((resolved.scheme != 'http' && resolved.scheme != 'https') ||
      resolved.host.isEmpty) {
    return '';
  }
  return resolved.toString();
}

/// Validates a book source subscription/import URL.
String? validateBookSourceUrl(String raw, {bool allowEmpty = false}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return allowEmpty ? null : '请输入有效的 http(s) 地址';
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return '地址必须以 http:// 或 https:// 开头并包含合法域名';
  }
  return null;
}

/// Validates a reverse proxy prefix (supports `https://p.com/` or `https://p.com/?url={url}`).
String? validateBookSourceProxyPrefix(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final sample = trimmed.contains('{url}')
      ? trimmed.replaceAll('{url}', Uri.encodeComponent('https://example.com'))
      : trimmed;
  final uri = Uri.tryParse(sample);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return '反代前缀必须为合法的 http(s) 地址，可选包含 {url} 占位符';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Schema Models (book-sources.v1)
// ---------------------------------------------------------------------------

/// Mirror health probe rule.
class BookSourceProbeConfig {
  const BookSourceProbeConfig({
    this.method = 'GET',
    this.path = '/',
    this.expectStatus = const <int>[200],
    this.timeoutMs = 8000,
  });

  factory BookSourceProbeConfig.fromJson(Map<String, dynamic> json) {
    final statuses = _parseIntList(json['expect_status']);
    return BookSourceProbeConfig(
      method: (json['method'] as String? ?? 'GET').trim().toUpperCase(),
      path: (json['path'] as String? ?? '/').trim(),
      expectStatus: statuses.isEmpty ? const <int>[200] : statuses,
      timeoutMs: (json['timeout_ms'] as num?)?.toInt() ?? 8000,
    );
  }

  final String method;
  final String path;
  final List<int> expectStatus;
  final int timeoutMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (method != 'GET') 'method': method,
    'path': path,
    if (expectStatus.length != 1 || expectStatus.first != 200)
      'expect_status': expectStatus,
    if (timeoutMs != 8000) 'timeout_ms': timeoutMs,
  };
}

/// Declarative field/value extraction rule across JSON, HTML, XML, and cookies.
class BookSourceExtractRule {
  const BookSourceExtractRule({
    this.selector = '',
    this.selectors = const <String>[],
    this.attr = '',
    this.attrs = const <String>[],
    this.all = false,
    this.nextSibling = '',
    this.afterHeading = '',
    this.headingSelector = '',
    this.preserveParagraphs = false,
    this.maxItems = 0,
    this.path = '',
    this.paths = const <String>[],
    this.pathSegments = const <String>[],
    this.jsonPath = '',
    this.cookie = '',
    this.template = '',
    this.firstOf = const <BookSourceExtractRule>[],
    this.whenPresent,
    this.constValue = '',
    this.splitRegex = '',
    this.transform = '',
    this.joinWith = ' / ',
    this.regex = '',
    this.regexGroup = 0,
    this.replacePattern = '',
    this.replaceWith = '',
    this.prefix = '',
    this.stripPrefix = '',
    this.stripSuffix = '',
    this.resolveUrl = false,
  });

  factory BookSourceExtractRule.fromJson(Object? raw) {
    if (raw is String) {
      final t = raw.trim();
      return BookSourceExtractRule(selector: t, path: t);
    }
    if (raw is! Map) return const BookSourceExtractRule();
    final json = raw.cast<String, dynamic>();
    final rawFirstOf = json['first_of'];
    final firstOfList = rawFirstOf is List
        ? List<BookSourceExtractRule>.unmodifiable(
            rawFirstOf.map(BookSourceExtractRule.fromJson),
          )
        : const <BookSourceExtractRule>[];
    final rawWhen = json['when_present'];
    return BookSourceExtractRule(
      selector: (json['selector'] as String? ?? '').trim(),
      selectors: _parseStringList(json['selectors']),
      attr: (json['attr'] as String? ?? '').trim(),
      attrs: _parseStringList(json['attrs']),
      all: json['all'] as bool? ?? false,
      nextSibling: (json['next_sibling'] as String? ?? '').trim(),
      afterHeading: (json['after_heading'] as String? ?? '').trim(),
      headingSelector: (json['heading_selector'] as String? ?? '').trim(),
      preserveParagraphs: json['preserve_paragraphs'] as bool? ?? false,
      maxItems: (json['max_items'] as num?)?.toInt() ?? 0,
      path: (json['path'] as String? ?? '').trim(),
      paths: _parseStringList(json['paths']),
      pathSegments: _parseStringList(json['path_segments']),
      jsonPath: (json['json_path'] as String? ?? '').trim(),
      cookie: (json['cookie'] as String? ?? '').trim(),
      template: json['template'] as String? ?? '',
      firstOf: firstOfList,
      whenPresent: rawWhen != null
          ? BookSourceExtractRule.fromJson(rawWhen)
          : null,
      constValue: json['const_value'] as String? ?? '',
      splitRegex: json['split_regex'] as String? ?? '',
      transform: (json['transform'] as String? ?? '').trim().toLowerCase(),
      joinWith: json['join_with'] as String? ?? ' / ',
      regex: json['regex'] as String? ?? '',
      regexGroup: (json['regex_group'] as num?)?.toInt() ?? 0,
      replacePattern: json['replace_pattern'] as String? ?? '',
      replaceWith: json['replace_with'] as String? ?? '',
      prefix: json['prefix'] as String? ?? '',
      stripPrefix: json['strip_prefix'] as String? ?? '',
      stripSuffix: json['strip_suffix'] as String? ?? '',
      resolveUrl: json['resolve_url'] as bool? ?? false,
    );
  }

  final String selector;
  final List<String> selectors;
  final String attr;
  final List<String> attrs;
  final bool all;
  final String nextSibling;
  final String afterHeading;
  final String headingSelector;
  final bool preserveParagraphs;
  final int maxItems;
  final String path;
  final List<String> paths;
  final List<String> pathSegments;
  final String jsonPath;
  final String cookie;
  final String template;
  final List<BookSourceExtractRule> firstOf;
  final BookSourceExtractRule? whenPresent;
  final String constValue;
  final String splitRegex;
  final String transform;
  final String joinWith;
  final String regex;
  final int regexGroup;
  final String replacePattern;
  final String replaceWith;
  final String prefix;
  final String stripPrefix;
  final String stripSuffix;
  final bool resolveUrl;

  List<String> get selectorCandidates {
    final out = <String>[];
    if (selector.isNotEmpty) out.add(selector);
    for (final s in selectors) {
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  List<String> get attrCandidates {
    final out = <String>[];
    if (attr.isNotEmpty) out.add(attr);
    for (final a in attrs) {
      if (a.isNotEmpty && !out.contains(a)) out.add(a);
    }
    return out;
  }

  List<String> get pathCandidates {
    final out = <String>[];
    if (path.isNotEmpty) out.add(path);
    for (final p in paths) {
      if (p.isNotEmpty && !out.contains(p)) out.add(p);
    }
    return out;
  }

  bool get isConfigured =>
      selector.isNotEmpty ||
      selectors.isNotEmpty ||
      attr.isNotEmpty ||
      attrs.isNotEmpty ||
      path.isNotEmpty ||
      paths.isNotEmpty ||
      pathSegments.isNotEmpty ||
      jsonPath.isNotEmpty ||
      cookie.isNotEmpty ||
      template.isNotEmpty ||
      firstOf.isNotEmpty ||
      whenPresent != null ||
      constValue.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (selector.isNotEmpty) 'selector': selector,
    if (selectors.isNotEmpty) 'selectors': selectors,
    if (attr.isNotEmpty) 'attr': attr,
    if (attrs.isNotEmpty) 'attrs': attrs,
    if (all) 'all': all,
    if (nextSibling.isNotEmpty) 'next_sibling': nextSibling,
    if (afterHeading.isNotEmpty) 'after_heading': afterHeading,
    if (headingSelector.isNotEmpty) 'heading_selector': headingSelector,
    if (preserveParagraphs) 'preserve_paragraphs': preserveParagraphs,
    if (maxItems > 0) 'max_items': maxItems,
    if (path.isNotEmpty) 'path': path,
    if (paths.isNotEmpty) 'paths': paths,
    if (pathSegments.isNotEmpty) 'path_segments': pathSegments,
    if (jsonPath.isNotEmpty) 'json_path': jsonPath,
    if (cookie.isNotEmpty) 'cookie': cookie,
    if (template.isNotEmpty) 'template': template,
    if (firstOf.isNotEmpty)
      'first_of': firstOf.map((e) => e.toJson()).toList(growable: false),
    if (whenPresent != null) 'when_present': whenPresent!.toJson(),
    if (constValue.isNotEmpty) 'const_value': constValue,
    if (splitRegex.isNotEmpty) 'split_regex': splitRegex,
    if (transform.isNotEmpty) 'transform': transform,
    if (joinWith != ' / ') 'join_with': joinWith,
    if (regex.isNotEmpty) 'regex': regex,
    if (regexGroup != 0) 'regex_group': regexGroup,
    if (replacePattern.isNotEmpty) 'replace_pattern': replacePattern,
    if (replaceWith.isNotEmpty) 'replace_with': replaceWith,
    if (prefix.isNotEmpty) 'prefix': prefix,
    if (stripPrefix.isNotEmpty) 'strip_prefix': stripPrefix,
    if (stripSuffix.isNotEmpty) 'strip_suffix': stripSuffix,
    if (resolveUrl) 'resolve_url': resolveUrl,
  };
}

Map<String, BookSourceExtractRule> _parseExtractMap(Object? raw) {
  if (raw is! Map) return const <String, BookSourceExtractRule>{};
  final out = <String, BookSourceExtractRule>{};
  for (final entry in raw.entries) {
    final k = entry.key.toString().trim();
    if (k.isEmpty) continue;
    out[k] = BookSourceExtractRule.fromJson(entry.value);
  }
  return Map<String, BookSourceExtractRule>.unmodifiable(out);
}

/// Polling specification attached to an asynchronous download step.
class BookSourcePollConfig {
  const BookSourcePollConfig({
    this.method = 'GET',
    this.path = '',
    this.url = '',
    this.headers = const <String, String>{},
    this.cookies = const <String, String>{},
    this.intervalMs = 3000,
    this.maxAttempts = 40,
    this.untilPath = '',
    this.untilValue = 'ready',
    this.failPath = '',
    this.failValue = 'failed',
    this.failMessagePath = '',
    this.extract = const <String, BookSourceExtractRule>{},
  });

  factory BookSourcePollConfig.fromJson(Map<String, dynamic> json) {
    return BookSourcePollConfig(
      method: (json['method'] as String? ?? 'GET').trim().toUpperCase(),
      path: (json['path'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      headers: _parseStringMap(json['headers']),
      cookies: _parseStringMap(json['cookies']),
      intervalMs: (json['interval_ms'] as num?)?.toInt() ?? 3000,
      maxAttempts: (json['max_attempts'] as num?)?.toInt() ?? 40,
      untilPath: (json['until_path'] as String? ?? '').trim(),
      untilValue: (json['until_value'] as String? ?? 'ready').trim(),
      failPath: (json['fail_path'] as String? ?? '').trim(),
      failValue: (json['fail_value'] as String? ?? 'failed').trim(),
      failMessagePath: (json['fail_message_path'] as String? ?? '').trim(),
      extract: _parseExtractMap(json['extract']),
    );
  }

  final String method;
  final String path;
  final String url;
  final Map<String, String> headers;
  final Map<String, String> cookies;
  final int intervalMs;
  final int maxAttempts;
  final String untilPath;
  final String untilValue;
  final String failPath;
  final String failValue;
  final String failMessagePath;
  final Map<String, BookSourceExtractRule> extract;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (method != 'GET') 'method': method,
    if (path.isNotEmpty) 'path': path,
    if (url.isNotEmpty) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
    if (cookies.isNotEmpty) 'cookies': cookies,
    if (intervalMs != 3000) 'interval_ms': intervalMs,
    if (maxAttempts != 40) 'max_attempts': maxAttempts,
    if (untilPath.isNotEmpty) 'until_path': untilPath,
    if (untilValue != 'ready') 'until_value': untilValue,
    if (failPath.isNotEmpty) 'fail_path': failPath,
    if (failValue != 'failed') 'fail_value': failValue,
    if (failMessagePath.isNotEmpty) 'fail_message_path': failMessagePath,
    if (extract.isNotEmpty)
      'extract': <String, dynamic>{
        for (final e in extract.entries) e.key: e.value.toJson(),
      },
  };
}

/// Declarative HTTP step used in auth pre-steps, verify steps, and download pipelines.
class BookSourceStepConfig {
  const BookSourceStepConfig({
    this.id = '',
    this.method = 'GET',
    this.path = '',
    this.url = '',
    this.contentType = 'none',
    this.headers = const <String, String>{},
    this.cookies = const <String, String>{},
    this.query = const <String, String>{},
    this.body = const <String, dynamic>{},
    this.responseMode = 'json',
    this.extract = const <String, BookSourceExtractRule>{},
    this.extractCookies = const <String, String>{},
    this.followWhileUrlRegex = '',
    this.maxHops = 3,
    this.poll,
  });

  factory BookSourceStepConfig.fromJson(Map<String, dynamic> json) {
    final pollRaw = json['poll'];
    return BookSourceStepConfig(
      id: (json['id'] as String? ?? '').trim(),
      method: (json['method'] as String? ?? 'GET').trim().toUpperCase(),
      path: (json['path'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      contentType: (json['content_type'] as String? ?? 'none')
          .trim()
          .toLowerCase(),
      headers: _parseStringMap(json['headers']),
      cookies: _parseStringMap(json['cookies']),
      query: _parseStringMap(json['query']),
      body: _parseDynamicMap(json['body']),
      responseMode: (json['response_mode'] as String? ?? 'json')
          .trim()
          .toLowerCase(),
      extract: _parseExtractMap(json['extract']),
      extractCookies: _parseStringMap(json['extract_cookies']),
      followWhileUrlRegex: (json['follow_while_url_regex'] as String? ?? '')
          .trim(),
      maxHops: (json['max_hops'] as num?)?.toInt() ?? 3,
      poll: pollRaw is Map
          ? BookSourcePollConfig.fromJson(pollRaw.cast<String, dynamic>())
          : null,
    );
  }

  final String id;
  final String method;
  final String path;
  final String url;
  final String contentType; // 'none' | 'form' | 'json'
  final Map<String, String> headers;
  final Map<String, String> cookies;
  final Map<String, String> query;
  final Map<String, dynamic> body;
  final String responseMode; // 'json' | 'html' | 'xml'
  final Map<String, BookSourceExtractRule> extract;
  final Map<String, String> extractCookies;
  final String followWhileUrlRegex;
  final int maxHops;
  final BookSourcePollConfig? poll;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (id.isNotEmpty) 'id': id,
    if (method != 'GET') 'method': method,
    if (path.isNotEmpty) 'path': path,
    if (url.isNotEmpty) 'url': url,
    if (contentType != 'none') 'content_type': contentType,
    if (headers.isNotEmpty) 'headers': headers,
    if (cookies.isNotEmpty) 'cookies': cookies,
    if (query.isNotEmpty) 'query': query,
    if (body.isNotEmpty) 'body': body,
    if (responseMode != 'json') 'response_mode': responseMode,
    if (extract.isNotEmpty)
      'extract': <String, dynamic>{
        for (final e in extract.entries) e.key: e.value.toJson(),
      },
    if (extractCookies.isNotEmpty) 'extract_cookies': extractCookies,
    if (followWhileUrlRegex.isNotEmpty)
      'follow_while_url_regex': followWhileUrlRegex,
    if (maxHops != 3) 'max_hops': maxHops,
    if (poll != null) 'poll': poll!.toJson(),
  };
}

/// Dynamic form field specification for an auth mode.
class BookSourceAuthField {
  const BookSourceAuthField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.required = true,
    this.hint = '',
  });

  factory BookSourceAuthField.fromJson(Map<String, dynamic> json) {
    return BookSourceAuthField(
      key: (json['key'] as String? ?? '').trim(),
      label: (json['label'] as String? ?? '').trim(),
      type: (json['type'] as String? ?? 'text').trim().toLowerCase(),
      required: json['required'] as bool? ?? true,
      hint: (json['hint'] as String? ?? '').trim(),
    );
  }

  final String key;
  final String label;
  final String type; // 'text' | 'email' | 'password' | 'multiline'
  final bool required;
  final String hint;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'label': label,
    if (type != 'text') 'type': type,
    if (!required) 'required': required,
    if (hint.isNotEmpty) 'hint': hint,
  };
}

/// Login request workflow for exchanging user inputs for reusable credentials.
class BookSourceLoginConfig {
  const BookSourceLoginConfig({
    this.preSteps = const <BookSourceStepConfig>[],
    this.method = 'POST',
    this.path = '',
    this.url = '',
    this.contentType = 'form',
    this.headers = const <String, String>{},
    this.cookies = const <String, String>{},
    this.body = const <String, dynamic>{},
    this.responseMode = 'json',
    this.saveCredentials = const <String, BookSourceExtractRule>{},
    this.saveCookieCredentials = const <String, String>{},
  });

  factory BookSourceLoginConfig.fromJson(Map<String, dynamic> json) {
    final rawPre = json['pre_steps'] as List<dynamic>? ?? const <dynamic>[];
    return BookSourceLoginConfig(
      preSteps: List<BookSourceStepConfig>.unmodifiable(
        rawPre.whereType<Map>().map(
          (e) => BookSourceStepConfig.fromJson(e.cast<String, dynamic>()),
        ),
      ),
      method: (json['method'] as String? ?? 'POST').trim().toUpperCase(),
      path: (json['path'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      contentType: (json['content_type'] as String? ?? 'form')
          .trim()
          .toLowerCase(),
      headers: _parseStringMap(json['headers']),
      cookies: _parseStringMap(json['cookies']),
      body: _parseDynamicMap(json['body']),
      responseMode: (json['response_mode'] as String? ?? 'json')
          .trim()
          .toLowerCase(),
      saveCredentials: _parseExtractMap(json['save_credentials']),
      saveCookieCredentials: _parseStringMap(json['save_cookie_credentials']),
    );
  }

  final List<BookSourceStepConfig> preSteps;
  final String method;
  final String path;
  final String url;
  final String contentType;
  final Map<String, String> headers;
  final Map<String, String> cookies;
  final Map<String, dynamic> body;
  final String responseMode;
  final Map<String, BookSourceExtractRule> saveCredentials;
  final Map<String, String> saveCookieCredentials;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (preSteps.isNotEmpty)
      'pre_steps': preSteps.map((e) => e.toJson()).toList(growable: false),
    'method': method,
    if (path.isNotEmpty) 'path': path,
    if (url.isNotEmpty) 'url': url,
    'content_type': contentType,
    if (headers.isNotEmpty) 'headers': headers,
    if (cookies.isNotEmpty) 'cookies': cookies,
    if (body.isNotEmpty) 'body': body,
    if (responseMode != 'json') 'response_mode': responseMode,
    if (saveCredentials.isNotEmpty)
      'save_credentials': <String, dynamic>{
        for (final e in saveCredentials.entries) e.key: e.value.toJson(),
      },
    if (saveCookieCredentials.isNotEmpty)
      'save_cookie_credentials': saveCookieCredentials,
  };
}

/// One authentication method supported by a source (e.g. password, cookies, basic).
class BookSourceAuthMode {
  const BookSourceAuthMode({
    required this.id,
    required this.label,
    this.fields = const <BookSourceAuthField>[],
    this.login,
  });

  factory BookSourceAuthMode.fromJson(Map<String, dynamic> json) {
    final rawFields = json['fields'] as List<dynamic>? ?? const <dynamic>[];
    final loginRaw = json['login'];
    return BookSourceAuthMode(
      id: (json['id'] as String? ?? '').trim(),
      label: (json['label'] as String? ?? '').trim(),
      fields: List<BookSourceAuthField>.unmodifiable(
        rawFields.whereType<Map>().map(
          (e) => BookSourceAuthField.fromJson(e.cast<String, dynamic>()),
        ),
      ),
      login: loginRaw is Map
          ? BookSourceLoginConfig.fromJson(loginRaw.cast<String, dynamic>())
          : null,
    );
  }

  final String id;
  final String label;
  final List<BookSourceAuthField> fields;
  final BookSourceLoginConfig? login;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'fields': fields.map((f) => f.toJson()).toList(growable: false),
    if (login != null) 'login': login!.toJson(),
  };
}

/// Verification and quota extraction specification.
class BookSourceVerifyConfig {
  const BookSourceVerifyConfig({
    this.method = 'GET',
    this.path = '',
    this.url = '',
    this.headers = const <String, String>{},
    this.responseMode = 'json',
    this.fields = const <String, BookSourceExtractRule>{},
    this.steps = const <BookSourceStepConfig>[],
  });

  factory BookSourceVerifyConfig.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as List<dynamic>? ?? const <dynamic>[];
    return BookSourceVerifyConfig(
      method: (json['method'] as String? ?? 'GET').trim().toUpperCase(),
      path: (json['path'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      headers: _parseStringMap(json['headers']),
      responseMode: (json['response_mode'] as String? ?? 'json')
          .trim()
          .toLowerCase(),
      fields: _parseExtractMap(json['fields']),
      steps: List<BookSourceStepConfig>.unmodifiable(
        rawSteps.whereType<Map>().map(
          (e) => BookSourceStepConfig.fromJson(e.cast<String, dynamic>()),
        ),
      ),
    );
  }

  final String method;
  final String path;
  final String url;
  final Map<String, String> headers;
  final String responseMode;
  final Map<String, BookSourceExtractRule> fields;
  final List<BookSourceStepConfig> steps;

  bool get isConfigured => path.isNotEmpty || url.isNotEmpty || steps.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (steps.isNotEmpty)
      'steps': steps.map((e) => e.toJson()).toList(growable: false),
    if (path.isNotEmpty) ...<String, dynamic>{
      if (method != 'GET') 'method': method,
      'path': path,
    },
    if (url.isNotEmpty) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
    if (responseMode != 'json') 'response_mode': responseMode,
    if (fields.isNotEmpty)
      'fields': <String, dynamic>{
        for (final e in fields.entries) e.key: e.value.toJson(),
      },
  };
}

/// How stored credentials are attached to outgoing requests.
class BookSourceAuthInjectConfig {
  const BookSourceAuthInjectConfig({
    this.sameOriginOnly = true,
    this.headers = const <String, String>{},
    this.cookies = const <String, String>{},
    this.query = const <String, String>{},
    this.basicUsername = '',
    this.basicPassword = '',
  });

  factory BookSourceAuthInjectConfig.fromJson(Map<String, dynamic> json) {
    final basicRaw = json['basic_auth'];
    var basicUser = '';
    var basicPass = '';
    if (basicRaw is Map) {
      basicUser = (basicRaw['username'] as String? ?? '').trim();
      basicPass = (basicRaw['password'] as String? ?? '').trim();
    }
    return BookSourceAuthInjectConfig(
      sameOriginOnly: json['same_origin_only'] as bool? ?? true,
      headers: _parseStringMap(json['headers']),
      cookies: _parseStringMap(json['cookies']),
      query: _parseStringMap(json['query']),
      basicUsername: basicUser,
      basicPassword: basicPass,
    );
  }

  final bool sameOriginOnly;
  final Map<String, String> headers;
  final Map<String, String> cookies;
  final Map<String, String> query;
  final String basicUsername;
  final String basicPassword;

  bool get hasBasicAuth => basicUsername.isNotEmpty || basicPassword.isNotEmpty;

  bool get isEmpty =>
      headers.isEmpty && cookies.isEmpty && query.isEmpty && !hasBasicAuth;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (!sameOriginOnly) 'same_origin_only': sameOriginOnly,
    if (headers.isNotEmpty) 'headers': headers,
    if (cookies.isNotEmpty) 'cookies': cookies,
    if (query.isNotEmpty) 'query': query,
    if (hasBasicAuth)
      'basic_auth': <String, String>{
        'username': basicUsername,
        'password': basicPassword,
      },
  };
}

/// Complete authentication and verification configuration for a book source.
class BookSourceAuthConfig {
  const BookSourceAuthConfig({
    this.required = false,
    this.requiredFor = const <String>[],
    this.inject = const BookSourceAuthInjectConfig(),
    this.modes = const <BookSourceAuthMode>[],
    this.verify,
  });

  factory BookSourceAuthConfig.fromJson(Map<String, dynamic> json) {
    final rawModes = json['modes'] as List<dynamic>? ?? const <dynamic>[];
    final injectRaw = json['inject'];
    final verifyRaw = json['verify'];
    return BookSourceAuthConfig(
      required: json['required'] as bool? ?? false,
      requiredFor: _parseStringList(
        json['required_for'],
      ).map((e) => e.toLowerCase()).toList(growable: false),
      inject: injectRaw is Map
          ? BookSourceAuthInjectConfig.fromJson(
              injectRaw.cast<String, dynamic>(),
            )
          : const BookSourceAuthInjectConfig(),
      modes: List<BookSourceAuthMode>.unmodifiable(
        rawModes.whereType<Map>().map(
          (e) => BookSourceAuthMode.fromJson(e.cast<String, dynamic>()),
        ),
      ),
      verify: verifyRaw is Map
          ? BookSourceVerifyConfig.fromJson(verifyRaw.cast<String, dynamic>())
          : null,
    );
  }

  final bool required;
  final List<String> requiredFor;
  final BookSourceAuthInjectConfig inject;
  final List<BookSourceAuthMode> modes;
  final BookSourceVerifyConfig? verify;

  bool get hasAuthConfig =>
      required || requiredFor.isNotEmpty || modes.isNotEmpty;

  bool get requiresAuthForSearch {
    if (requiredFor.contains('search')) return true;
    if (required && requiredFor.isEmpty) return true;
    return false;
  }

  bool get requiresAuthForDownload {
    if (requiredFor.contains('download')) return true;
    if (required && requiredFor.isEmpty) return true;
    return false;
  }

  List<String> get credentialKeys {
    final keys = <String>[];
    for (final mode in modes) {
      if (mode.login != null) {
        for (final k in mode.login!.saveCredentials.keys) {
          if (!keys.contains(k)) keys.add(k);
        }
        for (final k in mode.login!.saveCookieCredentials.keys) {
          if (!keys.contains(k)) keys.add(k);
        }
      } else {
        for (final f in mode.fields) {
          if (f.key.isNotEmpty && !keys.contains(f.key)) keys.add(f.key);
        }
      }
    }
    return List<String>.unmodifiable(keys);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'required': required,
    if (requiredFor.isNotEmpty) 'required_for': requiredFor,
    if (!inject.isEmpty) 'inject': inject.toJson(),
    if (modes.isNotEmpty)
      'modes': modes.map((m) => m.toJson()).toList(growable: false),
    if (verify != null && verify!.isConfigured) 'verify': verify!.toJson(),
  };
}

/// Anti-bot challenge detection rule.
class BookSourceBotProtectionConfig {
  const BookSourceBotProtectionConfig({
    this.statuses = const <int>[],
    this.htmlBody = false,
    this.hasLocationHeader = false,
  });

  factory BookSourceBotProtectionConfig.fromJson(Map<String, dynamic> json) {
    return BookSourceBotProtectionConfig(
      statuses: _parseIntList(json['statuses']),
      htmlBody: json['html_body'] as bool? ?? false,
      hasLocationHeader: json['has_location_header'] as bool? ?? false,
    );
  }

  final List<int> statuses;
  final bool htmlBody;
  final bool hasLocationHeader;

  bool get isConfigured => statuses.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (statuses.isNotEmpty) 'statuses': statuses,
    if (htmlBody) 'html_body': htmlBody,
    if (hasLocationHeader) 'has_location_header': hasLocationHeader,
  };
}

/// API envelope validation rule (e.g. `{"success":1,"error":"..."}`).
class BookSourceEnvelopeConfig {
  const BookSourceEnvelopeConfig({
    this.successPath = '',
    this.successValues = const <Object?>[],
    this.errorPath = '',
    this.errorCodePath = '',
  });

  factory BookSourceEnvelopeConfig.fromJson(Map<String, dynamic> json) {
    final rawValues = json['success_values'] as List<dynamic>? ?? const [];
    return BookSourceEnvelopeConfig(
      successPath: (json['success_path'] as String? ?? '').trim(),
      successValues: List<Object?>.unmodifiable(rawValues),
      errorPath: (json['error_path'] as String? ?? '').trim(),
      errorCodePath: (json['error_code_path'] as String? ?? '').trim(),
    );
  }

  final String successPath;
  final List<Object?> successValues;
  final String errorPath;
  final String errorCodePath;

  bool get isConfigured =>
      successPath.isNotEmpty ||
      errorPath.isNotEmpty ||
      errorCodePath.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (successPath.isNotEmpty) 'success_path': successPath,
    if (successValues.isNotEmpty) 'success_values': successValues,
    if (errorPath.isNotEmpty) 'error_path': errorPath,
    if (errorCodePath.isNotEmpty) 'error_code_path': errorCodePath,
  };
}

/// Maps HTTP statuses or upstream error messages to normalized Echo error codes.
class BookSourceErrorRule {
  const BookSourceErrorRule({
    required this.code,
    this.statuses = const <int>[],
    this.errorCodeRegex = '',
    this.errorRegex = '',
    this.requireUnauthenticated = false,
  });

  factory BookSourceErrorRule.fromJson(Map<String, dynamic> json) {
    return BookSourceErrorRule(
      code: (json['code'] as String? ?? '').trim().toUpperCase(),
      statuses: _parseIntList(json['statuses']),
      errorCodeRegex: (json['error_code_regex'] as String? ?? '').trim(),
      errorRegex: (json['error_regex'] as String? ?? '').trim(),
      requireUnauthenticated: json['require_unauthenticated'] as bool? ?? false,
    );
  }

  final String code;
  final List<int> statuses;
  final String errorCodeRegex;
  final String errorRegex;
  final bool requireUnauthenticated;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'code': code,
    if (statuses.isNotEmpty) 'statuses': statuses,
    if (errorCodeRegex.isNotEmpty) 'error_code_regex': errorCodeRegex,
    if (errorRegex.isNotEmpty) 'error_regex': errorRegex,
    if (requireUnauthenticated) 'require_unauthenticated': true,
  };
}

/// Complete error classification configuration for a source.
class BookSourceErrorConfig {
  const BookSourceErrorConfig({
    this.botProtection,
    this.envelope,
    this.rules = const <BookSourceErrorRule>[],
  });

  factory BookSourceErrorConfig.fromJson(Map<String, dynamic> json) {
    final bpRaw = json['bot_protection'];
    final envRaw = json['envelope'];
    final rawRules = json['rules'] as List<dynamic>? ?? const <dynamic>[];
    return BookSourceErrorConfig(
      botProtection: bpRaw is Map
          ? BookSourceBotProtectionConfig.fromJson(
              bpRaw.cast<String, dynamic>(),
            )
          : null,
      envelope: envRaw is Map
          ? BookSourceEnvelopeConfig.fromJson(envRaw.cast<String, dynamic>())
          : null,
      rules: List<BookSourceErrorRule>.unmodifiable(
        rawRules.whereType<Map>().map(
          (e) => BookSourceErrorRule.fromJson(e.cast<String, dynamic>()),
        ),
      ),
    );
  }

  final BookSourceBotProtectionConfig? botProtection;
  final BookSourceEnvelopeConfig? envelope;
  final List<BookSourceErrorRule> rules;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (botProtection != null && botProtection!.isConfigured)
      'bot_protection': botProtection!.toJson(),
    if (envelope != null && envelope!.isConfigured)
      'envelope': envelope!.toJson(),
    if (rules.isNotEmpty)
      'rules': rules.map((r) => r.toJson()).toList(growable: false),
  };
}

/// Option label/value pair for a filter control (e.g. sort order).
class BookSourceFilterOption {
  const BookSourceFilterOption({required this.value, required this.label});

  factory BookSourceFilterOption.fromJson(Map<String, dynamic> json) {
    return BookSourceFilterOption(
      value: (json['value'] as String? ?? '').trim(),
      label: (json['label'] as String? ?? '').trim(),
    );
  }

  final String value;
  final String label;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'value': value,
    'label': label,
  };
}

/// Maps one standard Echo search filter onto upstream query/form parameters.
class BookSourceFilterRule {
  const BookSourceFilterRule({
    this.param = '',
    this.mode = 'single',
    this.joinWith = ',',
    this.transform = '',
    this.omitIfZero = true,
    this.map = const <String, String>{},
    this.options = const <BookSourceFilterOption>[],
  });

  factory BookSourceFilterRule.fromJson(Map<String, dynamic> json) {
    final rawOpts = json['options'] as List<dynamic>? ?? const <dynamic>[];
    return BookSourceFilterRule(
      param: (json['param'] as String? ?? '').trim(),
      mode: (json['mode'] as String? ?? 'single').trim().toLowerCase(),
      joinWith: json['join_with'] as String? ?? ',',
      transform: (json['transform'] as String? ?? '').trim().toLowerCase(),
      omitIfZero: json['omit_if_zero'] as bool? ?? true,
      map: _parseStringMapPreserveEmpty(json['map']),
      options: List<BookSourceFilterOption>.unmodifiable(
        rawOpts.whereType<Map>().map(
          (e) => BookSourceFilterOption.fromJson(e.cast<String, dynamic>()),
        ),
      ),
    );
  }

  final String param;
  final String mode; // 'single' | 'repeat' | 'join'
  final String joinWith;
  final String transform; // '' | 'lower' | 'upper'
  final bool omitIfZero;
  final Map<String, String> map;
  final List<BookSourceFilterOption> options;

  bool get isConfigured => param.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'param': param,
    if (mode != 'single') 'mode': mode,
    if (joinWith != ',') 'join_with': joinWith,
    if (transform.isNotEmpty) 'transform': transform,
    if (!omitIfZero) 'omit_if_zero': omitIfZero,
    if (map.isNotEmpty) 'map': map,
    if (options.isNotEmpty)
      'options': options.map((o) => o.toJson()).toList(growable: false),
  };
}

/// Filter capabilities declared by a source for UI rendering & request mapping.
class BookSourceFiltersConfig {
  const BookSourceFiltersConfig({
    this.extensions,
    this.languages,
    this.yearFrom,
    this.yearTo,
    this.order,
  });

  factory BookSourceFiltersConfig.fromJson(Map<String, dynamic> json) {
    BookSourceFilterRule? readRule(String key) {
      final raw = json[key];
      if (raw is! Map) return null;
      final rule = BookSourceFilterRule.fromJson(raw.cast<String, dynamic>());
      return rule.isConfigured ? rule : null;
    }

    return BookSourceFiltersConfig(
      extensions: readRule('extensions'),
      languages: readRule('languages'),
      yearFrom: readRule('year_from'),
      yearTo: readRule('year_to'),
      order: readRule('order'),
    );
  }

  final BookSourceFilterRule? extensions;
  final BookSourceFilterRule? languages;
  final BookSourceFilterRule? yearFrom;
  final BookSourceFilterRule? yearTo;
  final BookSourceFilterRule? order;

  bool get supportsExtensions => extensions != null;
  bool get supportsLanguages => languages != null;
  bool get supportsYearRange => yearFrom != null || yearTo != null;
  bool get supportsOrder => order != null;

  bool get hasAnyFilter =>
      supportsExtensions ||
      supportsLanguages ||
      supportsYearRange ||
      supportsOrder;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (extensions != null) 'extensions': extensions!.toJson(),
    if (languages != null) 'languages': languages!.toJson(),
    if (yearFrom != null) 'year_from': yearFrom!.toJson(),
    if (yearTo != null) 'year_to': yearTo!.toJson(),
    if (order != null) 'order': order!.toJson(),
  };
}

/// Upstream search request template.
class BookSourceSearchRequestConfig {
  const BookSourceSearchRequestConfig({
    this.method = 'GET',
    this.path = '',
    this.url = '',
    this.contentType = 'none',
    this.headers = const <String, String>{},
    this.query = const <String, String>{},
    this.body = const <String, dynamic>{},
    this.pageSize = 20,
  });

  factory BookSourceSearchRequestConfig.fromJson(Map<String, dynamic> json) {
    final pageSizeRaw = (json['page_size'] as num?)?.toInt();
    return BookSourceSearchRequestConfig(
      method: (json['method'] as String? ?? 'GET').trim().toUpperCase(),
      path: (json['path'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      contentType: (json['content_type'] as String? ?? 'none')
          .trim()
          .toLowerCase(),
      headers: _parseStringMap(json['headers']),
      query: _parseStringMap(json['query']),
      body: _parseDynamicMap(json['body']),
      pageSize: pageSizeRaw != null && pageSizeRaw > 0 ? pageSizeRaw : 20,
    );
  }

  final String method;
  final String path;
  final String url;
  final String contentType;
  final Map<String, String> headers;
  final Map<String, String> query;
  final Map<String, dynamic> body;
  final int pageSize;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': method,
    if (path.isNotEmpty) 'path': path,
    if (url.isNotEmpty) 'url': url,
    if (contentType != 'none') 'content_type': contentType,
    if (headers.isNotEmpty) 'headers': headers,
    if (query.isNotEmpty) 'query': query,
    if (body.isNotEmpty) 'body': body,
    if (pageSize != 20) 'page_size': pageSize,
  };
}

/// Search pagination rule supporting page numbers, total counts, next-link HTML, and cursors.
class BookSourcePaginationConfig {
  const BookSourcePaginationConfig({
    this.currentPagePath = '',
    this.totalPagesPath = '',
    this.totalCountPath = '',
    this.pageSize = 0,
    this.nextPagePath = '',
    this.nextPageSelector = '',
    this.cursorParam = '',
    this.nextCursorPath = '',
  });

  factory BookSourcePaginationConfig.fromJson(Map<String, dynamic> json) {
    return BookSourcePaginationConfig(
      currentPagePath: (json['current_page_path'] as String? ?? '').trim(),
      totalPagesPath: (json['total_pages_path'] as String? ?? '').trim(),
      totalCountPath: (json['total_count_path'] as String? ?? '').trim(),
      pageSize: (json['page_size'] as num?)?.toInt() ?? 0,
      nextPagePath: (json['next_page_path'] as String? ?? '').trim(),
      nextPageSelector: (json['next_page_selector'] as String? ?? '').trim(),
      cursorParam: (json['cursor_param'] as String? ?? '').trim(),
      nextCursorPath: (json['next_cursor_path'] as String? ?? '').trim(),
    );
  }

  final String currentPagePath;
  final String totalPagesPath;
  final String totalCountPath;
  final int pageSize;
  final String nextPagePath;
  final String nextPageSelector;
  final String cursorParam;
  final String nextCursorPath;

  bool get isConfigured =>
      currentPagePath.isNotEmpty ||
      totalPagesPath.isNotEmpty ||
      totalCountPath.isNotEmpty ||
      nextPagePath.isNotEmpty ||
      nextPageSelector.isNotEmpty ||
      cursorParam.isNotEmpty ||
      nextCursorPath.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (currentPagePath.isNotEmpty) 'current_page_path': currentPagePath,
    if (totalPagesPath.isNotEmpty) 'total_pages_path': totalPagesPath,
    if (totalCountPath.isNotEmpty) 'total_count_path': totalCountPath,
    if (pageSize > 0) 'page_size': pageSize,
    if (nextPagePath.isNotEmpty) 'next_page_path': nextPagePath,
    if (nextPageSelector.isNotEmpty) 'next_page_selector': nextPageSelector,
    if (cursorParam.isNotEmpty) 'cursor_param': cursorParam,
    if (nextCursorPath.isNotEmpty) 'next_cursor_path': nextCursorPath,
  };
}

/// Search response parsing rule.
class BookSourceSearchResponseConfig {
  const BookSourceSearchResponseConfig({
    this.mode = 'json',
    this.itemsPath = '',
    this.itemsSelector = '',
    this.pagination = const BookSourcePaginationConfig(),
    this.vars = const <String, BookSourceExtractRule>{},
    this.fields = const <String, BookSourceExtractRule>{},
  });

  factory BookSourceSearchResponseConfig.fromJson(Map<String, dynamic> json) {
    final pageRaw = json['pagination'];
    return BookSourceSearchResponseConfig(
      mode: (json['mode'] as String? ?? 'json').trim().toLowerCase(),
      itemsPath: (json['items_path'] as String? ?? '').trim(),
      itemsSelector: (json['items_selector'] as String? ?? '').trim(),
      pagination: pageRaw is Map
          ? BookSourcePaginationConfig.fromJson(pageRaw.cast<String, dynamic>())
          : const BookSourcePaginationConfig(),
      vars: _parseExtractMap(json['vars']),
      fields: _parseExtractMap(json['fields']),
    );
  }

  final String mode; // 'json' | 'html' | 'xml'
  final String itemsPath;
  final String itemsSelector;
  final BookSourcePaginationConfig pagination;
  final Map<String, BookSourceExtractRule> vars;
  final Map<String, BookSourceExtractRule> fields;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'mode': mode,
    if (itemsPath.isNotEmpty) 'items_path': itemsPath,
    if (itemsSelector.isNotEmpty) 'items_selector': itemsSelector,
    if (pagination.isConfigured) 'pagination': pagination.toJson(),
    if (vars.isNotEmpty)
      'vars': <String, dynamic>{
        for (final e in vars.entries) e.key: e.value.toJson(),
      },
    'fields': <String, dynamic>{
      for (final e in fields.entries) e.key: e.value.toJson(),
    },
  };
}

/// Complete declarative search configuration.
class BookSourceSearchConfig {
  const BookSourceSearchConfig({
    required this.request,
    this.filters = const BookSourceFiltersConfig(),
    required this.response,
  });

  factory BookSourceSearchConfig.fromJson(Map<String, dynamic> json) {
    final reqRaw = json['request'];
    final filtersRaw = json['filters'];
    final respRaw = json['response'];
    return BookSourceSearchConfig(
      request: reqRaw is Map
          ? BookSourceSearchRequestConfig.fromJson(
              reqRaw.cast<String, dynamic>(),
            )
          : const BookSourceSearchRequestConfig(),
      filters: filtersRaw is Map
          ? BookSourceFiltersConfig.fromJson(
              filtersRaw.cast<String, dynamic>(),
            )
          : const BookSourceFiltersConfig(),
      response: respRaw is Map
          ? BookSourceSearchResponseConfig.fromJson(
              respRaw.cast<String, dynamic>(),
            )
          : const BookSourceSearchResponseConfig(),
    );
  }

  final BookSourceSearchRequestConfig request;
  final BookSourceFiltersConfig filters;
  final BookSourceSearchResponseConfig response;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'request': request.toJson(),
    if (filters.hasAnyFilter) 'filters': filters.toJson(),
    'response': response.toJson(),
  };
}

/// Optional book detail enrichment rule.
class BookSourceDetailConfig {
  const BookSourceDetailConfig({
    this.method = 'GET',
    this.path = '',
    this.url = '',
    this.headers = const <String, String>{},
    this.responseMode = 'html',
    this.rootPath = '',
    this.vars = const <String, BookSourceExtractRule>{},
    this.fields = const <String, BookSourceExtractRule>{},
  });

  factory BookSourceDetailConfig.fromJson(Map<String, dynamic> json) {
    return BookSourceDetailConfig(
      method: (json['method'] as String? ?? 'GET').trim().toUpperCase(),
      path: (json['path'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      headers: _parseStringMap(json['headers']),
      responseMode: (json['response_mode'] as String? ?? 'html')
          .trim()
          .toLowerCase(),
      rootPath: (json['root_path'] as String? ?? '').trim(),
      vars: _parseExtractMap(json['vars']),
      fields: _parseExtractMap(json['fields']),
    );
  }

  final String method;
  final String path;
  final String url;
  final Map<String, String> headers;
  final String responseMode;
  final String rootPath;
  final Map<String, BookSourceExtractRule> vars;
  final Map<String, BookSourceExtractRule> fields;

  bool get isConfigured => path.isNotEmpty || url.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (method != 'GET') 'method': method,
    if (path.isNotEmpty) 'path': path,
    if (url.isNotEmpty) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
    if (responseMode != 'html') 'response_mode': responseMode,
    if (rootPath.isNotEmpty) 'root_path': rootPath,
    if (vars.isNotEmpty)
      'vars': <String, dynamic>{
        for (final e in vars.entries) e.key: e.value.toJson(),
      },
    if (fields.isNotEmpty)
      'fields': <String, dynamic>{
        for (final e in fields.entries) e.key: e.value.toJson(),
      },
  };
}

/// Final streaming file download request configuration.
class BookSourceFileRequestConfig {
  const BookSourceFileRequestConfig({
    this.url = '',
    this.path = '',
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.sameOriginCredentials = true,
    this.retries = 3,
    this.stallTimeoutSeconds = kDefaultBookSourceStallTimeoutSeconds,
    this.maxBytes = kDefaultBookSourceMaxDownloadBytes,
  });

  factory BookSourceFileRequestConfig.fromJson(Map<String, dynamic> json) {
    return BookSourceFileRequestConfig(
      url: (json['url'] as String? ?? '').trim(),
      path: (json['path'] as String? ?? '').trim(),
      method: (json['method'] as String? ?? 'GET').trim().toUpperCase(),
      headers: _parseStringMap(json['headers']),
      sameOriginCredentials: json['same_origin_credentials'] as bool? ?? true,
      retries: (json['retries'] as num?)?.toInt() ?? 3,
      stallTimeoutSeconds:
          (json['stall_timeout_seconds'] as num?)?.toInt() ??
          kDefaultBookSourceStallTimeoutSeconds,
      maxBytes:
          (json['max_bytes'] as num?)?.toInt() ??
          kDefaultBookSourceMaxDownloadBytes,
    );
  }

  final String url;
  final String path;
  final String method;
  final Map<String, String> headers;
  final bool sameOriginCredentials;
  final int retries;
  final int stallTimeoutSeconds;
  final int maxBytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (url.isNotEmpty) 'url': url,
    if (path.isNotEmpty) 'path': path,
    if (method != 'GET') 'method': method,
    if (headers.isNotEmpty) 'headers': headers,
    if (!sameOriginCredentials)
      'same_origin_credentials': sameOriginCredentials,
    if (retries != 3) 'retries': retries,
    if (stallTimeoutSeconds != kDefaultBookSourceStallTimeoutSeconds)
      'stall_timeout_seconds': stallTimeoutSeconds,
    if (maxBytes != kDefaultBookSourceMaxDownloadBytes) 'max_bytes': maxBytes,
  };
}

/// Multi-step download pipeline configuration.
class BookSourceDownloadConfig {
  const BookSourceDownloadConfig({
    this.refSeparator = ':',
    this.steps = const <BookSourceStepConfig>[],
    this.fileRequest = const BookSourceFileRequestConfig(),
  });

  factory BookSourceDownloadConfig.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as List<dynamic>? ?? const <dynamic>[];
    final fileRaw = json['file_request'];
    return BookSourceDownloadConfig(
      refSeparator: json['ref_separator'] as String? ?? ':',
      steps: List<BookSourceStepConfig>.unmodifiable(
        rawSteps.whereType<Map>().map(
          (e) => BookSourceStepConfig.fromJson(e.cast<String, dynamic>()),
        ),
      ),
      fileRequest: fileRaw is Map
          ? BookSourceFileRequestConfig.fromJson(
              fileRaw.cast<String, dynamic>(),
            )
          : const BookSourceFileRequestConfig(),
    );
  }

  final String refSeparator;
  final List<BookSourceStepConfig> steps;
  final BookSourceFileRequestConfig fileRequest;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (refSeparator != ':') 'ref_separator': refSeparator,
    if (steps.isNotEmpty)
      'steps': steps.map((s) => s.toJson()).toList(growable: false),
    'file_request': fileRequest.toJson(),
  };
}

/// OPDS-specific options.
class BookSourceOpdsConfig {
  const BookSourceOpdsConfig({
    this.searchUrl = '',
    this.preferFormats = const <String>['epub', 'txt'],
  });

  factory BookSourceOpdsConfig.fromJson(Map<String, dynamic> json) {
    final formats = _parseStringList(
      json['prefer_formats'],
    ).map((e) => e.toLowerCase()).toList(growable: false);
    return BookSourceOpdsConfig(
      searchUrl: (json['search_url'] as String? ?? '').trim(),
      preferFormats: formats.isEmpty
          ? const <String>['epub', 'txt']
          : List<String>.unmodifiable(formats),
    );
  }

  final String searchUrl;
  final List<String> preferFormats;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (searchUrl.isNotEmpty) 'search_url': searchUrl,
    'prefer_formats': preferFormats,
  };
}

/// ebook-api specific options.
class BookSourceEbookApiConfig {
  const BookSourceEbookApiConfig({this.remoteProvider = 'zlib'});

  factory BookSourceEbookApiConfig.fromJson(Map<String, dynamic> json) {
    final provider = (json['remote_provider'] as String? ?? 'zlib').trim();
    return BookSourceEbookApiConfig(
      remoteProvider: provider.isEmpty ? 'zlib' : provider,
    );
  }

  final String remoteProvider;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'remote_provider': remoteProvider,
  };
}

/// Pure, shareable definition of a single book source (zero secrets, zero user overlays).
class BookSourceDefinition {
  const BookSourceDefinition({
    this.schemaVersion = kBookSourceSchemaVersion,
    required this.id,
    required this.name,
    this.description = '',
    required this.driver,
    this.defaultEnabled = true,
    this.domains = const <String>[],
    this.headers = const <String, String>{},
    this.imageHeaders = const <String, String>{},
    this.minRequestIntervalMs = 0,
    this.maxMirrorAttempts = 2,
    this.supportedFormats = const <String>['epub', 'txt'],
    this.probe,
    this.auth,
    this.errors,
    this.search,
    this.detail,
    this.download,
    this.opds,
    this.ebookApi,
  });

  factory BookSourceDefinition.fromJson(
    Map<String, dynamic> json, {
    int? fallbackSchemaVersion,
  }) {
    final rawDomains = _parseStringList(json['domains']);
    final baseUrl = (json['base_url'] as String? ?? '').trim();
    final mergedDomains = <String>[];
    for (final raw in <String>[...rawDomains, if (baseUrl.isNotEmpty) baseUrl]) {
      final norm = normalizeOriginUrl(raw);
      if (norm.isNotEmpty && !mergedDomains.contains(norm)) {
        mergedDomains.add(norm);
      }
    }

    final driverParsed =
        BookSourceDriverType.tryParse(json['driver'] as String?) ??
        BookSourceDriverType.rule;

    final formats = _parseStringList(
      json['supported_formats'],
    ).map((e) => e.toLowerCase()).toList(growable: false);

    final probeRaw = json['probe'];
    final authRaw = json['auth'];
    final errRaw = json['errors'];
    final searchRaw = json['search'];
    final detailRaw = json['detail'];
    final dlRaw = json['download'];
    final opdsRaw = json['opds'];
    final ebookApiRaw = json['ebook_api'];

    return BookSourceDefinition(
      schemaVersion:
          (json['schema_version'] as num?)?.toInt() ??
          fallbackSchemaVersion ??
          kBookSourceSchemaVersion,
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      description: (json['description'] as String? ?? '').trim(),
      driver: driverParsed,
      defaultEnabled: json['enabled'] as bool? ?? true,
      domains: List<String>.unmodifiable(mergedDomains),
      headers: _parseStringMap(json['headers']),
      imageHeaders: _parseStringMap(json['image_headers']),
      minRequestIntervalMs:
          (json['min_request_interval_ms'] as num?)?.toInt() ?? 0,
      maxMirrorAttempts: (json['max_mirror_attempts'] as num?)?.toInt() ?? 2,
      supportedFormats: formats.isEmpty
          ? const <String>['epub', 'txt']
          : List<String>.unmodifiable(formats),
      probe: probeRaw is Map
          ? BookSourceProbeConfig.fromJson(probeRaw.cast<String, dynamic>())
          : null,
      auth: authRaw is Map
          ? BookSourceAuthConfig.fromJson(authRaw.cast<String, dynamic>())
          : null,
      errors: errRaw is Map
          ? BookSourceErrorConfig.fromJson(errRaw.cast<String, dynamic>())
          : null,
      search: searchRaw is Map
          ? BookSourceSearchConfig.fromJson(searchRaw.cast<String, dynamic>())
          : null,
      detail: detailRaw is Map
          ? BookSourceDetailConfig.fromJson(detailRaw.cast<String, dynamic>())
          : null,
      download: dlRaw is Map
          ? BookSourceDownloadConfig.fromJson(dlRaw.cast<String, dynamic>())
          : null,
      opds: opdsRaw is Map
          ? BookSourceOpdsConfig.fromJson(opdsRaw.cast<String, dynamic>())
          : null,
      ebookApi: ebookApiRaw is Map
          ? BookSourceEbookApiConfig.fromJson(
              ebookApiRaw.cast<String, dynamic>(),
            )
          : null,
    );
  }

  final int schemaVersion;
  final String id;
  final String name;
  final String description;
  final BookSourceDriverType driver;
  final bool defaultEnabled;
  final List<String> domains;
  final Map<String, String> headers;
  final Map<String, String> imageHeaders;
  final int minRequestIntervalMs;
  final int maxMirrorAttempts;
  final List<String> supportedFormats;
  final BookSourceProbeConfig? probe;
  final BookSourceAuthConfig? auth;
  final BookSourceErrorConfig? errors;
  final BookSourceSearchConfig? search;
  final BookSourceDetailConfig? detail;
  final BookSourceDownloadConfig? download;
  final BookSourceOpdsConfig? opds;
  final BookSourceEbookApiConfig? ebookApi;

  Map<String, String> get effectiveImageHeaders {
    final out = <String, String>{...imageHeaders};
    final hasUa = out.keys.any((k) => k.toLowerCase() == 'user-agent');
    if (!hasUa) {
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == 'user-agent' &&
            entry.value.trim().isNotEmpty) {
          out['User-Agent'] = entry.value;
          break;
        }
      }
    }
    return Map<String, String>.unmodifiable(out);
  }

  /// Whitelisted JSON serialization of the pure rule definition.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema_version': schemaVersion,
    'id': id,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    'driver': driver.wireName,
    'enabled': defaultEnabled,
    'domains': domains,
    if (headers.isNotEmpty) 'headers': headers,
    if (imageHeaders.isNotEmpty) 'image_headers': imageHeaders,
    if (minRequestIntervalMs > 0)
      'min_request_interval_ms': minRequestIntervalMs,
    if (maxMirrorAttempts != 2) 'max_mirror_attempts': maxMirrorAttempts,
    if (supportedFormats.isNotEmpty) 'supported_formats': supportedFormats,
    if (probe != null) 'probe': probe!.toJson(),
    if (auth != null) 'auth': auth!.toJson(),
    if (errors != null) 'errors': errors!.toJson(),
    if (search != null) 'search': search!.toJson(),
    if (detail != null && detail!.isConfigured) 'detail': detail!.toJson(),
    if (download != null) 'download': download!.toJson(),
    if (opds != null) 'opds': opds!.toJson(),
    if (ebookApi != null) 'ebook_api': ebookApi!.toJson(),
  };

  /// Sanitized JSON suitable for sharing; physically excludes overlays & credentials.
  Map<String, dynamic> toExportJson() => toJson();

  String toPrettyExportJson() =>
      const JsonEncoder.withIndent('  ').convert(toExportJson());
}

/// Top-level bundle document (e.g. bundled rules or remote subscription JSON).
class BookSourceBundle {
  const BookSourceBundle({
    this.schemaVersion = kBookSourceSchemaVersion,
    this.configVersion = '',
    this.configTtlHours = kDefaultBookSourceConfigTtlHours,
    this.name = '',
    this.sources = const <BookSourceDefinition>[],
  });

  factory BookSourceBundle.fromJson(Map<String, dynamic> json) {
    final schema = (json['schema_version'] as num?)?.toInt() ?? 0;
    final rawSources = json['sources'] as List<dynamic>? ?? const <dynamic>[];
    return BookSourceBundle(
      schemaVersion: schema,
      configVersion: (json['config_version'] as String? ?? '').trim(),
      configTtlHours:
          (json['config_ttl_hours'] as num?)?.toInt() ??
          kDefaultBookSourceConfigTtlHours,
      name: (json['name'] as String? ?? '').trim(),
      sources: List<BookSourceDefinition>.unmodifiable(
        rawSources.whereType<Map>().map(
          (e) => BookSourceDefinition.fromJson(
            e.cast<String, dynamic>(),
            fallbackSchemaVersion: schema > 0 ? schema : null,
          ),
        ),
      ),
    );
  }

  final int schemaVersion;
  final String configVersion;
  final int configTtlHours;
  final String name;
  final List<BookSourceDefinition> sources;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema_version': schemaVersion,
    if (configVersion.isNotEmpty) 'config_version': configVersion,
    'config_ttl_hours': configTtlHours,
    if (name.isNotEmpty) 'name': name,
    'sources': sources.map((s) => s.toJson()).toList(growable: false),
  };
}

/// Parses an imported JSON string accepting either a bundle (`sources: []`) or a single source object.
BookSourceBundle parseBookSourceInput(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! Map) {
    throw const FormatException('书源配置 JSON 根节点必须为对象');
  }
  final map = decoded.cast<String, dynamic>();
  if (map['sources'] is List) {
    return BookSourceBundle.fromJson(map);
  }
  final schema =
      (map['schema_version'] as num?)?.toInt() ?? kBookSourceSchemaVersion;
  final single = BookSourceDefinition.fromJson(
    map,
    fallbackSchemaVersion: schema,
  );
  return BookSourceBundle(
    schemaVersion: schema,
    name: single.name,
    sources: <BookSourceDefinition>[single],
  );
}

// ---------------------------------------------------------------------------
// Schema Validation
// ---------------------------------------------------------------------------

/// Validates a single [BookSourceDefinition]. Returns null when valid.
String? validateBookSourceDefinition(
  BookSourceDefinition source, {
  String? rawDriver,
}) {
  if (source.schemaVersion != kBookSourceSchemaVersion) {
    return '不支持的书源 schema_version: ${source.schemaVersion}';
  }
  if (source.id.isEmpty) {
    return '书源缺少必填字段 id';
  }
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(source.id)) {
    return '书源 id "${source.id}" 仅允许字母、数字、下划线或连字符（最长 64 字符）';
  }
  if (source.name.isEmpty) {
    return '书源 ${source.id} 缺少 name';
  }
  if (rawDriver != null && BookSourceDriverType.tryParse(rawDriver) == null) {
    return '书源 ${source.id} 的 driver "$rawDriver" 不受支持（仅支持 rule / opds / ebook_api）';
  }
  if (source.domains.isEmpty) {
    return '书源 ${source.id} 至少需要 1 个合法的 http(s) 域名 (domains / base_url)';
  }
  for (final domain in source.domains) {
    if (normalizeOriginUrl(domain).isEmpty) {
      return '书源 ${source.id} 包含非法域名: $domain';
    }
  }

  if (source.driver == BookSourceDriverType.rule) {
    final search = source.search;
    if (search == null) {
      return 'rule 书源 ${source.id} 缺少 search 配置';
    }
    if (search.request.path.isEmpty && search.request.url.isEmpty) {
      return 'rule 书源 ${source.id} 的 search.request 缺少 path 或 url';
    }
    final mode = search.response.mode;
    if (mode != 'json' && mode != 'html' && mode != 'xml') {
      return 'rule 书源 ${source.id} 的 search.response.mode 仅支持 json / html / xml';
    }
    if (mode == 'html' && search.response.itemsSelector.isEmpty) {
      return 'HTML 书源 ${source.id} 缺少 search.response.items_selector';
    }
    final fields = search.response.fields;
    if (!fields.containsKey('title') || !fields['title']!.isConfigured) {
      return 'rule 书源 ${source.id} 的 search.response.fields 缺少 title';
    }
    if (!fields.containsKey('ref') || !fields['ref']!.isConfigured) {
      return 'rule 书源 ${source.id} 的 search.response.fields 缺少 ref';
    }
    final dl = source.download;
    if (dl == null ||
        (dl.fileRequest.url.isEmpty && dl.fileRequest.path.isEmpty)) {
      return 'rule 书源 ${source.id} 缺少 download.file_request (url 或 path)';
    }
  }

  return null;
}

/// Validates a parsed bundle (and validates the raw JSON if supplied to catch unknown driver strings).
String? validateBookSourceBundle(
  BookSourceBundle bundle, {
  Map<String, dynamic>? rawJson,
}) {
  if (bundle.schemaVersion != kBookSourceSchemaVersion) {
    return '不支持的书源 schema_version: ${bundle.schemaVersion}';
  }
  if (bundle.sources.isEmpty) {
    return '书源配置中至少需要包含 1 条书源';
  }
  final rawSources = rawJson?['sources'];
  final seenIds = <String>{};
  for (var i = 0; i < bundle.sources.length; i++) {
    final src = bundle.sources[i];
    if (!seenIds.add(src.id)) {
      return '存在重复的书源 id: ${src.id}';
    }
    String? rawDriver;
    if (rawSources is List && i < rawSources.length && rawSources[i] is Map) {
      rawDriver = (rawSources[i] as Map)['driver']?.toString();
    } else if (rawJson != null && rawJson['sources'] == null) {
      rawDriver = rawJson['driver']?.toString();
    }
    final err = validateBookSourceDefinition(src, rawDriver: rawDriver);
    if (err != null) return err;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 3-Tier Isolation Models (Subscription Registry / User Overlays / Credentials)
// ---------------------------------------------------------------------------

/// Subscription metadata plus its cached pure rule definitions.
class BookSourceSubscription {
  const BookSourceSubscription({
    required this.id,
    required this.name,
    required this.url,
    this.configVersion = '',
    this.configTtlHours = kDefaultBookSourceConfigTtlHours,
    required this.fetchedAt,
    this.sources = const <BookSourceDefinition>[],
  });

  factory BookSourceSubscription.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'] as List<dynamic>? ?? const <dynamic>[];
    final ms = (json['fetched_at_ms'] as num?)?.toInt() ?? 0;
    return BookSourceSubscription(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      configVersion: (json['config_version'] as String? ?? '').trim(),
      configTtlHours:
          (json['config_ttl_hours'] as num?)?.toInt() ??
          kDefaultBookSourceConfigTtlHours,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      sources: List<BookSourceDefinition>.unmodifiable(
        rawSources.whereType<Map>().map(
          (e) => BookSourceDefinition.fromJson(e.cast<String, dynamic>()),
        ),
      ),
    );
  }

  final String id;
  final String name;
  final String url;
  final String configVersion;
  final int configTtlHours;
  final DateTime fetchedAt;
  final List<BookSourceDefinition> sources;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'url': url,
    'config_version': configVersion,
    'config_ttl_hours': configTtlHours,
    'fetched_at_ms': fetchedAt.toUtc().millisecondsSinceEpoch,
    'sources': sources.map((s) => s.toJson()).toList(growable: false),
  };
}

/// Locally stored definitions registry (subscriptions + standalone imported definitions).
class BookSourceRegistryData {
  const BookSourceRegistryData({
    this.subscriptions = const <BookSourceSubscription>[],
    this.localSources = const <BookSourceDefinition>[],
    this.legacyMigrated = false,
  });

  factory BookSourceRegistryData.fromJson(Map<String, dynamic> json) {
    final rawSubs =
        json['subscriptions'] as List<dynamic>? ?? const <dynamic>[];
    final rawLocals =
        json['local_sources'] as List<dynamic>? ?? const <dynamic>[];
    return BookSourceRegistryData(
      subscriptions: List<BookSourceSubscription>.unmodifiable(
        rawSubs.whereType<Map>().map(
          (e) => BookSourceSubscription.fromJson(e.cast<String, dynamic>()),
        ),
      ),
      localSources: List<BookSourceDefinition>.unmodifiable(
        rawLocals.whereType<Map>().map(
          (e) => BookSourceDefinition.fromJson(e.cast<String, dynamic>()),
        ),
      ),
      legacyMigrated: json['legacy_migrated'] as bool? ?? false,
    );
  }

  final List<BookSourceSubscription> subscriptions;
  final List<BookSourceDefinition> localSources;
  final bool legacyMigrated;

  BookSourceRegistryData copyWith({
    List<BookSourceSubscription>? subscriptions,
    List<BookSourceDefinition>? localSources,
    bool? legacyMigrated,
  }) {
    return BookSourceRegistryData(
      subscriptions: subscriptions ?? this.subscriptions,
      localSources: localSources ?? this.localSources,
      legacyMigrated: legacyMigrated ?? this.legacyMigrated,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'subscriptions': subscriptions
        .map((s) => s.toJson())
        .toList(growable: false),
    'local_sources': localSources
        .map((s) => s.toJson())
        .toList(growable: false),
    'legacy_migrated': legacyMigrated,
  };
}

/// User-controlled per-source overrides stored separately from rule definitions.
class BookSourceUserOverlay {
  const BookSourceUserOverlay({
    required this.sourceId,
    this.enabled,
    this.preferredDomain = '',
    this.customDomain = '',
    this.proxyPrefix = '',
    this.sortOrder,
  });

  factory BookSourceUserOverlay.fromJson(Map<String, dynamic> json) {
    return BookSourceUserOverlay(
      sourceId: (json['source_id'] as String? ?? '').trim(),
      enabled: json['enabled'] as bool?,
      preferredDomain: (json['preferred_domain'] as String? ?? '').trim(),
      customDomain: (json['custom_domain'] as String? ?? '').trim(),
      proxyPrefix: (json['proxy_prefix'] as String? ?? '').trim(),
      sortOrder: (json['sort_order'] as num?)?.toInt(),
    );
  }

  final String sourceId;
  final bool? enabled;
  final String preferredDomain;
  final String customDomain;
  final String proxyPrefix;
  final int? sortOrder;

  BookSourceUserOverlay copyWith({
    bool? enabled,
    bool clearEnabled = false,
    String? preferredDomain,
    String? customDomain,
    String? proxyPrefix,
    int? sortOrder,
  }) {
    return BookSourceUserOverlay(
      sourceId: sourceId,
      enabled: clearEnabled ? null : (enabled ?? this.enabled),
      preferredDomain: preferredDomain ?? this.preferredDomain,
      customDomain: customDomain ?? this.customDomain,
      proxyPrefix: proxyPrefix ?? this.proxyPrefix,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'source_id': sourceId,
    if (enabled != null) 'enabled': enabled,
    if (preferredDomain.isNotEmpty) 'preferred_domain': preferredDomain,
    if (customDomain.isNotEmpty) 'custom_domain': customDomain,
    if (proxyPrefix.isNotEmpty) 'proxy_prefix': proxyPrefix,
    if (sortOrder != null) 'sort_order': sortOrder,
  };
}

/// Persisted user overlay collection + active search source id.
class BookSourceUserState {
  const BookSourceUserState({
    this.activeSourceId = '',
    this.overlays = const <String, BookSourceUserOverlay>{},
  });

  factory BookSourceUserState.fromJson(Map<String, dynamic> json) {
    final rawOverlays = json['overlays'];
    final map = <String, BookSourceUserOverlay>{};
    if (rawOverlays is Map) {
      for (final entry in rawOverlays.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty || entry.value is! Map) continue;
        final overlay = BookSourceUserOverlay.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        );
        map[key] = overlay.sourceId.isEmpty
            ? BookSourceUserOverlay(
                sourceId: key,
                enabled: overlay.enabled,
                preferredDomain: overlay.preferredDomain,
                customDomain: overlay.customDomain,
                proxyPrefix: overlay.proxyPrefix,
                sortOrder: overlay.sortOrder,
              )
            : overlay;
      }
    }
    return BookSourceUserState(
      activeSourceId: (json['active_source_id'] as String? ?? '').trim(),
      overlays: Map<String, BookSourceUserOverlay>.unmodifiable(map),
    );
  }

  final String activeSourceId;
  final Map<String, BookSourceUserOverlay> overlays;

  BookSourceUserState copyWith({
    String? activeSourceId,
    Map<String, BookSourceUserOverlay>? overlays,
  }) {
    return BookSourceUserState(
      activeSourceId: activeSourceId ?? this.activeSourceId,
      overlays: overlays ?? this.overlays,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'active_source_id': activeSourceId,
    'overlays': <String, dynamic>{
      for (final entry in overlays.entries) entry.key: entry.value.toJson(),
    },
  };
}

/// Securely persisted credentials for a single book source (Tier 3).
class BookSourceCredentials {
  const BookSourceCredentials({
    required this.sourceId,
    this.modeId = '',
    this.values = const <String, String>{},
    this.account,
    this.savedAt,
  });

  factory BookSourceCredentials.fromJson(Map<String, dynamic> json) {
    final accRaw = json['account'];
    return BookSourceCredentials(
      sourceId: (json['source_id'] as String? ?? '').trim(),
      modeId: (json['mode_id'] as String? ?? '').trim(),
      values: _parseStringMap(json['values']),
      account: accRaw is Map
          ? BookSourceAccountStatus.fromJson(accRaw.cast<String, dynamic>())
          : null,
      savedAt: DateTime.tryParse(json['saved_at'] as String? ?? '')?.toUtc(),
    );
  }

  final String sourceId;
  final String modeId;
  final Map<String, String> values;
  final BookSourceAccountStatus? account;
  final DateTime? savedAt;

  bool get hasValues => values.isNotEmpty;

  BookSourceCredentials copyWith({
    String? modeId,
    Map<String, String>? values,
    BookSourceAccountStatus? account,
    bool clearAccount = false,
    DateTime? savedAt,
  }) {
    return BookSourceCredentials(
      sourceId: sourceId,
      modeId: modeId ?? this.modeId,
      values: values ?? this.values,
      account: clearAccount ? null : (account ?? this.account),
      savedAt: savedAt ?? this.savedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'source_id': sourceId,
    if (modeId.isNotEmpty) 'mode_id': modeId,
    'values': values,
    if (account != null) 'account': account!.toJson(),
    'saved_at': (savedAt ?? DateTime.now().toUtc()).toIso8601String(),
  };
}

/// Runtime merged view combining definition + origin + user overlay + credentials.
class ResolvedBookSource {
  const ResolvedBookSource({
    required this.definition,
    required this.origin,
    this.subscriptionId = '',
    this.subscriptionName = '',
    this.overlay,
    this.credentials,
  });

  final BookSourceDefinition definition;
  final BookSourceOrigin origin;
  final String subscriptionId;
  final String subscriptionName;
  final BookSourceUserOverlay? overlay;
  final BookSourceCredentials? credentials;

  String get id => definition.id;
  String get name => definition.name;
  String get description => definition.description;
  BookSourceDriverType get driver => definition.driver;
  bool get isBundled => origin == BookSourceOrigin.bundled;
  bool get isEnabled => overlay?.enabled ?? definition.defaultEnabled;

  String get customDomain => normalizeOriginUrl(overlay?.customDomain ?? '');
  String get preferredDomain =>
      normalizeOriginUrl(overlay?.preferredDomain ?? '');
  String get proxyPrefix => (overlay?.proxyPrefix ?? '').trim();

  /// Candidate origins in user-configured priority order.
  List<String> get effectiveDomains {
    final out = <String>[];
    void add(String raw) {
      final norm = normalizeOriginUrl(raw);
      if (norm.isNotEmpty && !out.contains(norm)) out.add(norm);
    }

    if (customDomain.isNotEmpty) add(customDomain);
    if (preferredDomain.isNotEmpty) add(preferredDomain);
    for (final d in definition.domains) {
      add(d);
    }
    return List<String>.unmodifiable(out);
  }

  BookSourceAccountStatus? get account => credentials?.account;

  bool get hasCredentials => credentials?.hasValues ?? false;

  bool get requiresAuthForSearch =>
      definition.auth?.requiresAuthForSearch ?? false;

  bool get requiresAuthForDownload =>
      definition.auth?.requiresAuthForDownload ?? false;

  bool get hasAuthModes =>
      driver == BookSourceDriverType.ebookApi ||
      (definition.auth?.modes.isNotEmpty ?? false);

  bool get isReadyForSearch => !requiresAuthForSearch || hasCredentials;

  bool get isReadyForDownload => !requiresAuthForDownload || hasCredentials;

  BookSourceFiltersConfig? get filterCapabilities {
    if (driver == BookSourceDriverType.ebookApi) {
      // Standard ebook-api supports all 5 search filters.
      return const BookSourceFiltersConfig(
        extensions: BookSourceFilterRule(param: 'ext', mode: 'join'),
        languages: BookSourceFilterRule(param: 'lang', mode: 'join'),
        yearFrom: BookSourceFilterRule(param: 'year_from'),
        yearTo: BookSourceFilterRule(param: 'year_to'),
        order: BookSourceFilterRule(
          param: 'order',
          options: <BookSourceFilterOption>[
            BookSourceFilterOption(value: '', label: '相关度'),
            BookSourceFilterOption(value: 'popular', label: '最热'),
            BookSourceFilterOption(value: 'date', label: '最新'),
          ],
        ),
      );
    }
    return definition.search?.filters;
  }

  String get statusSummary {
    if (driver == BookSourceDriverType.ebookApi) {
      final acc = account;
      if (acc != null && acc.configured) {
        if (acc.needsLogin) return '需重新登录';
        if (acc.quotaKnown) return '账号正常 · 剩余 ${acc.dailyRemaining}/${acc.dailyLimit}';
        return '账号正常';
      }
      return '服务已配置';
    }
    if (!hasAuthModes && !requiresAuthForSearch && !requiresAuthForDownload) {
      return '免登录就绪';
    }
    final acc = account;
    if (hasCredentials) {
      if (acc != null && acc.needsLogin) return '需重新登录';
      if (acc != null && acc.quotaKnown) {
        return '已登录 · 剩余 ${acc.dailyRemaining}/${acc.dailyLimit}';
      }
      return '已配置账号';
    }
    if (requiresAuthForSearch) return '搜书与下载需登录';
    if (requiresAuthForDownload) return '搜书免登 · 下载需账号';
    return '免登录就绪（支持可选登录）';
  }
}
