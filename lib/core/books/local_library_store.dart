import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../offline/offline_store.dart';
import 'epub_parser.dart';
import 'txt_parser.dart';

/// 本地书库与离线有声书元数据持久化仓库（单机版核心数据源）。
///
/// 目录结构（`<appDocs>/echo_standalone/`）：
/// - `index.json`：书籍列表、有声书列表与自增 ID
/// - `books/<bookId>/source.<ext>`：原始电子书文件
/// - `books/<bookId>/cover.<ext>`：提取的本地封面
/// - `books/<bookId>/chapters.json`：解析好的章节列表与正文
/// - `audiobooks/<audiobookId>/manifest.json`：本地分块有声书清单
class LocalLibraryStore {
  LocalLibraryStore({
    Directory? rootDir,
    EpubParser? epubParser,
    TxtParser? txtParser,
  }) : _rootOverride = rootDir,
       _epubParser = epubParser ?? const EpubParser(),
       _txtParser = txtParser ?? const TxtParser();

  final Directory? _rootOverride;
  final EpubParser _epubParser;
  final TxtParser _txtParser;

  Directory? _root;
  int _nextBookId = 1;
  int _nextAudiobookId = 1;
  List<LibraryBook> _books = <LibraryBook>[];
  List<AudiobookInfo> _audiobooks = <AudiobookInfo>[];
  bool _loaded = false;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    if (_rootOverride != null) {
      await _rootOverride.create(recursive: true);
      _root = _rootOverride;
      return _root!;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'echo_standalone'));
    await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  Future<File> _indexFile() async {
    final root = await _ensureRoot();
    return File(p.join(root.path, 'index.json'));
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await reload();
  }

  Future<void> reload() async {
    final file = await _indexFile();
    if (!await file.exists()) {
      _books = <LibraryBook>[];
      _audiobooks = <AudiobookInfo>[];
      _nextBookId = 1;
      _nextAudiobookId = 1;
      _loaded = true;
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        _nextBookId = (decoded['next_book_id'] as num?)?.toInt() ?? 1;
        _nextAudiobookId = (decoded['next_audiobook_id'] as num?)?.toInt() ?? 1;
        _books = (decoded['books'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LibraryBook.fromJson)
            .toList();
        _audiobooks = (decoded['audiobooks'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AudiobookInfo.fromJson)
            .toList();
      }
    } catch (_) {
      _books = <LibraryBook>[];
      _audiobooks = <AudiobookInfo>[];
    }
    _loaded = true;
  }

  Future<void> _persistIndex() async {
    final file = await _indexFile();
    final payload = <String, dynamic>{
      'next_book_id': _nextBookId,
      'next_audiobook_id': _nextAudiobookId,
      'books': _books.map(_bookToJson).toList(),
      'audiobooks': _audiobooks.map(_audiobookToJson).toList(),
    };
    await file.writeAsString(jsonEncode(payload));
  }

  Future<List<LibraryBook>> listBooks() async {
    await ensureLoaded();
    return List<LibraryBook>.unmodifiable(_books);
  }

  Future<List<AudiobookInfo>> listAudiobooks() async {
    await ensureLoaded();
    return List<AudiobookInfo>.unmodifiable(_audiobooks);
  }

  Future<LibraryBook?> getBook(int bookId) async {
    await ensureLoaded();
    for (final b in _books) {
      if (b.id == bookId) return b;
    }
    return null;
  }

  Future<BookDetail> getBookDetail(int bookId) async {
    await ensureLoaded();
    final book = await getBook(bookId);
    final audios = _audiobooks.where((a) => a.bookId == bookId).toList();
    return BookDetail(book: book, audiobooks: audios);
  }

  /// 从本地文件路径导入 EPUB 或 TXT，自动解析章节与封面并持久化。
  Future<LibraryBook> importFile(
    File sourceFile, {
    String? filenameOverride,
    String provider = 'local',
    String providerBookId = '',
    String? titleOverride,
    List<String>? authorsOverride,
    String? coverUrlFallback,
  }) async {
    final bytes = await sourceFile.readAsBytes();
    final filename = filenameOverride ?? p.basename(sourceFile.path);
    return importBytes(
      bytes,
      filename: filename,
      provider: provider,
      providerBookId: providerBookId,
      titleOverride: titleOverride,
      authorsOverride: authorsOverride,
      coverUrlFallback: coverUrlFallback,
    );
  }

  /// 从字节流导入 EPUB 或 TXT。
  Future<LibraryBook> importBytes(
    Uint8List bytes, {
    required String filename,
    String provider = 'local',
    String providerBookId = '',
    String? titleOverride,
    List<String>? authorsOverride,
    String? coverUrlFallback,
  }) async {
    await ensureLoaded();
    final ext = p.extension(filename).toLowerCase().replaceFirst('.', '');
    final fallbackTitle = p.basenameWithoutExtension(filename).trim().isNotEmpty
        ? p.basenameWithoutExtension(filename).trim()
        : '未命名书籍';

    final ParsedBook parsed;
    if (ext == 'epub') {
      parsed = _epubParser.parse(bytes, fallbackTitle: fallbackTitle);
    } else if (ext == 'txt' || ext.isEmpty) {
      parsed = _txtParser.parse(bytes, fallbackTitle: fallbackTitle);
    } else {
      throw FormatException('暂不支持 .$ext 格式，仅支持 EPUB 和 TXT');
    }

    final bookId = _nextBookId++;
    final root = await _ensureRoot();
    final bookDir = Directory(p.join(root.path, 'books', '$bookId'));
    await bookDir.create(recursive: true);

    // 1. 保存源文件
    final sourceExt = parsed.format.isEmpty ? 'txt' : parsed.format;
    final destFile = File(p.join(bookDir.path, 'source.$sourceExt'));
    await destFile.writeAsBytes(bytes, flush: true);

    // 2. 保存提取的封面
    var coverPath = coverUrlFallback ?? '';
    if (parsed.coverBytes != null && parsed.coverBytes!.isNotEmpty) {
      final coverFile = File(p.join(bookDir.path, 'cover.${parsed.coverExt}'));
      await coverFile.writeAsBytes(parsed.coverBytes!, flush: true);
      coverPath = coverFile.uri.toString();
    }

    // 3. 保存解析后的章节 JSON
    final chaptersFile = File(p.join(bookDir.path, 'chapters.json'));
    await chaptersFile.writeAsString(
      jsonEncode(
        parsed.chapters
            .map(
              (c) => <String, dynamic>{
                'index': c.index,
                'title': c.title,
                'chars': c.chars,
                'preview': c.preview,
                'text': c.text,
              },
            )
            .toList(),
      ),
    );

    final finalTitle =
        (titleOverride != null && titleOverride.trim().isNotEmpty)
        ? titleOverride.trim()
        : parsed.title;
    final finalAuthors =
        (authorsOverride != null && authorsOverride.isNotEmpty)
        ? authorsOverride
        : parsed.authors;

    final book = LibraryBook(
      id: bookId,
      provider: provider,
      providerBookId: providerBookId,
      title: finalTitle,
      authors: finalAuthors,
      year: parsed.year,
      publisher: parsed.publisher,
      language: parsed.language,
      format: sourceExt,
      sizeBytes: bytes.length,
      coverUrl: coverPath,
      description: parsed.description,
      status: 'ready',
    );

    _books = <LibraryBook>[book, ..._books];
    await _persistIndex();
    return book;
  }

  /// 读取书籍所有章节列表（含预览与字数）。
  Future<List<ChapterPreview>> listChapters(int bookId) async {
    final root = await _ensureRoot();
    final file = File(p.join(root.path, 'books', '$bookId', 'chapters.json'));
    if (!await file.exists()) return const <ChapterPreview>[];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const <ChapterPreview>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(ChapterPreview.fromJson)
          .toList();
    } catch (_) {
      return const <ChapterPreview>[];
    }
  }

  /// 读取单章完整正文。
  Future<ChapterPreview?> getChapter(int bookId, int chapterIndex) async {
    final chapters = await listChapters(bookId);
    for (final c in chapters) {
      if (c.index == chapterIndex) return c;
    }
    if (chapterIndex >= 0 && chapterIndex < chapters.length) {
      return chapters[chapterIndex];
    }
    return null;
  }

  /// 获取书籍原始文件（用于本地导出分享）。
  Future<File?> getSourceFile(int bookId) async {
    final book = await getBook(bookId);
    if (book == null) return null;
    final root = await _ensureRoot();
    final ext = book.format.isEmpty ? 'txt' : book.format;
    final file = File(p.join(root.path, 'books', '$bookId', 'source.$ext'));
    return await file.exists() ? file : null;
  }

  /// 分配新的本地有声书 ID。
  Future<int> allocateAudiobookId() async {
    await ensureLoaded();
    final id = _nextAudiobookId++;
    await _persistIndex();
    return id;
  }

  /// 新增或更新本地有声书记录。
  Future<void> upsertAudiobook(AudiobookInfo info) async {
    await ensureLoaded();
    final idx = _audiobooks.indexWhere((a) => a.id == info.id);
    if (idx >= 0) {
      final next = List<AudiobookInfo>.of(_audiobooks);
      next[idx] = info;
      _audiobooks = next;
    } else {
      _audiobooks = <AudiobookInfo>[info, ..._audiobooks];
    }
    await _persistIndex();
  }

  /// 保存本地有声书分块清单（兼容 `ChunkedPlayerController`）。
  Future<void> saveChaptersManifest(
    int audiobookId,
    ChaptersManifestInfo manifest,
  ) async {
    final root = await _ensureRoot();
    final dir = Directory(p.join(root.path, 'audiobooks', '$audiobookId'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'manifest.json'));
    await file.writeAsString(jsonEncode(_manifestToJson(manifest)));
  }

  /// 读取本地有声书分块清单。
  Future<ChaptersManifestInfo?> readChaptersManifest(int audiobookId) async {
    final root = await _ensureRoot();
    final file = File(
      p.join(root.path, 'audiobooks', '$audiobookId', 'manifest.json'),
    );
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return ChaptersManifestInfo.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// 删除书籍及其关联封面、章节与有声书缓存。
  Future<void> deleteBook(int bookId) async {
    await ensureLoaded();
    final relatedAudios = _audiobooks.where((a) => a.bookId == bookId).toList();
    for (final audio in relatedAudios) {
      await deleteAudiobook(audio.id);
    }
    _books = _books.where((b) => b.id != bookId).toList();
    await _persistIndex();
    final root = await _ensureRoot();
    final bookDir = Directory(p.join(root.path, 'books', '$bookId'));
    if (await bookDir.exists()) {
      await bookDir.delete(recursive: true);
    }
  }

  /// 删除单个本地有声书及其离线音频块。
  Future<void> deleteAudiobook(int audiobookId) async {
    await ensureLoaded();
    _audiobooks = _audiobooks.where((a) => a.id != audiobookId).toList();
    await _persistIndex();
    final root = await _ensureRoot();
    final audioDir = Directory(p.join(root.path, 'audiobooks', '$audiobookId'));
    if (await audioDir.exists()) {
      await audioDir.delete(recursive: true);
    }
    try {
      await OfflineFiles.removeAudiobook(audiobookId);
    } catch (_) {}
  }

  Map<String, dynamic> _bookToJson(LibraryBook b) => <String, dynamic>{
    'id': b.id,
    'provider': b.provider,
    'provider_book_id': b.providerBookId,
    'title': b.title,
    'authors': b.authors,
    'year': b.year,
    'publisher': b.publisher,
    'language': b.language,
    'format': b.format,
    'size_bytes': b.sizeBytes,
    'cover_url': b.coverUrl,
    'description': b.description,
    'status': b.status,
  };

  Map<String, dynamic> _audiobookToJson(AudiobookInfo a) => <String, dynamic>{
    'id': a.id,
    'book_id': a.bookId,
    'book_title': a.bookTitle,
    'model': a.model,
    'voice': a.voice,
    'speed': a.speed,
    'status': a.status,
    'progress': a.progress,
    'error': a.error,
    'format': a.format,
    'duration_s': a.durationS,
    'size_bytes': a.sizeBytes,
    'segments': a.segments,
    'chars': a.chars,
    'audio_url': a.audioUrl,
    'srt_url': a.srtUrl,
    'chapters_url': a.chaptersUrl,
  };

  Map<String, dynamic> _manifestToJson(ChaptersManifestInfo m) =>
      <String, dynamic>{
        'audiobook_id': m.audiobookId,
        'format': m.format,
        'duration_s': m.durationS,
        'chunk_seconds': m.chunkSeconds,
        'audio_url': m.audioUrl,
        'srt_url': m.srtUrl,
        'chunks': m.chunks
            .map(
              (c) => <String, dynamic>{
                'n': c.n,
                'chapter_index': c.chapterIndex,
                'title': c.title,
                'start_s': c.startS,
                'end_s': c.endS,
                'duration_s': c.durationS,
                'size_bytes': c.sizeBytes,
                'audio_file': c.audioFile,
                'srt_file': c.srtFile,
                'audio_url': c.audioUrl,
                'srt_url': c.srtUrl,
              },
            )
            .toList(),
      };
}

final Provider<LocalLibraryStore> localLibraryStoreProvider =
    Provider<LocalLibraryStore>((ref) => LocalLibraryStore());
