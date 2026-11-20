import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// echo-service 的数据模型。
/// 字段契约来源：internal/api/views.go（book/audiobook/job view）与
/// internal/audiobook/split.go（ChunkInfo/Manifest），信封结构经真实服务验证。

// ---- 认证 ----

@immutable
class EchoUser {
  const EchoUser({required this.id, required this.email, this.name});

  factory EchoUser.fromJson(Map<String, dynamic> json) => EchoUser(
        id: (json['id'] as num?)?.toInt() ?? 0,
        email: json['email'] as String? ?? '',
        name: json['name'] as String?,
      );

  final int id;
  final String email;
  final String? name;
}

@immutable
class AuthToken {
  const AuthToken({
    required this.token,
    required this.tokenType,
    this.expiresAt,
    this.user,
  });

  /// 对应 `POST /api/auth/token` 响应：
  /// `{"token":"echo_pat_...","token_type":"Bearer","expires_at":"...","user":{...}}`
  factory AuthToken.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    return AuthToken(
      token: json['token'] as String? ?? '',
      tokenType: json['token_type'] as String? ?? 'Bearer',
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
      user:
          userJson is Map<String, dynamic> ? EchoUser.fromJson(userJson) : null,
    );
  }

  final String token;
  final String tokenType;
  final DateTime? expiresAt;
  final EchoUser? user;
}

@immutable
class MeInfo {
  const MeInfo({required this.user, this.registrationOpen = true});

  /// 对应 `GET /api/auth/me`：`{"user":{...},"registration_open":bool}`
  factory MeInfo.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    return MeInfo(
      user: userJson is Map<String, dynamic>
          ? EchoUser.fromJson(userJson)
          : const EchoUser(id: 0, email: ''),
      registrationOpen: json['registration_open'] as bool? ?? true,
    );
  }

  final EchoUser user;
  final bool registrationOpen;
}

/// 服务端错误契约：`{"error":{"code":"...","message":"..."}}`（echo-service AGENTS.md）。
@immutable
class ApiException implements Exception {
  const ApiException({this.code, required this.message, this.statusCode});

  factory ApiException.fromResponse(Response<dynamic>? response) {
    final body = response?.data;
    if (body is Map<String, dynamic> && body['error'] is Map) {
      final error = body['error']! as Map<String, dynamic>;
      return ApiException(
        code: error['code'] as String?,
        message: (error['message'] as String?) ?? '请求失败',
        statusCode: response?.statusCode,
      );
    }
    final code = response?.statusCode;
    return ApiException(
      message: code == null ? '网络连接失败，请检查服务' : '请求失败（HTTP $code）',
      statusCode: code,
    );
  }

  final String? code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

// ---- 书库（libraryBookView）----

@immutable
class LibraryBook {
  const LibraryBook({
    required this.id,
    required this.title,
    this.provider = '',
    this.providerBookId = '',
    this.authors = const [],
    this.year = '',
    this.publisher = '',
    this.language = '',
    this.format = '',
    this.sizeBytes = 0,
    this.coverUrl = '',
    this.description = '',
    this.status = '',
  });

  /// 对应 `GET /api/library` 的 `books[]`（views.go libraryBookView）。
  factory LibraryBook.fromJson(Map<String, dynamic> json) => LibraryBook(
        id: (json['id'] as num?)?.toInt() ?? 0,
        provider: json['provider'] as String? ?? '',
        providerBookId: json['provider_book_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        authors: (json['authors'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        year: json['year'] as String? ?? '',
        publisher: json['publisher'] as String? ?? '',
        language: json['language'] as String? ?? '',
        format: json['format'] as String? ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        coverUrl: json['cover_url'] as String? ?? '',
        description: json['description'] as String? ?? '',
        status: json['status'] as String? ?? '',
      );

  final int id;
  final String provider;
  final String providerBookId;
  final String title;
  final List<String> authors;
  final String year;
  final String publisher;
  final String language;
  final String format;
  final int sizeBytes;
  final String coverUrl;
  final String description;
  final String status;
}

/// 对应 `GET /api/library/{id}`：`{"book":{...},"audiobooks":[...]}`
@immutable
class BookDetail {
  const BookDetail({this.book, this.audiobooks = const []});

