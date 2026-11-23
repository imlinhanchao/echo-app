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

/// 分页缓存 Key：按书籍/章号/版心尺寸与排版参数唯一确定。
@immutable
class ChapterPaginationKey {
  ChapterPaginationKey({
    required this.bookId,
    required this.chapterIndex,
    required double maxWidth,
    required double maxHeight,
    required double fontSize,
    required double lineHeight,
    required double textScaleFactor,
  }) : widthRounded = maxWidth.round(),
       heightRounded = maxHeight.round(),
       fontSizeTenths = (fontSize * 10).round(),
       lineHeightTenths = (lineHeight * 10).round(),
       textScaleTenths = (textScaleFactor * 100).round();

  final int bookId;
  final int chapterIndex;
  final int widthRounded;
  final int heightRounded;
  final int fontSizeTenths;
  final int lineHeightTenths;
  final int textScaleTenths;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChapterPaginationKey &&
          bookId == other.bookId &&
          chapterIndex == other.chapterIndex &&
          widthRounded == other.widthRounded &&
          heightRounded == other.heightRounded &&
          fontSizeTenths == other.fontSizeTenths &&
          lineHeightTenths == other.lineHeightTenths &&
          textScaleTenths == other.textScaleTenths;

  @override
  int get hashCode => Object.hash(
    bookId,
    chapterIndex,
    widthRounded,
    heightRounded,
    fontSizeTenths,
    lineHeightTenths,
    textScaleTenths,
  );
}

/// 按章缓存已算好的分页结果（LRU，默认最多 60 章），从底部播放条重新进入可零耗时直达。
class ChapterPaginationCache {
  ChapterPaginationCache({this.maxEntries = 60});

  static final ChapterPaginationCache instance = ChapterPaginationCache();

  final int maxEntries;
  final Map<ChapterPaginationKey, List<ReaderPage>> _entries =
      <ChapterPaginationKey, List<ReaderPage>>{};

  List<ReaderPage>? get(ChapterPaginationKey key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit;
    return hit;
  }

  void put(ChapterPaginationKey key, List<ReaderPage> pages) {
    _entries.remove(key);
    _entries[key] = List<ReaderPage>.unmodifiable(pages);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clearForBook(int bookId) {
    _entries.removeWhere((k, _) => k.bookId == bookId);
  }

  void clear() => _entries.clear();
}

class _ChapterPaginator {
  _ChapterPaginator._({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.text,
    required this.style,
    required this.textScaler,
    required this.maxWidth,
    required this.maxHeight,
    required this.contentStart,
    required this.contentEnd,
  }) : _painter = TextPainter(
         textDirection: TextDirection.ltr,
         textScaler: textScaler,
       ),
       _maxCandidateChars = _computeMaxCandidateChars(
         style: style,
         textScaler: textScaler,
         maxWidth: maxWidth,
         maxHeight: maxHeight,
       ),
       _offset = contentStart;

  factory _ChapterPaginator({
    required int chapterIndex,
    required String chapterTitle,
    required String text,
    required TextStyle style,
    required TextScaler textScaler,
    required double maxWidth,
    required double maxHeight,
  }) {
    var start = 0;
    while (start < text.length && text[start].trim().isEmpty) {
      start++;
    }
    var end = text.length;
    while (end > start && text[end - 1].trim().isEmpty) {
      end--;
    }
    return _ChapterPaginator._(
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      text: text,
      style: style,
      textScaler: textScaler,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      contentStart: start,
      contentEnd: end,
    );
  }

  final int chapterIndex;
  final String chapterTitle;
  final String text;
  final TextStyle style;
  final TextScaler textScaler;
  final double maxWidth;
  final double maxHeight;
  final int contentStart;
  final int contentEnd;
  final TextPainter _painter;
  final int _maxCandidateChars;

  int _offset;
  final List<ReaderPage> _pages = <ReaderPage>[];

  static int _computeMaxCandidateChars({
    required TextStyle style,
    required TextScaler textScaler,
    required double maxWidth,
    required double maxHeight,
  }) {
    final scaledFontSize = math.max(
      10.0,
      textScaler.scale(style.fontSize ?? 17.0),
    );
    final lineHeightPx = scaledFontSize * (style.height ?? 1.6);
    final estLines = math.max(1, (maxHeight / lineHeightPx).ceil());
    final estCharsPerLine = math.max(
      4,
      (maxWidth / (scaledFontSize * 0.45)).ceil(),
    );
    return math.max(80, (estLines * estCharsPerLine * 1.8).ceil());
  }

  bool get isEmptyOrUnbounded =>
      contentStart >= contentEnd || maxWidth <= 0 || maxHeight <= 0;

  bool get isDone => isEmptyOrUnbounded || _offset >= contentEnd;

  bool _fits(String candidate) {
    _painter.text = TextSpan(text: candidate, style: style);
    _painter.layout(maxWidth: maxWidth);
    return _painter.height <= maxHeight;
  }

