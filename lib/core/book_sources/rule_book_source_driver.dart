import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'book_source_driver.dart';
import 'book_source_models.dart';
import 'mirror_pool_manager.dart';
import 'rule_extractor.dart';

/// Declarative rule-based book source driver supporting JSON API, HTML scraping,
/// XML parsing, multi-mirror failover, dynamic auth/CSRF/cookies, cursor & page
/// pagination, async polling, and streaming downloads.
class RuleBookSourceDriver implements BookSourceDriver {
  RuleBookSourceDriver({
    required MirrorPoolManager mirrorPool,
    RuleExtractor? extractor,
    Future<void> Function(Duration)? delay,
    Duration downloadRetryBaseDelay = const Duration(milliseconds: 500),
  }) : _mirrorPool = mirrorPool,
       _extractor = extractor ?? RuleExtractor(),
       _delay = delay ?? Future<void>.delayed,
       _downloadRetryBaseDelay = downloadRetryBaseDelay;

  final MirrorPoolManager _mirrorPool;
  final RuleExtractor _extractor;
  final Future<void> Function(Duration) _delay;
  final Duration _downloadRetryBaseDelay;

  /// Cursor cache keyed by `sourceId|query|filterSignature` -> `{page: cursor}`.
  final Map<String, Map<int, String>> _cursorCache =
      <String, Map<int, String>>{};

  @override
  Future<BookSourceSearchPage> search(
    ResolvedBookSource source,
    BookSourceSearchRequest request,
  ) async {
    final searchCfg = source.definition.search;
    if (searchCfg == null) {
      throw const BookSourceException(
        code: 'UNSUPPORTED',
        message: '该书源未配置搜索规则',
      );
    }
    if (request.query.trim().isEmpty) {
      throw const BookSourceException(
        code: 'INVALID_INPUT',
        message: '请输入搜索关键词',
      );
    }
    if (source.requiresAuthForSearch && !source.hasCredentials) {
      throw BookSourceException(
        code: 'PROVIDER_NOT_CONFIGURED',
        message: '书源「${source.name}」需要先配置账号凭据才能搜索',
      );
    }

    final page = request.page < 1 ? 1 : request.page;
    final pageSize = request.limit > 0
        ? request.limit
        : searchCfg.request.pageSize;
    final offset = (page - 1) * pageSize;

    final pagination = searchCfg.response.pagination;
    final cursorKey = '${source.id}|${request.query.trim()}|${request.filterSignature}';
    String? cursorValue;
    if (page > 1 && pagination.cursorParam.isNotEmpty) {
      cursorValue = _cursorCache[cursorKey]?[page];
      if (cursorValue == null || cursorValue.isEmpty) {
        return BookSourceSearchPage(
          books: const <BookSourceSearchBook>[],
          page: page,
          totalPages: page,
          provider: source.id,
        );
      }
    }

    final randCache = <String, String>{};
    final result = await _executeWithMirrorFailover(
      source,
      injectAuth: source.hasCredentials,
      buildRequest: (origin) {
        final ctx = _baseContext(
          source,
          origin: origin,
          query: request.query.trim(),
          page: page,
          limit: pageSize,
          offset: offset,
        );
        final queryPairs = <MapEntry<String, String>>[];
        for (final entry in searchCfg.request.query.entries) {
          final v = _extractor.renderTemplate(
            entry.value,
            ctx,
            randCache: randCache,
          );
          if (v.isNotEmpty) {
            queryPairs.add(MapEntry<String, String>(entry.key, v));
          }
        }
        if (cursorValue != null &&
            cursorValue.isNotEmpty &&
            pagination.cursorParam.isNotEmpty) {
          queryPairs.add(MapEntry<String, String>(pagination.cursorParam, cursorValue));
        }

        final bodyPairs = <MapEntry<String, String>>[];
        if (searchCfg.request.method != 'GET' &&
            searchCfg.request.contentType == 'form') {
          for (final entry in searchCfg.request.body.entries) {
            final rendered = _extractor
                .renderTemplateObject(entry.value, ctx, randCache: randCache)
                ?.toString() ??
                '';
            bodyPairs.add(MapEntry<String, String>(entry.key, rendered));
          }
          _appendFilters(
            bodyPairs,
            searchCfg.filters,
            request,
          );
        } else {
          _appendFilters(
            queryPairs,
            searchCfg.filters,
            request,
          );
        }

        final headers = _renderHeaders(
          searchCfg.request.headers,
          ctx,
          randCache: randCache,
        );

        Object? encodedBody;
        String? contentType;
        if (searchCfg.request.method != 'GET' &&
            searchCfg.request.method != 'HEAD') {
          if (searchCfg.request.contentType == 'form') {
            encodedBody = _encodePairs(bodyPairs);
            contentType = 'application/x-www-form-urlencoded';
          } else if (searchCfg.request.contentType == 'json' &&
              searchCfg.request.body.isNotEmpty) {
            encodedBody = jsonEncode(
              _extractor.renderTemplateObject(
                searchCfg.request.body,
                ctx,
                randCache: randCache,
              ),
            );
            contentType = 'application/json';
          }
        }

        final rawTarget = searchCfg.request.url.isNotEmpty
            ? _extractor.renderTemplate(
                searchCfg.request.url,
                ctx,
                randCache: randCache,
              )
            : _extractor.renderTemplate(
                searchCfg.request.path,
                ctx,
                randCache: randCache,
              );
        final resolvedUrl = resolveSafeBookSourceUrl(rawTarget, origin);
        final fullUrl = _appendQueryPairs(resolvedUrl, queryPairs);

        return _BuiltHttpCall(
          method: searchCfg.request.method,
          url: fullUrl,
          headers: headers,
          body: encodedBody,
          contentType: contentType,
        );
      },
    );

    final responseCfg = searchCfg.response;
    final items = _extractor.extractItems(
      result.bodyText,
      mode: responseCfg.mode,
      itemsPath: responseCfg.itemsPath,
      itemsSelector: responseCfg.itemsSelector,
    );

    final books = <BookSourceSearchBook>[];
    for (final item in items) {
      final book = _extractBookRecord(
        source: source,
        item: item,
        mode: responseCfg.mode,
        origin: result.originUsed,
        varsRules: responseCfg.vars,
        fieldRules: responseCfg.fields,
      );
      if (book != null) {
        books.add(book);
      }
    }

    // Parse pagination metadata.
    final root = _extractor.parseRoot(result.bodyText, mode: responseCfg.mode);
    var currentPage = page;
    var totalPages = page;

    if (pagination.currentPagePath.isNotEmpty && responseCfg.mode == 'json') {
      final cur = _tryParsePositiveInt(
        RuleExtractor.resolveJsonPath(root, pagination.currentPagePath),
      );
      if (cur != null) currentPage = cur;
    }

    if (pagination.totalPagesPath.isNotEmpty && responseCfg.mode == 'json') {
      final tp = _tryParsePositiveInt(
        RuleExtractor.resolveJsonPath(root, pagination.totalPagesPath),
      );
      if (tp != null) totalPages = tp;
    } else if (pagination.totalCountPath.isNotEmpty &&
        responseCfg.mode == 'json') {
      final totalCount = _tryParsePositiveInt(
        RuleExtractor.resolveJsonPath(root, pagination.totalCountPath),
      );
      final effectiveSize = pagination.pageSize > 0
          ? pagination.pageSize
          : pageSize;
      if (totalCount != null && effectiveSize > 0) {
        totalPages = (totalCount / effectiveSize).ceil();
        if (totalPages < 1) totalPages = 1;
      }
    }

    if (pagination.nextCursorPath.isNotEmpty && responseCfg.mode == 'json') {
      final nextCursor = RuleExtractor.resolveJsonPath(
        root,
        pagination.nextCursorPath,
      )?.toString().trim() ??
          '';
      if (nextCursor.isNotEmpty) {
        final cache = _cursorCache.putIfAbsent(
          cursorKey,
          () => <int, String>{},
        );
        cache[currentPage + 1] = nextCursor;
        if (totalPages <= currentPage) {
          totalPages = currentPage + 1;
        }
      }
    } else if (pagination.nextPagePath.isNotEmpty &&
        responseCfg.mode == 'json') {
      final nextVal = RuleExtractor.resolveJsonPath(root, pagination.nextPagePath);
      if (nextVal != null && nextVal.toString().trim().isNotEmpty) {
        if (totalPages <= currentPage) totalPages = currentPage + 1;
      }
    } else if (pagination.nextPageSelector.isNotEmpty &&
        responseCfg.mode == 'html') {
      final nextLink = _extractor.extractSingle(
        root,
        BookSourceExtractRule(selector: pagination.nextPageSelector),
        mode: 'html',
        baseUrl: result.originUsed,
      );
      if (nextLink.isNotEmpty && totalPages <= currentPage) {
        totalPages = currentPage + 1;
      }
    }

    return BookSourceSearchPage(
      books: books,
      page: currentPage,
      totalPages: totalPages < currentPage ? currentPage : totalPages,
      provider: source.id,
    );
  }