  factory BookDetail.fromJson(Map<String, dynamic> json) {
    final bookJson = json['book'];
    return BookDetail(
      book: bookJson is Map<String, dynamic>
          ? LibraryBook.fromJson(bookJson)
          : null,
      audiobooks: (json['audiobooks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AudiobookInfo.fromJson)
          .toList(),
    );
  }

  final LibraryBook? book;
  final List<AudiobookInfo> audiobooks;
}

// ---- 有声书（audiobookView）----

@immutable
class AudiobookInfo {
  const AudiobookInfo({
    required this.id,
    required this.status,
    this.bookId = 0,
    this.bookTitle = '',
    this.model = '',
    this.voice = '',
    this.speed = 1.0,
    this.progress = 0,
    this.error = '',
    this.format = '',
    this.durationS = 0,
    this.sizeBytes = 0,
    this.segments = 0,
    this.chars = 0,
    this.audioUrl = '',
    this.srtUrl = '',
    this.chaptersUrl = '',
  });

  /// 对应 `GET /api/audiobooks` 的 `audiobooks[]`（views.go audiobookView）。
  factory AudiobookInfo.fromJson(Map<String, dynamic> json) => AudiobookInfo(
        id: (json['id'] as num?)?.toInt() ?? 0,
        bookId: (json['book_id'] as num?)?.toInt() ?? 0,
        bookTitle: json['book_title'] as String? ?? '',
        model: json['model'] as String? ?? '',
        voice: json['voice'] as String? ?? '',
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        status: json['status'] as String? ?? '',
        progress: (json['progress'] as num?)?.toInt() ?? 0,
        error: json['error'] as String? ?? '',
        format: json['format'] as String? ?? '',
        durationS: (json['duration_s'] as num?)?.toDouble() ?? 0,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        segments: (json['segments'] as num?)?.toInt() ?? 0,
        chars: (json['chars'] as num?)?.toInt() ?? 0,
        audioUrl: json['audio_url'] as String? ?? '',
        srtUrl: json['srt_url'] as String? ?? '',
        chaptersUrl: json['chapters_url'] as String? ?? '',
      );

  final int id;
  final int bookId;
  final String bookTitle;
  final String model;
  final String voice;
  final double speed;
  final String status;
  final int progress;
  final String error;
  final String format;
  final double durationS;
  final int sizeBytes;
  final int segments;
  final int chars;

  /// 相对路径，需经 EchoApi.resolveUrl 拼接并携带 Bearer 头。
  final String audioUrl;
  final String srtUrl;
  final String chaptersUrl;

  bool get isReady => status == 'done';
  bool get isRunning => status == 'running' || status == 'queued';
}

// ---- 分章清单（chapters.go chunkView + audiobook.ChunkInfo）----

@immutable
class ChapterChunk {
  const ChapterChunk({
    required this.n,
    required this.chapterIndex,
    required this.title,
    required this.startS,
    required this.endS,
    required this.durationS,
    required this.audioUrl,
    this.srtUrl = '',
    this.sizeBytes = 0,
    this.audioFile = '',
    this.srtFile = '',
  });

  /// 对应 `GET /api/audiobooks/{id}/chapters` 的 `chunks[]`。
  factory ChapterChunk.fromJson(Map<String, dynamic> json) => ChapterChunk(
        n: (json['n'] as num?)?.toInt() ?? 0,
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        startS: (json['start_s'] as num?)?.toDouble() ?? 0,
        endS: (json['end_s'] as num?)?.toDouble() ?? 0,
        durationS: (json['duration_s'] as num?)?.toDouble() ?? 0,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        audioFile: json['audio_file'] as String? ?? '',
        srtFile: json['srt_file'] as String? ?? '',
        audioUrl: json['audio_url'] as String? ?? '',
        srtUrl: json['srt_url'] as String? ?? '',
      );

  final int n;
  final int chapterIndex;
  final String title;
  final double startS;
  final double endS;
  final double durationS;
  final int sizeBytes;
  final String audioFile;
  final String srtFile;
  final String audioUrl;
  final String srtUrl;
}

/// 对应 `GET /api/audiobooks/{id}/chapters` 完整信封。
@immutable
class ChaptersManifestInfo {
  const ChaptersManifestInfo({
    required this.audiobookId,
    required this.chunks,
    this.format = '',
    this.durationS = 0,
    this.chunkSeconds = 0,
    this.audioUrl = '',
    this.srtUrl = '',
  });

  factory ChaptersManifestInfo.fromJson(Map<String, dynamic> json) =>
      ChaptersManifestInfo(
        audiobookId: (json['audiobook_id'] as num?)?.toInt() ?? 0,
        format: json['format'] as String? ?? '',
        durationS: (json['duration_s'] as num?)?.toDouble() ?? 0,
        chunkSeconds: (json['chunk_seconds'] as num?)?.toInt() ?? 0,
        chunks: (json['chunks'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ChapterChunk.fromJson)
            .toList(),
        audioUrl: json['audio_url'] as String? ?? '',
        srtUrl: json['srt_url'] as String? ?? '',
      );

  final int audiobookId;
  final String format;
  final double durationS;
  final int chunkSeconds;
  final List<ChapterChunk> chunks;
  final String audioUrl;
  final String srtUrl;
}

// ---- 书源与账号（providers.go providerView / accountView）----

@immutable
class ProviderAccountInfo {
  const ProviderAccountInfo({
    required this.configured,
    this.status = '',
    this.email = '',
    this.dailyUsed = 0,
    this.dailyLimit = 0,
    this.dailyRemaining = 0,
    this.quotaKnown = false,
    this.lastVerifiedAt,
  });

  factory ProviderAccountInfo.fromJson(Map<String, dynamic> json) =>
      ProviderAccountInfo(
        configured: json['configured'] as bool? ?? false,
        status: json['status'] as String? ?? '',
        email: json['email'] as String? ?? '',
        dailyUsed: (json['daily_used'] as num?)?.toInt() ?? 0,
        dailyLimit: (json['daily_limit'] as num?)?.toInt() ?? 0,
        dailyRemaining: (json['daily_remaining'] as num?)?.toInt() ?? 0,
        quotaKnown: json['quota_known'] as bool? ?? false,
        lastVerifiedAt:
            DateTime.tryParse(json['last_verified_at'] as String? ?? ''),
      );

  final bool configured;
  final String status;
  final String email;
  final int dailyUsed;
  final int dailyLimit;
  final int dailyRemaining;
  final bool quotaKnown;
  final DateTime? lastVerifiedAt;

  bool get needsLogin => status == 'needs_login' || status == 'error';
}

@immutable
class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.name,
    this.capabilities = const <String>[],
    this.defaultDomain = '',
    this.domains = const <String>[],
    this.credentialKeys = const <String>[],
    this.account,
  });

