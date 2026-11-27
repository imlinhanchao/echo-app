import 'package:dio/dio.dart';

import '../api/ebook_api_client.dart';
import '../api/models.dart';
import 'book_source_driver.dart';
import 'book_source_models.dart';
import 'mirror_pool_manager.dart';

/// Book source driver bridging to a self-hosted `ebook-api` HTTP service.
class EbookApiBookSourceDriver implements BookSourceDriver {
  EbookApiBookSourceDriver({
    EbookApiClient Function({required String baseUrl, String apiKey})?
    clientFactory,
  }) : _clientFactory =
           clientFactory ??
           (({required String baseUrl, String apiKey = ''}) =>
               EbookApiClient(baseUrl: baseUrl, apiKey: apiKey));

  final EbookApiClient Function({required String baseUrl, String apiKey})
  _clientFactory;

  EbookApiClient _clientFor(ResolvedBookSource source) {
    final domains = source.effectiveDomains;
    if (domains.isEmpty) {
      throw const BookSourceException(
        code: 'EBOOK_API_NOT_CONFIGURED',
        message: '尚未配置 ebook-api 服务地址',
      );
    }
    final rawBase = domains.first;
    final baseUrl = source.proxyPrefix.isNotEmpty
        ? MirrorPoolManager.rewriteWithProxy(rawBase, source.proxyPrefix)
        : rawBase;
    final apiKey = source.credentials?.values['api_key'] ?? '';
    return _clientFactory(baseUrl: baseUrl, apiKey: apiKey);
  }

  String _remoteProvider(ResolvedBookSource source) {
    final p = (source.definition.ebookApi?.remoteProvider ?? 'zlib').trim();
    return p.isEmpty ? 'zlib' : p;
  }

  String? _providerToken(ResolvedBookSource source) {
    final t = (source.credentials?.values['credential_token'] ?? '').trim();
    return t.isEmpty ? null : t;
  }

