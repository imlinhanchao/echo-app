import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/standalone_config_store.dart';
import 'models.dart';
import 'provider_token_store.dart';

/// ebook-api 健康检查结果。
@immutable
class EbookApiHealth {
  const EbookApiHealth({required this.ok, this.providers = const <String>[]});

  final bool ok;
  final List<String> providers;
}

/// 书源登录或凭据封装结果。
@immutable
class ProviderSealResult {
  const ProviderSealResult({
    required this.providerId,
    required this.credentialToken,
    this.account,
  });

  final String providerId;
  final String credentialToken;
  final ProviderAccountInfo? account;
}

/// 电子书流式下载结果元数据。
@immutable
class DownloadedBookFile {
  const DownloadedBookFile({
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

/// 对接独立 `ebook-api` HTTP 服务的客户端（零用户系统、基于加密凭据令牌）。
class EbookApiClient {
  EbookApiClient({
    required String baseUrl,
    String apiKey = '',
    Dio? dio,
    ProviderTokenStore? tokenStore,
  }) : _baseUrl = normalizeEbookApiUrl(baseUrl),
       _apiKey = apiKey.trim(),
       _tokenStore = tokenStore,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: normalizeEbookApiUrl(baseUrl),
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 60),
               headers: const <String, String>{'Accept': 'application/json'},
             ),
           ) {
    if (dio == null) {
      _dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (_apiKey.isNotEmpty) {
              options.headers['X-API-Key'] = _apiKey;
            }
            handler.next(options);
          },
        ),
      );
    }
  }

  final String _baseUrl;
  final String _apiKey;
  final Dio _dio;
  final ProviderTokenStore? _tokenStore;

  String get baseUrl => _baseUrl;
  bool get isConfigured => _baseUrl.isNotEmpty;

  void _ensureConfigured() {
    if (!isConfigured) {
      throw const ApiException(
        code: 'EBOOK_API_NOT_CONFIGURED',
        message: '尚未配置 ebook-api 服务地址，请先在「我的 → ebook-api 配置」中填写',
      );
    }
  }

  Map<String, dynamic> _authHeaders({String? providerToken}) {
    final headers = <String, dynamic>{};
    if (_apiKey.isNotEmpty) {
      headers['X-API-Key'] = _apiKey;
    }
    if (providerToken != null && providerToken.trim().isNotEmpty) {
      headers['X-Provider-Token'] = providerToken.trim();
    }
    return headers;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw const ApiException(code: 'CANCELLED', message: '下载已取消');
      }
      throw ApiException.fromResponse(e.response);
    }
  }

  /// `GET /health`：测试 ebook-api 连通性。
  Future<EbookApiHealth> checkHealth() async {
    _ensureConfigured();
    return _guard(() async {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/health',
        options: Options(headers: _authHeaders()),
      );
      final data = resp.data ?? const <String, dynamic>{};
      final ok = data['status'] == 'ok' || resp.statusCode == 200;
      final providers = (data['providers'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      return EbookApiHealth(ok: ok, providers: providers);
    });
  }

  /// `GET /v1/providers`：获取已启用书源列表，并与本地已保存的凭据状态合并。
  Future<List<ProviderInfo>> listProviders() async {
    _ensureConfigured();
    return _guard(() async {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/v1/providers',
        options: Options(headers: _authHeaders()),
      );
      final data = resp.data ?? const <String, dynamic>{};
      final rawList = (data['providers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final storedMap = await (_tokenStore?.readAll() ?? Future.value(const {}));
      return rawList.map((item) {
        final id = item['id'] as String? ?? '';
        final defaultConfigured = item['default_configured'] as bool? ?? false;
        final stored = storedMap[id];
        final ProviderAccountInfo? account;
        if (stored != null) {
          account =
              stored.account ??
              const ProviderAccountInfo(configured: true, status: 'ok');
        } else if (defaultConfigured) {
          account = const ProviderAccountInfo(
            configured: true,
            status: 'ok',
            email: '服务端默认凭据',
          );
        } else {
          account = const ProviderAccountInfo(configured: false);
        }
        return ProviderInfo(
          id: id,
          name: item['name'] as String? ?? id,
          capabilities: (item['capabilities'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(),
          defaultDomain: item['default_domain'] as String? ?? '',
          domains: (item['domains'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(),
          credentialKeys:
              (item['credential_keys'] as List<dynamic>? ?? const [])
                  .whereType<String>()
                  .toList(),
          account: account,
        );
      }).toList();
    });
  }

  /// `POST /v1/providers/{id}/login`：邮箱密码登录换取加密 `credential_token`。
  Future<ProviderSealResult> loginProvider({
    required String providerId,
    String domain = '',
    required String email,
    required String password,
  }) async {
    _ensureConfigured();
    return _guard(() async {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/providers/$providerId/login',
        data: <String, dynamic>{
          if (domain.trim().isNotEmpty) 'domain': domain.trim(),
          'email': email.trim(),
          'password': password,
        },
        options: Options(headers: _authHeaders()),
      );
      return _parseSealResult(providerId, resp.data);
    });
  }

  /// `POST /v1/providers/{id}/seal`：将 Cookie/凭据加密封装为 `credential_token`。
  Future<ProviderSealResult> sealProvider({
    required String providerId,
    required Map<String, String> credentials,
    bool verify = true,
  }) async {
    _ensureConfigured();
    return _guard(() async {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/providers/$providerId/seal',
        data: <String, dynamic>{'credentials': credentials, 'verify': verify},
        options: Options(headers: _authHeaders()),
      );
      return _parseSealResult(providerId, resp.data);
    });
  }

  /// `POST /v1/providers/{id}/verify`：校验令牌并获取配额信息。
  Future<ProviderAccountInfo> verifyProvider(
    String providerId, {
    String? credentialToken,
  }) async {
    _ensureConfigured();
    final token =
        credentialToken ??
        (await _tokenStore?.read(providerId))?.credentialToken;
    return _guard(() async {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/providers/$providerId/verify',
        data: const <String, dynamic>{},
        options: Options(headers: _authHeaders(providerToken: token)),
      );
      final data = resp.data ?? const <String, dynamic>{};
      final accJson = data['account'];
      final account = accJson is Map<String, dynamic>
          ? _parseAccountInfo(accJson)
          : const ProviderAccountInfo(configured: true, status: 'ok');
      if (token != null && token.isNotEmpty && _tokenStore != null) {
        await _tokenStore.write(
          StoredProviderCredential(
            providerId: providerId,
            credentialToken: token,
            account: account,
          ),
        );
      }
      return account;
    });
  }

  /// `GET /v1/search`：搜索图书（自动附带该书源本地保存的 `X-Provider-Token`）。
  Future<SearchPageInfo> search({
    required String query,
    String provider = 'zlib',
    int page = 1,
    int limit = 20,
    List<String> extensions = const <String>[],
    List<String> languages = const <String>[],
    int yearFrom = 0,
    int yearTo = 0,
    String order = '',
    String? credentialToken,
  }) async {
    _ensureConfigured();
    final resolvedProvider = provider.trim().isEmpty ? 'zlib' : provider.trim();
    final token =
        credentialToken ??
        (await _tokenStore?.read(resolvedProvider))?.credentialToken;
    return _guard(() async {
      final qp = <String, dynamic>{
        'q': query.trim(),
        'provider': resolvedProvider,
        'page': page,
        'limit': limit,
        if (extensions.isNotEmpty) 'ext': extensions.join(','),
        if (languages.isNotEmpty) 'lang': languages.join(','),
        if (yearFrom > 0) 'year_from': yearFrom,
        if (yearTo > 0) 'year_to': yearTo,
        if (order.isNotEmpty) 'order': order,
      };
      final resp = await _dio.get<Map<String, dynamic>>(
        '/v1/search',
        queryParameters: qp,
        options: Options(headers: _authHeaders(providerToken: token)),
      );
      return SearchPageInfo.fromJson(resp.data ?? const <String, dynamic>{});
    });
  }

  /// `GET /v1/providers/{id}/books/{ref}/download`：流式下载电子书到本地文件。
  Future<DownloadedBookFile> downloadBook({
    required String providerId,
    required String ref,
    required String savePath,
    String? credentialToken,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    _ensureConfigured();
    final resolvedProvider = providerId.trim().isEmpty
        ? 'zlib'
        : providerId.trim();
    final token =
        credentialToken ??
        (await _tokenStore?.read(resolvedProvider))?.credentialToken;
    return _guard(() async {
      final encodedRef = Uri.encodeComponent(ref);
      final resp = await _dio.download(
        '/v1/providers/$resolvedProvider/books/$encodedRef/download',
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        options: Options(
          headers: _authHeaders(providerToken: token),
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
      final headers = resp.headers;
      final rawName = headers.value('x-book-filename') ?? '';
      final filename = rawName.isNotEmpty
          ? Uri.decodeComponent(rawName)
          : _filenameFromDisposition(headers.value('content-disposition'));
      final format = (headers.value('x-book-format') ?? '').toLowerCase();
      final contentLength =
          int.tryParse(headers.value('content-length') ?? '') ?? 0;
      return DownloadedBookFile(
        savePath: savePath,
        filename: filename,
        format: format,
        sizeBytes: contentLength,
      );
    });
  }

  ProviderSealResult _parseSealResult(
    String providerId,
    Map<String, dynamic>? data,
  ) {
    final map = data ?? const <String, dynamic>{};
    final token = map['credential_token'] as String? ?? '';
    final accJson = map['account'];
    final account = accJson is Map<String, dynamic>
        ? _parseAccountInfo(accJson)
        : const ProviderAccountInfo(configured: true, status: 'ok');
    return ProviderSealResult(
      providerId: providerId,
      credentialToken: token,
      account: account,
    );
  }

  ProviderAccountInfo _parseAccountInfo(Map<String, dynamic> json) {
    return ProviderAccountInfo(
      configured: true,
      status: (json['status'] as String? ?? 'ok').isEmpty
          ? 'ok'
          : (json['status'] as String),
      email: json['email'] as String? ?? '',
      dailyUsed: (json['daily_used'] as num?)?.toInt() ?? 0,
      dailyLimit: (json['daily_limit'] as num?)?.toInt() ?? 0,
      dailyRemaining: (json['daily_remaining'] as num?)?.toInt() ?? 0,
      quotaKnown: json['quota_known'] as bool? ?? false,
      lastVerifiedAt: DateTime.now().toUtc(),
    );
  }

  String _filenameFromDisposition(String? header) {
    if (header == null || header.isEmpty) return '';
    final utf8Match = RegExp(
      r"filename\*=UTF-8''([^;\s]+)",
      caseSensitive: false,
    ).firstMatch(header);
    if (utf8Match != null) {
      return Uri.decodeComponent(utf8Match.group(1)!);
    }
    final basicMatch = RegExp(r'filename="([^"]+)"').firstMatch(header);
    return basicMatch?.group(1) ?? '';
  }
}

final Provider<EbookApiClient> ebookApiClientProvider =
    Provider<EbookApiClient>((ref) {
      final config = ref.watch(standaloneConfigProvider);
      final tokenStore = ref.watch(providerTokenStoreProvider);
      return EbookApiClient(
        baseUrl: config.ebookApiBaseUrl,
        apiKey: config.ebookApiKey,
        tokenStore: tokenStore,
      );
    });