  @override
  Future<BookSourceSearchBook> getBookDetail(
    ResolvedBookSource source,
    String ref, {
    BookSourceSearchBook? baseBook,
  }) async {
    final detailCfg = source.definition.detail;
    final fallback =
        baseBook ?? BookSourceSearchBook(ref: ref, title: ref, provider: source.id);
    if (detailCfg == null || !detailCfg.isConfigured) {
      return fallback;
    }

    final refParts = _splitRef(ref, source.definition.download?.refSeparator ?? ':');
    final randCache = <String, String>{};
    final resp = await _executeWithMirrorFailover(
      source,
      injectAuth: source.hasCredentials,
      buildRequest: (origin) {
        final ctx = _baseContext(
          source,
          origin: origin,
          ref: ref,
          refParts: refParts,
          bookVars: fallback.sourceVars,
        );
        final rawTarget = detailCfg.url.isNotEmpty
            ? _extractor.renderTemplate(
                detailCfg.url,
                ctx,
                randCache: randCache,
              )
            : _extractor.renderTemplate(
                detailCfg.path,
                ctx,
                randCache: randCache,
              );
        final resolvedUrl = resolveSafeBookSourceUrl(rawTarget, origin);
        return _BuiltHttpCall(
          method: detailCfg.method,
          url: resolvedUrl,
          headers: _renderHeaders(
            detailCfg.headers,
            ctx,
            randCache: randCache,
          ),
        );
      },
    );

    final root = _extractor.parseRoot(
      resp.bodyText,
      mode: detailCfg.responseMode,
      rootPath: detailCfg.rootPath,
    );
    if (root == null) return fallback;

    final extracted = _extractBookRecord(
      source: source,
      item: root,
      mode: detailCfg.responseMode,
      origin: resp.originUsed,
      varsRules: detailCfg.vars,
      fieldRules: detailCfg.fields,
      fallbackRef: ref,
      fallbackTitle: fallback.title,
    );
    if (extracted == null) return fallback;
    return fallback.mergeDetail(extracted);
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
    final dlCfg = source.definition.download;
    if (dlCfg == null) {
      throw const BookSourceException(
        code: 'UNSUPPORTED',
        message: '该书源未配置下载规则',
      );
    }
    if (source.requiresAuthForDownload && !source.hasCredentials) {
      throw BookSourceException(
        code: 'PROVIDER_NOT_CONFIGURED',
        message: '书源「${source.name}」下载需要登录账号，请先在书源配置中完成登录',
      );
    }

    var effectiveMeta = meta;
    final refParts = _splitRef(ref, dlCfg.refSeparator);
    final origins = _mirrorPool.candidateOrigins(source);
    if (origins.isEmpty) {
      throw const BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: '书源没有可用的域名镜像',
      );
    }
    var activeOrigin = origins.first;

    // Step pipeline execution
    final stepCtx = <String, dynamic>{};
    if (dlCfg.steps.isNotEmpty) {
      for (final step in dlCfg.steps) {
        if (cancelToken?.isCancelled ?? false) {
          throw const BookSourceException(code: 'CANCELLED', message: '下载已取消');
        }
        final extracted = await _runDownloadStepWithMirror(
          source: source,
          step: step,
          ref: ref,
          refParts: refParts,
          bookVars: effectiveMeta?.sourceVars ?? const <String, String>{},
          stepCtx: stepCtx,
          preferredOrigin: activeOrigin,
          cancelToken: cancelToken,
          onOriginResolved: (o) => activeOrigin = o,
        );
        if (step.id.isNotEmpty) {
          stepCtx[step.id] = extracted;
        }
        stepCtx['last'] = extracted;
      }
    }

    // Resolve final file URL
    final fileReq = dlCfg.fileRequest;
    String renderFileTarget(BookSourceSearchBook? bookMeta) {
      final ctx = _baseContext(
        source,
        origin: activeOrigin,
        ref: ref,
        refParts: refParts,
        bookVars: bookMeta?.sourceVars ?? const <String, String>{},
        stepCtx: stepCtx,
      );
      final raw = fileReq.url.isNotEmpty
          ? _extractor.renderTemplate(fileReq.url, ctx)
          : _extractor.renderTemplate(fileReq.path, ctx);
      return resolveSafeBookSourceUrl(raw, activeOrigin);
    }

    var targetUrl = renderFileTarget(effectiveMeta);
    if (targetUrl.isEmpty &&
        source.definition.detail != null &&
        source.definition.detail!.isConfigured) {
      // Cold-cache fallback: fetch detail to populate book.var.* before download.
      effectiveMeta = await getBookDetail(source, ref, baseBook: effectiveMeta);
      targetUrl = renderFileTarget(effectiveMeta);
    }
    if (targetUrl.isEmpty) {
      throw const BookSourceException(
        code: 'NOT_FOUND',
        message: '未能解析到可下载的文件地址',
      );
    }

    final finalCtx = _baseContext(
      source,
      origin: activeOrigin,
      ref: ref,
      refParts: refParts,
      bookVars: effectiveMeta?.sourceVars ?? const <String, String>{},
      stepCtx: stepCtx,
    );
    final authPrepared = _buildAuthHeadersAndQuery(source);
    final mergedHeaders = <String, String>{
      ...source.definition.headers,
      ..._renderHeaders(fileReq.headers, finalCtx),
      if (fileReq.sameOriginCredentials) ...authPrepared.headers,
    };
    final finalTargetWithAuthQuery =
        fileReq.sameOriginCredentials && authPrepared.query.isNotEmpty
        ? _appendQueryPairs(targetUrl, authPrepared.query)
        : targetUrl;

    await _mirrorPool.throttle(source);

