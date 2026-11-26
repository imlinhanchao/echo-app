import 'package:flutter/foundation.dart';

import 'discover_config.dart';

/// 规则配置来源。
enum DiscoverConfigOrigin { bundled, remoteCache }

/// 荐书动态扩展字段区块（由规则配置按来源声明并按语义样式动态渲染）。
///
/// 支持 `style`：`text` | `quote` | `list` | `positive_list` | `negative_list` | `tags`。
@immutable
class DiscoverExtraSection {
  const DiscoverExtraSection({
    required this.key,
    required this.label,
    this.style = 'text',
    this.text = '',
    this.items = const <String>[],
  });

  factory DiscoverExtraSection.fromJson(Map<String, dynamic> json) {
    final rawStyle = (json['style'] as String? ?? '').trim();
    final rawItems = json['items'] as List<dynamic>? ?? const <dynamic>[];
    return DiscoverExtraSection(
      key: (json['key'] as String? ?? '').trim(),
      label: (json['label'] as String? ?? '').trim(),
      style: rawStyle.isEmpty ? 'text' : rawStyle,
      text: (json['text'] as String? ?? '').trim(),
      items: rawItems
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
    );
  }

  final String key;
  final String label;
  final String style;
  final String text;
  final List<String> items;

  bool get isEmpty => text.isEmpty && items.isEmpty;
  bool get isNotEmpty => !isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'label': label,
    'style': style,
    if (text.isNotEmpty) 'text': text,
    if (items.isNotEmpty) 'items': items,
  };
}

/// 荐书单本条目。
@immutable
class DiscoverBook {
  const DiscoverBook({
    required this.title,
    this.author = '',
    this.publisher = '',
    this.year = '',
    this.meta = '',
    this.summary = '',
    this.note = '',
    this.score = '',
    this.pages = '',
    this.wordCount = '',
    this.chapterCount = '',
    this.isbn = '',
    this.coverUrl = '',
    this.detailUrl = '',
    this.sourceId = '',
    this.imageHeaders = const <String, String>{},
    this.extraSections = const <DiscoverExtraSection>[],
  });

  factory DiscoverBook.fromJson(Map<String, dynamic> json) {
    final hdrRaw = json['image_headers'];
    final imageHeaders = hdrRaw is Map
        ? <String, String>{
            for (final e in hdrRaw.entries)
              if (e.key.toString().isNotEmpty && e.value != null)
                e.key.toString(): e.value.toString(),
          }
        : const <String, String>{};
    final extrasRaw =
        json['extra_sections'] as List<dynamic>? ?? const <dynamic>[];
    final extraSections = extrasRaw
        .whereType<Map>()
        .map((e) => DiscoverExtraSection.fromJson(e.cast<String, dynamic>()))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return DiscoverBook(
      title: (json['title'] as String? ?? '').trim(),
      author: (json['author'] as String? ?? '').trim(),
      publisher: (json['publisher'] as String? ?? '').trim(),
      year: (json['year'] as String? ?? '').trim(),
      meta: (json['meta'] as String? ?? '').trim(),
      summary: (json['summary'] as String? ?? '').trim(),
      note: (json['note'] as String? ?? '').trim(),
      score: (json['score'] as String? ?? '').trim(),
      pages: (json['pages'] as String? ?? '').trim(),
      wordCount: (json['word_count'] as String? ?? '').trim(),
      chapterCount: (json['chapter_count'] as String? ?? '').trim(),
      isbn: (json['isbn'] as String? ?? '').trim(),
      coverUrl: (json['cover_url'] as String? ?? '').trim(),
      detailUrl: (json['detail_url'] as String? ?? '').trim(),
      sourceId: (json['source_id'] as String? ?? '').trim(),
      imageHeaders: Map<String, String>.unmodifiable(imageHeaders),
      extraSections: List<DiscoverExtraSection>.unmodifiable(extraSections),
    );
  }

  final String title;
  final String author;
  final String publisher;
  final String year;
  final String meta;
  final String summary;
  final String note;
  final String score;
  final String pages;
  final String wordCount;
  final String chapterCount;
  final String isbn;
  final String coverUrl;
  final String detailUrl;
  final String sourceId;
  final Map<String, String> imageHeaders;
  final List<DiscoverExtraSection> extraSections;