  @override
  Future<BookSourceSearchPage> search(
    ResolvedBookSource source,
    BookSourceSearchRequest request,
  ) async {
    final client = _clientFor(source);
    try {
      final res = await client.search(
        query: request.query,
        provider: _remoteProvider(source),
        page: request.page,
        limit: request.limit,
        extensions: request.extensions,
        languages: request.languages,
        yearFrom: request.yearFrom,
        yearTo: request.yearTo,
        order: request.order,
        credentialToken: _providerToken(source),
      );
      return BookSourceSearchPage(
        books: res.books
            .map(
              (b) => BookSourceSearchBook(
                provider: source.id,
                ref: b.ref,
                title: b.title,
                authors: b.authors,
                year: b.year,
                publisher: b.publisher,
                language: b.language,
                format: b.format,
                size: b.size,
                isbn: b.isbn,
                coverUrl: b.coverUrl,
                description: b.description,
                sourceUrl: b.sourceUrl,
              ),
            )
            .toList(growable: false),
        page: res.page,
        totalPages: res.totalPages,
        provider: source.id,
      );
    } on ApiException catch (e) {
      throw _mapApiException(e);
    }
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
    final client = _clientFor(source);
    try {
      final downloaded = await client.downloadBook(
        providerId: _remoteProvider(source),
        ref: ref,
        savePath: savePath,
        credentialToken: _providerToken(source),
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      return BookSourceDownloadedFile(
        savePath: downloaded.savePath,
        filename: downloaded.filename,
        format: downloaded.format,
        sizeBytes: downloaded.sizeBytes,
      );
    } on ApiException catch (e) {
      throw _mapApiException(e);
    }
  }

  @override
  Future<BookSourceCredentials> authenticate(
    ResolvedBookSource source, {
    required String modeId,
    required Map<String, String> inputs,
  }) async {
    final client = _clientFor(source);
    final remoteId = _remoteProvider(source);
    final existingApiKey =
        inputs['api_key']?.trim() ??
        source.credentials?.values['api_key'] ??
        '';
    final effectiveClient = existingApiKey.isNotEmpty
        ? _clientFactory(
            baseUrl: source.effectiveDomains.first,
            apiKey: existingApiKey,
          )
        : client;

    try {
      final ProviderSealResult sealed;
      if (modeId == 'cookies') {
        final creds = <String, String>{
          if ((inputs['domain'] ?? '').trim().isNotEmpty)
            'domain': inputs['domain']!.trim(),
          if ((inputs['remix_userid'] ?? '').trim().isNotEmpty)
            'remix_userid': inputs['remix_userid']!.trim(),
          if ((inputs['remix_userkey'] ?? '').trim().isNotEmpty)
            'remix_userkey': inputs['remix_userkey']!.trim(),
        };
        sealed = await effectiveClient.sealProvider(
          providerId: remoteId,
          credentials: creds,
          verify: true,
        );
      } else {
        sealed = await effectiveClient.loginProvider(
          providerId: remoteId,
          domain: inputs['domain'] ?? '',
          email: inputs['email'] ?? '',
          password: inputs['password'] ?? '',
        );
      }

      final nextValues = <String, String>{
        if (existingApiKey.isNotEmpty) 'api_key': existingApiKey,
        'credential_token': sealed.credentialToken,
      };
      final acc = sealed.account;
      return BookSourceCredentials(
        sourceId: source.id,
        modeId: modeId,
        values: Map<String, String>.unmodifiable(nextValues),
        account: acc != null
            ? BookSourceAccountStatus(
                configured: acc.configured,
                status: acc.status,
                email: acc.email,
                dailyUsed: acc.dailyUsed,
                dailyLimit: acc.dailyLimit,
                dailyRemaining: acc.dailyRemaining,
                quotaKnown: acc.quotaKnown,
                lastVerifiedAt: acc.lastVerifiedAt,
              )
            : BookSourceAccountStatus(
                configured: true,
                status: 'ok',
                lastVerifiedAt: DateTime.now().toUtc(),
              ),
        savedAt: DateTime.now().toUtc(),
      );
    } on ApiException catch (e) {
      throw _mapApiException(e);
    }
  }

  @override
  Future<BookSourceAccountStatus> verify(ResolvedBookSource source) async {
    final client = _clientFor(source);
    final token = _providerToken(source);
    try {
      final acc = await client.verifyProvider(
        _remoteProvider(source),
        credentialToken: token,
      );
      return BookSourceAccountStatus(
        configured: acc.configured,
        status: acc.status,
        email: acc.email,
        dailyUsed: acc.dailyUsed,
        dailyLimit: acc.dailyLimit,
        dailyRemaining: acc.dailyRemaining,
        quotaKnown: acc.quotaKnown,
        lastVerifiedAt: acc.lastVerifiedAt ?? DateTime.now().toUtc(),
      );
    } on ApiException catch (e) {
      throw _mapApiException(e);
    }
  }

  @override
  Future<List<MirrorProbeResult>> probeDomains(ResolvedBookSource source) async {
    final domains = source.effectiveDomains;
    if (domains.isEmpty) return const <MirrorProbeResult>[];
    final apiKey = source.credentials?.values['api_key'] ?? '';
    final results = <MirrorProbeResult>[];
    for (final domain in domains) {
      final sw = Stopwatch()..start();
      try {
        final baseUrl = source.proxyPrefix.isNotEmpty
            ? MirrorPoolManager.rewriteWithProxy(domain, source.proxyPrefix)
            : domain;
        final health = await _clientFactory(
          baseUrl: baseUrl,
          apiKey: apiKey,
        ).checkHealth();
        sw.stop();
        results.add(
          MirrorProbeResult(
            domain: domain,
            ok: health.ok,
            latencyMs: sw.elapsedMilliseconds,
            statusCode: health.ok ? 200 : 502,
          ),
        );
      } catch (e) {
        sw.stop();
        results.add(
          MirrorProbeResult(
            domain: domain,
            ok: false,
            latencyMs: sw.elapsedMilliseconds,
            error: e.toString(),
          ),
        );
      }
    }
    return results;
  }

  static BookSourceException _mapApiException(ApiException e) =>
      BookSourceException(
        code: e.code ?? 'PROVIDER_ERROR',
        message: e.message,
        statusCode: e.statusCode,
      );
}