    return BookSourceDownloadHelper.streamToFile(
      mirrorPool: _mirrorPool,
      url: finalTargetWithAuthQuery,
      originUsed: activeOrigin,
      savePath: savePath,
      method: fileReq.method,
      headers: mergedHeaders,
      authHeaderNames: authPrepared.authHeaderNames,
      sameOriginCredentials: fileReq.sameOriginCredentials,
      proxyPrefix: source.proxyPrefix,
      retries: fileReq.retries,
      stallTimeoutSeconds: fileReq.stallTimeoutSeconds,
      maxBytes: fileReq.maxBytes,
      retryBaseDelay: _downloadRetryBaseDelay,
      delay: _delay,
      meta: effectiveMeta,
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
    final auth = source.definition.auth;
    if (auth == null || auth.modes.isEmpty) {
      throw const BookSourceException(
        code: 'UNSUPPORTED',
        message: '该书源无需或不支持账号配置',
      );
    }
    final mode = auth.modes.firstWhere(
      (m) => m.id == modeId,
      orElse: () => auth.modes.first,
    );

    for (final field in mode.fields) {
      if (field.required && (inputs[field.key] ?? '').trim().isEmpty) {
        throw BookSourceException(
          code: 'INVALID_INPUT',
          message: '请填写${field.label}',
        );
      }
    }

    final Map<String, String> credValues;
    if (mode.login == null) {
      // Direct credential storage mode (cookies / api_key / basic).
      credValues = <String, String>{
        for (final entry in inputs.entries)
          if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
      };
    } else {
      credValues = await _executeLogin(source, mode.login!, inputs);
    }

    final nextSource = ResolvedBookSource(
      definition: source.definition,
      origin: source.origin,
      subscriptionId: source.subscriptionId,
      subscriptionName: source.subscriptionName,
      overlay: source.overlay,
      credentials: BookSourceCredentials(
        sourceId: source.id,
        modeId: mode.id,
        values: credValues,
        savedAt: DateTime.now().toUtc(),
      ),
    );

    BookSourceAccountStatus? account;
    if (auth.verify != null && auth.verify!.isConfigured) {
      account = await verify(nextSource);
    } else {
      account = BookSourceAccountStatus(
        configured: true,
        status: 'ok',
        email: credValues['email'] ?? inputs['email'] ?? '',
        lastVerifiedAt: DateTime.now().toUtc(),
      );
    }

    return BookSourceCredentials(
      sourceId: source.id,
      modeId: mode.id,
      values: Map<String, String>.unmodifiable(credValues),
      account: account,
      savedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<BookSourceAccountStatus> verify(ResolvedBookSource source) async {
    final verifyCfg = source.definition.auth?.verify;
    if (!source.hasCredentials) {
      throw const BookSourceException(
        code: 'PROVIDER_NOT_CONFIGURED',
        message: '尚未配置该书源的账号凭据',
      );
    }
    if (verifyCfg == null || !verifyCfg.isConfigured) {
      return BookSourceAccountStatus(
        configured: true,
        status: 'ok',
        email: source.credentials?.values['email'] ?? '',
        lastVerifiedAt: DateTime.now().toUtc(),
      );
    }

    final stepCtx = <String, dynamic>{};
    String responseBody = '';
    Map<String, String> responseCookies = const <String, String>{};
    String originUsed = source.effectiveDomains.isNotEmpty
        ? source.effectiveDomains.first
        : '';

    if (verifyCfg.steps.isNotEmpty) {
      for (final step in verifyCfg.steps) {
        final stepResult = await _runSingleStep(
          source: source,
          step: step,
          ref: '',
          refParts: const <String>[],
          bookVars: const <String, String>{},
          stepCtx: stepCtx,
          origin: originUsed,
          injectAuth: true,
        );
        originUsed = stepResult.originUsed;
        responseBody = stepResult.bodyText;
        responseCookies = stepResult.cookies;
        if (step.id.isNotEmpty) {
          stepCtx[step.id] = stepResult.extracted;
        }
        stepCtx['last'] = stepResult.extracted;
      }
    } else {
      final randCache = <String, String>{};
      final resp = await _executeWithMirrorFailover(
        source,
        injectAuth: true,
        buildRequest: (origin) {
          final ctx = _baseContext(source, origin: origin);
          final rawTarget = verifyCfg.url.isNotEmpty
              ? _extractor.renderTemplate(
                  verifyCfg.url,
                  ctx,
                  randCache: randCache,
                )
              : _extractor.renderTemplate(
                  verifyCfg.path,
                  ctx,
                  randCache: randCache,
                );
          return _BuiltHttpCall(
            method: verifyCfg.method,
            url: resolveSafeBookSourceUrl(rawTarget, origin),
            headers: _renderHeaders(
              verifyCfg.headers,
              ctx,
              randCache: randCache,
            ),
          );
        },
      );
      originUsed = resp.originUsed;
      responseBody = resp.bodyText;
      responseCookies = RuleExtractor.parseSetCookieHeaders(
        resp.headers['set-cookie'],
      );
    }

    final root = _extractor.parseRoot(
      responseBody,
      mode: verifyCfg.responseMode,
    );
    final tplCtx = <String, Object?>{
      ..._baseContext(source, origin: originUsed, stepCtx: stepCtx),
    };

    String readField(String key) => _extractor.extractSingle(
      root,
      verifyCfg.fields[key],
      mode: verifyCfg.responseMode,
      baseUrl: originUsed,
      templateContext: tplCtx,
      responseCookies: responseCookies,
    );

    final email = readField('email');
    final used = int.tryParse(readField('daily_used')) ?? 0;
    final limitRaw = readField('daily_limit');
    final limit = int.tryParse(limitRaw);
    final remainingRaw = readField('daily_remaining');
    final remainingParsed = int.tryParse(remainingRaw);
    final premiumRaw = readField('premium').toLowerCase();
    final premium =
        premiumRaw == 'true' ||
        premiumRaw == '1' ||
        premiumRaw == 'yes' ||
        premiumRaw == 'premium';

    final quotaKnown = limit != null || remainingParsed != null;
    final resolvedLimit = limit ?? 0;
    var resolvedRemaining = remainingParsed ?? (resolvedLimit - used);
    if (resolvedRemaining < 0) resolvedRemaining = 0;

    return BookSourceAccountStatus(
      configured: true,
      status: 'ok',
      email: email.isNotEmpty
          ? email
          : (source.credentials?.values['email'] ?? ''),
      dailyUsed: used,
      dailyLimit: resolvedLimit,
      dailyRemaining: resolvedRemaining,
      quotaKnown: quotaKnown,
      premium: premium,
      lastVerifiedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<List<MirrorProbeResult>> probeDomains(ResolvedBookSource source) =>
      _mirrorPool.probeAll(source);

  // ---------------------------------------------------------------------------
  // Internal Auth & Step Execution
  // ---------------------------------------------------------------------------

  Future<Map<String, String>> _executeLogin(
    ResolvedBookSource source,
    BookSourceLoginConfig login,
    Map<String, String> inputs,
  ) async {
    final origins = _mirrorPool.candidateOrigins(source);
    if (origins.isEmpty) {
      throw const BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: '书源没有可用的镜像域名',
      );
    }

    final maxAttempts = source.definition.maxMirrorAttempts > 0
        ? source.definition.maxMirrorAttempts
        : 2;
    BookSourceException? lastMirrorErr;
    var attemptCount = 0;

    for (final origin in origins) {
      if (attemptCount >= maxAttempts) break;
      attemptCount++;

      try {
        final stepCtx = <String, dynamic>{};
        for (final pre in login.preSteps) {
          final preRes = await _runSingleStep(
            source: source,
            step: pre,
            ref: '',
            refParts: const <String>[],
            bookVars: const <String, String>{},
            stepCtx: stepCtx,
            origin: origin,
            injectAuth: false,
            inputs: inputs,
          );
          if (pre.id.isNotEmpty) {
            stepCtx[pre.id] = preRes.extracted;
          }
          stepCtx['last'] = preRes.extracted;
        }

        final randCache = <String, String>{};
        final ctx = _baseContext(
          source,
          origin: origin,
          inputs: inputs,
          stepCtx: stepCtx,
        );
        final headers = <String, String>{
          ...source.definition.headers,
          ..._renderHeaders(login.headers, ctx, randCache: randCache),
        };
        if (login.cookies.isNotEmpty) {
          final cookiePairs = _renderHeaders(
            login.cookies,
            ctx,
            randCache: randCache,
          );
          if (cookiePairs.isNotEmpty) {
            headers['Cookie'] = _joinCookies(
              existing: headers['Cookie'],
              extra: cookiePairs,
            );
          }
        }

        Object? encodedBody;
        String? contentType;
        if (login.contentType == 'form') {
          final pairs = <MapEntry<String, String>>[
            for (final e in login.body.entries)
              MapEntry<String, String>(
                e.key,
                _extractor
                        .renderTemplateObject(e.value, ctx, randCache: randCache)
                        ?.toString() ??
                    '',
              ),
          ];
          encodedBody = _encodePairs(pairs);
          contentType = 'application/x-www-form-urlencoded';
        } else if (login.contentType == 'json') {
          encodedBody = jsonEncode(
            _extractor.renderTemplateObject(
              login.body,
              ctx,
              randCache: randCache,
            ),
          );
          contentType = 'application/json';
        }

        final rawTarget = login.url.isNotEmpty
            ? _extractor.renderTemplate(login.url, ctx, randCache: randCache)
            : _extractor.renderTemplate(login.path, ctx, randCache: randCache);
        final fullUrl = resolveSafeBookSourceUrl(rawTarget, origin);

        final resp = await _mirrorPool.sendWithRedirects(
          url: fullUrl,
          originUsed: origin,
          method: login.method,
          headers: headers,
          body: encodedBody,
          contentType: contentType,
          proxyPrefix: source.proxyPrefix,
        );

        _validateResponseOrThrow(
          source: source,
          resp: resp,
          isLogin: true,
        );
        _mirrorPool.markHealthy(source.id, origin);

        final cookies = RuleExtractor.parseSetCookieHeaders(
          resp.headers['set-cookie'],
        );
        final root = _extractor.parseRoot(
          resp.bodyText,
          mode: login.responseMode,
        );

        final saved = <String, String>{};
        for (final entry in login.saveCredentials.entries) {
          final v = _extractor.extractSingle(
            root,
            entry.value,
            mode: login.responseMode,
            baseUrl: origin,
            templateContext: ctx,
            responseCookies: cookies,
          );
          if (v.isNotEmpty) saved[entry.key] = v;
        }
        for (final entry in login.saveCookieCredentials.entries) {
          final v = cookies[entry.value] ?? '';
          if (v.isNotEmpty) saved[entry.key] = v;
        }

        if (saved.isEmpty) {
          throw const BookSourceException(
            code: 'PROVIDER_ERROR',
            message: '登录响应中未包含有效的会话凭据',
          );
        }
        return saved;
      } on BookSourceException catch (e) {
        if (e.code == 'PROVIDER_BLOCKED' || e.code == 'PROVIDER_UNAVAILABLE') {
          _mirrorPool.markUnhealthy(source.id, origin);
          lastMirrorErr = e;
          continue;
        }
        rethrow;
      } on DioException catch (e) {
        _mirrorPool.markUnhealthy(source.id, origin);
        lastMirrorErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '连接镜像失败：${e.message ?? e.type.name}',
          statusCode: e.response?.statusCode,
        );
      }
    }

    throw lastMirrorErr ??
        const BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '所有镜像均不可用，请检查网络或切换反代',
        );
  }

  Future<Map<String, String>> _runDownloadStepWithMirror({
    required ResolvedBookSource source,
    required BookSourceStepConfig step,
    required String ref,
    required List<String> refParts,
    required Map<String, String> bookVars,
    required Map<String, dynamic> stepCtx,
    required String preferredOrigin,
    required void Function(String origin) onOriginResolved,
    CancelToken? cancelToken,
  }) async {
    final candidates = <String>[
      preferredOrigin,
      ..._mirrorPool.candidateOrigins(source).where((o) => o != preferredOrigin),
    ];
    final maxAttempts = source.definition.maxMirrorAttempts > 0
        ? source.definition.maxMirrorAttempts
        : 2;
    BookSourceException? lastMirrorErr;

    for (var i = 0; i < candidates.length && i < maxAttempts; i++) {
      final origin = candidates[i];
      try {
        final res = await _runSingleStep(
          source: source,
          step: step,
          ref: ref,
          refParts: refParts,
          bookVars: bookVars,
          stepCtx: stepCtx,
          origin: origin,
          injectAuth: true,
          cancelToken: cancelToken,
        );
        onOriginResolved(res.originUsed);
        return res.extracted;
      } on BookSourceException catch (e) {
        if (e.code == 'PROVIDER_BLOCKED' || e.code == 'PROVIDER_UNAVAILABLE') {
          _mirrorPool.markUnhealthy(source.id, origin);
          lastMirrorErr = e;
          continue;
        }
        rethrow;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          throw const BookSourceException(code: 'CANCELLED', message: '下载已取消');
        }
        _mirrorPool.markUnhealthy(source.id, origin);
        lastMirrorErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '请求镜像失败：${e.message ?? e.type.name}',
          statusCode: e.response?.statusCode,
        );
      }
    }