  /// 用于列表卡片的副标题（优先拼接作者 / 出版社 / 年份，缺失时回退 meta）。
  String get displaySubtitle {
    final parts = <String>[
      if (author.isNotEmpty) author,
      if (publisher.isNotEmpty) publisher,
      if (year.isNotEmpty) year,
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    return meta;
  }

  /// 点击「在书源中搜索此书」时填入搜索框的关键词。
  String get searchQuery => title.trim();

  /// 用于按 ISBN 搜索的标准数字/X 字符串（去除连字符与空白）。
  String get isbnSearchQuery => isbn.replaceAll(RegExp(r'[^0-9Xx]'), '').trim();

  /// 是否包含任一基础统计/标识信息（页数、字数、章节数、ISBN）。
  bool get hasBookStats =>
      pages.isNotEmpty ||
      wordCount.isNotEmpty ||
      chapterCount.isNotEmpty ||
      isbn.isNotEmpty;

  /// 将懒加载的详情页结果合并进列表项，保留列表既有元信息并补充简介与动态区块。
  DiscoverBook mergeDetail(DiscoverBook detail) {
    final detailKeys = <String>{
      for (final section in detail.extraSections)
        if (section.isNotEmpty) section.key,
    };
    final mergedExtras = <DiscoverExtraSection>[
      for (final section in extraSections)
        if (section.isNotEmpty && !detailKeys.contains(section.key)) section,
      for (final section in detail.extraSections)
        if (section.isNotEmpty) section,
    ];
    return DiscoverBook(
      title: title.isNotEmpty ? title : detail.title,
      author: author.isNotEmpty ? author : detail.author,
      publisher: publisher.isNotEmpty ? publisher : detail.publisher,
      year: year.isNotEmpty ? year : detail.year,
      meta: meta.isNotEmpty ? meta : detail.meta,
      summary: detail.summary.isNotEmpty ? detail.summary : summary,
      note: detail.note.isNotEmpty ? detail.note : note,
      score: score.isEmpty && detail.score.isNotEmpty ? detail.score : score,
      pages: detail.pages.isNotEmpty ? detail.pages : pages,
      wordCount: detail.wordCount.isNotEmpty ? detail.wordCount : wordCount,
      chapterCount: detail.chapterCount.isNotEmpty
          ? detail.chapterCount
          : chapterCount,
      isbn: detail.isbn.isNotEmpty ? detail.isbn : isbn,
      coverUrl: coverUrl.isNotEmpty ? coverUrl : detail.coverUrl,
      detailUrl: detailUrl.isNotEmpty ? detailUrl : detail.detailUrl,
      sourceId: sourceId.isNotEmpty ? sourceId : detail.sourceId,
      imageHeaders: imageHeaders.isNotEmpty ? imageHeaders : detail.imageHeaders,
      extraSections: List<DiscoverExtraSection>.unmodifiable(mergedExtras),
    );
  }

  DiscoverBook copyWith({
    String? title,
    String? author,
    String? publisher,
    String? year,
    String? meta,
    String? summary,
    String? note,
    String? score,
    String? pages,
    String? wordCount,
    String? chapterCount,
    String? isbn,
    String? coverUrl,
    String? detailUrl,
    String? sourceId,
    Map<String, String>? imageHeaders,
    List<DiscoverExtraSection>? extraSections,
  }) => DiscoverBook(
    title: title ?? this.title,
    author: author ?? this.author,
    publisher: publisher ?? this.publisher,
    year: year ?? this.year,
    meta: meta ?? this.meta,
    summary: summary ?? this.summary,
    note: note ?? this.note,
    score: score ?? this.score,
    pages: pages ?? this.pages,
    wordCount: wordCount ?? this.wordCount,
    chapterCount: chapterCount ?? this.chapterCount,
    isbn: isbn ?? this.isbn,
    coverUrl: coverUrl ?? this.coverUrl,
    detailUrl: detailUrl ?? this.detailUrl,
    sourceId: sourceId ?? this.sourceId,
    imageHeaders: imageHeaders ?? this.imageHeaders,
    extraSections: extraSections ?? this.extraSections,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    if (author.isNotEmpty) 'author': author,
    if (publisher.isNotEmpty) 'publisher': publisher,
    if (year.isNotEmpty) 'year': year,
    if (meta.isNotEmpty) 'meta': meta,
    if (summary.isNotEmpty) 'summary': summary,
    if (note.isNotEmpty) 'note': note,
    if (score.isNotEmpty) 'score': score,
    if (pages.isNotEmpty) 'pages': pages,
    if (wordCount.isNotEmpty) 'word_count': wordCount,
    if (chapterCount.isNotEmpty) 'chapter_count': chapterCount,
    if (isbn.isNotEmpty) 'isbn': isbn,
    if (coverUrl.isNotEmpty) 'cover_url': coverUrl,
    if (detailUrl.isNotEmpty) 'detail_url': detailUrl,
    if (sourceId.isNotEmpty) 'source_id': sourceId,
    if (imageHeaders.isNotEmpty) 'image_headers': imageHeaders,
    if (extraSections.isNotEmpty)
      'extra_sections': extraSections
          .map((s) => s.toJson())
          .toList(growable: false),
  };
}

/// 荐书主题书单。
@immutable
class DiscoverBooklist {
  const DiscoverBooklist({
    required this.title,
    this.meta = '',
    this.summary = '',
    this.covers = const <String>[],
    this.detailUrl = '',
    this.sourceId = '',
    this.imageHeaders = const <String, String>{},
  });