  /// 对应 `GET /api/providers` 的 `providers[]`。
  factory ProviderInfo.fromJson(Map<String, dynamic> json) {
    final accountJson = json['account'];
    return ProviderInfo(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      capabilities: (json['capabilities'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      defaultDomain: json['default_domain'] as String? ?? '',
      domains: (json['domains'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      credentialKeys: (json['credential_keys'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      account: accountJson is Map<String, dynamic>
          ? ProviderAccountInfo.fromJson(accountJson)
          : null,
    );
  }

  final String id;
  final String name;
  final List<String> capabilities;
  final String defaultDomain;
  final List<String> domains;
  final List<String> credentialKeys;
  final ProviderAccountInfo? account;
}

// ---- 搜索（providers.Book / SearchResult）----

@immutable
class SearchBook {
  const SearchBook({
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
  });

  factory SearchBook.fromJson(Map<String, dynamic> json) => SearchBook(
        provider: json['provider'] as String? ?? '',
        ref: json['ref'] as String? ?? '',
        title: json['title'] as String? ?? '',
        authors: (json['authors'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        year: json['year'] as String? ?? '',
        publisher: json['publisher'] as String? ?? '',
        language: json['language'] as String? ?? '',
        format: json['format'] as String? ?? '',
        size: json['size'] as String? ?? '',
        isbn: json['isbn'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        description: json['description'] as String? ?? '',
        sourceUrl: json['source_url'] as String? ?? '',
      );

  final String provider;
  /// 书源引用（`id:hash`，下载与详情的定位符）。
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
}

@immutable
class SearchPageInfo {
  const SearchPageInfo({
    required this.books,
    required this.page,
    required this.totalPages,
    this.provider = '',
  });

  factory SearchPageInfo.fromJson(Map<String, dynamic> json) => SearchPageInfo(
        books: (json['books'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SearchBook.fromJson)
            .toList(),
        page: (json['page'] as num?)?.toInt() ?? 1,
        totalPages: (json['total_pages'] as num?)?.toInt() ?? 1,
        provider: json['provider'] as String? ?? '',
      );

  final List<SearchBook> books;
  final int page;
  final int totalPages;
  final String provider;

  bool get hasMore => page < totalPages;
}

// ---- 任务（jobView，jobs.go）----

enum JobKind { download, audiobook, unknown }

enum JobStatus { queued, running, cancelling, done, failed, cancelled, unknown }

@immutable
class JobInfo {
  const JobInfo({
    required this.id,
    required this.kind,
    required this.status,
    required this.progress,
    this.refId,
    this.error = '',
    this.createdAt,
    this.startedAt,
    this.finishedAt,
    this.result,
  });

  factory JobInfo.fromJson(Map<String, dynamic> json) => JobInfo(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: switch (json['kind']) {
          'download' => JobKind.download,
          'audiobook' => JobKind.audiobook,
          _ => JobKind.unknown,
        },
        status: switch (json['status']) {
          'queued' => JobStatus.queued,
          'running' => JobStatus.running,
          'cancelling' => JobStatus.cancelling,
          'done' => JobStatus.done,
          'failed' => JobStatus.failed,
          'cancelled' => JobStatus.cancelled,
          _ => JobStatus.unknown,
        },
        progress: (json['progress'] as num?)?.toInt() ?? 0,
        refId: (json['ref_id'] as num?)?.toInt(),
        error: json['error'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        startedAt: DateTime.tryParse(json['started_at'] as String? ?? ''),
        finishedAt: DateTime.tryParse(json['finished_at'] as String? ?? ''),
        result: json['result'] is Map<String, dynamic>
            ? json['result']! as Map<String, dynamic>
            : null,
      );

  final int id;
  final JobKind kind;
  final JobStatus status;
  final int progress;
  final int? refId;
  final String error;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final Map<String, dynamic>? result;

  bool get isActive =>
      status == JobStatus.queued ||
      status == JobStatus.running ||
      status == JobStatus.cancelling;

  String get kindLabel => switch (kind) {
        JobKind.download => '下载',
        JobKind.audiobook => '转有声书',
        JobKind.unknown => '任务',
      };
}

@immutable
class JobsPage {
  const JobsPage({required this.jobs, required this.total});

  factory JobsPage.fromJson(Map<String, dynamic> json) => JobsPage(
        jobs: (json['jobs'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(JobInfo.fromJson)
            .toList(),
        total: (json['total'] as num?)?.toInt() ?? 0,
      );

  final List<JobInfo> jobs;
  final int total;
}

// ---- 章节预览（library.go chapterView）----

@immutable
class ChapterPreview {
  const ChapterPreview({
    required this.index,
    required this.title,
    required this.chars,
    this.preview = '',
    this.text = '',
  });

  factory ChapterPreview.fromJson(Map<String, dynamic> json) =>
      ChapterPreview(
        index: (json['index'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        chars: (json['chars'] as num?)?.toInt() ?? 0,
        preview: json['preview'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );

  final int index;
  final String title;
  final int chars;
  final String preview;
  final String text;
}

// ---- TTS（tts.Model / tts.Voice / handleTTSModels 响应）----

@immutable
class TtsModelInfo {
  const TtsModelInfo({
    required this.id,
    this.repo = '',
    this.isDefault = false,
    this.provider = '',
    this.voices = const <String>[],
  });

  factory TtsModelInfo.fromJson(Map<String, dynamic> json) => TtsModelInfo(
        id: json['id'] as String? ?? '',
        repo: json['repo'] as String? ?? '',
        isDefault: json['default'] as bool? ?? false,
        provider: json['provider'] as String? ?? '',
        voices: (json['voices'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
      );

  final String id;
  final String repo;
  final bool isDefault;
  /// `local`（Qwen/Kokoro）或 `edge`（在线）。
  final String provider;
  final List<String> voices;
}

@immutable
class TtsVoiceInfo {
  const TtsVoiceInfo({
    required this.id,
    this.name = '',
    this.description = '',
  });

  factory TtsVoiceInfo.fromJson(Map<String, dynamic> json) => TtsVoiceInfo(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
      );

  final String id;
  final String name;
  final String description;
}

@immutable
class TtsModelsResponse {
  const TtsModelsResponse({
    required this.models,
    this.maxJobChars = 0,
    this.ttsHealthy = false,
  });

  factory TtsModelsResponse.fromJson(Map<String, dynamic> json) =>
      TtsModelsResponse(
        models: (json['models'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TtsModelInfo.fromJson)
            .toList(),
        maxJobChars: (json['max_job_chars'] as num?)?.toInt() ?? 0,
        ttsHealthy: (json['health'] is Map &&
            (json['health']! as Map)['status'] == 'ok'),
      );

  final List<TtsModelInfo> models;
  final int maxJobChars;
  final bool ttsHealthy;
}
