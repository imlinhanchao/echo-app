import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../books/local_library_store.dart';
import '../settings/standalone_config_store.dart';
import '../tts/local_convert_service.dart';
import '../tts/system_tts_engine.dart';
import '../tts/tts_model_catalog.dart';
import '../tts/tts_model_manager.dart';
import 'ebook_api_client.dart';
import 'echo_api.dart';
import 'models.dart';
import 'provider_token_store.dart';

/// 单机版核心 API 实现（继承 [EchoApi] 契约，完全摆脱 `echo-service`）：
/// - 书库与章节 -> [LocalLibraryStore]
/// - 搜书、书源凭据与流式下载 -> [EbookApiClient] + [ProviderTokenStore]
/// - TTS 模型与音色 -> [TtsModelManager] + [TtsModelCatalog]
/// - 本地下载 / 本地转有声书任务 -> 内存任务队列 + [LocalConvertService]
/// - 云端同步 -> 静默空操作
class StandaloneEchoApi extends EchoApi {
  StandaloneEchoApi({
    required LocalLibraryStore libraryStore,
    required EbookApiClient Function() readEbookApi,
    required ProviderTokenStore tokenStore,
    required TtsModelManager ttsModelManager,
    required LocalConvertService convertService,
    required StandaloneConfig Function() readConfig,
    void Function()? onLibraryChanged,
  }) : _libraryStore = libraryStore,
       _readEbookApi = readEbookApi,
       _tokenStore = tokenStore,
       _ttsModelManager = ttsModelManager,
       _convertService = convertService,
       _readConfig = readConfig,
       _onLibraryChanged = onLibraryChanged,
       super(baseUri: Uri.parse('http://localhost'));

  final LocalLibraryStore _libraryStore;
  final EbookApiClient Function() _readEbookApi;
  final ProviderTokenStore _tokenStore;
  final TtsModelManager _ttsModelManager;
  final LocalConvertService _convertService;
  final StandaloneConfig Function() _readConfig;
  final void Function()? _onLibraryChanged;

  final List<JobInfo> _jobs = <JobInfo>[];
  final Map<int, CancelToken> _downloadCancelTokens = <int, CancelToken>{};
  final Set<int> _cancelledConvertJobs = <int>{};
  int _nextJobId = 1;

  /// 记录最近一次搜索结果，用于下载入库时保留标题/作者/封面元数据。
  final Map<String, SearchBook> _searchCache = <String, SearchBook>{};

  @override
  String get baseUrl => _readConfig().ebookApiBaseUrl;

  @override
  Future<Map<String, String>> authHeaders() async => const <String, String>{};

  // ---- 认证（单机模式无账号系统）----

  @override
  Future<MeInfo> me() async => const MeInfo(
    user: EchoUser(id: 0, email: 'local', name: '单机书库'),
    registrationOpen: false,
  );

  // ---- 本地书库 ----

  @override
  Future<List<LibraryBook>> listBooks() => _libraryStore.listBooks();

  @override
  Future<BookDetail> getBook(int id) => _libraryStore.getBookDetail(id);

  @override
  Future<void> deleteBook(int id) => _libraryStore.deleteBook(id);

  @override
  Future<List<AudiobookInfo>> listAudiobooks() =>
      _libraryStore.listAudiobooks();

  @override
  Future<AudiobookInfo> getAudiobook(int id) async {
    final list = await _libraryStore.listAudiobooks();
    for (final a in list) {
      if (a.id == id) return a;
    }
    throw const ApiException(code: 'NOT_FOUND', message: '未找到本地有声书');
  }

  @override
  Future<void> deleteAudiobook(int id) => _libraryStore.deleteAudiobook(id);

  @override
  Future<ChaptersManifestInfo> getAudiobookChapters(int id) async {
    final manifest = await _libraryStore.readChaptersManifest(id);
    if (manifest == null) {
      throw const ApiException(code: 'NOT_FOUND', message: '有声书分块尚未生成');
    }
    return manifest;
  }