  factory DiscoverBooklist.fromJson(Map<String, dynamic> json) {
    final coversRaw = json['covers'] as List<dynamic>? ?? const <dynamic>[];
    final hdrRaw = json['image_headers'];
    final imageHeaders = hdrRaw is Map
        ? <String, String>{
            for (final e in hdrRaw.entries)
              if (e.key.toString().isNotEmpty && e.value != null)
                e.key.toString(): e.value.toString(),
          }
        : const <String, String>{};
    return DiscoverBooklist(
      title: (json['title'] as String? ?? '').trim(),
      meta: (json['meta'] as String? ?? '').trim(),
      summary: (json['summary'] as String? ?? '').trim(),
      covers: coversRaw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      detailUrl: (json['detail_url'] as String? ?? '').trim(),
      sourceId: (json['source_id'] as String? ?? '').trim(),
      imageHeaders: Map<String, String>.unmodifiable(imageHeaders),
    );
  }

  final String title;
  final String meta;
  final String summary;
  final List<String> covers;
  final String detailUrl;
  final String sourceId;
  final Map<String, String> imageHeaders;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    if (meta.isNotEmpty) 'meta': meta,
    if (summary.isNotEmpty) 'summary': summary,
    if (covers.isNotEmpty) 'covers': covers,
    if (detailUrl.isNotEmpty) 'detail_url': detailUrl,
    if (sourceId.isNotEmpty) 'source_id': sourceId,
    if (imageHeaders.isNotEmpty) 'image_headers': imageHeaders,
  };
}

/// 单个频道或书单详情页的拉取结果。
@immutable
class DiscoverFeedData {
  const DiscoverFeedData({
    required this.sourceId,
    required this.feedId,
    required this.title,
    this.kind = 'books',
    this.books = const <DiscoverBook>[],
    this.booklists = const <DiscoverBooklist>[],
    required this.fetchedAt,
    this.fromCache = false,
    this.isStale = false,
  });

  factory DiscoverFeedData.fromJson(Map<String, dynamic> json) {
    final booksRaw = json['books'] as List<dynamic>? ?? const <dynamic>[];
    final listsRaw = json['booklists'] as List<dynamic>? ?? const <dynamic>[];
    final fetchedMs = (json['fetched_at_ms'] as num?)?.toInt() ?? 0;
    return DiscoverFeedData(
      sourceId: (json['source_id'] as String? ?? '').trim(),
      feedId: (json['feed_id'] as String? ?? '').trim(),
      title: (json['title'] as String? ?? '').trim(),
      kind: (json['kind'] as String? ?? 'books').trim(),
      books: booksRaw
          .whereType<Map>()
          .map((e) => DiscoverBook.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
      booklists: listsRaw
          .whereType<Map>()
          .map((e) => DiscoverBooklist.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetchedMs, isUtc: true),
      fromCache: json['from_cache'] as bool? ?? true,
      isStale: json['is_stale'] as bool? ?? false,
    );
  }

  final String sourceId;
  final String feedId;
  final String title;
  final String kind;
  final List<DiscoverBook> books;
  final List<DiscoverBooklist> booklists;
  final DateTime fetchedAt;
  final bool fromCache;
  final bool isStale;

  bool get isBooklists => kind == 'booklists';
  bool get isEmpty => isBooklists ? booklists.isEmpty : books.isEmpty;

  DiscoverFeedData copyWith({
    String? sourceId,
    String? feedId,
    String? title,
    String? kind,
    List<DiscoverBook>? books,
    List<DiscoverBooklist>? booklists,
    DateTime? fetchedAt,
    bool? fromCache,
    bool? isStale,
  }) => DiscoverFeedData(
    sourceId: sourceId ?? this.sourceId,
    feedId: feedId ?? this.feedId,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    books: books ?? this.books,
    booklists: booklists ?? this.booklists,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    fromCache: fromCache ?? this.fromCache,
    isStale: isStale ?? this.isStale,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'source_id': sourceId,
    'feed_id': feedId,
    'title': title,
    'kind': kind,
    'books': books.map((b) => b.toJson()).toList(growable: false),
    'booklists': booklists.map((l) => l.toJson()).toList(growable: false),
    'fetched_at_ms': fetchedAt.toUtc().millisecondsSinceEpoch,
  };
}

/// 当前激活规则的快照元信息。
@immutable
class DiscoverConfigSnapshot {
  const DiscoverConfigSnapshot({
    required this.config,
    required this.origin,
    this.fetchedAt,
    this.remoteUrl = '',
  });

  final DiscoverRulesConfig config;
  final DiscoverConfigOrigin origin;
  final DateTime? fetchedAt;
  final String remoteUrl;

  String get originLabel =>
      origin == DiscoverConfigOrigin.remoteCache ? '远程配置缓存' : '内置默认规则';
}

/// 手动刷新远程配置的结果。
@immutable
class DiscoverConfigUpdateResult {
  const DiscoverConfigUpdateResult({
    required this.updated,
    required this.message,
    required this.snapshot,
  });

  final bool updated;
  final String message;
  final DiscoverConfigSnapshot snapshot;
}
