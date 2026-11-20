import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 阅读进度：整本书的全局页序号（跨章连续分页）。
@immutable
class ReadingPosition {
  const ReadingPosition({
    required this.bookId,
    required this.globalPage,
    this.updatedAt,
  });

  factory ReadingPosition.fromJson(Map<String, dynamic> json) => ReadingPosition(
        bookId: (json['book_id'] as num?)?.toInt() ?? 0,
        globalPage: (json['global_page'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      );

  final int bookId;
  final int globalPage;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'book_id': bookId,
        'global_page': globalPage,
        'updated_at': (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
      };
}

/// 阅读位置存储抽象（书比音频更需要"上次看到哪"）。
abstract class ReadingStore {
  Future<ReadingPosition?> read(int bookId);
  Future<void> write(ReadingPosition position);
  Future<void> delete(int bookId);
}

/// 持久化实现（与播放进度一致，用安全存储保证跨版本可用）。
class PersistentReadingStore implements ReadingStore {
  PersistentReadingStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _key(int bookId) => 'echo_reading_$bookId';

  @override
  Future<ReadingPosition?> read(int bookId) async {
    final raw = await _storage.read(key: _key(bookId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      return map is Map<String, dynamic> ? ReadingPosition.fromJson(map) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(ReadingPosition position) => _storage.write(
        key: _key(position.bookId),
        value: jsonEncode(position.toJson()),
      );

  @override
  Future<void> delete(int bookId) => _storage.delete(key: _key(bookId));
}

/// 内存实现（测试用）。
class MemoryReadingStore implements ReadingStore {
  final Map<int, ReadingPosition> _items = <int, ReadingPosition>{};

  @override
  Future<ReadingPosition?> read(int bookId) async => _items[bookId];

  @override
  Future<void> write(ReadingPosition position) async {
    _items[position.bookId] = position;
  }

  @override
  Future<void> delete(int bookId) async {
    _items.remove(bookId);
  }
}

/// 分页结果：一页 = 章节内的一段文字。
@immutable
class ReaderPage {
  const ReaderPage({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.pageInChapter,
    required this.pageCountInChapter,
    required this.text,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int pageInChapter;
  final int pageCountInChapter;
  final String text;
}

/// 把章节正文按段落切分为阅读页（近似字数分页，段落边界优先）。
List<String> paginateChapter(String text, int charsPerPage) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const <String>[''];
  final paragraphs = trimmed
      .split(RegExp(r'\n+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (paragraphs.isEmpty) return <String>[trimmed];

  final pages = <String>[];
  final buffer = StringBuffer();
  var length = 0;

  void flush() {
    if (length == 0) return;
    pages.add(buffer.toString().trim());
    buffer.clear();
    length = 0;
  }

  for (final paragraph in paragraphs) {
    // 单段超长：按字数硬切
    if (paragraph.length > charsPerPage) {
      flush();
      var rest = paragraph;
      while (rest.length > charsPerPage) {
        pages.add(rest.substring(0, charsPerPage));
        rest = rest.substring(charsPerPage);
      }
      if (rest.isNotEmpty) {
        buffer.write(rest);
        buffer.write('\n\n');
        length = rest.length;
      }
      continue;
    }
    if (length + paragraph.length > charsPerPage) flush();
    buffer.write(paragraph);
    buffer.write('\n\n');
    length += paragraph.length;
  }
  flush();
  return pages.isEmpty ? <String>[trimmed] : pages;
}

/// 全书连续分页：把每章切成若干页并展开为扁平列表。
List<ReaderPage> buildReaderPages(
  List<dynamic> chapters, {
  int charsPerPage = 480,
}) {
  final result = <ReaderPage>[];
  for (var i = 0; i < chapters.length; i++) {
    final chapter = chapters[i];
    final title = (chapter.title as String?) ?? '';
    final text = (chapter.text as String?) ?? '';
    final pages = paginateChapter(text, charsPerPage);
    for (var p = 0; p < pages.length; p++) {
      result.add(
        ReaderPage(
          chapterIndex: chapter.index as int? ?? i,
          chapterTitle: title.isEmpty ? '第 ${i + 1} 章' : title,
          pageInChapter: p + 1,
          pageCountInChapter: pages.length,
          text: pages[p],
        ),
      );
    }
  }
  return result;
}