  @override
  Future<List<int>> downloadBookBytes(int bookId) async {
    final file = await _libraryStore.getSourceFile(bookId);
    if (file == null) {
      throw const ApiException(code: 'NOT_FOUND', message: '本地书籍源文件不存在');
    }
    return file.readAsBytes();
  }

  @override
  Future<String> fetchText(String pathOrUrl) async {
    if (pathOrUrl.startsWith('file://')) {
      final file = File.fromUri(Uri.parse(pathOrUrl));
      if (await file.exists()) return file.readAsString();
      return '';
    }
    final direct = File(pathOrUrl);
    if (await direct.exists()) return direct.readAsString();
    return '';
  }

  @override
  Future<List<ChapterPreview>> bookChapters(
    int bookId, {
    bool full = false,
  }) async {
    final chapters = await _libraryStore.listChapters(bookId);
    if (full) return chapters;
    return chapters
        .map(
          (c) => ChapterPreview(
            index: c.index,
            title: c.title,
            chars: c.chars,
            preview: c.preview,
          ),
        )
        .toList();
  }

  // ---- ebook-api 书源与搜书 ----

  @override
  Future<List<ProviderInfo>> listProviders() => _readEbookApi().listProviders();

  @override
  Future<ProviderAccountInfo> saveProviderAccount({
    required String providerId,
    required String mode,
    String domain = '',
    String email = '',
    String password = '',
    String remixUserId = '',
    String remixUserKey = '',
  }) async {
    final api = _readEbookApi();
    final ProviderSealResult sealed;
    if (mode == 'cookies') {
      final creds = <String, String>{
        if (domain.trim().isNotEmpty) 'domain': domain.trim(),
        if (remixUserId.trim().isNotEmpty) 'remix_userid': remixUserId.trim(),
        if (remixUserKey.trim().isNotEmpty)
          'remix_userkey': remixUserKey.trim(),
      };
      sealed = await api.sealProvider(
        providerId: providerId,
        credentials: creds,
        verify: true,
      );
    } else {
      sealed = await api.loginProvider(
        providerId: providerId,
        domain: domain,
        email: email,
        password: password,
      );
    }

    final account =
        sealed.account ??
        const ProviderAccountInfo(configured: true, status: 'ok');
    await _tokenStore.write(
      StoredProviderCredential(
        providerId: providerId,
        credentialToken: sealed.credentialToken,
        account: account,
      ),
    );
    return account;
  }

  @override
  Future<ProviderAccountInfo> verifyProviderAccount(String providerId) =>
      _readEbookApi().verifyProvider(providerId);

  @override
  Future<void> deleteProviderAccount(String providerId) =>
      _tokenStore.delete(providerId);