  int _fitLength(int offset) {
    final remaining = contentEnd - offset;
    var lo = 1;
    var hi = math.min(remaining, _maxCandidateChars);
    while (hi < remaining && _fits(text.substring(offset, offset + hi))) {
      lo = hi;
      hi = math.min(remaining, hi * 2);
    }
    var best = lo == 1 ? 0 : lo;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (_fits(text.substring(offset, offset + mid))) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  int _adjustBreak(int offset, int length) {
    if (offset + length >= contentEnd) return contentEnd - offset;
    const lookback = 120;
    final windowStart = offset + math.max(1, length - lookback);
    for (var i = offset + length - 1; i >= windowStart; i--) {
      final ch = text[i];
      if (ch == '\n' || ch == '。' || ch == '！' || ch == '？' || ch == '；') {
        return i - offset + 1;
      }
    }
    for (var i = offset + length - 1; i >= windowStart; i--) {
      final ch = text[i];
      if (ch == '，' || ch == '、' || ch == ' ') {
        return i - offset + 1;
      }
    }
    return length;
  }

  void stepPage() {
    while (_offset < contentEnd && text[_offset].trim().isEmpty) {
      _offset++;
    }
    if (_offset >= contentEnd) return;

    var length = _fitLength(_offset);
    if (length <= 0) {
      length = 1;
    } else {
      length = _adjustBreak(_offset, length);
    }
    final end = math.min(_offset + length, contentEnd);
    _pages.add(
      ReaderPage(
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        startChar: _offset,
        endChar: end,
        text: text.substring(_offset, end).trimRight(),
        pageInChapter: _pages.length + 1,
        pageCountInChapter: 0,
      ),
    );
    _offset = end;
  }

  List<ReaderPage> buildResult() {
    if (isEmptyOrUnbounded || _pages.isEmpty) {
      final isBlank = contentStart >= contentEnd;
      return <ReaderPage>[
        ReaderPage(
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
          startChar: isBlank ? 0 : contentStart,
          endChar: contentEnd,
          text: isBlank
              ? '（本章暂无内容）'
              : text.substring(contentStart, contentEnd),
          pageInChapter: 1,
          pageCountInChapter: 1,
        ),
      ];
    }
    return <ReaderPage>[
      for (final page in _pages)
        ReaderPage(
          chapterIndex: page.chapterIndex,
          chapterTitle: page.chapterTitle,
          startChar: page.startChar,
          endChar: page.endChar,
          text: page.text,
          pageInChapter: page.pageInChapter,
          pageCountInChapter: _pages.length,
        ),
    ];
  }
}

/// 精确分页：用 [TextPainter] 实测文本高度，保证每页内容都装得进可视区域，
/// 不会出现"文字被工具栏盖住/露出一半"的情况。
///
/// - 所有 `startChar` / `endChar` 严格保持原始 `text` 字符坐标系（与分句器偏移完全一致）；
/// - 每页尽量在段落或句读（\n。！？；）处断开；
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
  final paginator = _ChapterPaginator(
    chapterIndex: chapterIndex,
    chapterTitle: chapterTitle,
    text: text,
    style: style,
    textScaler: textScaler,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
  while (!paginator.isDone) {
    paginator.stepPage();
  }
  return paginator.buildResult();
}

/// 分时让帧精确分页：每耗时超过 8ms 自动让出事件循环，避免长章阻塞 UI 渲染或 TTS 切句。
Future<List<ReaderPage>> paginateChapterBySizeAsync({
  required int chapterIndex,
  required String chapterTitle,
  required String text,
  required TextStyle style,
  required TextScaler textScaler,
  required double maxWidth,
  required double maxHeight,
  bool Function()? isCancelled,
}) async {
  final paginator = _ChapterPaginator(
    chapterIndex: chapterIndex,
    chapterTitle: chapterTitle,
    text: text,
    style: style,
    textScaler: textScaler,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
  final sw = Stopwatch()..start();
  while (!paginator.isDone) {
    if (isCancelled?.call() == true) return const <ReaderPage>[];
    paginator.stepPage();
    if (!paginator.isDone && sw.elapsedMilliseconds >= 8) {
      await Future<void>.delayed(Duration.zero);
      sw.reset();
    }
  }
  if (isCancelled?.call() == true) return const <ReaderPage>[];
  return paginator.buildResult();
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
  // 回退 1：偏移落在章首/页间被跳过的空白处 -> 取第一页 endChar > charOffset
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    if (page.chapterIndex == chapterIndex && page.endChar > charOffset) {
      return i;
    }
  }
  // 回退 2：同一章最后一页 / 首页
  var sameChapter = -1;
  for (var i = 0; i < pages.length; i++) {
    if (pages[i].chapterIndex == chapterIndex) sameChapter = i;
  }
  return sameChapter >= 0 ? sameChapter : 0;
}
