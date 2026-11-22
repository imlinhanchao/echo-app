import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final readingStoreProvider = Provider<ReadingStore>(
  (ref) => PersistentReadingStore(),
);

/// 阅读进度：章号 + 章内字符偏移。
///
/// 用字符偏移（而不是页码）记录位置：字号/屏幕变化导致重新分页后，
/// 仍能精确定位到同一处文字。
@immutable
class ReadingPosition {
  const ReadingPosition({
    required this.bookId,
    required this.chapterIndex,
    required this.charOffset,
    this.updatedAt,
  });

  factory ReadingPosition.fromJson(Map<String, dynamic> json) =>
      ReadingPosition(
        bookId: (json['book_id'] as num?)?.toInt() ?? 0,
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        charOffset: (json['char_offset'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      );

  final int bookId;
  final int chapterIndex;
  final int charOffset;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'book_id': bookId,
    'chapter_index': chapterIndex,
    'char_offset': charOffset,
    'updated_at': (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
  };
}

/// 阅读位置存储抽象（书比音频更需要"上次看到哪"）。
abstract class ReadingStore {
  Future<ReadingPosition?> read(int bookId);
  Future<void> write(ReadingPosition position);
  Future<void> delete(int bookId);
}

/// 持久化实现。
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

/// 一页正文（记录在章内的字符区间，便于重新分页后定位）。
@immutable
class ReaderPage {
  const ReaderPage({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.startChar,
    required this.endChar,
    required this.text,
    required this.pageInChapter,
    required this.pageCountInChapter,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int startChar;
  final int endChar;
  final String text;
  final int pageInChapter;
  final int pageCountInChapter;

  bool containsOffset(int offset) => offset >= startChar && offset < endChar;
}

/// 精确分页：用 [TextPainter] 实测文本高度，保证每页内容都装得进可视区域，
/// 不会出现"文字被工具栏盖住/露出一半"的情况。
///
/// - 每页尽量在段落或句读（。！？；，\n）处断开；
/// - 单章过长时按可视高度逐页切分。
List<ReaderPage> paginateChapterBySize({
  required int chapterIndex,
  required String chapterTitle,
  required String text,
  required TextStyle style,
  required TextScaler textScaler,
  required double maxWidth,
  required double maxHeight,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || maxWidth <= 0 || maxHeight <= 0) {
    return <ReaderPage>[
      ReaderPage(
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        startChar: 0,
        endChar: trimmed.length,
        text: trimmed.isEmpty ? '（本章暂无内容）' : trimmed,
        pageInChapter: 1,
        pageCountInChapter: 1,
      ),
    ];
  }

  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  );

  // 单页最多能容纳的字符数估算上限，避免二分第一步把整章数万字丢进 TextPainter 导致主线程卡死
  final scaledFontSize = math.max(
    10.0,
    textScaler.scale(style.fontSize ?? 17.0),
  );
  final lineHeightPx = scaledFontSize * (style.height ?? 1.6);
  final estLines = math.max(1, (maxHeight / lineHeightPx).ceil());
  final estCharsPerLine = math.max(4, (maxWidth / (scaledFontSize * 0.45)).ceil());
  final maxCandidateChars = math.max(
    80,
    (estLines * estCharsPerLine * 1.8).ceil(),
  );

  bool fits(String candidate) {
    painter.text = TextSpan(text: candidate, style: style);
    painter.layout(maxWidth: maxWidth);
    return painter.height <= maxHeight;
  }

  // 有界二分查找：从 offset 起最多能容纳多少字符
  int fitLength(int offset) {
    final remaining = trimmed.length - offset;
    var lo = 1;
    var hi = math.min(remaining, maxCandidateChars);
    // 极端窄字符场景（如全英文/数字）若估算上限仍装得下，倍增扩窗
    while (hi < remaining && fits(trimmed.substring(offset, offset + hi))) {
      lo = hi;
      hi = math.min(remaining, hi * 2);
    }
    var best = lo == 1 ? 0 : lo;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (fits(trimmed.substring(offset, offset + mid))) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  // 把切点回退到最近的句读/段落边界，避免半句被切断
  int adjustBreak(int offset, int length) {
    if (offset + length >= trimmed.length) return trimmed.length - offset;
    const lookback = 60;
    final windowStart = offset + math.max(1, length - lookback);
    for (var i = offset + length - 1; i >= windowStart; i--) {
      final ch = trimmed[i];
      if (ch == '\n' || ch == '。' || ch == '！' || ch == '？' || ch == '；') {
        return i - offset + 1;
      }
    }
    for (var i = offset + length - 1; i >= windowStart; i--) {
      final ch = trimmed[i];
      if (ch == '，' || ch == '、' || ch == ' ') {
        return i - offset + 1;
      }
    }
    return length;
  }

  final pages = <ReaderPage>[];
  var offset = 0;
  while (offset < trimmed.length) {
    var length = fitLength(offset);
    if (length <= 0) {
      // 极端窄屏/大字号下至少放一个字，防止死循环
      length = 1;
    } else {
      length = adjustBreak(offset, length);
    }
    final end = math.min(offset + length, trimmed.length);
    pages.add(
      ReaderPage(
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        startChar: offset,
        endChar: end,
        text: trimmed.substring(offset, end).trim(),
        pageInChapter: pages.length + 1,
        pageCountInChapter: 0, // 稍后回填
      ),
    );
    offset = end;
  }

  return <ReaderPage>[
    for (final page in pages)
      ReaderPage(
        chapterIndex: page.chapterIndex,
        chapterTitle: page.chapterTitle,
        startChar: page.startChar,
        endChar: page.endChar,
        text: page.text,
        pageInChapter: page.pageInChapter,
        pageCountInChapter: pages.length,
      ),
  ];
}

/// 找到包含指定字符偏移的页索引；找不到时返回最接近的页。
int pageIndexForOffset(
  List<ReaderPage> pages,
  int chapterIndex,
  int charOffset,
) {
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    if (page.chapterIndex == chapterIndex && page.containsOffset(charOffset)) {
      return i;
    }
  }
  // 回退：同一章最后一页 / 同章第一页 / 首页
  var sameChapter = -1;
  for (var i = 0; i < pages.length; i++) {
    if (pages[i].chapterIndex == chapterIndex) sameChapter = i;
  }
  return sameChapter >= 0 ? sameChapter : 0;
}