    throw lastMirrorErr ??
        const BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '下载解析步骤执行失败，镜像不可达',
        );
  }

  Future<
    ({
      Map<String, String> extracted,
      Map<String, String> cookies,
      String bodyText,
      String originUsed,
    })
  >
  _runSingleStep({
    required ResolvedBookSource source,
    required BookSourceStepConfig step,
    required String ref,
    required List<String> refParts,
    required Map<String, String> bookVars,
    required Map<String, dynamic> stepCtx,
    required String origin,
    required bool injectAuth,
    Map<String, String> inputs = const <String, String>{},
    CancelToken? cancelToken,
  }) async {
    final randCache = <String, String>{};
    var currentTarget = '';
    Map<String, String> extracted = const <String, String>{};
    Map<String, String> cookies = const <String, String>{};
    String bodyText = '';

    final hopsLimit = step.followWhileUrlRegex.isNotEmpty && step.maxHops > 0
        ? step.maxHops
        : 1;
    final followRegex = step.followWhileUrlRegex.isNotEmpty
        ? RegExp(step.followWhileUrlRegex)
        : null;

    for (var hop = 0; hop < hopsLimit; hop++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const BookSourceException(code: 'CANCELLED', message: '下载已取消');
      }

      final ctx = _baseContext(
        source,
        origin: origin,
        inputs: inputs,
        ref: ref,
        refParts: refParts,
        bookVars: bookVars,
        stepCtx: stepCtx,
      );

      if (hop == 0) {
        final raw = step.url.isNotEmpty
            ? _extractor.renderTemplate(step.url, ctx, randCache: randCache)
            : _extractor.renderTemplate(step.path, ctx, randCache: randCache);
        currentTarget = resolveSafeBookSourceUrl(raw, origin);
      }
      if (currentTarget.isEmpty) {
        throw BookSourceException(
          code: 'PROVIDER_ERROR',
          message: '步骤 ${step.id} 请求地址无效',
        );
      }

      final queryPairs = <MapEntry<String, String>>[
        for (final e in step.query.entries)
          MapEntry<String, String>(
            e.key,
            _extractor.renderTemplate(e.value, ctx, randCache: randCache),
          ),
      ];
      final fullUrl = _appendQueryPairs(currentTarget, queryPairs);

      final authPrepared = injectAuth
          ? _buildAuthHeadersAndQuery(source)
          : const _PreparedAuth();
      final headers = <String, String>{
        ...source.definition.headers,
        ...authPrepared.headers,
        ..._renderHeaders(step.headers, ctx, randCache: randCache),
      };
      if (step.cookies.isNotEmpty) {
        final extraCookies = _renderHeaders(
          step.cookies,
          ctx,
          randCache: randCache,
        );
        if (extraCookies.isNotEmpty) {
          headers['Cookie'] = _joinCookies(
            existing: headers['Cookie'],
            extra: extraCookies,
          );
        }
      }

      Object? encodedBody;
      String? contentType;
      if (hop == 0 && step.method != 'GET' && step.method != 'HEAD') {
        if (step.contentType == 'form') {
          final pairs = <MapEntry<String, String>>[
            for (final e in step.body.entries)
              MapEntry<String, String>(
                e.key,
                _extractor
                        .renderTemplateObject(e.value, ctx, randCache: randCache)
                        ?.toString() ??
                    '',
              ),
          ];
          encodedBody = _encodePairs(pairs);
          contentType = 'application/x-www-form-urlencoded';
        } else if (step.contentType == 'json') {
          encodedBody = jsonEncode(
            _extractor.renderTemplateObject(
              step.body,
              ctx,
              randCache: randCache,
            ),
          );
          contentType = 'application/json';
        }
      }

      await _mirrorPool.throttle(source);
      final resp = await _mirrorPool.sendWithRedirects(
        url: _appendQueryPairs(fullUrl, authPrepared.query),
        originUsed: origin,
        method: hop == 0 ? step.method : 'GET',
        headers: headers,
        body: encodedBody,
        contentType: contentType,
        authHeaderNames: authPrepared.authHeaderNames,
        sameOriginCredentials:
            source.definition.auth?.inject.sameOriginOnly ?? true,
        proxyPrefix: source.proxyPrefix,
        cancelToken: cancelToken,
      );

      _validateResponseOrThrow(source: source, resp: resp);
      _mirrorPool.markHealthy(source.id, origin);

      bodyText = resp.bodyText;
      cookies = RuleExtractor.parseSetCookieHeaders(resp.headers['set-cookie']);
      final root = _extractor.parseRoot(bodyText, mode: step.responseMode);
      final nextExtracted = <String, String>{};
      for (final entry in step.extract.entries) {
        final val = _extractor.extractSingle(
          root,
          entry.value,
          mode: step.responseMode,
          baseUrl: origin,
          templateContext: ctx,
          responseCookies: cookies,
        );
        if (val.isNotEmpty) nextExtracted[entry.key] = val;
      }
      for (final entry in step.extractCookies.entries) {
        final v = cookies[entry.value] ?? '';
        if (v.isNotEmpty) nextExtracted[entry.key] = v;
      }
      extracted = nextExtracted;

      final maybeUrl = extracted['url'] ?? '';
      if (followRegex != null && maybeUrl.isNotEmpty) {
        final parsedMaybe = Uri.tryParse(maybeUrl);
        final pathMatch =
            followRegex.hasMatch(maybeUrl) ||
            (parsedMaybe != null && followRegex.hasMatch(parsedMaybe.path));
        if (pathMatch && hop + 1 < hopsLimit) {
          currentTarget = resolveSafeBookSourceUrl(maybeUrl, origin);
          continue;
        }
      }
      break;
    }

    // Handle optional asynchronous polling (e.g. wenshuoge EPUB generation).
    final poll = step.poll;
    if (poll != null) {
      final root = _extractor.parseRoot(bodyText, mode: step.responseMode);
      var isReady = false;
      if (poll.untilPath.isNotEmpty && step.responseMode == 'json') {
        final curState =
            RuleExtractor.resolveJsonPath(root, poll.untilPath)?.toString() ??
            '';
        isReady = curState == poll.untilValue;
      }
      if (poll.failPath.isNotEmpty && step.responseMode == 'json') {
        final curState =
            RuleExtractor.resolveJsonPath(root, poll.failPath)?.toString() ??
            '';
        if (curState == poll.failValue) {
          final msg =
              RuleExtractor.resolveJsonPath(
                root,
                poll.failMessagePath,
              )?.toString() ??
              '生成电子书失败，请稍后重试';
          throw BookSourceException(code: 'PROVIDER_ERROR', message: msg);
        }
      }

      if (!isReady) {
        final mutableStepCtx = <String, dynamic>{...stepCtx};
        if (step.id.isNotEmpty) {
          mutableStepCtx[step.id] = extracted;
        }
        mutableStepCtx['last'] = extracted;

        final interval = Duration(
          milliseconds: poll.intervalMs > 0 ? poll.intervalMs : 3000,
        );
        final attempts = poll.maxAttempts > 0 ? poll.maxAttempts : 40;

        for (var attempt = 0; attempt < attempts; attempt++) {
          if (cancelToken?.isCancelled ?? false) {
            throw const BookSourceException(
              code: 'CANCELLED',
              message: '下载已取消',
            );
          }
          await _delay(interval);
          if (cancelToken?.isCancelled ?? false) {
            throw const BookSourceException(
              code: 'CANCELLED',
              message: '下载已取消',
            );
          }

          final ctx = _baseContext(
            source,
            origin: origin,
            inputs: inputs,
            ref: ref,
            refParts: refParts,
            bookVars: bookVars,
            stepCtx: mutableStepCtx,
          );
          final rawPollUrl = poll.url.isNotEmpty
              ? _extractor.renderTemplate(poll.url, ctx)
              : _extractor.renderTemplate(poll.path, ctx);
          final pollUrl = resolveSafeBookSourceUrl(rawPollUrl, origin);
          final authPrepared = _buildAuthHeadersAndQuery(source);
          final pollHeaders = <String, String>{
            ...source.definition.headers,
            ...authPrepared.headers,
            ..._renderHeaders(poll.headers, ctx),
          };
          if (poll.cookies.isNotEmpty) {
            pollHeaders['Cookie'] = _joinCookies(
              existing: pollHeaders['Cookie'],
              extra: _renderHeaders(poll.cookies, ctx),
            );
          }

          final pollResp = await _mirrorPool.sendWithRedirects(
            url: _appendQueryPairs(pollUrl, authPrepared.query),
            originUsed: origin,
            method: poll.method,
            headers: pollHeaders,
            authHeaderNames: authPrepared.authHeaderNames,
            sameOriginCredentials:
                source.definition.auth?.inject.sameOriginOnly ?? true,
            proxyPrefix: source.proxyPrefix,
            cancelToken: cancelToken,
          );

          _validateResponseOrThrow(source: source, resp: pollResp);
          final pollRoot = _extractor.parseRoot(pollResp.bodyText, mode: 'json');

          if (poll.failPath.isNotEmpty) {
            final curState =
                RuleExtractor.resolveJsonPath(
                  pollRoot,
                  poll.failPath,
                )?.toString() ??
                '';
            if (curState == poll.failValue) {
              final msg =
                  RuleExtractor.resolveJsonPath(
                    pollRoot,
                    poll.failMessagePath,
                  )?.toString() ??
                  '生成电子书失败';
              throw BookSourceException(code: 'PROVIDER_ERROR', message: msg);
            }
          }

          final curReadyState =
              RuleExtractor.resolveJsonPath(
                pollRoot,
                poll.untilPath,
              )?.toString() ??
              '';
          if (curReadyState == poll.untilValue) {
            final merged = <String, String>{...extracted};
            for (final entry in poll.extract.entries) {
              final val = _extractor.extractSingle(
                pollRoot,
                entry.value,
                mode: 'json',
                baseUrl: origin,
                templateContext: ctx,
              );
              if (val.isNotEmpty) merged[entry.key] = val;
            }
            extracted = merged;
            isReady = true;
            break;
          }
        }

        if (!isReady) {
          throw const BookSourceException(
            code: 'TIMEOUT',
            message: '等待服务端生成电子书超时，请稍后重试',
          );
        }
      }
    }

    return (
      extracted: extracted,
      cookies: cookies,
      bodyText: bodyText,
      originUsed: origin,
    );
  }

  Future<MirrorHttpResponse> _executeWithMirrorFailover(
    ResolvedBookSource source, {
    required bool injectAuth,
    required _BuiltHttpCall Function(String origin) buildRequest,
  }) async {
    final origins = _mirrorPool.candidateOrigins(source);
    if (origins.isEmpty) {
      throw const BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: '该书源未配置可用的站点域名',
      );
    }

    final maxAttempts = source.definition.maxMirrorAttempts > 0
        ? source.definition.maxMirrorAttempts
        : 2;
    BookSourceException? lastMirrorErr;
    var attempts = 0;

    for (final origin in origins) {
      if (attempts >= maxAttempts) break;
      attempts++;

      final built = buildRequest(origin);
      if (built.url.isEmpty) {
        throw const BookSourceException(
          code: 'PROVIDER_ERROR',
          message: '书源请求地址无效',
        );
      }

      final authPrepared = injectAuth
          ? _buildAuthHeadersAndQuery(source)
          : const _PreparedAuth();
      final headers = <String, String>{
        ...source.definition.headers,
        ...authPrepared.headers,
        ...built.headers,
      };
      final urlWithQuery = _appendQueryPairs(built.url, authPrepared.query);

      try {
        await _mirrorPool.throttle(source);
        final resp = await _mirrorPool.sendWithRedirects(
          url: urlWithQuery,
          originUsed: origin,
          method: built.method,
          headers: headers,
          body: built.body,
          contentType: built.contentType,
          authHeaderNames: authPrepared.authHeaderNames,
          sameOriginCredentials:
              source.definition.auth?.inject.sameOriginOnly ?? true,
          proxyPrefix: source.proxyPrefix,
        );
        _validateResponseOrThrow(source: source, resp: resp);
        _mirrorPool.markHealthy(source.id, origin);
        return resp;
      } on BookSourceException catch (e) {
        if (e.code == 'PROVIDER_BLOCKED' || e.code == 'PROVIDER_UNAVAILABLE') {
          _mirrorPool.markUnhealthy(source.id, origin);
          lastMirrorErr = e;
          continue;
        }
        rethrow;
      } on DioException catch (e) {
        _mirrorPool.markUnhealthy(source.id, origin);
        lastMirrorErr = BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '网络请求失败：${e.message ?? e.type.name}',
          statusCode: e.response?.statusCode,
        );
      }
    }

    throw lastMirrorErr ??
        const BookSourceException(
          code: 'PROVIDER_UNAVAILABLE',
          message: '书源镜像均不可达，请检查网络或配置反代',
        );
  }

  // ---------------------------------------------------------------------------
  // Error Classification & Book Mapping
  // ---------------------------------------------------------------------------

  void _validateResponseOrThrow({
    required ResolvedBookSource source,
    required MirrorHttpResponse resp,
    bool isLogin = false,
  }) {
    final status = resp.statusCode;
    final bodyText = resp.bodyText;
    final errorsCfg = source.definition.errors;

    // 1. Bot-protection check (e.g. Cloudflare / DiamWall HTML challenge)
    final bp = errorsCfg?.botProtection;
    if (bp != null && bp.isConfigured && bp.statuses.contains(status)) {
      final hasLoc = (resp.headers.value('location') ?? '').trim().isNotEmpty;
      final ct = (resp.headers.value('content-type') ?? '').toLowerCase();
      final isHtml =
          ct.contains('text/html') ||
          ct.contains('application/xhtml') ||
          bodyText.trimLeft().startsWith('<');
      final triggered =
          (bp.hasLocationHeader && hasLoc) ||
          (bp.htmlBody && isHtml) ||
          (!bp.hasLocationHeader && !bp.htmlBody);
      if (triggered) {
        throw BookSourceException(
          code: 'PROVIDER_BLOCKED',
          message: '书源节点被反爬拦截（HTTP $status），将尝试切换镜像或配置反代',
          statusCode: status,
        );
      }
    }

    if (status >= 500) {
      throw BookSourceException(
        code: 'PROVIDER_UNAVAILABLE',
        message: '书源服务异常（HTTP $status）',
        statusCode: status,
      );
    }

    // 2. Parse optional JSON envelope
    Object? jsonBody;
    final trimmed = bodyText.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('\ufeff{')) {
      try {
        jsonBody = jsonDecode(
          trimmed.startsWith('\ufeff') ? trimmed.substring(1) : trimmed,
        );
      } catch (_) {}
    }

    final envelope = errorsCfg?.envelope;
    var envelopeFailed = false;
    var envelopeErrorMsg = '';
    var envelopeErrorCode = '';

    if (jsonBody != null && envelope != null) {
      if (envelope.errorPath.isNotEmpty) {
        envelopeErrorMsg =
            RuleExtractor.resolveJsonPath(
              jsonBody,
              envelope.errorPath,
            )?.toString().trim() ??
            '';
      }
      if (envelope.errorCodePath.isNotEmpty) {
        envelopeErrorCode =
            RuleExtractor.resolveJsonPath(
              jsonBody,
              envelope.errorCodePath,
            )?.toString().trim() ??
            '';
      }
      if (envelope.successPath.isNotEmpty) {
        final successVal = RuleExtractor.resolveJsonPath(
          jsonBody,
          envelope.successPath,
        );
        if (successVal != null &&
            !_matchesAnySuccessValue(successVal, envelope.successValues)) {
          envelopeFailed = true;
        }
      }
    }

    if (jsonBody is Map && envelopeErrorMsg.isEmpty) {
      final errObj = jsonBody['error'];
      if (errObj is String) {
        envelopeErrorMsg = errObj.trim();
      } else if (errObj is Map) {
        envelopeErrorMsg = (errObj['message']?.toString() ?? '').trim();
        if (envelopeErrorCode.isEmpty) {
          envelopeErrorCode = (errObj['code']?.toString() ?? '').trim();
        }
      }
    }

    // Login endpoint reports credential rejection directly rather than SESSION_EXPIRED.
    if (isLogin) {
      if (status >= 400 || envelopeFailed) {
        final msg = envelopeErrorMsg.isNotEmpty
            ? envelopeErrorMsg
            : '登录失败（HTTP $status）';
        throw BookSourceException(
          code: 'INVALID_CREDENTIALS',
          message: msg,
          statusCode: status,
        );
      }
      return;
    }

    // 3. Apply declarative error mapping rules
    if (errorsCfg != null && (status >= 400 || envelopeFailed)) {
      for (final rule in errorsCfg.rules) {
        if (rule.requireUnauthenticated && source.hasCredentials) {
          continue;
        }
        final statusMatched = rule.statuses.contains(status);
        final codeMatched =
            rule.errorCodeRegex.isNotEmpty &&
            envelopeErrorCode.isNotEmpty &&
            RegExp(
              rule.errorCodeRegex,
              caseSensitive: false,
            ).hasMatch(envelopeErrorCode);
        final msgMatched =
            rule.errorRegex.isNotEmpty &&
            envelopeErrorMsg.isNotEmpty &&
            RegExp(
              rule.errorRegex,
              caseSensitive: false,
            ).hasMatch(envelopeErrorMsg);

        final hasRegexConstraint =
            rule.errorCodeRegex.isNotEmpty || rule.errorRegex.isNotEmpty;
        final matched = hasRegexConstraint
            ? (codeMatched ||
                  msgMatched ||
                  (statusMatched &&
                      status != 400 &&
                      envelopeErrorMsg.isEmpty &&
                      envelopeErrorCode.isEmpty))
            : statusMatched;

        if (matched) {
          throw BookSourceException(
            code: rule.code,
            message: envelopeErrorMsg.isNotEmpty
                ? envelopeErrorMsg
                : _defaultMessageForErrorCode(rule.code, status),
            statusCode: status,
          );
        }
      }
    }

    // 4. Fallback HTTP / envelope checks
    if (envelopeFailed) {
      throw BookSourceException(
        code: 'PROVIDER_ERROR',
        message: envelopeErrorMsg.isNotEmpty ? envelopeErrorMsg : '书源拒绝了本次请求',
        statusCode: status,
      );
    }
    if (status >= 400) {
      if (status == 401 || status == 403) {
        throw BookSourceException(
          code: 'SESSION_EXPIRED',
          message: envelopeErrorMsg.isNotEmpty
              ? envelopeErrorMsg
              : '书源会话已失效或无权访问（HTTP $status）',
          statusCode: status,
        );
      }
      if (status == 404) {
        throw BookSourceException(
          code: 'NOT_FOUND',
          message: envelopeErrorMsg.isNotEmpty
              ? envelopeErrorMsg
              : '未找到目标资源（HTTP 404）',
          statusCode: status,
        );
      }
      if (status == 429) {
        throw BookSourceException(
          code: 'QUOTA_EXCEEDED',
          message: envelopeErrorMsg.isNotEmpty
              ? envelopeErrorMsg
              : '请求或下载配额已达上限（HTTP 429）',
          statusCode: status,
        );
      }
      throw BookSourceException(
        code: 'PROVIDER_ERROR',
        message: envelopeErrorMsg.isNotEmpty
            ? envelopeErrorMsg
            : '书源请求失败（HTTP $status）',
        statusCode: status,
      );
    }
  }

  BookSourceSearchBook? _extractBookRecord({
    required ResolvedBookSource source,
    required Object? item,
    required String mode,
    required String origin,
    required Map<String, BookSourceExtractRule> varsRules,
    required Map<String, BookSourceExtractRule> fieldRules,
    String fallbackRef = '',
    String fallbackTitle = '',
  }) {
    final extractedVars = <String, String>{};
    for (final entry in varsRules.entries) {
      final val = _extractor.extractSingle(
        item,
        entry.value,
        mode: mode,
        baseUrl: origin,
        templateContext: <String, Object?>{
          'origin': origin,
          'vars': extractedVars,
        },
      );
      if (val.isNotEmpty) {
        extractedVars[entry.key] = val;
      }
    }

    final extractedFields = <String, String>{};
    String readField(String key) {
      final rule = fieldRules[key];
      if (rule == null) return '';
      final val = _extractor.extractSingle(
        item,
        rule,
        mode: mode,
        baseUrl: origin,
        templateContext: <String, Object?>{
          'origin': origin,
          'vars': extractedVars,
          'fields': extractedFields,
        },
      );
      if (val.isNotEmpty) extractedFields[key] = val;
      return val;
    }

    // Extract primitive fields first so templates (e.g. ref / source_url) can reference them.
    for (final key in fieldRules.keys) {
      final rule = fieldRules[key];
      if (rule != null && rule.template.isEmpty && key != 'authors') {
        readField(key);
      }
    }

    final title =
        (extractedFields['title'] ?? readField('title')).isNotEmpty
        ? (extractedFields['title'] ?? '')
        : fallbackTitle;
    final ref =
        (extractedFields['ref'] ?? readField('ref')).isNotEmpty
        ? (extractedFields['ref'] ?? '')
        : fallbackRef;

    if (title.isEmpty && fallbackTitle.isEmpty) return null;
    if (ref.isEmpty && fallbackRef.isEmpty) return null;

    // Evaluate templated fields after non-templated fields.
    for (final entry in fieldRules.entries) {
      if (entry.value.template.isNotEmpty && entry.key != 'authors') {
        readField(entry.key);
      }
    }

    final authorsRule = fieldRules['authors'];
    final authors = authorsRule != null
        ? _extractor.extractList(
            item,
            authorsRule,
            mode: mode,
            baseUrl: origin,
            templateContext: <String, Object?>{
              'origin': origin,
              'vars': extractedVars,
              'fields': extractedFields,
            },
          )
        : const <String>[];

    return BookSourceSearchBook(
      provider: source.id,
      ref: extractedFields['ref'] ?? fallbackRef,
      title: extractedFields['title'] ?? fallbackTitle,
      authors: authors,
      year: extractedFields['year'] ?? '',
      publisher: extractedFields['publisher'] ?? '',
      language: extractedFields['language'] ?? '',
      format: (extractedFields['format'] ?? '').toLowerCase(),
      size: extractedFields['size'] ?? '',
      isbn: extractedFields['isbn'] ?? '',
      coverUrl: extractedFields['cover_url'] ?? '',
      description: extractedFields['description'] ?? '',
      sourceUrl: extractedFields['source_url'] ?? '',
      imageHeaders: source.definition.effectiveImageHeaders,
      sourceVars: Map<String, String>.unmodifiable(extractedVars),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, Object?> _baseContext(
    ResolvedBookSource source, {
    required String origin,
    String query = '',
    int page = 1,
    int limit = 20,
    int offset = 0,
    Map<String, String> inputs = const <String, String>{},
    String ref = '',
    List<String> refParts = const <String>[],
    Map<String, String> bookVars = const <String, String>{},
    Map<String, dynamic> stepCtx = const <String, dynamic>{},
  }) {
    return <String, Object?>{
      'origin': origin,
      'query': <String, String>{
        'q': query,
        'page': '$page',
        'limit': '$limit',
        'offset': '$offset',
      },
      'input': inputs,
      'cred': source.credentials?.values ?? const <String, String>{},
      'book': <String, Object?>{
        'ref': ref,
        'ref_parts': refParts,
        'var': bookVars,
      },
      'step': stepCtx,
    };
  }

  _PreparedAuth _buildAuthHeadersAndQuery(ResolvedBookSource source) {
    final inject = source.definition.auth?.inject;
    if (inject == null || inject.isEmpty) {
      return const _PreparedAuth();
    }
    final creds = source.credentials?.values ?? const <String, String>{};
    if (creds.isEmpty) {
      return const _PreparedAuth();
    }
    final ctx = <String, Object?>{'cred': creds};

    final headers = <String, String>{};
    final authNames = <String>{};

    for (final entry in inject.headers.entries) {
      final v = _extractor.renderTemplate(entry.value, ctx).trim();
      if (v.isNotEmpty) {
        headers[entry.key] = v;
        authNames.add(entry.key);
      }
    }

    if (inject.cookies.isNotEmpty) {
      final cookieMap = <String, String>{};
      for (final entry in inject.cookies.entries) {
        final v = _extractor.renderTemplate(entry.value, ctx).trim();
        if (v.isNotEmpty) cookieMap[entry.key] = v;
      }
      if (cookieMap.isNotEmpty) {
        headers['Cookie'] = _joinCookies(extra: cookieMap);
        authNames.add('Cookie');
      }
    }

    if (inject.hasBasicAuth) {
      final u = _extractor.renderTemplate(inject.basicUsername, ctx).trim();
      final p = _extractor.renderTemplate(inject.basicPassword, ctx);
      if (u.isNotEmpty || p.isNotEmpty) {
        headers['Authorization'] =
            'Basic ${base64Encode(utf8.encode('$u:$p'))}';
        authNames.add('Authorization');
      }
    }

    final query = <MapEntry<String, String>>[];
    for (final entry in inject.query.entries) {
      final v = _extractor.renderTemplate(entry.value, ctx).trim();
      if (v.isNotEmpty) {
        query.add(MapEntry<String, String>(entry.key, v));
      }
    }

    return _PreparedAuth(
      headers: headers,
      query: query,
      authHeaderNames: authNames,
    );
  }

  void _appendFilters(
    List<MapEntry<String, String>> target,
    BookSourceFiltersConfig filters,
    BookSourceSearchRequest request,
  ) {
    void applyListFilter(BookSourceFilterRule? rule, List<String> values) {
      if (rule == null || values.isEmpty) return;
      final mapped = <String>[];
      for (final raw in values) {
        var val =
            rule.map[raw] ??
            rule.map[raw.toLowerCase()] ??
            rule.map[raw.toUpperCase()] ??
            raw;
        if (rule.transform == 'lower') {
          val = val.toLowerCase();
        } else if (rule.transform == 'upper') {
          val = val.toUpperCase();
        }
        if (val.isNotEmpty) mapped.add(val);
      }
      if (mapped.isEmpty) return;
      if (rule.mode == 'repeat') {
        for (final v in mapped) {
          target.add(MapEntry<String, String>(rule.param, v));
        }
      } else if (rule.mode == 'join') {
        target.add(MapEntry<String, String>(rule.param, mapped.join(rule.joinWith)));
      } else {
        target.add(MapEntry<String, String>(rule.param, mapped.first));
      }
    }

    applyListFilter(filters.extensions, request.extensions);
    applyListFilter(filters.languages, request.languages);

    if (filters.yearFrom != null &&
        (request.yearFrom > 0 || !filters.yearFrom!.omitIfZero)) {
      target.add(
        MapEntry<String, String>(filters.yearFrom!.param, '${request.yearFrom}'),
      );
    }
    if (filters.yearTo != null &&
        (request.yearTo > 0 || !filters.yearTo!.omitIfZero)) {
      target.add(
        MapEntry<String, String>(filters.yearTo!.param, '${request.yearTo}'),
      );
    }
    if (filters.order != null) {
      final raw = request.order.trim();
      final mapped = filters.order!.map[raw] ?? raw;
      if (mapped.isNotEmpty) {
        target.add(MapEntry<String, String>(filters.order!.param, mapped));
      }
    }
  }

  Map<String, String> _renderHeaders(
    Map<String, String> raw,
    Map<String, Object?> ctx, {
    Map<String, String>? randCache,
  }) {
    if (raw.isEmpty) return const <String, String>{};
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final rendered = _extractor
          .renderTemplate(entry.value, ctx, randCache: randCache)
          .trim();
      if (rendered.isNotEmpty) {
        out[entry.key] = rendered;
      }
    }
    return out;
  }

  static String _joinCookies({
    String? existing,
    required Map<String, String> extra,
  }) {
    final merged = <String, String>{};
    if (existing != null && existing.trim().isNotEmpty) {
      for (final part in existing.split(';')) {
        final idx = part.indexOf('=');
        if (idx > 0) {
          merged[part.substring(0, idx).trim()] = part
              .substring(idx + 1)
              .trim();
        }
      }
    }
    merged.addAll(extra);
    return merged.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  static String _encodePairs(List<MapEntry<String, String>> pairs) {
    return pairs
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
  }

  static String _appendQueryPairs(
    String baseUrl,
    List<MapEntry<String, String>> pairs,
  ) {
    if (pairs.isEmpty) return baseUrl;
    final sep = baseUrl.contains('?') ? '&' : '?';
    return '$baseUrl$sep${_encodePairs(pairs)}';
  }

  static List<String> _splitRef(String ref, String sep) {
    if (sep.isEmpty) return <String>[ref];
    return ref.split(sep);
  }

  static int? _tryParsePositiveInt(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString().trim());
  }

  static bool _matchesAnySuccessValue(Object val, List<Object?> allowed) {
    if (allowed.isEmpty) return true;
    for (final item in allowed) {
      if (val == item) return true;
      if (val.toString() == item.toString()) return true;
    }
    return false;
  }

  static String _defaultMessageForErrorCode(String code, int status) {
    switch (code) {
      case 'SESSION_EXPIRED':
        return '书源会话已失效，请重新登录或更新凭据';
      case 'QUOTA_EXCEEDED':
        return '今日下载配额已用尽';
      case 'NOT_FOUND':
        return '未找到该图书';
      case 'PROVIDER_NOT_CONFIGURED':
        return '请先配置该书源账号凭据';
      case 'PROVIDER_BLOCKED':
        return '书源节点被反爬拦截（HTTP $status）';
      default:
        return '书源请求失败（HTTP $status）';
    }
  }
}

class _BuiltHttpCall {
  const _BuiltHttpCall({
    required this.method,
    required this.url,
    this.headers = const <String, String>{},
    this.body,
    this.contentType,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final Object? body;
  final String? contentType;
}

class _PreparedAuth {
  const _PreparedAuth({
    this.headers = const <String, String>{},
    this.query = const <MapEntry<String, String>>[],
    this.authHeaderNames = const <String>{},
  });

  final Map<String, String> headers;
  final List<MapEntry<String, String>> query;
  final Set<String> authHeaderNames;
}
