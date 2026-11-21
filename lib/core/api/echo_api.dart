import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/token_store.dart';
import 'models.dart';

/// Echo 客户端对 echo-service 的 API 层。
///
/// - Bearer Token 自动注入；
/// - 401 时自动 `POST /api/auth/token/refresh` 轮换并重放原请求一次；
/// - refresh 失败则清除 Token 并回调 [onSessionExpired]；
/// - 所有错误统一为 [ApiException]（服务端 `{"error":{code,message}}` 契约）。
class EchoApi {
  EchoApi({
    Uri? baseUri,
    TokenStore? tokenStore,
    Dio? dio,
    VoidCallback? onSessionExpired,
  })  : _tokenStore = tokenStore ?? SecureTokenStore(),
        _onSessionExpired = onSessionExpired {
    _dio = dio ??
        Dio(
          BaseOptions(
            baseUrl: (baseUri ?? Uri.parse('http://127.0.0.1:8090')).toString(),
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 60),
            contentType: 'application/json',
          ),
        );
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: _attachToken,
        onError: _handleUnauthorized,
      ),
    );
  }

  late final Dio _dio;
  final TokenStore _tokenStore;
  final VoidCallback? _onSessionExpired;

  /// 这些端点自身 401 时不进入 refresh 重放（避免循环）。
  static const _noRetryPaths = {'/api/auth/token', '/api/auth/token/refresh'};

  String get baseUrl => _dio.options.baseUrl;

  /// 将服务端返回的相对媒体地址（如 `/api/files/audiobooks/1?variant=chapter&n=0`）
  /// 解析为完整 URI。
  Uri resolveUri(String pathOrUrl) {
    final parsed = Uri.parse(pathOrUrl);
    if (parsed.hasScheme) return parsed;
    return Uri.parse(_dio.options.baseUrl).resolveUri(parsed);
  }

  /// 为媒体播放器（just_audio）构造带 Bearer Token 的请求头。
  Future<Map<String, String>> authHeaders() async {
    final token = await _tokenStore.read();
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  // ---- 认证 ----

  /// App 登录：账密换取 Bearer Token（README「认证」节）。
  Future<AuthToken> login({
    required String email,
    required String password,
    String device = 'Echo',
  }) async =>
      AuthToken.fromJson(await _postJson(
        '/api/auth/token',
        {'email': email, 'password': password, 'name': device},
      ));

  /// 轮换 Token（旧 Token 立即失效）。
  Future<AuthToken> refreshToken() async =>
      AuthToken.fromJson(await _postJson('/api/auth/token/refresh', null));

  /// 撤销当前 Token。
  Future<void> revoke() async => _postJson('/api/auth/token/revoke', null);

  /// 当前用户与会话信息。
  Future<MeInfo> me() async => MeInfo.fromJson(await _getJson('/api/auth/me'));

  /// 注册（App 内注册，随后调用 [login] 换取 Token）。
  Future<void> register({
    required String email,
    required String password,
  }) async =>
      _postJson('/api/auth/register', {'email': email, 'password': password});

  // ---- 书库（/api/library）----

  /// 已下载书籍列表：`GET /api/library` → `{"books":[...]}`
  Future<List<LibraryBook>> listBooks() async {
    final json = await _getJson('/api/library');
    return (json['books'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(LibraryBook.fromJson)
        .toList();
  }

  /// 书籍详情（含关联有声书列表）：`GET /api/library/{id}`
  Future<BookDetail> getBook(int id) async =>
      BookDetail.fromJson(await _getJson('/api/library/$id'));

  /// 删除书库书籍：`DELETE /api/library/{id}`
  Future<void> deleteBook(int id) async => _deleteJson('/api/library/$id');

  // ---- 有声书（/api/audiobooks）----

  /// 有声书列表：`GET /api/audiobooks` → `{"audiobooks":[...]}`
  Future<List<AudiobookInfo>> listAudiobooks() async {
    final json = await _getJson('/api/audiobooks');
    return (json['audiobooks'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AudiobookInfo.fromJson)
        .toList();
  }

  /// 单个有声书详情：`GET /api/audiobooks/{id}` → `{"audiobook":{...}}`
  Future<AudiobookInfo> getAudiobook(int id) async {
    final json = await _getJson('/api/audiobooks/$id');
    final raw = json['audiobook'];
    return raw is Map<String, dynamic>
        ? AudiobookInfo.fromJson(raw)
        : AudiobookInfo.fromJson(json);
  }

  /// 删除有声书：`DELETE /api/audiobooks/{id}`
  Future<void> deleteAudiobook(int id) async =>
      _deleteJson('/api/audiobooks/$id');

  /// 分章播放清单：`GET /api/audiobooks/{id}/chapters`
  Future<ChaptersManifestInfo> getAudiobookChapters(int id) async =>
      ChaptersManifestInfo.fromJson(
        await _getJson('/api/audiobooks/$id/chapters'),
      );

  /// 下载书籍文件字节（EPUB 导出用）。
  Future<List<int>> downloadBookBytes(int bookId) async {
    try {
      final response = await _dio.get<List<int>>(
        '/api/files/books/$bookId',
        options: Options(responseType: ResponseType.bytes),
      );
      return response.data ?? const <int>[];
    } on DioException catch (e) {
      throw ApiException.fromResponse(e.response);
    }
  }

  /// 拉取 SRT 字幕文本（如 `/api/files/audiobooks/1?variant=chapter_srt&n=0`）。
  Future<String> fetchText(String pathOrUrl) async {
    try {
      final response = await _dio.get<String>(
        pathOrUrl,
        options: Options(responseType: ResponseType.plain),
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw ApiException.fromResponse(e.response);
    }
  }

  // ---- 书源与账号（providers.go）----

  /// 书源列表与账号状态：`GET /api/providers` → `{"providers":[...]}`
  Future<List<ProviderInfo>> listProviders() async {
    final json = await _getJson('/api/providers');
    return (json['providers'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ProviderInfo.fromJson)
        .toList();
  }

  /// 保存书源账号凭据：`PUT /api/providers/{id}/account`
  ///
  /// [mode] 为 `password`（[email]+[password] 登录）或 `cookies`
  /// （[remixUserId]+[remixUserKey] 导入）。凭据只存服务端（AES-256-GCM），
  /// 保存动作本身会执行一次验证。
  Future<ProviderAccountInfo> saveProviderAccount({
    required String providerId,
    required String mode,
    String domain = '',
    String email = '',
    String password = '',
    String remixUserId = '',
    String remixUserKey = '',
  }) async {
    final json = await _putJson(
      '/api/providers/$providerId/account',
      <String, dynamic>{
        'mode': mode,
        'domain': domain,
        'email': email,
        'password': password,
        'remix_userid': remixUserId,
        'remix_userkey': remixUserKey,
      },
    );
    final raw = json['account'];
    return raw is Map<String, dynamic>
        ? ProviderAccountInfo.fromJson(raw)
        : const ProviderAccountInfo(configured: false);
  }

  /// 重新验证账号并刷新配额：`POST /api/providers/{id}/account/verify`
  Future<ProviderAccountInfo> verifyProviderAccount(String providerId) async {
    final json = await _postJson('/api/providers/$providerId/account/verify', null);
    final raw = json['account'];
    return raw is Map<String, dynamic>
        ? ProviderAccountInfo.fromJson(raw)
        : const ProviderAccountInfo(configured: false);
  }

  /// 删除书源账号：`DELETE /api/providers/{id}/account`
  Future<void> deleteProviderAccount(String providerId) async =>
      _deleteJson('/api/providers/$providerId/account');

  // ---- 搜索（search.go）----

  /// 跨书源搜索：`GET /api/search`
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
  }) async {
    final params = <String, String>{
      'provider': provider,
      'q': query,
      'page': '$page',
      'limit': '$limit',
      if (extensions.isNotEmpty) 'ext': extensions.join(','),
      if (languages.isNotEmpty) 'lang': languages.join(','),
      if (yearFrom > 0) 'year_from': '$yearFrom',
      if (yearTo > 0) 'year_to': '$yearTo',
      if (order.isNotEmpty) 'order': order,
    };
    final uri = Uri(path: '/api/search', queryParameters: params);
    return SearchPageInfo.fromJson(await _getJson(uri.toString()));
  }

  /// 书源侧图书详情：`GET /api/providers/{id}/books/{ref}`
  Future<SearchBook> providerBook({
    required String providerId,
    required String ref,
  }) async {
    final json =
        await _getJson('/api/providers/$providerId/books/${Uri.encodeComponent(ref)}');
    final raw = json['book'];
    return raw is Map<String, dynamic> ? SearchBook.fromJson(raw) : SearchBook.fromJson(json);
  }

  // ---- 下载与转换任务（library.go / jobs.go）----

  /// 发起下载入书库（异步任务）：`POST /api/library/download` → `{"job":...}`
  Future<JobInfo> downloadBook({
    required String provider,
    required String ref,
  }) async {
    final json = await _postJson(
      '/api/library/download',
      <String, dynamic>{'provider': provider, 'ref': ref},
    );
    return _jobFromEnvelope(json);
  }

  /// 发起转有声书任务（仅 EPUB）：`POST /api/library/{id}/audiobooks` → `{"job":...}`
  Future<JobInfo> createAudiobook({
    required int bookId,
    required String model,
    String voice = '',
    double speed = 1.0,
    String instruct = '',
    String fallbackModel = '',
    List<int> chapters = const <int>[],
  }) async {
    final json = await _postJson(
      '/api/library/$bookId/audiobooks',
      <String, dynamic>{
        'model': model,
        'voice': voice,
        'speed': speed,
        'instruct': instruct,
        'fallback_model': fallbackModel,
        'chapters': chapters,
      },
    );
    return _jobFromEnvelope(json);
  }

  /// 任务列表：`GET /api/jobs?limit=&offset=`
  Future<JobsPageInfo> listJobs({int limit = 20, int offset = 0}) async {
    final uri = Uri(path: '/api/jobs', queryParameters: <String, String>{
      'limit': '$limit',
      'offset': '$offset',
    });
    return JobsPageInfo.fromJson(await _getJson(uri.toString()));
  }

  /// 取消任务：`POST /api/jobs/{id}/cancel`
  Future<JobInfo> cancelJob(int id) async =>
      _jobFromEnvelope(await _postJson('/api/jobs/$id/cancel', null));

  // ---- 章节预览（EPUB 解析结果）----

  /// 章节预览/正文清单：`GET /api/library/{id}/chapters`（`?full=1` 含正文）。
  Future<List<ChapterPreview>> bookChapters(
    int bookId, {
    bool full = false,
  }) async {
    final json = await _getJson(
      full ? '/api/library/$bookId/chapters?full=1' : '/api/library/$bookId/chapters',
    );
    return (json['chapters'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ChapterPreview.fromJson)
        .toList();
  }

  // ---- TTS 能力（tts.go，经 echo-service 代理局域网 tts-service）----

  /// TTS 模型列表（含健康状态）：`GET /api/tts/models`
  Future<TtsModelsResponse> ttsModels() async =>
      TtsModelsResponse.fromJson(await _getJson('/api/tts/models'));

  /// 指定模型的音色列表：`GET /api/tts/voices?model=`
  Future<List<TtsVoiceInfo>> ttsVoices(String model) async {
    final uri = Uri(
      path: '/api/tts/voices',
      queryParameters: <String, String>{'model': model},
    );
    final json = await _getJson(uri.toString());
    return (json['voices'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TtsVoiceInfo.fromJson)
        .toList();
  }

  /// 音色试听地址（WAV，需携带 Bearer 头）。
  Uri ttsSampleUrl(String model, String voice) => resolveUri(
        Uri(path: '/api/tts/sample', queryParameters: <String, String>{
          'model': model,
          if (voice.isNotEmpty) 'voice': voice,
        }).toString(),
      );

  static JobInfo _jobFromEnvelope(Map<String, dynamic> json) {
    final raw = json['job'];
    return raw is Map<String, dynamic> ? JobInfo.fromJson(raw) : JobInfo.fromJson(json);
  }

  // ---- 拦截器 ----

  Future<void> _attachToken(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _tokenStore.read();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  Future<void> _handleUnauthorized(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final status = err.response?.statusCode;
    final path = err.requestOptions.uri.path;
    if (status != 401 || _noRetryPaths.contains(path)) {
      handler.next(err);
      return;
    }
    try {
      final refreshed = await refreshToken();
      await _tokenStore.write(refreshed.token);
      final options = err.requestOptions
        ..headers['Authorization'] = 'Bearer ${refreshed.token}';
      final response = await _dio.fetch(options);
      handler.resolve(response);
    } on ApiException {
      // refresh 也失败：清理凭据并通知会话过期。
      await _tokenStore.clear();
      _onSessionExpired?.call();
      handler.next(err);
    }
  }

  // ---- 基础请求 ----

  Future<Map<String, dynamic>> _getJson(String path) async {
    try {
      final response = await _dio.get<dynamic>(path);
      return _asJsonMap(response.data);
    } on DioException catch (e) {
      throw ApiException.fromResponse(e.response);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic>? body,
  ) async {
    try {
      final response = await _dio.post<dynamic>(path, data: body);
      return _asJsonMap(response.data);
    } on DioException catch (e) {
      throw ApiException.fromResponse(e.response);
    }
  }

  Future<Map<String, dynamic>> _deleteJson(String path) async {
    try {
      final response = await _dio.delete<dynamic>(path);
      return _asJsonMap(response.data);
    } on DioException catch (e) {
      throw ApiException.fromResponse(e.response);
    }
  }

  Future<Map<String, dynamic>> _putJson(
    String path,
    Map<String, dynamic>? body,
  ) async {
    try {
      final response = await _dio.put<dynamic>(path, data: body);
      return _asJsonMap(response.data);
    } on DioException catch (e) {
      throw ApiException.fromResponse(e.response);
    }
  }

  static Map<String, dynamic> _asJsonMap(Object? data) =>
      data is Map<String, dynamic> ? data : const <String, dynamic>{};
}
