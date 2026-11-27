import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'translation_models.dart';

/// 单本书籍的翻译偏好设置（阅读模式 + 忽略外文弹窗）。
@immutable
class BookTranslationPrefs {
  const BookTranslationPrefs({
    this.displayMode = BilingualDisplayMode.original,
    this.dismissedForeignPrompt = false,
  });

  factory BookTranslationPrefs.fromJson(Map<String, dynamic> json) {
    return BookTranslationPrefs(
      displayMode: BilingualDisplayMode.fromId(
        json['display_mode'] as String?,
      ),
      dismissedForeignPrompt:
          json['dismissed_foreign_prompt'] as bool? ?? false,
    );
  }

  final BilingualDisplayMode displayMode;
  final bool dismissedForeignPrompt;

  BookTranslationPrefs copyWith({
    BilingualDisplayMode? displayMode,
    bool? dismissedForeignPrompt,
  }) {
    return BookTranslationPrefs(
      displayMode: displayMode ?? this.displayMode,
      dismissedForeignPrompt:
          dismissedForeignPrompt ?? this.dismissedForeignPrompt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'display_mode': displayMode.id,
    'dismissed_foreign_prompt': dismissedForeignPrompt,
  };
}

/// 翻译持久化缓存存储抽象（分章节缓存段落译文 + 单书偏好设置）。
abstract class TranslationCacheStore {
  Future<Map<String, String>> readChapterTranslations({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
  });

  Future<void> saveParagraphTranslation({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required String paragraphHash,
    required String translatedText,
  });

  Future<void> saveChapterTranslations({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required Map<String, String> entries,
  });

  Future<BookTranslationPrefs> readBookPrefs(int bookId);

  Future<void> writeBookPrefs(int bookId, BookTranslationPrefs prefs);

  Future<void> clearBookCache(int bookId);

  Future<int> computeTotalCacheBytes();

  Future<void> clearAllCaches();
}

/// 基于 `ApplicationSupportDirectory/translations` 的持久化文件系统实现。
class FileTranslationCacheStore implements TranslationCacheStore {
  FileTranslationCacheStore({Future<Directory> Function()? rootDirResolver})
    : _rootDirResolver = rootDirResolver;

  final Future<Directory> Function()? _rootDirResolver;
  Directory? _cachedRootDir;
  Future<void> _writeChain = Future<void>.value();

  Future<Directory> _rootDir() async {
    final cached = _cachedRootDir;
    if (cached != null) return cached;
    if (_rootDirResolver != null) {
      final dir = await _rootDirResolver();
      _cachedRootDir = dir;
      return dir;
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'translations'));
    _cachedRootDir = dir;
    return dir;
  }

  String _sanitizeSegment(String raw) =>
      raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

  Future<File> _chapterFile({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
  }) async {
    final root = await _rootDir();
    final langSeg = _sanitizeSegment(targetLangCode);
    final modelSeg = _sanitizeSegment(modelId.isEmpty ? 'default' : modelId);
    return File(
      p.join(
        root.path,
        'book_$bookId',
        '${langSeg}_$modelSeg',
        'ch_$chapterIndex.json',
      ),
    );
  }

