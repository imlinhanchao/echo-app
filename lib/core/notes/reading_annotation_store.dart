import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../reader/reading_store.dart' show ReaderPage;

/// 阅读器划线与笔记墨色调色板（极简书房 Editorial Ink）。
enum ReadingHighlightColor {
  gold('香槟金', Color(0xFFD4AE74)),
  amber('暖琥珀', Color(0xFFD68A47)),
  sage('青玉绿', Color(0xFF6AA889)),
  rose('胭脂红', Color(0xFFC96F6F)),
  slate('霁青蓝', Color(0xFF6F94C9));

  const ReadingHighlightColor(this.label, this.color);

  final String label;
  final Color color;

  static ReadingHighlightColor fromKey(String? key) {
    if (key == null || key.isEmpty) return ReadingHighlightColor.gold;
    for (final value in ReadingHighlightColor.values) {
      if (value.name == key) return value;
    }
    return ReadingHighlightColor.gold;
  }
}

/// 一条阅读划线 / 读书笔记记录（按章节号 + 章内字符偏移精确定位）。
@immutable
class ReadingAnnotation {
  const ReadingAnnotation({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.startOffset,
    required this.endOffset,
    required this.quote,
    this.note = '',
    this.color = ReadingHighlightColor.gold,
    this.chapterTitle = '',
    required this.createdAt,
    required this.updatedAt,
  });