  @override
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
    final api = _readEbookApi();
    if (!api.isConfigured) {
      throw const ApiException(
        code: 'EBOOK_API_NOT_CONFIGURED',
        message: '已跳过书源配置，暂无法在线搜书，请先配置书源服务或直接导入本地书籍',
      );
    }
    final res = await api.search(
      query: query,
      provider: provider,
      page: page,
      limit: limit,
      extensions: extensions,
      languages: languages,
      yearFrom: yearFrom,
      yearTo: yearTo,
      order: order,
    );
    for (final b in res.books) {
      _searchCache['${b.provider}:${b.ref}'] = b;
    }
    return res;
  }

  // ---- 本地异步任务（下载 + 本地转有声书）----

  @override
  Future<JobInfo> downloadBook({
    required String provider,
    required String ref,
  }) async {
    final api = _readEbookApi();
    if (!api.isConfigured) {
      throw const ApiException(
        code: 'EBOOK_API_NOT_CONFIGURED',
        message: '请先在「我的 → ebook-api 配置」填写服务地址',
      );
    }

    final jobId = _nextJobId++;
    final now = DateTime.now().toUtc();
    final cachedMeta = _searchCache['$provider:$ref'];
    final job = JobInfo(
      id: jobId,
      kind: JobKind.download,
      status: JobStatus.running,
      progress: 0,
      createdAt: now,
      startedAt: now,
      result: <String, dynamic>{
        'title': cachedMeta?.title ?? ref,
        'provider': provider,
      },
    );
    _upsertJob(job);

    final cancelToken = CancelToken();
    _downloadCancelTokens[jobId] = cancelToken;

    unawaited(
      _runDownloadJob(
        jobId: jobId,
        api: api,
        provider: provider,
        ref: ref,
        meta: cachedMeta,
        cancelToken: cancelToken,
      ),
    );
    return job;
  }

  Future<void> _runDownloadJob({
    required int jobId,
    required EbookApiClient api,
    required String provider,
    required String ref,
    required SearchBook? meta,
    required CancelToken cancelToken,
  }) async {
    File? tmpFile;
    try {
      final tmpDir = await getTemporaryDirectory();
      final extHint = (meta?.format ?? 'epub').toLowerCase();
      final safeExt = (extHint == 'txt' || extHint == 'epub')
          ? extHint
          : 'epub';
      tmpFile = File(p.join(tmpDir.path, 'echo_dl_$jobId.$safeExt'));

      final downloaded = await api.downloadBook(
        providerId: provider,
        ref: ref,
        savePath: tmpFile.path,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          final pct = total > 0 ? ((received / total) * 90).round() : 20;
          _updateJob(jobId, progress: pct.clamp(1, 90));
        },
      );

      _updateJob(jobId, progress: 92);
      final resolvedExt = downloaded.format.isNotEmpty
          ? downloaded.format
          : safeExt;
      final filename = downloaded.filename.isNotEmpty
          ? downloaded.filename
          : '${meta?.title ?? "book_$jobId"}.$resolvedExt';

      final book = await _libraryStore.importFile(
        tmpFile,
        filenameOverride: filename,
        provider: provider,
        providerBookId: ref,
        titleOverride: meta?.title,
        authorsOverride: meta?.authors,
        coverUrlFallback: meta?.coverUrl,
      );

      _updateJob(
        jobId,
        status: JobStatus.done,
        progress: 100,
        refId: book.id,
        finishedAt: DateTime.now().toUtc(),
        result: <String, dynamic>{
          'title': book.title,
          'book_id': book.id,
        },
      );
      _onLibraryChanged?.call();
    } on ApiException catch (e) {
      final isCancelled = e.code == 'CANCELLED';
      _updateJob(
        jobId,
        status: isCancelled ? JobStatus.cancelled : JobStatus.failed,
        error: e.message,
        finishedAt: DateTime.now().toUtc(),
      );
    } catch (e) {
      _updateJob(
        jobId,
        status: JobStatus.failed,
        error: e.toString(),
        finishedAt: DateTime.now().toUtc(),
      );
    } finally {
      _downloadCancelTokens.remove(jobId);
      if (tmpFile != null && await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Future<JobInfo> createAudiobook({
    required int bookId,
    required String model,
    String voice = '',
    double speed = 1.0,
    String instruct = '',
    String fallbackModel = '',
    List<int> chapters = const <int>[],
  }) async {
    final book = await _libraryStore.getBook(bookId);
    if (book == null) {
      throw const ApiException(code: 'NOT_FOUND', message: '本地书库中未找到该书');
    }

    final entry = _ttsModelManager.currentState.entryOf(model);
    final resolvedPaths = (entry != null && entry.isInstalled)
        ? entry.resolvedPaths!
        : _ttsModelManager.activeModelPaths;
    if (resolvedPaths == null) {
      throw const ApiException(
        code: 'NO_TTS_MODEL',
        message: '尚未下载任何端侧语音模型，请先前往「我的 → 语音模型管理」下载',
      );
    }

    final int speakerId;
    final String voiceLabel;
    final ResolvedTtsModelPaths effectivePaths;
    if (resolvedPaths.spec.isSystemTts) {
      speakerId = 0;
      final chosenVoice = voice.trim().isNotEmpty
          ? voice.trim()
          : resolvedPaths.systemVoiceName;
      effectivePaths = resolvedPaths.copyWith(systemVoiceName: chosenVoice);
      final matched = _ttsModelManager.currentState.systemVoices
          .cast<SystemTtsVoiceInfo?>()
          .firstWhere((v) => v?.name == chosenVoice, orElse: () => null);
      voiceLabel =
          matched?.label ??
          (chosenVoice.isNotEmpty ? chosenVoice : '系统默认音色');
    } else {
      speakerId = int.tryParse(voice) ?? resolvedPaths.spec.speakers.first.id;
      final speakerPreset = resolvedPaths.spec.speakers
          .cast<TtsSpeakerPreset?>()
          .firstWhere((s) => s?.id == speakerId, orElse: () => null);
      voiceLabel = speakerPreset?.name ?? '音色 #$speakerId';
      effectivePaths = resolvedPaths;
    }

    final jobId = _nextJobId++;
    final now = DateTime.now().toUtc();
    final job = JobInfo(
      id: jobId,
      kind: JobKind.audiobook,
      status: JobStatus.running,
      progress: 0,
      refId: bookId,
      createdAt: now,
      startedAt: now,
      result: <String, dynamic>{
        'title': book.title,
        'model': effectivePaths.spec.name,
      },
    );
    _upsertJob(job);

    unawaited(
      _runConvertJob(
        jobId: jobId,
        book: book,
        modelPaths: effectivePaths,
        speakerId: speakerId,
        voiceLabel: voiceLabel,
        speed: speed,
        chapters: chapters,
      ),
    );
    return job;
  }

  Future<void> _runConvertJob({
    required int jobId,
    required LibraryBook book,
    required ResolvedTtsModelPaths modelPaths,
    required int speakerId,
    required String voiceLabel,
    required double speed,
    required List<int> chapters,
  }) async {
    try {
      final info = await _convertService.convertBook(
        book: book,
        modelPaths: modelPaths,
        speakerId: speakerId,
        voiceLabel: voiceLabel,
        speed: speed,
        chapterIndices: chapters.isEmpty ? null : chapters,
        isCancelled: () => _cancelledConvertJobs.contains(jobId),
        onProgress: (pct, _) {
          _updateJob(jobId, progress: pct);
        },
      );
      if (_cancelledConvertJobs.remove(jobId) || info.status == 'cancelled') {
        _updateJob(
          jobId,
          status: JobStatus.cancelled,
          finishedAt: DateTime.now().toUtc(),
        );
      } else {
        _updateJob(
          jobId,
          status: JobStatus.done,
          progress: 100,
          refId: info.id,
          finishedAt: DateTime.now().toUtc(),
          result: <String, dynamic>{
            'title': book.title,
            'audiobook_id': info.id,
          },
        );
      }
      _onLibraryChanged?.call();
    } catch (e) {
      _cancelledConvertJobs.remove(jobId);
      _updateJob(
        jobId,
        status: JobStatus.failed,
        error: e.toString(),
        finishedAt: DateTime.now().toUtc(),
      );
      _onLibraryChanged?.call();
    }
  }

  @override
  Future<JobsPageInfo> listJobs({int limit = 20, int offset = 0}) async {
    final sliced = _jobs.skip(offset).take(limit).toList();
    return JobsPageInfo(jobs: sliced, total: _jobs.length);
  }

  @override
  Future<JobInfo> cancelJob(int id) async {
    _downloadCancelTokens[id]?.cancel('user_cancelled');
    _cancelledConvertJobs.add(id);
    _updateJob(id, status: JobStatus.cancelling);
    for (final j in _jobs) {
      if (j.id == id) return j;
    }
    throw const ApiException(code: 'NOT_FOUND', message: '任务不存在');
  }

  // ---- 本地 TTS 模型与音色清单 ----

  @override
  Future<TtsModelsResponse> ttsModels() async {
    if (!_ttsModelManager.currentState.initialized) {
      await _ttsModelManager.refresh();
    }
    final modelsState = _ttsModelManager.currentState;
    final installed = modelsState.installedEntries;
    final cfg = _readConfig();
    final activeId = cfg.activeTtsModelId;
    final models = installed.map((entry) {
      final spec = entry.spec;
      final isDef = activeId.isNotEmpty
          ? spec.id == activeId
          : installed.first.spec.id == spec.id;
      if (spec.isSystemTts) {
        final sysVoices = modelsState.systemVoices;
        final voiceIds = sysVoices.isNotEmpty
            ? sysVoices.map((v) => v.name).toList()
            : <String>[
                cfg.systemTtsVoice.isNotEmpty ? cfg.systemTtsVoice : '',
              ];
        return TtsModelInfo(
          id: spec.id,
          repo: spec.name,
          isDefault: isDef,
          provider: 'android_system',
          voices: voiceIds,
        );
      }
      return TtsModelInfo(
        id: spec.id,
        repo: spec.name,
        isDefault: isDef,
        provider: 'local',
        voices: spec.speakers.map((s) => '${s.id}').toList(),
      );
    }).toList();

    return TtsModelsResponse(
      models: models,
      maxJobChars: 0,
      ttsHealthy: installed.isNotEmpty,
    );
  }

  @override
  Future<List<TtsVoiceInfo>> ttsVoices(String model) async {
    if (model == TtsModelCatalog.androidSystemTts.id) {
      final cfg = _readConfig();
      final voices = _ttsModelManager.currentState.systemVoices;
      if (voices.isNotEmpty) {
        return voices
            .map(
              (v) => TtsVoiceInfo(
                id: v.name,
                name: v.label.isNotEmpty ? v.label : v.name,
                description: v.locale,
              ),
            )
            .toList();
      }
      return <TtsVoiceInfo>[
        TtsVoiceInfo(
          id: cfg.systemTtsVoice,
          name: cfg.systemTtsVoice.isNotEmpty ? cfg.systemTtsVoice : '系统引擎默认音色',
          description: cfg.systemTtsEngine.isNotEmpty
              ? cfg.systemTtsEngine
              : '本机默认引擎',
        ),
      ];
    }
    final spec = TtsModelCatalog.byId(model);
    if (spec == null) return const <TtsVoiceInfo>[];
    return spec.speakers
        .map(
          (s) => TtsVoiceInfo(
            id: '${s.id}',
            name: s.name,
            description: s.tag,
          ),
        )
        .toList();
  }

  // ---- 云端同步：单机版静默空操作 ----

  @override
  Future<List<SyncProgressItem>> getCloudProgress() async =>
      const <SyncProgressItem>[];

  @override
  Future<void> pushCloudProgress(List<SyncProgressItem> items) async {}

  @override
  Future<List<SyncNoteItem>> getCloudNotes({int? audiobookId}) async =>
      const <SyncNoteItem>[];

  @override
  Future<void> pushCloudNotes(List<SyncNoteItem> notes) async {}

  @override
  Future<void> deleteCloudNote(String noteId) async {}

  void _upsertJob(JobInfo job) {
    final idx = _jobs.indexWhere((j) => j.id == job.id);
    if (idx >= 0) {
      _jobs[idx] = job;
    } else {
      _jobs.insert(0, job);
    }
  }

  void _updateJob(
    int jobId, {
    JobStatus? status,
    int? progress,
    int? refId,
    String? error,
    DateTime? finishedAt,
    Map<String, dynamic>? result,
  }) {
    final idx = _jobs.indexWhere((j) => j.id == jobId);
    if (idx < 0) return;
    final old = _jobs[idx];
    _jobs[idx] = JobInfo(
      id: old.id,
      kind: old.kind,
      status: status ?? old.status,
      progress: progress ?? old.progress,
      refId: refId ?? old.refId,
      error: error ?? old.error,
      createdAt: old.createdAt,
      startedAt: old.startedAt,
      finishedAt: finishedAt ?? old.finishedAt,
      result: result ?? old.result,
    );
  }
}