  Future<File> _prefsFile(int bookId) async {
    final root = await _rootDir();
    return File(p.join(root.path, 'book_$bookId', 'prefs.json'));
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _writeChain.then((_) => action(), onError: (_) => action());
    _writeChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  @override
  Future<Map<String, String>> readChapterTranslations({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
  }) async {
    try {
      final file = await _chapterFile(
        bookId: bookId,
        chapterIndex: chapterIndex,
        targetLangCode: targetLangCode,
        modelId: modelId,
      );
      if (!await file.exists()) return <String, String>{};
      final raw = await file.readAsString();
      if (raw.isEmpty) return <String, String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, String>{};
      final items = decoded['entries'];
      if (items is! Map) return <String, String>{};
      return items.map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
    } catch (_) {
      return <String, String>{};
    }
  }

  @override
  Future<void> saveParagraphTranslation({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required String paragraphHash,
    required String translatedText,
  }) => saveChapterTranslations(
    bookId: bookId,
    chapterIndex: chapterIndex,
    targetLangCode: targetLangCode,
    modelId: modelId,
    entries: <String, String>{paragraphHash: translatedText},
  );

  @override
  Future<void> saveChapterTranslations({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required Map<String, String> entries,
  }) => _serialized(() async {
    if (entries.isEmpty) return;
    final file = await _chapterFile(
      bookId: bookId,
      chapterIndex: chapterIndex,
      targetLangCode: targetLangCode,
      modelId: modelId,
    );
    await file.parent.create(recursive: true);
    final existing = await readChapterTranslations(
      bookId: bookId,
      chapterIndex: chapterIndex,
      targetLangCode: targetLangCode,
      modelId: modelId,
    );
    existing.addAll(entries);
    final payload = jsonEncode(<String, dynamic>{
      'book_id': bookId,
      'chapter_index': chapterIndex,
      'target_lang': targetLangCode,
      'model_id': modelId,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'entries': existing,
    });
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  });

  @override
  Future<BookTranslationPrefs> readBookPrefs(int bookId) async {
    try {
      final file = await _prefsFile(bookId);
      if (!await file.exists()) return const BookTranslationPrefs();
      final raw = await file.readAsString();
      if (raw.isEmpty) return const BookTranslationPrefs();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return BookTranslationPrefs.fromJson(decoded);
      }
    } catch (_) {}
    return const BookTranslationPrefs();
  }

  @override
  Future<void> writeBookPrefs(int bookId, BookTranslationPrefs prefs) =>
      _serialized(() async {
        final file = await _prefsFile(bookId);
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(prefs.toJson()));
      });

  @override
  Future<void> clearBookCache(int bookId) => _serialized(() async {
    final root = await _rootDir();
    final dir = Directory(p.join(root.path, 'book_$bookId'));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  @override
  Future<int> computeTotalCacheBytes() async {
    try {
      final root = await _rootDir();
      if (!await root.exists()) return 0;
      var total = 0;
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> clearAllCaches() => _serialized(() async {
    final root = await _rootDir();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });
}

/// 纯内存缓存实现，供单元测试与无文件系统环境使用。
class MemoryTranslationCacheStore implements TranslationCacheStore {
  final Map<String, Map<String, String>> _chapters =
      <String, Map<String, String>>{};
  final Map<int, BookTranslationPrefs> _prefs = <int, BookTranslationPrefs>{};

  String _key(int bookId, int chapterIndex, String targetLangCode, String modelId) =>
      '$bookId::$chapterIndex::$targetLangCode::$modelId';

  @override
  Future<Map<String, String>> readChapterTranslations({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
  }) async {
    final m = _chapters[_key(bookId, chapterIndex, targetLangCode, modelId)];
    return m == null ? <String, String>{} : Map<String, String>.from(m);
  }

  @override
  Future<void> saveParagraphTranslation({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required String paragraphHash,
    required String translatedText,
  }) async {
    final k = _key(bookId, chapterIndex, targetLangCode, modelId);
    (_chapters[k] ??= <String, String>{})[paragraphHash] = translatedText;
  }

  @override
  Future<void> saveChapterTranslations({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required Map<String, String> entries,
  }) async {
    final k = _key(bookId, chapterIndex, targetLangCode, modelId);
    (_chapters[k] ??= <String, String>{}).addAll(entries);
  }

  @override
  Future<BookTranslationPrefs> readBookPrefs(int bookId) async =>
      _prefs[bookId] ?? const BookTranslationPrefs();

  @override
  Future<void> writeBookPrefs(int bookId, BookTranslationPrefs prefs) async {
    _prefs[bookId] = prefs;
  }

  @override
  Future<void> clearBookCache(int bookId) async {
    _chapters.removeWhere((k, _) => k.startsWith('$bookId::'));
    _prefs.remove(bookId);
  }

  @override
  Future<int> computeTotalCacheBytes() async {
    var total = 0;
    for (final map in _chapters.values) {
      for (final e in map.entries) {
        total += e.key.length + e.value.length;
      }
    }
    return total;
  }

  @override
  Future<void> clearAllCaches() async {
    _chapters.clear();
    _prefs.clear();
  }
}

final Provider<TranslationCacheStore> translationCacheStoreProvider =
    Provider<TranslationCacheStore>((ref) => FileTranslationCacheStore());