  factory ReadingAnnotation.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now().toUtc();
    final created =
        DateTime.tryParse(json['created_at'] as String? ?? '') ?? now;
    final updated =
        DateTime.tryParse(json['updated_at'] as String? ?? '') ?? created;
    final rawStart = (json['start_offset'] as num?)?.toInt() ?? 0;
    final rawEnd = (json['end_offset'] as num?)?.toInt() ?? rawStart;
    return ReadingAnnotation(
      id: json['id'] as String? ?? '',
      bookId: (json['book_id'] as num?)?.toInt() ?? 0,
      chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
      startOffset: math.min(rawStart, rawEnd),
      endOffset: math.max(rawStart, rawEnd),
      quote: json['quote'] as String? ?? '',
      note: json['note'] as String? ?? '',
      color: ReadingHighlightColor.fromKey(json['color'] as String?),
      chapterTitle: json['chapter_title'] as String? ?? '',
      createdAt: created,
      updatedAt: updated,
    );
  }

  final String id;
  final int bookId;
  final int chapterIndex;
  final int startOffset;
  final int endOffset;
  final String quote;
  final String note;
  final ReadingHighlightColor color;
  final String chapterTitle;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasNote => note.trim().isNotEmpty;

  ReadingAnnotation copyWith({
    String? id,
    int? bookId,
    int? chapterIndex,
    int? startOffset,
    int? endOffset,
    String? quote,
    String? note,
    ReadingHighlightColor? color,
    String? chapterTitle,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ReadingAnnotation(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      startOffset: startOffset ?? this.startOffset,
      endOffset: endOffset ?? this.endOffset,
      quote: quote ?? this.quote,
      note: note ?? this.note,
      color: color ?? this.color,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'book_id': bookId,
    'chapter_index': chapterIndex,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'quote': quote,
    'note': note,
    'color': color.name,
    'chapter_title': chapterTitle,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

int _compareAnnotations(ReadingAnnotation a, ReadingAnnotation b) {
  final ch = a.chapterIndex.compareTo(b.chapterIndex);
  if (ch != 0) return ch;
  final start = a.startOffset.compareTo(b.startOffset);
  if (start != 0) return start;
  return a.createdAt.compareTo(b.createdAt);
}

/// 书籍划线与笔记持久化接口。
abstract class ReadingAnnotationStore {
  Future<List<ReadingAnnotation>> listForBook(int bookId);
  Future<ReadingAnnotation> upsert(ReadingAnnotation annotation);
  Future<void> delete(int bookId, String annotationId);
  Future<void> deleteAllForBook(int bookId);
}

/// 基于本地 JSON 文件的按书分片划线/笔记存储。
///
/// 无平台文档目录权限（如纯 Widget 单元测试环境）时自动退回内存存储，确保不阻塞或崩溃。
class PersistentReadingAnnotationStore implements ReadingAnnotationStore {
  PersistentReadingAnnotationStore({Directory? rootDirOverride})
    : _rootDirOverride = rootDirOverride;

  final Directory? _rootDirOverride;
  final Map<int, List<ReadingAnnotation>> _memoryFallback =
      <int, List<ReadingAnnotation>>{};
  Directory? _cachedRoot;
  bool _useMemoryFallback = false;

  Future<Directory?> _ensureRoot() async {
    if (_useMemoryFallback) return null;
    if (_cachedRoot != null) return _cachedRoot;
    try {
      final base = _rootDirOverride ?? await getApplicationDocumentsDirectory();
      final dir = _rootDirOverride != null
          ? base
          : Directory(p.join(base.path, 'echo_reading_annotations'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _cachedRoot = dir;
      return dir;
    } catch (_) {
      _useMemoryFallback = true;
      return null;
    }
  }

  File _bookFile(Directory root, int bookId) =>
      File(p.join(root.path, 'book_$bookId.json'));

  List<ReadingAnnotation> _sortedCopy(Iterable<ReadingAnnotation> items) {
    final list = items.toList()..sort(_compareAnnotations);
    return List<ReadingAnnotation>.unmodifiable(list);
  }

  Future<List<ReadingAnnotation>> _readFile(Directory root, int bookId) async {
    final file = _bookFile(root, bookId);
    if (!await file.exists()) return const <ReadingAnnotation>[];
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return const <ReadingAnnotation>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ReadingAnnotation>[];
      return _sortedCopy(
        decoded.whereType<Map<String, dynamic>>().map(
          ReadingAnnotation.fromJson,
        ),
      );
    } catch (_) {
      return const <ReadingAnnotation>[];
    }
  }

  Future<void> _writeFile(
    Directory root,
    int bookId,
    List<ReadingAnnotation> items,
  ) async {
    final file = _bookFile(root, bookId);
    final payload = jsonEncode(items.map((e) => e.toJson()).toList());
    await file.writeAsString(payload, flush: true);
  }

  @override
  Future<List<ReadingAnnotation>> listForBook(int bookId) async {
    final root = await _ensureRoot();
    if (root == null) {
      return _sortedCopy(_memoryFallback[bookId] ?? const <ReadingAnnotation>[]);
    }
    return _readFile(root, bookId);
  }

  @override
  Future<ReadingAnnotation> upsert(ReadingAnnotation annotation) async {
    final root = await _ensureRoot();
    if (root == null) {
      final list = List<ReadingAnnotation>.from(
        _memoryFallback[annotation.bookId] ?? const <ReadingAnnotation>[],
      );
      list.removeWhere((a) => a.id == annotation.id);
      list.add(annotation);
      _memoryFallback[annotation.bookId] = _sortedCopy(list);
      return annotation;
    }
    final list = List<ReadingAnnotation>.from(
      await _readFile(root, annotation.bookId),
    );
    list.removeWhere((a) => a.id == annotation.id);
    list.add(annotation);
    await _writeFile(root, annotation.bookId, _sortedCopy(list));
    return annotation;
  }

  @override
  Future<void> delete(int bookId, String annotationId) async {
    final root = await _ensureRoot();
    if (root == null) {
      final list = _memoryFallback[bookId];
      if (list == null) return;
      final next = list.where((a) => a.id != annotationId).toList();
      if (next.isEmpty) {
        _memoryFallback.remove(bookId);
      } else {
        _memoryFallback[bookId] = _sortedCopy(next);
      }
      return;
    }
    final list = await _readFile(root, bookId);
    final next = list.where((a) => a.id != annotationId).toList();
    if (next.isEmpty) {
      final file = _bookFile(root, bookId);
      if (await file.exists()) {
        await file.delete();
      }
    } else {
      await _writeFile(root, bookId, _sortedCopy(next));
    }
  }

  @override
  Future<void> deleteAllForBook(int bookId) async {
    final root = await _ensureRoot();
    if (root == null) {
      _memoryFallback.remove(bookId);
      return;
    }
    final file = _bookFile(root, bookId);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// 纯内存划线/笔记存储（单元测试与 Widget 测试用）。
class MemoryReadingAnnotationStore implements ReadingAnnotationStore {
  final Map<int, List<ReadingAnnotation>> _items =
      <int, List<ReadingAnnotation>>{};

  @override
  Future<List<ReadingAnnotation>> listForBook(int bookId) async {
    final list = List<ReadingAnnotation>.from(
      _items[bookId] ?? const <ReadingAnnotation>[],
    )..sort(_compareAnnotations);
    return List<ReadingAnnotation>.unmodifiable(list);
  }

  @override
  Future<ReadingAnnotation> upsert(ReadingAnnotation annotation) async {
    final list = List<ReadingAnnotation>.from(
      _items[annotation.bookId] ?? const <ReadingAnnotation>[],
    );
    list.removeWhere((a) => a.id == annotation.id);
    list.add(annotation);
    list.sort(_compareAnnotations);
    _items[annotation.bookId] = list;
    return annotation;
  }

  @override
  Future<void> delete(int bookId, String annotationId) async {
    final list = _items[bookId];
    if (list == null) return;
    list.removeWhere((a) => a.id == annotationId);
    if (list.isEmpty) {
      _items.remove(bookId);
    }
  }

  @override
  Future<void> deleteAllForBook(int bookId) async {
    _items.remove(bookId);
  }
}

/// 单本书的划线与笔记状态控制器。
class BookAnnotationsController extends StateNotifier<List<ReadingAnnotation>> {
  BookAnnotationsController(this._store, this.bookId)
    : super(const <ReadingAnnotation>[]) {
    unawaited(load());
  }

  final ReadingAnnotationStore _store;
  final int bookId;

  Future<void> load() async {
    final list = await _store.listForBook(bookId);
    if (!mounted) return;
    state = list;
  }

  Future<ReadingAnnotation> add({
    required int chapterIndex,
    required int startOffset,
    required int endOffset,
    required String quote,
    String note = '',
    ReadingHighlightColor color = ReadingHighlightColor.gold,
    String chapterTitle = '',
  }) async {
    final start = math.min(startOffset, endOffset);
    final end = math.max(startOffset, endOffset);
    final now = DateTime.now().toUtc();
    final ann = ReadingAnnotation(
      id: '${now.microsecondsSinceEpoch}_${state.length}',
      bookId: bookId,
      chapterIndex: chapterIndex,
      startOffset: start,
      endOffset: end,
      quote: quote,
      note: note.trim(),
      color: color,
      chapterTitle: chapterTitle,
      createdAt: now,
      updatedAt: now,
    );
    await _store.upsert(ann);
    final refreshed = await _store.listForBook(bookId);
    if (mounted) {
      state = refreshed;
    }
    return ann;
  }

  Future<ReadingAnnotation> update(ReadingAnnotation updated) async {
    final next = updated.copyWith(
      note: updated.note.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    await _store.upsert(next);
    final refreshed = await _store.listForBook(bookId);
    if (mounted) {
      state = refreshed;
    }
    return next;
  }

  Future<void> remove(String annotationId) async {
    await _store.delete(bookId, annotationId);
    if (!mounted) return;
    state = state.where((a) => a.id != annotationId).toList(growable: false);
  }
}

final Provider<ReadingAnnotationStore> readingAnnotationStoreProvider =
    Provider<ReadingAnnotationStore>((ref) => PersistentReadingAnnotationStore());

final StateNotifierProviderFamily<
  BookAnnotationsController,
  List<ReadingAnnotation>,
  int
>
bookAnnotationsProvider = StateNotifierProvider.family<
  BookAnnotationsController,
  List<ReadingAnnotation>,
  int
>((ref, bookId) {
  return BookAnnotationsController(
    ref.watch(readingAnnotationStoreProvider),
    bookId,
  );
});

/// 单页正文切割后的互不重叠样式片段（保证拼接后与原正文完全一致，不改变排版高度）。
@immutable
class StyledPageSegment {
  const StyledPageSegment({
    required this.start,
    required this.end,
    required this.text,
    this.annotation,
    this.isActiveCue = false,
  });

  final int start;
  final int end;
  final String text;
  final ReadingAnnotation? annotation;
  final bool isActiveCue;
}

typedef _ProjectedAnnotation = ({
  int start,
  int end,
  ReadingAnnotation annotation,
});

/// 将当前页内所有划线与当前听书高亮句按区间端点拆分为互不重叠的顺序片段。
List<StyledPageSegment> buildStyledPageSegments({
  required ReaderPage page,
  required List<ReadingAnnotation> annotations,
  ({int start, int end})? activeCueSpan,
}) {
  final textLen = page.text.length;
  if (textLen == 0) return const <StyledPageSegment>[];

  final points = <int>{0, textLen};
  final projected = <_ProjectedAnnotation>[];

  for (final ann in annotations) {
    if (ann.chapterIndex != page.chapterIndex) continue;
    final s = (ann.startOffset - page.startChar).clamp(0, textLen);
    final e = (ann.endOffset - page.startChar).clamp(0, textLen);
    if (s >= e) continue;
    points.add(s);
    points.add(e);
    projected.add((start: s, end: e, annotation: ann));
  }

  int? cueStart;
  int? cueEnd;
  if (activeCueSpan != null) {
    final s = activeCueSpan.start.clamp(0, textLen);
    final e = activeCueSpan.end.clamp(0, textLen);
    if (s < e) {
      cueStart = s;
      cueEnd = e;
      points.add(s);
      points.add(e);
    }
  }

  final sortedPoints = points.toList()..sort();
  final segments = <StyledPageSegment>[];

  for (var i = 0; i + 1 < sortedPoints.length; i++) {
    final segStart = sortedPoints[i];
    final segEnd = sortedPoints[i + 1];
    if (segStart >= segEnd) continue;

    final isCue =
        cueStart != null &&
        cueEnd != null &&
        segStart >= cueStart &&
        segEnd <= cueEnd;

    ReadingAnnotation? bestAnn;
    for (final item in projected) {
      if (item.start <= segStart && item.end >= segEnd) {
        if (bestAnn == null) {
          bestAnn = item.annotation;
        } else {
          final currentNoteRank = bestAnn.hasNote ? 1 : 0;
          final nextNoteRank = item.annotation.hasNote ? 1 : 0;
          if (nextNoteRank > currentNoteRank ||
              (nextNoteRank == currentNoteRank &&
                  item.annotation.updatedAt.isAfter(bestAnn.updatedAt))) {
            bestAnn = item.annotation;
          }
        }
      }
    }

    segments.add(
      StyledPageSegment(
        start: segStart,
        end: segEnd,
        text: page.text.substring(segStart, segEnd),
        annotation: bestAnn,
        isActiveCue: isCue,
      ),
    );
  }

  return segments;
}

/// 根据长按命中的字符偏移自动扩展为语义词句选区（英文扩至完整单词，中文扩至分句且过长截窗）。
({int start, int end})? expandInitialSelection(String text, int rawOffset) {
  if (text.trim().isEmpty) return null;
  var offset = rawOffset.clamp(0, text.length - 1);
  const separators = '\n。！？；，、：“”「」（）()';

  bool isWordContent(String ch) => ch.trim().isNotEmpty && !separators.contains(ch);

  if (text[offset].trim().isEmpty) {
    int? nearestContent;
    int? nearestNonWs;
    for (var delta = 1; delta <= 8; delta++) {
      final fwd = offset + delta;
      if (fwd < text.length) {
        if (isWordContent(text[fwd])) {
          nearestContent = fwd;
          break;
        }
        nearestNonWs ??= text[fwd].trim().isNotEmpty ? fwd : null;
      }
      final bwd = offset - delta;
      if (bwd >= 0) {
        if (isWordContent(text[bwd])) {
          nearestContent = bwd;
          break;
        }
        nearestNonWs ??= text[bwd].trim().isNotEmpty ? bwd : null;
      }
    }
    final resolved = nearestContent ?? nearestNonWs;
    if (resolved == null) return null;
    offset = resolved;
  }

  final asciiWordChar = RegExp(r"[A-Za-z0-9_'-]");
  var start = offset;
  var end = offset + 1;

  if (asciiWordChar.hasMatch(text[offset])) {
    while (start > 0 && asciiWordChar.hasMatch(text[start - 1])) {
      start--;
    }
    while (end < text.length && asciiWordChar.hasMatch(text[end])) {
      end++;
    }
  } else {
    if (separators.contains(text[offset])) {
      var steps = 0;
      while (steps < 3 &&
          end < text.length &&
          !separators.contains(text[end])) {
        if (text[end].trim().isNotEmpty) steps++;
        end++;
      }
      if (steps == 0) {
        while (steps < 3 &&
            start > 0 &&
            !separators.contains(text[start - 1])) {
          if (text[start - 1].trim().isNotEmpty) steps++;
          start--;
        }
      }
    } else {
      while (start > 0 && !separators.contains(text[start - 1])) {
        start--;
      }
      while (end < text.length && !separators.contains(text[end])) {
        end++;
      }
      while (start < end && text[start].trim().isEmpty) {
        start++;
      }
      while (end > start && text[end - 1].trim().isEmpty) {
        end--;
      }
      if (end - start > 24) {
        start = (offset - 7).clamp(start, text.length - 1);
        end = math.min(text.length, start + 14);
      }
    }
  }

  while (start < end && text[start].trim().isEmpty) {
    start++;
  }
  while (end > start && text[end - 1].trim().isEmpty) {
    end--;
  }
  if (start >= end) return null;
  return (start: start, end: end);
}
