import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../translation/language_detector.dart';
import '../translation/translation_models.dart';

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

/// 双语/仅译文页面中的单个视觉片段类型。
enum BilingualRunKind {
  transPrimary,
  origSubtitle,
  untranslatedOrig,
  innerBreak,
  pairGapBreak,
  sentenceBreak,
  paragraphBreak,
}

/// 双语/仅译文页面展示字符串 `ReaderPage.text` 中的一个带偏移视觉片段。
@immutable
class BilingualDisplayRun {
  const BilingualDisplayRun({
    required this.displayStart,
    required this.displayEnd,
    required this.kind,
    this.origStartChar = -1,
    this.origEndChar = -1,
    this.transStartChar = -1,
    this.transEndChar = -1,
    this.paragraphIndex = -1,
    this.isTranslating = false,
    this.exactOrigMapping = false,
  });

  final int displayStart;
  final int displayEnd;
  final BilingualRunKind kind;
  final int origStartChar;
  final int origEndChar;
  final int transStartChar;
  final int transEndChar;
  final int paragraphIndex;
  final bool isTranslating;
  final bool exactOrigMapping;

  bool get isBreak =>
      kind == BilingualRunKind.innerBreak ||
      kind == BilingualRunKind.pairGapBreak ||
      kind == BilingualRunKind.sentenceBreak ||
      kind == BilingualRunKind.paragraphBreak;
}

/// 双语/仅译文模式下单页内的一个对照单元（按句切分，携带是否自然段结尾标识）。
@immutable
class BilingualPageBlock {
  const BilingualPageBlock({
    required this.paragraphIndex,
    required this.paragraphHash,
    required this.origStartChar,
    required this.origEndChar,
    required this.originalText,
    required this.mode,
    this.isParagraphEnd = true,
    this.translatedText,
    this.isTranslating = false,
    this.origDisplayStart = 0,
    this.origDisplayEnd = 0,
    this.transDisplayStart = 0,
    this.transDisplayEnd = 0,
  });

  final int paragraphIndex;
  final String paragraphHash;
  final int origStartChar;
  final int origEndChar;
  final String originalText;
  final BilingualDisplayMode mode;
  final bool isParagraphEnd;
  final String? translatedText;
  final bool isTranslating;

  /// 原文文本在当前页展示字符串 `ReaderPage.text` 中的区间 [origDisplayStart, origDisplayEnd)
  final int origDisplayStart;
  final int origDisplayEnd;

  /// 译文文本在当前页展示字符串 `ReaderPage.text` 中的区间 [transDisplayStart, transDisplayEnd)
  final int transDisplayStart;
  final int transDisplayEnd;

  bool get hasTranslation =>
      translatedText != null && translatedText!.trim().isNotEmpty;

  BilingualPageBlock copyWith({
    int? origDisplayStart,
    int? origDisplayEnd,
    int? transDisplayStart,
    int? transDisplayEnd,
  }) {
    return BilingualPageBlock(
      paragraphIndex: paragraphIndex,
      paragraphHash: paragraphHash,
      origStartChar: origStartChar,
      origEndChar: origEndChar,
      originalText: originalText,
      mode: mode,
      isParagraphEnd: isParagraphEnd,
      translatedText: translatedText,
      isTranslating: isTranslating,
      origDisplayStart: origDisplayStart ?? this.origDisplayStart,
      origDisplayEnd: origDisplayEnd ?? this.origDisplayEnd,
      transDisplayStart: transDisplayStart ?? this.transDisplayStart,
      transDisplayEnd: transDisplayEnd ?? this.transDisplayEnd,
    );
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
    this.blocks,
    this.displayRuns,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int startChar;
  final int endChar;
  final String text;
  final int pageInChapter;
  final int pageCountInChapter;
  final List<BilingualPageBlock>? blocks;
  final List<BilingualDisplayRun>? displayRuns;

  bool get isBilingual => blocks != null;

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

/// 计算双语章节内容与当前已译状态/活跃句子的轻量指纹，用于在 LRU 缓存中精确命中未变动的分页结果。
({int sigA, int sigB, int translatedCount}) computeBilingualPaginationSignature({
  required List<ParagraphSegment> segments,
  required Map<String, String> translationsByHash,
  String? activeTranslatingHash,
}) {
  var h1 = 0x811c9dc5;
  var h2 = 0x9e3779b1;
  var translatedCount = 0;

  void mix(int v) {
    h1 = ((h1 ^ v) * 0x01000193) & 0xffffffff;
    h2 = ((h2 + v + (h1 >> 3)) * 0x85ebca6b) & 0xffffffff;
  }

  mix(segments.length);
  for (final seg in segments) {
    mix(seg.hash.hashCode);
    mix(seg.startChar);
    mix(seg.endChar);
    mix(seg.isParagraphEnd ? 1 : 0);
    final tr = translationsByHash[seg.hash];
    if (tr != null && tr.trim().isNotEmpty) {
      translatedCount++;
      mix(tr.length);
      mix(tr.hashCode);
    } else {
      mix(-1);
    }
  }
  mix(activeTranslatingHash?.hashCode ?? 0);
  return (sigA: h1, sigB: h2, translatedCount: translatedCount);
}

/// 双语/仅译文分页缓存 Key：按书籍/章号/显示模式/版心尺寸/排版参数及译文状态指纹唯一确定。
@immutable
class BilingualChapterPaginationKey {
  BilingualChapterPaginationKey({
    required this.bookId,
    required this.chapterIndex,
    required this.mode,
    required double maxWidth,
    required double maxHeight,
    required double fontSize,
    required double lineHeight,
    required double textScaleFactor,
    required this.sigA,
    required this.sigB,
    required this.translatedCount,
    this.anchorCharOffset = -1,
  }) : widthRounded = maxWidth.round(),
       heightRounded = maxHeight.round(),
       fontSizeTenths = (fontSize * 10).round(),
       lineHeightTenths = (lineHeight * 10).round(),
       textScaleTenths = (textScaleFactor * 100).round();

  final int bookId;
  final int chapterIndex;
  final BilingualDisplayMode mode;
  final int widthRounded;
  final int heightRounded;
  final int fontSizeTenths;
  final int lineHeightTenths;
  final int textScaleTenths;
  final int sigA;
  final int sigB;
  final int translatedCount;
  final int anchorCharOffset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BilingualChapterPaginationKey &&
          bookId == other.bookId &&
          chapterIndex == other.chapterIndex &&
          mode == other.mode &&
          widthRounded == other.widthRounded &&
          heightRounded == other.heightRounded &&
          fontSizeTenths == other.fontSizeTenths &&
          lineHeightTenths == other.lineHeightTenths &&
          textScaleTenths == other.textScaleTenths &&
          sigA == other.sigA &&
          sigB == other.sigB &&
          translatedCount == other.translatedCount &&
          anchorCharOffset == other.anchorCharOffset;

  @override
  int get hashCode => Object.hash(
    bookId,
    chapterIndex,
    mode,
    widthRounded,
    heightRounded,
    fontSizeTenths,
    lineHeightTenths,
    textScaleTenths,
    sigA,
    sigB,
    translatedCount,
    anchorCharOffset,
  );
}

/// 双语/仅译文按章分页 LRU 缓存（默认最多 16 章），切章及预热命中时零重排耗时直达。
class BilingualChapterPaginationCache {
  BilingualChapterPaginationCache({this.maxEntries = 16});

  static final BilingualChapterPaginationCache instance =
      BilingualChapterPaginationCache();

  final int maxEntries;
  final Map<BilingualChapterPaginationKey, List<ReaderPage>> _entries =
      <BilingualChapterPaginationKey, List<ReaderPage>>{};

  List<ReaderPage>? get(BilingualChapterPaginationKey key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit;
    return hit;
  }

  void put(BilingualChapterPaginationKey key, List<ReaderPage> pages) {
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
    Locale? locale,
    TextHeightBehavior? textHeightBehavior,
  }) : _painter = TextPainter(
         textDirection: TextDirection.ltr,
         textScaler: textScaler,
         locale: locale,
         textHeightBehavior: textHeightBehavior,
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
    Locale? locale,
    TextHeightBehavior? textHeightBehavior,
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
      locale: locale,
      textHeightBehavior: textHeightBehavior,
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
  Locale? locale,
  TextHeightBehavior? textHeightBehavior,
}) {
  final paginator = _ChapterPaginator(
    chapterIndex: chapterIndex,
    chapterTitle: chapterTitle,
    text: text,
    style: style,
    textScaler: textScaler,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    locale: locale,
    textHeightBehavior: textHeightBehavior,
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
  Locale? locale,
  TextHeightBehavior? textHeightBehavior,
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
    locale: locale,
    textHeightBehavior: textHeightBehavior,
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

/// 双语行间对照排版字体规格（分页测算与界面绘制严格共用同一套样式）。
({
  TextStyle transPrimaryStyle,
  TextStyle origSubtitleStyle,
  TextStyle untranslatedOrigStyle,
  TextStyle innerBreakStyle,
  TextStyle pairGapBreakStyle,
  TextStyle sentenceBreakStyle,
  TextStyle paragraphBreakStyle,
})
bilingualTypographyStyles({
  required TextStyle origStyle,
  required Color secondaryColor,
}) {
  final baseSize = origStyle.fontSize ?? 17.0;
  final baseHeight = origStyle.height ?? 1.8;
  return (
    transPrimaryStyle: origStyle.copyWith(
      fontSize: baseSize,
      height: math.max(1.26, math.min(1.36, baseHeight - 0.48)),
      letterSpacing: 0.2,
      color: origStyle.color,
    ),
    origSubtitleStyle: origStyle.copyWith(
      fontSize: math.max(10.5, baseSize * 0.68),
      height: 1.24,
      letterSpacing: 0.1,
      color: secondaryColor.withValues(alpha: 0.72),
    ),
    untranslatedOrigStyle: origStyle.copyWith(
      fontSize: math.max(13.0, baseSize * 0.90),
      height: math.max(1.44, baseHeight - 0.28),
      color: secondaryColor.withValues(alpha: 0.88),
    ),
    innerBreakStyle: origStyle.copyWith(fontSize: 1.5, height: 1.0),
    pairGapBreakStyle: origStyle.copyWith(
      fontSize: math.max(5.0, (baseHeight - 1.5) * 6.0 + 5.5),
      height: 1.0,
    ),
    sentenceBreakStyle: origStyle.copyWith(fontSize: 6.5, height: 1.0),
    paragraphBreakStyle: origStyle.copyWith(
      fontSize: math.max(15.5, (baseHeight - 1.5) * 9.0 + 16.0),
      height: 1.0,
    ),
  );
}

bool _isCjkOrWidePunctRune(int rune) =>
    (rune >= 0x2014 && rune <= 0x2026) ||
    (rune >= 0x3000 && rune <= 0x303F) ||
    (rune >= 0x3040 && rune <= 0x30FF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xAC00 && rune <= 0xD7AF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFF00 && rune <= 0xFFEF);

bool _isCjkWordBreakUnit(int rune) =>
    (rune >= 0x3040 && rune <= 0x30FF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xAC00 && rune <= 0xD7AF) ||
    (rune >= 0xF900 && rune <= 0xFAFF);

bool _needsJoinSpace(String left, String right) {
  if (left.isEmpty || right.isEmpty) return false;
  if (left[left.length - 1].trim().isEmpty || right[0].trim().isEmpty) {
    return false;
  }
  final leftRune = left.runes.last;
  final rightRune = right.runes.first;
  return !_isCjkOrWidePunctRune(leftRune) && !_isCjkOrWidePunctRune(rightRune);
}

int _advancePastOneGraphemeSafe(String text, int offset) {
  if (offset >= text.length) return text.length;
  final unit = text.codeUnitAt(offset);
  if (unit >= 0xD800 && unit <= 0xDBFF && offset + 1 < text.length) {
    return offset + 2;
  }
  return offset + 1;
}

class _RunFragment {
  const _RunFragment({
    required this.text,
    required this.kind,
    this.origStartChar = -1,
    this.origEndChar = -1,
    this.transStartChar = -1,
    this.transEndChar = -1,
    this.paragraphIndex = -1,
    this.isTranslating = false,
    this.exactOrigMapping = false,
  });

  final String text;
  final BilingualRunKind kind;
  final int origStartChar;
  final int origEndChar;
  final int transStartChar;
  final int transEndChar;
  final int paragraphIndex;
  final bool isTranslating;
  final bool exactOrigMapping;
}

class _SentenceRunSpan {
  const _SentenceRunSpan({
    required this.block,
    required this.start,
    required this.end,
    this.origTrimDelta = 0,
  });

  final BilingualPageBlock block;
  final int start;
  final int end;
  final int origTrimDelta;
}

class _BilingualVisualUnit {
  const _BilingualVisualUnit({
    required this.primaryFragments,
    required this.subtitleFragments,
    required this.breakAfterKind,
    required this.unitOrigStart,
    required this.unitOrigEnd,
    required this.touchedBlocks,
  });

  final List<_RunFragment> primaryFragments;
  final List<_RunFragment> subtitleFragments;
  final BilingualRunKind breakAfterKind;
  final int unitOrigStart;
  final int unitOrigEnd;
  final List<BilingualPageBlock> touchedBlocks;
}

List<({int start, int end})> _extractVisualLineRanges(
  String text,
  TextPainter painter,
  TextStyle style,
  double safeWidth,
) {
  if (text.isEmpty) return const <({int start, int end})>[];
  painter.text = TextSpan(text: text, style: style);
  painter.layout(maxWidth: safeWidth);
  final lines = <({int start, int end})>[];
  var offset = 0;
  var lastEmittedEnd = 0;
  while (offset < text.length) {
    final boundary = painter.getLineBoundary(TextPosition(offset: offset));
    var end = boundary.end.clamp(offset, text.length);
    if (end <= offset) {
      end = _advancePastOneGraphemeSafe(text, offset);
    }
    var trimStart = math.max(offset, lastEmittedEnd);
    while (trimStart < end && text[trimStart].trim().isEmpty) {
      trimStart++;
    }
    var trimEnd = end;
    while (trimEnd > trimStart && text[trimEnd - 1].trim().isEmpty) {
      trimEnd--;
    }
    if (trimStart < trimEnd) {
      lines.add((start: trimStart, end: trimEnd));
      lastEmittedEnd = trimEnd;
    }
    offset = end;
  }
  return lines;
}

int _snapToWordBoundary(String text, int rawIndex, int minIndex, int maxIndex) {
  final target = rawIndex.clamp(minIndex, maxIndex);
  if (target <= minIndex || target >= maxIndex) return target;

  final leftSub = text.substring(minIndex, target);
  final rightSub = text.substring(target, maxIndex);
  final leftRune = leftSub.isNotEmpty ? leftSub.runes.last : 0;
  final rightRune = rightSub.isNotEmpty ? rightSub.runes.first : 0;
  if (_isCjkWordBreakUnit(leftRune) || _isCjkWordBreakUnit(rightRune)) {
    const closingPunct = '，。！？；：、）》」』”’,.!?;:)]}';
    const openingPunct = '（《「『“‘([{';
    var pos = target;
    while (pos < maxIndex && closingPunct.contains(text[pos])) {
      pos++;
    }
    while (pos > minIndex && openingPunct.contains(text[pos - 1])) {
      pos--;
    }
    return pos;
  }

  var prevBreak = minIndex;
  for (var i = target; i > minIndex; i--) {
    final chBefore = text[i - 1];
    if (chBefore.trim().isEmpty) {
      prevBreak = i;
      while (prevBreak > minIndex && text[prevBreak - 1].trim().isEmpty) {
        prevBreak--;
      }
      break;
    }
    if (i < maxIndex &&
        (chBefore == '-' || chBefore == '/' || chBefore == '—')) {
      prevBreak = i;
      break;
    }
  }

  var nextBreak = maxIndex;
  for (var i = target; i < maxIndex; i++) {
    final ch = text[i];
    if (ch.trim().isEmpty) {
      nextBreak = i;
      break;
    }
    if (ch == '-' || ch == '/' || ch == '—') {
      nextBreak = math.min(maxIndex, i + 1);
      break;
    }
  }

  if (prevBreak <= minIndex) {
    return nextBreak;
  }
  return (target - prevBreak <= nextBreak - target) ? prevBreak : nextBreak;
}

int _measureOneLineEnd(
  String fullText,
  int start,
  TextPainter enPainter,
  TextStyle origSubStyle,
  double safeWidth,
) {
  var s = start;
  while (s < fullText.length && fullText[s].trim().isEmpty) {
    s++;
  }
  if (s >= fullText.length) return fullText.length;

  enPainter.text = TextSpan(text: fullText.substring(s), style: origSubStyle);
  enPainter.layout(maxWidth: safeWidth);
  final boundary = enPainter.getLineBoundary(const TextPosition(offset: 0));
  var relEnd = boundary.end;
  if (relEnd <= 0) {
    relEnd = math.min(fullText.length - s, 1);
  }
  var absEnd = (s + relEnd).clamp(s, fullText.length);
  while (absEnd > s && fullText[absEnd - 1].trim().isEmpty) {
    absEnd--;
  }
  if (absEnd < fullText.length && absEnd > s) {
    final lastUnit = fullText.codeUnitAt(absEnd - 1);
    final nextUnit = fullText.codeUnitAt(absEnd);
    final lastIsSpace = fullText[absEnd - 1].trim().isEmpty;
    final nextIsSpace = fullText[absEnd].trim().isEmpty;
    final isLatinMidWord =
        !lastIsSpace &&
        !nextIsSpace &&
        !_isCjkWordBreakUnit(lastUnit) &&
        !_isCjkWordBreakUnit(nextUnit) &&
        lastUnit != 0x2D &&
        lastUnit != 0x2F &&
        lastUnit != 0x2014;
    if (isLatinMidWord) {
      var snapBack = absEnd;
      while (snapBack > s && fullText[snapBack - 1].trim().isNotEmpty) {
        snapBack--;
      }
      while (snapBack > s && fullText[snapBack - 1].trim().isEmpty) {
        snapBack--;
      }
      if (snapBack > s) {
        absEnd = snapBack;
      }
    }
  }
  return absEnd > s ? absEnd : _advancePastOneGraphemeSafe(fullText, s);
}

List<_RunFragment> _splitRangeBySentenceSpans({
  required String runText,
  required int rangeStart,
  required int rangeEnd,
  required List<_SentenceRunSpan> spans,
  required BilingualRunKind kind,
  required bool projectExactOrig,
}) {
  if (rangeStart >= rangeEnd) return const <_RunFragment>[];
  final fragments = <_RunFragment>[];
  var cursor = rangeStart;
  for (var i = 0; i < spans.length; i++) {
    final sp = spans[i];
    if (sp.end <= rangeStart) continue;
    if (sp.start >= rangeEnd) break;

    if (cursor < sp.start) {
      final gapEnd = math.min(sp.start, rangeEnd);
      if (cursor < gapEnd) {
        final prevBlock = i > 0 ? spans[i - 1].block : sp.block;
        final hasGapOrig = i > 0 && prevBlock.origEndChar < sp.block.origStartChar;
        final gapExact = projectExactOrig &&
            hasGapOrig &&
            (sp.block.origStartChar - prevBlock.origEndChar) == (gapEnd - cursor);
        fragments.add(
          _RunFragment(
            text: runText.substring(cursor, gapEnd),
            kind: kind,
            origStartChar: hasGapOrig ? prevBlock.origEndChar : -1,
            origEndChar: hasGapOrig ? sp.block.origStartChar : -1,
            paragraphIndex: sp.block.paragraphIndex,
            exactOrigMapping: gapExact,
          ),
        );
        cursor = gapEnd;
      }
    }

    final ovStart = math.max(rangeStart, sp.start);
    final ovEnd = math.min(rangeEnd, sp.end);
    if (ovStart < ovEnd) {
      final rawOrigStart = sp.block.origStartChar + sp.origTrimDelta + (ovStart - sp.start);
      final rawOrigEnd = sp.block.origStartChar + sp.origTrimDelta + (ovEnd - sp.start);
      final origStart = projectExactOrig
          ? rawOrigStart.clamp(sp.block.origStartChar, sp.block.origEndChar)
          : sp.block.origStartChar;
      final origEnd = projectExactOrig
          ? rawOrigEnd.clamp(origStart, sp.block.origEndChar)
          : sp.block.origEndChar;
      final transStart = kind == BilingualRunKind.transPrimary
          ? ovStart - sp.start
          : -1;
      final transEnd = kind == BilingualRunKind.transPrimary
          ? ovEnd - sp.start
          : -1;
      fragments.add(
        _RunFragment(
          text: runText.substring(ovStart, ovEnd),
          kind: kind,
          origStartChar: origStart,
          origEndChar: origEnd,
          transStartChar: transStart,
          transEndChar: transEnd,
          paragraphIndex: sp.block.paragraphIndex,
          exactOrigMapping: projectExactOrig,
        ),
      );
      cursor = ovEnd;
    }
  }
  if (cursor < rangeEnd && spans.isNotEmpty) {
    final lastBlock = spans.last.block;
    fragments.add(
      _RunFragment(
        text: runText.substring(cursor, rangeEnd),
        kind: kind,
        paragraphIndex: lastBlock.paragraphIndex,
      ),
    );
  }
  return fragments;
}

List<BilingualPageBlock> _touchedBlocksFromFragments(
  List<_RunFragment> primary,
  List<_RunFragment> subtitle,
  Map<int, BilingualPageBlock> byParagraphIndex,
) {
  final seen = <int>{};
  final touched = <BilingualPageBlock>[];
  for (final frag in primary) {
    if (frag.paragraphIndex >= 0 && seen.add(frag.paragraphIndex)) {
      final b = byParagraphIndex[frag.paragraphIndex];
      if (b != null) touched.add(b);
    }
  }
  for (final frag in subtitle) {
    if (frag.paragraphIndex >= 0 && seen.add(frag.paragraphIndex)) {
      final b = byParagraphIndex[frag.paragraphIndex];
      if (b != null) touched.add(b);
    }
  }
  return touched;
}

List<_BilingualVisualUnit> _compileTranslatedRunInterlinear({
  required List<BilingualPageBlock> runBlocks,
  required BilingualDisplayMode mode,
  required ({
    TextStyle transPrimaryStyle,
    TextStyle origSubtitleStyle,
    TextStyle untranslatedOrigStyle,
    TextStyle innerBreakStyle,
    TextStyle pairGapBreakStyle,
    TextStyle sentenceBreakStyle,
    TextStyle paragraphBreakStyle,
  })
  styles,
  required TextPainter zhPainter,
  required TextPainter enPainter,
  required double safeWidth,
}) {
  if (runBlocks.isEmpty) return const <_BilingualVisualUnit>[];

  final zhBuf = StringBuffer();
  final zhSpans = <_SentenceRunSpan>[];
  final enBuf = StringBuffer();
  final enSpans = <_SentenceRunSpan>[];
  final byParagraphIndex = <int, BilingualPageBlock>{
    for (final b in runBlocks) b.paragraphIndex: b,
  };

  for (final b in runBlocks) {
    final zhPart = b.translatedText!.trim();
    if (zhPart.isNotEmpty) {
      if (_needsJoinSpace(zhBuf.toString(), zhPart)) {
        zhBuf.write(' ');
      }
      final s = zhBuf.length;
      zhBuf.write(zhPart);
      zhSpans.add(_SentenceRunSpan(block: b, start: s, end: zhBuf.length));
    }

    final enPart = b.originalText.trim();
    if (enPart.isNotEmpty) {
      if (enBuf.isNotEmpty) {
        enBuf.write(' ');
      }
      final s = enBuf.length;
      final leadDelta = b.originalText.indexOf(enPart);
      enBuf.write(enPart);
      enSpans.add(
        _SentenceRunSpan(
          block: b,
          start: s,
          end: enBuf.length,
          origTrimDelta: leadDelta >= 0 ? leadDelta : 0,
        ),
      );
    }
  }

  final zhRun = zhBuf.toString();
  final enRun = enBuf.toString();
  final runEndsParagraph = runBlocks.last.isParagraphEnd;
  final tailBreakKind = runEndsParagraph
      ? BilingualRunKind.paragraphBreak
      : BilingualRunKind.sentenceBreak;

  final zhLines = _extractVisualLineRanges(
    zhRun,
    zhPainter,
    styles.transPrimaryStyle,
    safeWidth,
  );
  if (zhLines.isEmpty) {
    final fallbackFrags = <_RunFragment>[
      for (final b in runBlocks)
        () {
          final zhTrimmed = b.translatedText!.trim();
          return _RunFragment(
            text: zhTrimmed,
            kind: BilingualRunKind.transPrimary,
            origStartChar: b.origStartChar,
            origEndChar: b.origEndChar,
            transStartChar: 0,
            transEndChar: zhTrimmed.length,
            paragraphIndex: b.paragraphIndex,
          );
        }(),
    ];
    final fallbackSub = mode == BilingualDisplayMode.translatedOnly
        ? const <_RunFragment>[]
        : <_RunFragment>[
            for (final b in runBlocks)
              _RunFragment(
                text: b.originalText.trim(),
                kind: BilingualRunKind.origSubtitle,
                origStartChar: b.origStartChar,
                origEndChar: b.origEndChar,
                paragraphIndex: b.paragraphIndex,
                exactOrigMapping: true,
              ),
          ];
    return <_BilingualVisualUnit>[
      _BilingualVisualUnit(
        primaryFragments: fallbackFrags,
        subtitleFragments: fallbackSub,
        breakAfterKind: tailBreakKind,
        unitOrigStart: runBlocks.first.origStartChar,
        unitOrigEnd: runBlocks.last.origEndChar,
        touchedBlocks: List<BilingualPageBlock>.from(runBlocks),
      ),
    ];
  }

  final runOrigMin = runBlocks.first.origStartChar;
  final runOrigMax = runBlocks.last.origEndChar;
  final units = <_BilingualVisualUnit>[];
  var enCursor = 0;
  var prevUnitOrigEnd = runOrigMin;

  for (var k = 0; k < zhLines.length; k++) {
    final zhLine = zhLines[k];
    final primaryFragments = _splitRangeBySentenceSpans(
      runText: zhRun,
      rangeStart: zhLine.start,
      rangeEnd: zhLine.end,
      spans: zhSpans,
      kind: BilingualRunKind.transPrimary,
      projectExactOrig: false,
    );

    var subtitleFragments = const <_RunFragment>[];
    if (mode != BilingualDisplayMode.translatedOnly &&
        enCursor < enRun.length) {
      while (enCursor < enRun.length && enRun[enCursor].trim().isEmpty) {
        enCursor++;
      }
      if (enCursor < enRun.length) {
        final enLineStart = enCursor;
        int enLineEnd;
        if (k == zhLines.length - 1) {
          enLineEnd = enRun.length;
          while (enLineEnd > enLineStart &&
              enRun[enLineEnd - 1].trim().isEmpty) {
            enLineEnd--;
          }
          enCursor = enRun.length;
        } else {
          // 依据中文行尾所在的句子锚点做分段线性插值，防止长段渐进偏移
          var anchorZhSpan = zhSpans.last;
          for (final zs in zhSpans) {
            if (zhLine.end <= zs.end) {
              anchorZhSpan = zs;
              break;
            }
          }
          var anchorEnSpan = enSpans.last;
          for (final es in enSpans) {
            if (es.block.paragraphIndex == anchorZhSpan.block.paragraphIndex) {
              anchorEnSpan = es;
              break;
            }
          }
          final zhSpanLen = math.max(1, anchorZhSpan.end - anchorZhSpan.start);
          final frac = ((zhLine.end - anchorZhSpan.start) / zhSpanLen).clamp(
            0.0,
            1.0,
          );
          final rawTarget =
              anchorEnSpan.start +
              (frac * (anchorEnSpan.end - anchorEnSpan.start)).round();
          final desiredEnd = _snapToWordBoundary(
            enRun,
            rawTarget,
            enLineStart,
            enRun.length,
          );
          if (desiredEnd <= enLineStart) {
            enLineEnd = enLineStart;
          } else {
            final oneLineEnd = _measureOneLineEnd(
              enRun,
              enLineStart,
              enPainter,
              styles.origSubtitleStyle,
              safeWidth,
            );
            enLineEnd = math.min(desiredEnd, oneLineEnd);
            while (enLineEnd > enLineStart &&
                enRun[enLineEnd - 1].trim().isEmpty) {
              enLineEnd--;
            }
            enCursor = enLineEnd;
            while (enCursor < enRun.length && enRun[enCursor].trim().isEmpty) {
              enCursor++;
            }
          }
        }
        if (enLineEnd > enLineStart) {
          subtitleFragments = _splitRangeBySentenceSpans(
            runText: enRun,
            rangeStart: enLineStart,
            rangeEnd: enLineEnd,
            spans: enSpans,
            kind: BilingualRunKind.origSubtitle,
            projectExactOrig: true,
          );
        }
      }
    }

    final int rawUnitEnd;
    final exactSubs = subtitleFragments.where(
      (f) => f.exactOrigMapping && f.origStartChar >= 0,
    );
    if (exactSubs.isNotEmpty) {
      rawUnitEnd = exactSubs.map((f) => f.origEndChar).reduce(math.max);
    } else {
      final zhTotal = math.max(1, zhRun.length);
      rawUnitEnd =
          runOrigMin + ((zhLine.end / zhTotal) * (runOrigMax - runOrigMin)).round();
    }

    final unitStart = k == 0
        ? runOrigMin
        : prevUnitOrigEnd.clamp(runOrigMin, runOrigMax);
    var unitEnd = k == zhLines.length - 1
        ? runOrigMax
        : math.max(unitStart, rawUnitEnd.clamp(runOrigMin, runOrigMax));
    if (unitEnd < unitStart) unitEnd = unitStart;
    prevUnitOrigEnd = unitEnd;

    final breakAfterKind = k < zhLines.length - 1
        ? (mode == BilingualDisplayMode.translatedOnly
              ? BilingualRunKind.innerBreak
              : BilingualRunKind.pairGapBreak)
        : tailBreakKind;

    var touched = _touchedBlocksFromFragments(
      primaryFragments,
      subtitleFragments,
      byParagraphIndex,
    );
    if (touched.isEmpty) {
      touched = <BilingualPageBlock>[runBlocks.last];
    }

    units.add(
      _BilingualVisualUnit(
        primaryFragments: primaryFragments,
        subtitleFragments: subtitleFragments,
        breakAfterKind: breakAfterKind,
        unitOrigStart: unitStart,
        unitOrigEnd: unitEnd,
        touchedBlocks: touched,
      ),
    );
  }

  return units;
}

List<_BilingualVisualUnit> _compileBilingualVisualUnits({
  required List<BilingualPageBlock> blocks,
  required BilingualDisplayMode mode,
  required ({
    TextStyle transPrimaryStyle,
    TextStyle origSubtitleStyle,
    TextStyle untranslatedOrigStyle,
    TextStyle innerBreakStyle,
    TextStyle pairGapBreakStyle,
    TextStyle sentenceBreakStyle,
    TextStyle paragraphBreakStyle,
  })
  styles,
  required TextPainter zhPainter,
  required TextPainter enPainter,
  required double maxWidth,
}) {
  if (blocks.isEmpty) return const <_BilingualVisualUnit>[];
  final safeWidth = math.max(40.0, maxWidth - 2.0);
  final allUnits = <_BilingualVisualUnit>[];

  // 按自然段分组；段内连续已译句聚合成无缝流，遇到未译句时切换为柔和待译原文
  var idx = 0;
  while (idx < blocks.length) {
    final paragraphGroup = <BilingualPageBlock>[];
    while (idx < blocks.length) {
      final b = blocks[idx++];
      paragraphGroup.add(b);
      if (b.isParagraphEnd) break;
    }

    var pIdx = 0;
    while (pIdx < paragraphGroup.length) {
      if (paragraphGroup[pIdx].hasTranslation) {
        final translatedRun = <BilingualPageBlock>[];
        while (pIdx < paragraphGroup.length &&
            paragraphGroup[pIdx].hasTranslation) {
          translatedRun.add(paragraphGroup[pIdx++]);
        }
        allUnits.addAll(
          _compileTranslatedRunInterlinear(
            runBlocks: translatedRun,
            mode: mode,
            styles: styles,
            zhPainter: zhPainter,
            enPainter: enPainter,
            safeWidth: safeWidth,
          ),
        );
      } else {
        final untrans = paragraphGroup[pIdx++];
        allUnits.add(
          _BilingualVisualUnit(
            primaryFragments: <_RunFragment>[
              _RunFragment(
                text: untrans.originalText,
                kind: BilingualRunKind.untranslatedOrig,
                origStartChar: untrans.origStartChar,
                origEndChar: untrans.origEndChar,
                paragraphIndex: untrans.paragraphIndex,
                isTranslating: untrans.isTranslating,
                exactOrigMapping: true,
              ),
            ],
            subtitleFragments: const <_RunFragment>[],
            breakAfterKind: untrans.isParagraphEnd
                ? BilingualRunKind.paragraphBreak
                : BilingualRunKind.sentenceBreak,
            unitOrigStart: untrans.origStartChar,
            unitOrigEnd: untrans.origEndChar,
            touchedBlocks: <BilingualPageBlock>[untrans],
          ),
        );
      }
    }
  }

  return allUnits;
}

({
  String displayText,
  List<BilingualDisplayRun> displayRuns,
  List<BilingualPageBlock> positionedBlocks,
  TextSpan rootSpan,
})
_assemblePageFromUnits({
  required List<_BilingualVisualUnit> units,
  required TextStyle origStyle,
  required ({
    TextStyle transPrimaryStyle,
    TextStyle origSubtitleStyle,
    TextStyle untranslatedOrigStyle,
    TextStyle innerBreakStyle,
    TextStyle pairGapBreakStyle,
    TextStyle sentenceBreakStyle,
    TextStyle paragraphBreakStyle,
  })
  styles,
}) {
  final textBuf = StringBuffer();
  final children = <InlineSpan>[];
  final runs = <BilingualDisplayRun>[];
  final blockOrder = <int>[];
  final blockMap = <int, BilingualPageBlock>{};
  final transMin = <int, int>{};
  final transMax = <int, int>{};
  final origMin = <int, int>{};
  final origMax = <int, int>{};
  var cursor = 0;

  void appendRun({
    required String str,
    required TextStyle style,
    required BilingualRunKind kind,
    int origStartChar = -1,
    int origEndChar = -1,
    int transStartChar = -1,
    int transEndChar = -1,
    int paragraphIndex = -1,
    bool isTranslating = false,
    bool exactOrigMapping = false,
  }) {
    if (str.isEmpty) return;
    final ds = cursor;
    textBuf.write(str);
    children.add(TextSpan(text: str, style: style));
    cursor += str.length;
    runs.add(
      BilingualDisplayRun(
        displayStart: ds,
        displayEnd: cursor,
        kind: kind,
        origStartChar: origStartChar,
        origEndChar: origEndChar,
        transStartChar: transStartChar,
        transEndChar: transEndChar,
        paragraphIndex: paragraphIndex,
        isTranslating: isTranslating,
        exactOrigMapping: exactOrigMapping,
      ),
    );
    if (paragraphIndex >= 0) {
      if (kind == BilingualRunKind.transPrimary) {
        transMin[paragraphIndex] = transMin.containsKey(paragraphIndex)
            ? math.min(transMin[paragraphIndex]!, ds)
            : ds;
        transMax[paragraphIndex] = transMax.containsKey(paragraphIndex)
            ? math.max(transMax[paragraphIndex]!, cursor)
            : cursor;
      } else if (kind == BilingualRunKind.origSubtitle ||
          kind == BilingualRunKind.untranslatedOrig) {
        origMin[paragraphIndex] = origMin.containsKey(paragraphIndex)
            ? math.min(origMin[paragraphIndex]!, ds)
            : ds;
        origMax[paragraphIndex] = origMax.containsKey(paragraphIndex)
            ? math.max(origMax[paragraphIndex]!, cursor)
            : cursor;
      }
    }
  }

  for (var u = 0; u < units.length; u++) {
    final unit = units[u];
    for (final b in unit.touchedBlocks) {
      if (!blockMap.containsKey(b.paragraphIndex)) {
        blockMap[b.paragraphIndex] = b;
        blockOrder.add(b.paragraphIndex);
      }
    }
    if (u > 0) {
      final brkKind = units[u - 1].breakAfterKind;
      final (brkStr, brkStyle) = switch (brkKind) {
        BilingualRunKind.innerBreak => ('\n', styles.innerBreakStyle),
        BilingualRunKind.pairGapBreak => ('\n\n', styles.pairGapBreakStyle),
        BilingualRunKind.sentenceBreak => ('\n\n', styles.sentenceBreakStyle),
        _ => ('\n\n', styles.paragraphBreakStyle),
      };
      appendRun(str: brkStr, style: brkStyle, kind: brkKind);
    }

    for (final frag in unit.primaryFragments) {
      final style = switch (frag.kind) {
        BilingualRunKind.transPrimary => styles.transPrimaryStyle,
        BilingualRunKind.untranslatedOrig => styles.untranslatedOrigStyle,
        _ => styles.origSubtitleStyle,
      };
      appendRun(
        str: frag.text,
        style: style,
        kind: frag.kind,
        origStartChar: frag.origStartChar,
        origEndChar: frag.origEndChar,
        transStartChar: frag.transStartChar,
        transEndChar: frag.transEndChar,
        paragraphIndex: frag.paragraphIndex,
        isTranslating: frag.isTranslating,
        exactOrigMapping: frag.exactOrigMapping,
      );
    }

    if (unit.subtitleFragments.isNotEmpty) {
      appendRun(
        str: '\n',
        style: styles.innerBreakStyle,
        kind: BilingualRunKind.innerBreak,
      );
      for (final frag in unit.subtitleFragments) {
        appendRun(
          str: frag.text,
          style: styles.origSubtitleStyle,
          kind: frag.kind,
          origStartChar: frag.origStartChar,
          origEndChar: frag.origEndChar,
          paragraphIndex: frag.paragraphIndex,
          isTranslating: frag.isTranslating,
          exactOrigMapping: frag.exactOrigMapping,
        );
      }
    }
  }

  final positioned = <BilingualPageBlock>[
    for (final idx in blockOrder)
      blockMap[idx]!.copyWith(
        origDisplayStart: origMin[idx] ?? 0,
        origDisplayEnd: origMax[idx] ?? 0,
        transDisplayStart: transMin[idx] ?? 0,
        transDisplayEnd: transMax[idx] ?? 0,
      ),
  ];

  return (
    displayText: textBuf.toString(),
    displayRuns: List<BilingualDisplayRun>.unmodifiable(runs),
    positionedBlocks: List<BilingualPageBlock>.unmodifiable(positioned),
    rootSpan: TextSpan(style: origStyle, children: children),
  );
}

/// 根据给定 [blocks] 组装双语/仅译文展示文本、视觉片段、映射坐标与排版 [TextSpan] 树（行间紧贴双语流）。
({
  String displayText,
  List<BilingualDisplayRun> displayRuns,
  List<BilingualPageBlock> positionedBlocks,
  TextSpan rootSpan,
})
composeBilingualPageLayout({
  required List<BilingualPageBlock> blocks,
  required TextStyle origStyle,
  required Color secondaryColor,
  double maxWidth = 360.0,
  TextScaler textScaler = TextScaler.noScaling,
  Locale? locale,
  TextHeightBehavior? textHeightBehavior,
}) {
  final styles = bilingualTypographyStyles(
    origStyle: origStyle,
    secondaryColor: secondaryColor,
  );
  if (blocks.isEmpty) {
    return (
      displayText: '',
      displayRuns: const <BilingualDisplayRun>[],
      positionedBlocks: const <BilingualPageBlock>[],
      rootSpan: TextSpan(style: origStyle, children: const <InlineSpan>[]),
    );
  }
  final mode = blocks.first.mode;
  final zhPainter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    locale: locale,
    textHeightBehavior: textHeightBehavior,
  );
  final enPainter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    locale: locale,
    textHeightBehavior: textHeightBehavior,
  );
  final units = _compileBilingualVisualUnits(
    blocks: blocks,
    mode: mode,
    styles: styles,
    zhPainter: zhPainter,
    enPainter: enPainter,
    maxWidth: maxWidth,
  );
  return _assemblePageFromUnits(
    units: units,
    origStyle: origStyle,
    styles: styles,
  );
}

/// 解析双语页局部选区 `[localStart, localEnd)` 实际命中的同语种视觉片段（避免跨行拖拽误裹挟夹行外文或译文）。
({
  bool isTranslation,
  List<({BilingualDisplayRun run, int start, int end})> hits,
})
resolveBilingualSelectionHits(ReaderPage page, int localStart, int localEnd) {
  final safeStart = localStart.clamp(0, page.text.length);
  final safeEnd = localEnd.clamp(0, page.text.length);
  if (safeStart >= safeEnd) {
    return (
      isTranslation: false,
      hits: const <({BilingualDisplayRun run, int start, int end})>[],
    );
  }
  final runs = page.displayRuns;
  if (runs == null || runs.isEmpty) {
    return (
      isTranslation: false,
      hits: const <({BilingualDisplayRun run, int start, int end})>[],
    );
  }
  final allHits = <({BilingualDisplayRun run, int start, int end})>[];
  for (final r in runs) {
    if (r.isBreak) continue;
    final s = math.max(safeStart, r.displayStart);
    final e = math.min(safeEnd, r.displayEnd);
    if (s < e) {
      allHits.add((run: r, start: s, end: e));
    }
  }
  if (allHits.isEmpty) {
    return (
      isTranslation: false,
      hits: const <({BilingualDisplayRun run, int start, int end})>[],
    );
  }

  final isOriginalOnly =
      allHits.first.run.kind != BilingualRunKind.transPrimary &&
      allHits.last.run.kind != BilingualRunKind.transPrimary;
  if (isOriginalOnly) {
    final origHits = <({BilingualDisplayRun run, int start, int end})>[
      for (final h in allHits)
        if (h.run.kind == BilingualRunKind.origSubtitle ||
            h.run.kind == BilingualRunKind.untranslatedOrig)
          h,
    ];
    if (origHits.isNotEmpty) {
      return (isTranslation: false, hits: origHits);
    }
  }

  final transAndUntrans = <({BilingualDisplayRun run, int start, int end})>[
    for (final h in allHits)
      if (h.run.kind == BilingualRunKind.transPrimary ||
          h.run.kind == BilingualRunKind.untranslatedOrig)
        h,
  ];
  if (transAndUntrans.isNotEmpty) {
    return (isTranslation: true, hits: transAndUntrans);
  }
  return (isTranslation: false, hits: allHits);
}

/// 将页面局部展示选区 `[localStart, localEnd)` 映射回原文章节偏移、纯净引用文字及精准译文句内偏移（支持行间对照跨三态划线）。
({
  int startOffset,
  int endOffset,
  String quote,
  bool isTranslation,
  int? transStartInFirst,
  int? transEndInLast,
})
resolveOriginalSelectionForPage(
  ReaderPage page,
  int localStart,
  int localEnd,
) {
  final safeStart = localStart.clamp(0, page.text.length);
  final safeEnd = localEnd.clamp(0, page.text.length);
  if (safeStart >= safeEnd) {
    return (
      startOffset: page.startChar,
      endOffset: page.startChar,
      quote: '',
      isTranslation: false,
      transStartInFirst: null,
      transEndInLast: null,
    );
  }

  final runs = page.displayRuns;
  if (runs != null && runs.isNotEmpty) {
    final resolved = resolveBilingualSelectionHits(page, safeStart, safeEnd);
    if (resolved.hits.isNotEmpty && !resolved.isTranslation) {
      int? minOrig;
      int? maxOrig;
      final quoteBuf = StringBuffer();
      for (final hit in resolved.hits) {
        final slice = page.text.substring(hit.start, hit.end);
        if (slice.trim().isNotEmpty) {
          if (_needsJoinSpace(quoteBuf.toString(), slice)) {
            quoteBuf.write(' ');
          }
          quoteBuf.write(slice);
        }
        final r = hit.run;
        if (r.origStartChar >= 0 && r.origEndChar > r.origStartChar) {
          final mappedS = r.exactOrigMapping
              ? (r.origStartChar + (hit.start - r.displayStart)).clamp(
                  r.origStartChar,
                  r.origEndChar,
                )
              : r.origStartChar;
          final mappedE = r.exactOrigMapping
              ? (r.origStartChar + (hit.end - r.displayStart)).clamp(
                  mappedS,
                  r.origEndChar,
                )
              : r.origEndChar;
          if (mappedS < mappedE) {
            minOrig = minOrig == null ? mappedS : math.min(minOrig, mappedS);
            maxOrig = maxOrig == null ? mappedE : math.max(maxOrig, mappedE);
          }
        }
      }
      if (minOrig != null && maxOrig != null && minOrig < maxOrig) {
        return (
          startOffset: minOrig,
          endOffset: maxOrig,
          quote: quoteBuf.toString().trim(),
          isTranslation: false,
          transStartInFirst: null,
          transEndInLast: null,
        );
      }
    }

    if (resolved.hits.isNotEmpty && resolved.isTranslation) {
      int? minOrig;
      int? maxOrig;
      int? transStartInFirst;
      int? transEndInLast;
      var sawParaBreakAfterFirst = false;

      for (final hit in resolved.hits) {
        final r = hit.run;
        if (r.origStartChar < 0 || r.origEndChar <= r.origStartChar) continue;
        final int mappedS;
        final int mappedE;
        if (r.kind == BilingualRunKind.untranslatedOrig && r.exactOrigMapping) {
          mappedS = (r.origStartChar + (hit.start - r.displayStart)).clamp(
            r.origStartChar,
            r.origEndChar,
          );
          mappedE = (r.origStartChar + (hit.end - r.displayStart)).clamp(
            mappedS,
            r.origEndChar,
          );
        } else {
          mappedS = r.origStartChar;
          mappedE = r.origEndChar;
        }
        if (mappedS < mappedE) {
          minOrig = minOrig == null ? mappedS : math.min(minOrig, mappedS);
          maxOrig = maxOrig == null ? mappedE : math.max(maxOrig, mappedE);
        }
        if (r.kind == BilingualRunKind.transPrimary && r.transStartChar >= 0) {
          final localTS = r.transStartChar + (hit.start - r.displayStart);
          final localTE = r.transStartChar + (hit.end - r.displayStart);
          transStartInFirst ??= localTS;
          transEndInLast = localTE;
        } else if (r.kind == BilingualRunKind.untranslatedOrig) {
          transEndInLast = null;
        }
      }

      // 多行划选中文主行时自动剔除穿插在中间的英文副标，拼接出连贯纯净的中文摘录
      final hitByRunStart = <int, ({BilingualDisplayRun run, int start, int end})>{
        for (final h in resolved.hits) h.run.displayStart: h,
      };
      final quoteBuf = StringBuffer();
      var prevPara = -1;
      for (final r in runs) {
        if (r.kind == BilingualRunKind.paragraphBreak &&
            safeStart < r.displayEnd &&
            safeEnd > r.displayStart &&
            quoteBuf.isNotEmpty) {
          sawParaBreakAfterFirst = true;
          if (!quoteBuf.toString().endsWith('\n')) {
            quoteBuf.write('\n');
          }
          continue;
        }
        final hit = hitByRunStart[r.displayStart];
        if (hit == null) continue;
        final slice = page.text.substring(hit.start, hit.end);
        if (slice.isEmpty) continue;
        if (quoteBuf.isNotEmpty && !quoteBuf.toString().endsWith('\n')) {
          if (r.kind == BilingualRunKind.untranslatedOrig &&
              prevPara != r.paragraphIndex) {
            quoteBuf.write(' ');
          } else if (_needsJoinSpace(quoteBuf.toString(), slice)) {
            quoteBuf.write(' ');
          }
        }
        quoteBuf.write(slice);
        prevPara = r.paragraphIndex;
      }

      final cleanQuote = quoteBuf.toString().trim();
      final fallbackRaw = sawParaBreakAfterFirst
          ? page.text.substring(safeStart, safeEnd).trim()
          : '';
      return (
        startOffset: minOrig ?? page.startChar,
        endOffset: maxOrig ?? page.endChar,
        quote: cleanQuote.isNotEmpty
            ? cleanQuote
            : (fallbackRaw.isNotEmpty
                  ? fallbackRaw
                  : page.text.substring(safeStart, safeEnd).trim()),
        isTranslation: true,
        transStartInFirst: transStartInFirst,
        transEndInLast: transEndInLast,
      );
    }
  }

  final blocks = page.blocks;
  if (blocks == null || blocks.isEmpty) {
    return (
      startOffset: page.startChar + safeStart,
      endOffset: page.startChar + safeEnd,
      quote: page.text.substring(safeStart, safeEnd).trim(),
      isTranslation: false,
      transStartInFirst: null,
      transEndInLast: null,
    );
  }

  int? minOrig;
  int? maxOrig;
  for (final b in blocks) {
    if (b.origDisplayEnd <= b.origDisplayStart) continue;
    final ovStart = math.max(safeStart, b.origDisplayStart);
    final ovEnd = math.min(safeEnd, b.origDisplayEnd);
    if (ovStart < ovEnd) {
      final mappedStart = b.origStartChar + (ovStart - b.origDisplayStart);
      final mappedEnd = b.origStartChar + (ovEnd - b.origDisplayStart);
      minOrig = minOrig == null ? mappedStart : math.min(minOrig, mappedStart);
      maxOrig = maxOrig == null ? mappedEnd : math.max(maxOrig, mappedEnd);
    }
  }
  if (minOrig != null && maxOrig != null && minOrig < maxOrig) {
    return (
      startOffset: minOrig,
      endOffset: maxOrig,
      quote: page.text.substring(safeStart, safeEnd).trim(),
      isTranslation: false,
      transStartInFirst: null,
      transEndInLast: null,
    );
  }

  int? fallbackStart;
  int? fallbackEnd;
  var sawTrans = false;
  for (final b in blocks) {
    final bStart = math.min(
      b.origDisplayEnd > b.origDisplayStart
          ? b.origDisplayStart
          : b.transDisplayStart,
      b.transDisplayEnd > b.transDisplayStart
          ? b.transDisplayStart
          : b.origDisplayStart,
    );
    final bEnd = math.max(b.origDisplayEnd, b.transDisplayEnd);
    if (safeStart < bEnd && safeEnd > bStart) {
      if (b.transDisplayEnd > b.transDisplayStart &&
          safeStart < b.transDisplayEnd &&
          safeEnd > b.transDisplayStart) {
        sawTrans = true;
      }
      fallbackStart = fallbackStart == null
          ? b.origStartChar
          : math.min(fallbackStart, b.origStartChar);
      fallbackEnd = fallbackEnd == null
          ? b.origEndChar
          : math.max(fallbackEnd, b.origEndChar);
    }
  }
  return (
    startOffset: fallbackStart ?? page.startChar,
    endOffset: fallbackEnd ?? page.endChar,
    quote: page.text.substring(safeStart, safeEnd).trim(),
    isTranslation: sawTrans,
    transStartInFirst: null,
    transEndInLast: null,
  );
}

/// 分时让帧双语/仅译文分页：
/// 按段内连续译文流切分为「中文行 + 英文副标行」原子行对并严格按 [TextPainter] 实测高度跨页拆分，
/// 保证屏幕像素高度完全匹配、不留大块页底空白，且每页 [ReaderPage.startChar]/[endChar] 严格单调锚定原文偏移。
Future<List<ReaderPage>> paginateBilingualChapterBySizeAsync({
  required int chapterIndex,
  required String chapterTitle,
  required List<ParagraphSegment> segments,
  required Map<String, String> translationsByHash,
  required Set<String> activeTranslatingHashes,
  required BilingualDisplayMode mode,
  required TextStyle style,
  required Color secondaryColor,
  required TextScaler textScaler,
  required double maxWidth,
  required double maxHeight,
  Locale? locale,
  TextHeightBehavior? textHeightBehavior,
  bool Function()? isCancelled,
  int? anchorCharOffset,
}) async {
  if (segments.isEmpty || maxWidth <= 0 || maxHeight <= 0) {
    return <ReaderPage>[
      ReaderPage(
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        startChar: 0,
        endChar: 0,
        text: segments.isEmpty ? '（本章暂无内容）' : segments.first.text,
        pageInChapter: 1,
        pageCountInChapter: 1,
        blocks: const <BilingualPageBlock>[],
        displayRuns: const <BilingualDisplayRun>[],
      ),
    ];
  }

  final styles = bilingualTypographyStyles(
    origStyle: style,
    secondaryColor: secondaryColor,
  );
  final allBlocks = <BilingualPageBlock>[
    for (final s in segments)
      BilingualPageBlock(
        paragraphIndex: s.index,
        paragraphHash: s.hash,
        origStartChar: s.startChar,
        origEndChar: s.endChar,
        originalText: s.text,
        mode: mode,
        isParagraphEnd: s.isParagraphEnd,
        translatedText: translationsByHash[s.hash],
        isTranslating: activeTranslatingHashes.contains(s.hash),
      ),
  ];

  final zhPainter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    locale: locale,
    textHeightBehavior: textHeightBehavior,
  );
  final enPainter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    locale: locale,
    textHeightBehavior: textHeightBehavior,
  );
  final pagePainter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    locale: locale,
    textHeightBehavior: textHeightBehavior,
  );

  try {
    // 第 1 阶段：分时把各自然段编译为「中文行 + 英文副标行」或未译原句视觉单元
    final allUnits = <_BilingualVisualUnit>[];
    final sw = Stopwatch()..start();
    var idx = 0;
    final safeWidth = math.max(40.0, maxWidth - 2.0);
    while (idx < allBlocks.length) {
      if (isCancelled?.call() == true) return const <ReaderPage>[];
      final paragraphGroup = <BilingualPageBlock>[];
      while (idx < allBlocks.length) {
        final b = allBlocks[idx++];
        paragraphGroup.add(b);
        if (b.isParagraphEnd) break;
      }

      var pIdx = 0;
      while (pIdx < paragraphGroup.length) {
        if (paragraphGroup[pIdx].hasTranslation) {
          final translatedRun = <BilingualPageBlock>[];
          while (pIdx < paragraphGroup.length &&
              paragraphGroup[pIdx].hasTranslation) {
            translatedRun.add(paragraphGroup[pIdx++]);
          }
          allUnits.addAll(
            _compileTranslatedRunInterlinear(
              runBlocks: translatedRun,
              mode: mode,
              styles: styles,
              zhPainter: zhPainter,
              enPainter: enPainter,
              safeWidth: safeWidth,
            ),
          );
        } else {
          final untrans = paragraphGroup[pIdx++];
          allUnits.add(
            _BilingualVisualUnit(
              primaryFragments: <_RunFragment>[
                _RunFragment(
                  text: untrans.originalText,
                  kind: BilingualRunKind.untranslatedOrig,
                  origStartChar: untrans.origStartChar,
                  origEndChar: untrans.origEndChar,
                  paragraphIndex: untrans.paragraphIndex,
                  isTranslating: untrans.isTranslating,
                  exactOrigMapping: true,
                ),
              ],
              subtitleFragments: const <_RunFragment>[],
              breakAfterKind: untrans.isParagraphEnd
                  ? BilingualRunKind.paragraphBreak
                  : BilingualRunKind.sentenceBreak,
              unitOrigStart: untrans.origStartChar,
              unitOrigEnd: untrans.origEndChar,
              touchedBlocks: <BilingualPageBlock>[untrans],
            ),
          );
        }
      }

      if (sw.elapsedMilliseconds >= 8) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled?.call() == true) return const <ReaderPage>[];
        sw.reset();
      }
    }

    // 第 2 阶段：按视觉单元做指数扩展 + 二分测高装箱（避免逐单元全量组装导致的 O(k^2) 卡顿）
    TextSpan buildProbeSpan(int startUnit, int endUnit) {
      final children = <InlineSpan>[];
      for (var u = startUnit; u < endUnit; u++) {
        final unit = allUnits[u];
        if (u > startUnit) {
          final brkKind = allUnits[u - 1].breakAfterKind;
          final (brkStr, brkStyle) = switch (brkKind) {
            BilingualRunKind.innerBreak => ('\n', styles.innerBreakStyle),
            BilingualRunKind.pairGapBreak => ('\n\n', styles.pairGapBreakStyle),
            BilingualRunKind.sentenceBreak => ('\n\n', styles.sentenceBreakStyle),
            _ => ('\n\n', styles.paragraphBreakStyle),
          };
          if (brkStr.isNotEmpty) {
            children.add(TextSpan(text: brkStr, style: brkStyle));
          }
        }
        for (final frag in unit.primaryFragments) {
          if (frag.text.isEmpty) continue;
          final fragStyle = switch (frag.kind) {
            BilingualRunKind.transPrimary => styles.transPrimaryStyle,
            BilingualRunKind.untranslatedOrig => styles.untranslatedOrigStyle,
            _ => styles.origSubtitleStyle,
          };
          children.add(TextSpan(text: frag.text, style: fragStyle));
        }
        if (unit.subtitleFragments.isNotEmpty) {
          children.add(TextSpan(text: '\n', style: styles.innerBreakStyle));
          for (final frag in unit.subtitleFragments) {
            if (frag.text.isEmpty) continue;
            children.add(
              TextSpan(text: frag.text, style: styles.origSubtitleStyle),
            );
          }
        }
      }
      return TextSpan(style: style, children: children);
    }

    bool fitsRange(int startUnit, int count) {
      pagePainter.text = buildProbeSpan(startUnit, startUnit + count);
      pagePainter.layout(maxWidth: maxWidth);
      return pagePainter.height <= maxHeight;
    }

    final rawPages = <List<_BilingualVisualUnit>>[];

    Future<bool> packUnitSlice(int sliceStart, int sliceEnd) async {
      var cursor = sliceStart;
      var estUnitsPerPage = 8;
      sw.reset();

      while (cursor < sliceEnd) {
        if (isCancelled?.call() == true) return false;
        final remaining = sliceEnd - cursor;
        int take;
        if (remaining == 1) {
          take = 1;
        } else {
          var lo = 1;
          var hi = math.min(remaining, math.max(2, estUnitsPerPage));
          if (fitsRange(cursor, hi)) {
            lo = hi;
            while (hi < remaining) {
              if (isCancelled?.call() == true) return false;
              final nextHi = math.min(remaining, hi * 2);
              if (fitsRange(cursor, nextHi)) {
                lo = nextHi;
                hi = nextHi;
              } else {
                hi = nextHi;
                break;
              }
            }
          }
          if (lo == hi) {
            take = lo;
          } else {
            var best = lo;
            var left = lo + 1;
            var right = hi - 1;
            while (left <= right) {
              if (isCancelled?.call() == true) return false;
              final mid = (left + right) ~/ 2;
              if (fitsRange(cursor, mid)) {
                best = mid;
                left = mid + 1;
              } else {
                right = mid - 1;
              }
            }
            take = best;
          }
        }
        rawPages.add(allUnits.sublist(cursor, cursor + take));
        cursor += take;
        estUnitsPerPage = math.max(2, take + 2);
        if (sw.elapsedMilliseconds >= 8) {
          await Future<void>.delayed(Duration.zero);
          if (isCancelled?.call() == true) return false;
          sw.reset();
        }
      }
      return true;
    }

    var splitIdx = 0;
    if (anchorCharOffset != null &&
        anchorCharOffset > 0 &&
        allUnits.length > 1) {
      for (var i = 0; i < allUnits.length; i++) {
        final u = allUnits[i];
        if (anchorCharOffset >= u.unitOrigStart &&
            anchorCharOffset < u.unitOrigEnd) {
          splitIdx = i;
          break;
        }
        if (u.unitOrigStart >= anchorCharOffset) {
          splitIdx = i;
          break;
        }
      }
    }

    if (splitIdx > 0 && splitIdx < allUnits.length) {
      if (!await packUnitSlice(0, splitIdx)) return const <ReaderPage>[];
      if (!await packUnitSlice(splitIdx, allUnits.length)) {
        return const <ReaderPage>[];
      }
    } else {
      if (!await packUnitSlice(0, allUnits.length)) return const <ReaderPage>[];
    }

    final pageCount = rawPages.length;
    final result = <ReaderPage>[];
    for (var i = 0; i < pageCount; i++) {
      final pageUnits = rawPages[i];
      final assembled = _assemblePageFromUnits(
        units: pageUnits,
        origStyle: style,
        styles: styles,
      );
      final pageStartChar = pageUnits.first.unitOrigStart;
      final pageEndChar = i + 1 < pageCount
          ? math.max(
              pageStartChar,
              math.min(pageUnits.last.unitOrigEnd, rawPages[i + 1].first.unitOrigStart),
            )
          : math.max(pageStartChar, segments.last.endChar);
      result.add(
        ReaderPage(
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
          startChar: pageStartChar,
          endChar: pageEndChar,
          text: assembled.displayText,
          pageInChapter: i + 1,
          pageCountInChapter: pageCount,
          blocks: assembled.positionedBlocks,
          displayRuns: assembled.displayRuns,
        ),
      );
    }
    return result;
  } finally {
    zhPainter.dispose();
    enPainter.dispose();
    pagePainter.dispose();
  }
}
