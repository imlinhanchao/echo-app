import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'discover_config.dart';
import 'discover_models.dart';

/// 荐书源页面/接口解析器抽象。
abstract class DiscoverParser {
  List<DiscoverBook> parseBooks(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverFeedConfig feed,
  );

  List<DiscoverBooklist> parseBooklists(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverFeedConfig feed,
  );

  List<DiscoverBook> parseBooklistDetail(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverDetailConfig detail,
  );

  DiscoverBook parseBookDetail(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverBookDetailConfig detail, {
    required DiscoverBook baseBook,
  });
}

/// 按 `source.mode`（`html` / `json`）分发解析器的注册表。
class DiscoverParserRegistry {
  DiscoverParserRegistry({Map<String, DiscoverParser>? parsers})
    : _parsers = parsers ??
          <String, DiscoverParser>{
            'html': HtmlDiscoverParser(),
            'json': JsonDiscoverParser(),
          };

  final Map<String, DiscoverParser> _parsers;

  DiscoverParser? forMode(String mode) =>
      _parsers[mode.trim().toLowerCase()];
}

/// 基于 CSS 选择器的声明式 HTML 解析器。
class HtmlDiscoverParser implements DiscoverParser {
  static const Set<String> _ignoredTextTags = <String>{
    'style',
    'script',
    'noscript',
  };

  static const Set<String> _ignoredSiblingTags = <String>{
    'script',
    'style',
    'link',
    'meta',
  };

  static const Set<String> _blockTags = <String>{
    'p',
    'div',
    'li',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
  };

  @override
  List<DiscoverBook> parseBooks(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverFeedConfig feed,
  ) {
    return _parseBookItems(
      rawBody: rawBody,
      source: source,
      itemsSelector: feed.itemsSelector,
      fields: feed.fields,
      extraFields: feed.extraFields,
    );
  }

  @override
  List<DiscoverBooklist> parseBooklists(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverFeedConfig feed,
  ) {
    if (feed.itemsSelector.isEmpty) return const <DiscoverBooklist>[];
    final doc = html_parser.parse(rawBody);
    final items = doc.querySelectorAll(feed.itemsSelector);
    final results = <DiscoverBooklist>[];
    final seenKeys = <String>{};
    final imageHeaders = source.effectiveImageHeaders;

    for (final item in items) {
      final title = _extractSingle(item, feed.fields['title'], source.baseUrl);
      if (title.isEmpty) continue;

      final meta = _extractSingle(item, feed.fields['meta'], source.baseUrl);
      final summary = _extractSingle(
        item,
        feed.fields['summary'],
        source.baseUrl,
      );
      final covers = _extractList(item, feed.fields['covers'], source.baseUrl);
      final detailUrl = _extractSingle(
        item,
        feed.fields['url'],
        source.baseUrl,
      );

      final dedupeKey = '$title::$detailUrl';
      if (!seenKeys.add(dedupeKey)) continue;

      results.add(
        DiscoverBooklist(
          title: title,
          meta: meta,
          summary: summary,
          covers: covers,
          detailUrl: detailUrl,
          sourceId: source.id,
          imageHeaders: imageHeaders,
        ),
      );
    }
    return results;
  }

  @override
  List<DiscoverBook> parseBooklistDetail(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverDetailConfig detail,
  ) {
    return _parseBookItems(
      rawBody: rawBody,
      source: source,
      itemsSelector: detail.itemsSelector,
      fields: detail.fields,
      extraFields: detail.extraFields,
    );
  }

  @override
  DiscoverBook parseBookDetail(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverBookDetailConfig detail, {
    required DiscoverBook baseBook,
  }) {
    final doc = html_parser.parse(rawBody);
    final root = doc.documentElement ?? doc.body;
    if (root == null) return baseBook;

    final fields = detail.fields;
    final title = _extractSingle(root, fields['title'], source.baseUrl);
    final rawAuthor = _extractSingle(root, fields['author'], source.baseUrl);
    final rawPublisher = _extractSingle(
      root,
      fields['publisher'],
      source.baseUrl,
    );
    final rawYear = _extractSingle(root, fields['year'], source.baseUrl);
    final meta = _extractSingle(root, fields['meta'], source.baseUrl);
    final summary = _extractSingle(root, fields['summary'], source.baseUrl);
    final note = _extractSingle(root, fields['note'], source.baseUrl);
    final score = _extractSingle(root, fields['score'], source.baseUrl);
    final pages = _extractSingle(root, fields['pages'], source.baseUrl);
    final wordCount = _extractSingle(
      root,
      fields['word_count'],
      source.baseUrl,
    );
    final chapterCount = _extractSingle(
      root,
      fields['chapter_count'],
      source.baseUrl,
    );
    final isbn = _extractSingle(root, fields['isbn'], source.baseUrl);
    final coverUrl = _extractSingle(root, fields['cover'], source.baseUrl);

    final resolved = _resolveBookMeta(
      author: rawAuthor,
      publisher: rawPublisher,
      year: rawYear,
      meta: meta,
    );
    final extraSections = _extractExtraSections(
      root,
      detail.extraFields,
      source.baseUrl,
    );

    final parsedDetail = DiscoverBook(
      title: title,
      author: resolved.author,
      publisher: resolved.publisher,
      year: resolved.year,
      meta: meta,
      summary: summary,
      note: note,
      score: score,
      pages: pages,
      wordCount: wordCount,
      chapterCount: chapterCount,
      isbn: isbn,
      coverUrl: coverUrl,
      sourceId: source.id,
      imageHeaders: source.effectiveImageHeaders,
      extraSections: extraSections,
    );
    return baseBook.mergeDetail(parsedDetail).copyWith(
      imageHeaders: source.effectiveImageHeaders,
    );
  }

  List<DiscoverBook> _parseBookItems({
    required String rawBody,
    required DiscoverSourceConfig source,
    required String itemsSelector,
    required Map<String, DiscoverFieldRule> fields,
    List<DiscoverExtraFieldConfig> extraFields =
        const <DiscoverExtraFieldConfig>[],
  }) {
    if (itemsSelector.isEmpty) return const <DiscoverBook>[];
    final doc = html_parser.parse(rawBody);
    final items = doc.querySelectorAll(itemsSelector);
    final results = <DiscoverBook>[];
    final seenKeys = <String>{};
    final imageHeaders = source.effectiveImageHeaders;

    for (final item in items) {
      final title = _extractSingle(item, fields['title'], source.baseUrl);
      if (title.isEmpty) continue;

      final rawAuthor = _extractSingle(item, fields['author'], source.baseUrl);
      final rawPublisher = _extractSingle(
        item,
        fields['publisher'],
        source.baseUrl,
      );
      final rawYear = _extractSingle(item, fields['year'], source.baseUrl);
      final meta = _extractSingle(item, fields['meta'], source.baseUrl);
      final summary = _extractSingle(item, fields['summary'], source.baseUrl);
      final note = _extractSingle(item, fields['note'], source.baseUrl);
      final score = _extractSingle(item, fields['score'], source.baseUrl);
      final pages = _extractSingle(item, fields['pages'], source.baseUrl);
      final wordCount = _extractSingle(
        item,
        fields['word_count'],
        source.baseUrl,
      );
      final chapterCount = _extractSingle(
        item,
        fields['chapter_count'],
        source.baseUrl,
      );
      final isbn = _extractSingle(item, fields['isbn'], source.baseUrl);
      final coverUrl = _extractSingle(item, fields['cover'], source.baseUrl);
      final detailUrl = _extractSingle(item, fields['url'], source.baseUrl);

      final resolved = _resolveBookMeta(
        author: rawAuthor,
        publisher: rawPublisher,
        year: rawYear,
        meta: meta,
      );

      final dedupeKey = detailUrl.isNotEmpty
          ? '$title::$detailUrl'
          : '$title::${resolved.author}';
      if (!seenKeys.add(dedupeKey)) continue;

      final extraSections = _extractExtraSections(
        item,
        extraFields,
        source.baseUrl,
      );

      results.add(
        DiscoverBook(
          title: title,
          author: resolved.author,
          publisher: resolved.publisher,
          year: resolved.year,
          meta: meta,
          summary: summary,
          note: note,
          score: score,
          pages: pages,
          wordCount: wordCount,
          chapterCount: chapterCount,
          isbn: isbn,
          coverUrl: coverUrl,
          detailUrl: detailUrl,
          sourceId: source.id,
          imageHeaders: imageHeaders,
          extraSections: extraSections,
        ),
      );
    }
    return results;
  }

  List<DiscoverExtraSection> _extractExtraSections(
    Element root,
    List<DiscoverExtraFieldConfig> extraFields,
    String baseUrl,
  ) {
    if (extraFields.isEmpty) return const <DiscoverExtraSection>[];
    final out = <DiscoverExtraSection>[];
    for (final cfg in extraFields) {
      final isList = _isExtraListField(cfg);
      final section = _buildExtraSection(
        cfg,
        items: isList ? _extractList(root, cfg.rule, baseUrl) : const <String>[],
        text: isList ? '' : _extractSingle(root, cfg.rule, baseUrl),
      );
      if (section != null) out.add(section);
    }
    return List<DiscoverExtraSection>.unmodifiable(out);
  }

  String _extractSingle(
    Element item,
    DiscoverFieldRule? rule,
    String baseUrl,
  ) {
    if (rule == null) return '';
    final elements = _locateElements(item, rule);
    if (elements.isEmpty) return '';

    for (final el in elements) {
      final raw = _readElementValue(el, rule);
      if (raw.isEmpty) continue;
      final transformed = _applyTransforms(raw, rule, baseUrl);
      if (transformed.isNotEmpty) return transformed;
    }
    return '';
  }

  List<String> _extractList(
    Element item,
    DiscoverFieldRule? rule,
    String baseUrl,
  ) {
    if (rule == null) return const <String>[];
    final elements = _locateElements(item, rule);
    if (elements.isEmpty) return const <String>[];

    final out = <String>[];
    final seen = <String>{};
    for (final el in elements) {
      final raw = _readElementValue(el, rule);
      if (raw.isEmpty) continue;
      final transformed = _applyTransforms(raw, rule, baseUrl);
      if (transformed.isNotEmpty && seen.add(transformed)) {
        out.add(transformed);
        if (rule.maxItems > 0 && out.length >= rule.maxItems) break;
        if (!rule.all && rule.maxItems <= 0) break;
      }
    }
    return out;
  }

  List<Element> _queryFirstMatching(
    Element scope,
    List<String> selectorCandidates,
  ) {
    for (final sel in selectorCandidates) {
      final matches = scope.querySelectorAll(sel);
      if (matches.isNotEmpty) return matches;
    }
    return const <Element>[];
  }

  List<Element> _locateElements(Element item, DiscoverFieldRule rule) {
    final selectorCandidates = rule.selectorCandidates;
    if (rule.nextSibling.isNotEmpty) {
      final sibling = item.nextElementSibling;
      if (sibling == null) return const <Element>[];
      final expectedTag = rule.nextSibling.toLowerCase();
      if (expectedTag != '*' &&
          (sibling.localName ?? '').toLowerCase() != expectedTag) {
        return const <Element>[];
      }
      if (selectorCandidates.isEmpty) return <Element>[sibling];
      return _queryFirstMatching(sibling, selectorCandidates);
    }
    if (rule.afterHeading.isNotEmpty) {
      final headingQuery = rule.headingSelector.isNotEmpty
          ? rule.headingSelector
          : 'h1, h2, h3, h4, .section-title';
      Element? matchedHeading;
      for (final h in item.querySelectorAll(headingQuery)) {
        final headingText = _normalizeWhitespace(
          _extractCleanText(h, preserveParagraphs: false),
        );
        if (headingText.contains(rule.afterHeading)) {
          matchedHeading = h;
          break;
        }
      }
      if (matchedHeading == null) return const <Element>[];

      var sibling = matchedHeading.nextElementSibling;
      while (sibling != null &&
          _ignoredSiblingTags.contains(
            (sibling.localName ?? '').toLowerCase(),
          )) {
        sibling = sibling.nextElementSibling;
      }
      if (sibling == null) return const <Element>[];
      if (selectorCandidates.isEmpty) return <Element>[sibling];
      return _queryFirstMatching(sibling, selectorCandidates);
    }
    if (selectorCandidates.isEmpty) return <Element>[item];
    return _queryFirstMatching(item, selectorCandidates);
  }

  String _readElementValue(Element element, DiscoverFieldRule rule) {
    final attrCandidates = rule.attrCandidates;
    if (attrCandidates.isEmpty) {
      return _extractCleanText(
        element,
        preserveParagraphs: rule.preserveParagraphs,
      );
    }
    for (final attr in attrCandidates) {
      final raw = element.attributes[attr];
      if (raw == null) continue;
      final trimmed = raw.trim();
      if (trimmed.isEmpty || _isPlaceholderDataUri(trimmed)) {
        continue;
      }
      return trimmed;
    }
    return '';
  }

  String _extractCleanText(
    Element element, {
    required bool preserveParagraphs,
  }) {
    if (!preserveParagraphs) {
      final buf = StringBuffer();
      void collectInline(Node node) {
        if (node is Element) {
          final tag = (node.localName ?? '').toLowerCase();
          if (_ignoredTextTags.contains(tag)) return;
          if (tag == 'br') {
            buf.write(' ');
            return;
          }
          for (final child in node.nodes) {
            collectInline(child);
          }
        } else if (node.nodeType == Node.TEXT_NODE) {
          buf.write(node.text ?? '');
        }
      }

      for (final child in element.nodes) {
        collectInline(child);
      }
      return _normalizeWhitespace(buf.toString());
    }

    final paragraphs = <String>[];
    final current = StringBuffer();

    void flushParagraph() {
      final line = _normalizeWhitespace(current.toString());
      current.clear();
      if (line.isNotEmpty) {
        paragraphs.add(line);
      }
    }

    void visit(Node node) {
      if (node is Element) {
        final tag = (node.localName ?? '').toLowerCase();
        if (_ignoredTextTags.contains(tag)) return;
        if (tag == 'br') {
          flushParagraph();
          return;
        }
        final isBlock = _blockTags.contains(tag);
        if (isBlock) flushParagraph();
        for (final child in node.nodes) {
          visit(child);
        }
        if (isBlock) flushParagraph();
      } else if (node.nodeType == Node.TEXT_NODE) {
        current.write(node.text ?? '');
      }
    }

    for (final child in element.nodes) {
      visit(child);
    }
    flushParagraph();
    return paragraphs.join('\n\n');
  }
}

/// 基于点路径的声明式 JSON 解析器（便于无缝切换静态 JSON / API 源）。
class JsonDiscoverParser implements DiscoverParser {
  @override
  List<DiscoverBook> parseBooks(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverFeedConfig feed,
  ) {
    return _parseBookItems(
      rawBody: rawBody,
      source: source,
      itemsPath: feed.itemsPath,
      fields: feed.fields,
      extraFields: feed.extraFields,
    );
  }

  @override
  List<DiscoverBooklist> parseBooklists(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverFeedConfig feed,
  ) {
    final items = _extractItems(rawBody, feed.itemsPath);
    if (items.isEmpty) return const <DiscoverBooklist>[];
    final results = <DiscoverBooklist>[];
    final seenKeys = <String>{};
    final imageHeaders = source.effectiveImageHeaders;

    for (final item in items) {
      final title = _extractSingle(item, feed.fields['title'], source.baseUrl);
      if (title.isEmpty) continue;

      final meta = _extractSingle(item, feed.fields['meta'], source.baseUrl);
      final summary = _extractSingle(
        item,
        feed.fields['summary'],
        source.baseUrl,
      );
      final covers = _extractList(item, feed.fields['covers'], source.baseUrl);
      final detailUrl = _extractSingle(
        item,
        feed.fields['url'],
        source.baseUrl,
      );

      final dedupeKey = '$title::$detailUrl';
      if (!seenKeys.add(dedupeKey)) continue;

      results.add(
        DiscoverBooklist(
          title: title,
          meta: meta,
          summary: summary,
          covers: covers,
          detailUrl: detailUrl,
          sourceId: source.id,
          imageHeaders: imageHeaders,
        ),
      );
    }
    return results;
  }

  @override
  List<DiscoverBook> parseBooklistDetail(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverDetailConfig detail,
  ) {
    return _parseBookItems(
      rawBody: rawBody,
      source: source,
      itemsPath: detail.itemsPath,
      fields: detail.fields,
      extraFields: detail.extraFields,
    );
  }

  @override
  DiscoverBook parseBookDetail(
    String rawBody,
    DiscoverSourceConfig source,
    DiscoverBookDetailConfig detail, {
    required DiscoverBook baseBook,
  }) {
    final decoded = jsonDecode(rawBody);
    if (decoded is! Map) return baseBook;
    final item = decoded.cast<String, dynamic>();
    final fields = detail.fields;

    final title = _extractSingle(item, fields['title'], source.baseUrl);
    final rawAuthor = _extractSingle(item, fields['author'], source.baseUrl);
    final rawPublisher = _extractSingle(
      item,
      fields['publisher'],
      source.baseUrl,
    );
    final rawYear = _extractSingle(item, fields['year'], source.baseUrl);
    final meta = _extractSingle(item, fields['meta'], source.baseUrl);
    final summary = _extractSingle(item, fields['summary'], source.baseUrl);
    final note = _extractSingle(item, fields['note'], source.baseUrl);
    final score = _extractSingle(item, fields['score'], source.baseUrl);
    final pages = _extractSingle(item, fields['pages'], source.baseUrl);
    final wordCount = _extractSingle(
      item,
      fields['word_count'],
      source.baseUrl,
    );
    final chapterCount = _extractSingle(
      item,
      fields['chapter_count'],
      source.baseUrl,
    );
    final isbn = _extractSingle(item, fields['isbn'], source.baseUrl);
    final coverUrl = _extractSingle(item, fields['cover'], source.baseUrl);

    final resolved = _resolveBookMeta(
      author: rawAuthor,
      publisher: rawPublisher,
      year: rawYear,
      meta: meta,
    );
    final extraSections = _extractExtraSections(
      item,
      detail.extraFields,
      source.baseUrl,
    );

    final parsedDetail = DiscoverBook(
      title: title,
      author: resolved.author,
      publisher: resolved.publisher,
      year: resolved.year,
      meta: meta,
      summary: summary,
      note: note,
      score: score,
      pages: pages,
      wordCount: wordCount,
      chapterCount: chapterCount,
      isbn: isbn,
      coverUrl: coverUrl,
      sourceId: source.id,
      imageHeaders: source.effectiveImageHeaders,
      extraSections: extraSections,
    );
    return baseBook.mergeDetail(parsedDetail).copyWith(
      imageHeaders: source.effectiveImageHeaders,
    );
  }

  List<DiscoverBook> _parseBookItems({
    required String rawBody,
    required DiscoverSourceConfig source,
    required String itemsPath,
    required Map<String, DiscoverFieldRule> fields,
    List<DiscoverExtraFieldConfig> extraFields =
        const <DiscoverExtraFieldConfig>[],
  }) {
    final items = _extractItems(rawBody, itemsPath);
    if (items.isEmpty) return const <DiscoverBook>[];
    final results = <DiscoverBook>[];
    final seenKeys = <String>{};
    final imageHeaders = source.effectiveImageHeaders;

    for (final item in items) {
      final title = _extractSingle(item, fields['title'], source.baseUrl);
      if (title.isEmpty) continue;

      final rawAuthor = _extractSingle(item, fields['author'], source.baseUrl);
      final rawPublisher = _extractSingle(
        item,
        fields['publisher'],
        source.baseUrl,
      );
      final rawYear = _extractSingle(item, fields['year'], source.baseUrl);
      final meta = _extractSingle(item, fields['meta'], source.baseUrl);
      final summary = _extractSingle(item, fields['summary'], source.baseUrl);
      final note = _extractSingle(item, fields['note'], source.baseUrl);
      final score = _extractSingle(item, fields['score'], source.baseUrl);
      final pages = _extractSingle(item, fields['pages'], source.baseUrl);
      final wordCount = _extractSingle(
        item,
        fields['word_count'],
        source.baseUrl,
      );
      final chapterCount = _extractSingle(
        item,
        fields['chapter_count'],
        source.baseUrl,
      );
      final isbn = _extractSingle(item, fields['isbn'], source.baseUrl);
      final coverUrl = _extractSingle(item, fields['cover'], source.baseUrl);
      final detailUrl = _extractSingle(item, fields['url'], source.baseUrl);

      final resolved = _resolveBookMeta(
        author: rawAuthor,
        publisher: rawPublisher,
        year: rawYear,
        meta: meta,
      );

      final dedupeKey = detailUrl.isNotEmpty
          ? '$title::$detailUrl'
          : '$title::${resolved.author}';
      if (!seenKeys.add(dedupeKey)) continue;

      final extraSections = _extractExtraSections(
        item,
        extraFields,
        source.baseUrl,
      );

      results.add(
        DiscoverBook(
          title: title,
          author: resolved.author,
          publisher: resolved.publisher,
          year: resolved.year,
          meta: meta,
          summary: summary,
          note: note,
          score: score,
          pages: pages,
          wordCount: wordCount,
          chapterCount: chapterCount,
          isbn: isbn,
          coverUrl: coverUrl,
          detailUrl: detailUrl,
          sourceId: source.id,
          imageHeaders: imageHeaders,
          extraSections: extraSections,
        ),
      );
    }
    return results;
  }

  List<DiscoverExtraSection> _extractExtraSections(
    Map<String, dynamic> item,
    List<DiscoverExtraFieldConfig> extraFields,
    String baseUrl,
  ) {
    if (extraFields.isEmpty) return const <DiscoverExtraSection>[];
    final out = <DiscoverExtraSection>[];
    for (final cfg in extraFields) {
      final isList = _isExtraListField(cfg);
      final section = _buildExtraSection(
        cfg,
        items: isList ? _extractList(item, cfg.rule, baseUrl) : const <String>[],
        text: isList ? '' : _extractSingle(item, cfg.rule, baseUrl),
      );
      if (section != null) out.add(section);
    }
    return List<DiscoverExtraSection>.unmodifiable(out);
  }

  List<Map<String, dynamic>> _extractItems(String rawBody, String itemsPath) {
    final decoded = jsonDecode(rawBody);
    final target = _resolvePath(decoded, itemsPath);
    if (target is! List) return const <Map<String, dynamic>>[];
    return target
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  }

  Object? _resolvePath(Object? root, String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return root;
    Object? cur = root;
    for (final segment in trimmed.split('.')) {
      if (cur == null) return null;
      if (cur is Map) {
        cur = cur[segment];
      } else if (cur is List) {
        final idx = int.tryParse(segment);
        if (idx == null || idx < 0 || idx >= cur.length) return null;
        cur = cur[idx];
      } else {
        return null;
      }
    }
    return cur;
  }

  String _extractSingle(
    Map<String, dynamic> item,
    DiscoverFieldRule? rule,
    String baseUrl,
  ) {
    if (rule == null) return '';
    for (final path in rule.pathCandidates) {
      final value = _resolvePath(item, path);
      if (value == null) continue;

      if (value is List) {
        final parts = value
            .map(_scalarText)
            .where((s) => s.isNotEmpty && !_isPlaceholderDataUri(s))
            .toList(growable: false);
        if (parts.isEmpty) continue;
        final transformed = _applyTransforms(
          parts.join(rule.joinWith),
          rule,
          baseUrl,
        );
        if (transformed.isNotEmpty) return transformed;
        continue;
      }

      final text = _scalarText(value);
      if (text.isEmpty || _isPlaceholderDataUri(text)) continue;
      final transformed = _applyTransforms(text, rule, baseUrl);
      if (transformed.isNotEmpty) return transformed;
    }
    return '';
  }

  List<String> _extractList(
    Map<String, dynamic> item,
    DiscoverFieldRule? rule,
    String baseUrl,
  ) {
    if (rule == null) return const <String>[];
    for (final path in rule.pathCandidates) {
      final value = _resolvePath(item, path);
      if (value == null) continue;
      final candidates = value is List ? value : <Object?>[value];
      final out = <String>[];
      final seen = <String>{};
      for (final entry in candidates) {
        final text = _scalarText(entry);
        if (text.isEmpty || _isPlaceholderDataUri(text)) continue;
        final transformed = _applyTransforms(text, rule, baseUrl);
        if (transformed.isNotEmpty && seen.add(transformed)) {
          out.add(transformed);
          if (rule.maxItems > 0 && out.length >= rule.maxItems) break;
          if (!rule.all && rule.maxItems <= 0) break;
        }
      }
      if (out.isNotEmpty) return out;
    }
    return const <String>[];
  }

  String _scalarText(Object? value) {
    if (value == null) return '';
    if (value is Map) {
      final nested = value['name'] ?? value['title'];
      return nested == null ? '' : _normalizeWhitespace(nested.toString());
    }
    if (value is List) return '';
    return _normalizeWhitespace(value.toString());
  }
}

/// 剥离 JSONP 外层回调函数包装（例如 `callback({...});`），返回内部 JSON 文本。
String stripJsonpWrapper(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return trimmed;
  }
  final match = RegExp(
    r'^(?:\/\*\*\/)?\s*[A-Za-z_\$][A-Za-z0-9_\$.]*\s*\(\s*([\s\S]*?)\s*\)\s*;?\s*$',
  ).firstMatch(trimmed);
  if (match != null) {
    final inner = (match.group(1) ?? '').trim();
    if (inner.startsWith('{') || inner.startsWith('[')) {
      return inner;
    }
  }
  return trimmed;
}

bool _isExtraListField(DiscoverExtraFieldConfig cfg) =>
    cfg.rule.all ||
    cfg.style == 'list' ||
    cfg.style == 'positive_list' ||
    cfg.style == 'negative_list' ||
    cfg.style == 'tags';

DiscoverExtraSection? _buildExtraSection(
  DiscoverExtraFieldConfig cfg, {
  required List<String> items,
  required String text,
}) {
  if (_isExtraListField(cfg)) {
    if (items.isEmpty) return null;
    return DiscoverExtraSection(
      key: cfg.key,
      label: cfg.label,
      style: cfg.style,
      items: List<String>.unmodifiable(items),
    );
  }
  if (text.isEmpty) return null;
  return DiscoverExtraSection(
    key: cfg.key,
    label: cfg.label,
    style: cfg.style,
    text: text,
  );
}

bool _isPlaceholderDataUri(String value) =>
    value.trim().toLowerCase().startsWith('data:');

String _normalizeWhitespace(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), ' ').trim();

String _normalizeFieldWhitespace(
  String raw, {
  required bool preserveParagraphs,
}) {
  if (!preserveParagraphs) return _normalizeWhitespace(raw);
  return raw
      .split(RegExp(r'\n\s*\n+'))
      .map(_normalizeWhitespace)
      .where((p) => p.isNotEmpty)
      .join('\n\n');
}

String _applyTransforms(
  String raw,
  DiscoverFieldRule rule,
  String baseUrl,
) {
  var value = _normalizeFieldWhitespace(
    raw,
    preserveParagraphs: rule.preserveParagraphs,
  );
  if (value.isEmpty) return '';

  if (rule.stripPrefix.isNotEmpty && value.startsWith(rule.stripPrefix)) {
    value = value.substring(rule.stripPrefix.length).trim();
  }
  if (rule.stripSuffix.isNotEmpty && value.endsWith(rule.stripSuffix)) {
    value = value.substring(0, value.length - rule.stripSuffix.length).trim();
  }
  if (value.isEmpty) return '';

  if (rule.regex.isNotEmpty) {
    try {
      final match = RegExp(rule.regex).firstMatch(value);
      if (match == null) return '';
      final groupIdx =
          rule.regexGroup >= 0 && rule.regexGroup <= match.groupCount
          ? rule.regexGroup
          : 0;
      value = (match.group(groupIdx) ?? '').trim();
      if (value.isEmpty) return '';
    } catch (_) {
      return '';
    }
  }

  if (rule.replacePattern.isNotEmpty) {
    try {
      value = value.replaceAll(
        RegExp(rule.replacePattern),
        rule.replaceWith,
      );
    } catch (_) {}
  }

  if (rule.prefix.isNotEmpty) {
    value = '${rule.prefix}$value';
  }
  if (rule.resolveUrl) {
    value = resolveSafeHttpUrl(value, baseUrl);
  }
  return value;
}

({String author, String publisher, String year}) _resolveBookMeta({
  required String author,
  required String publisher,
  required String year,
  required String meta,
}) {
  var nextAuthor = author;
  var nextPublisher = publisher;
  var nextYear = year;

  if (meta.isEmpty ||
      (nextAuthor.isNotEmpty &&
          nextPublisher.isNotEmpty &&
          nextYear.isNotEmpty)) {
    return (author: nextAuthor, publisher: nextPublisher, year: nextYear);
  }

  var parts = meta
      .split(RegExp(r'\s+·\s+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList(growable: false);
  if (parts.length <= 1 && meta.contains('/')) {
    parts = meta
        .split(RegExp(r'\s+/\s+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) {
      parts = meta
          .split('/')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
    }
  }

  final remaining = <String>[];
  for (final part in parts) {
    if (_looksLikeYear(part)) {
      if (nextYear.isEmpty) nextYear = part;
      continue;
    }
    if (_isNoiseMetaSegment(part)) {
      continue;
    }
    if (_looksLikePublisher(part)) {
      if (nextPublisher.isEmpty) {
        nextPublisher = part;
      } else {
        remaining.add(part);
      }
      continue;
    }
    remaining.add(part);
  }

  if (remaining.length == 1) {
    if (nextAuthor.isEmpty) {
      nextAuthor = remaining.first;
    } else if (nextPublisher.isEmpty) {
      nextPublisher = remaining.first;
    }
  } else if (remaining.length >= 2) {
    if (nextAuthor.isEmpty && nextPublisher.isEmpty) {
      nextAuthor = remaining.sublist(0, remaining.length - 1).join(' / ');
      nextPublisher = remaining.last;
    } else if (nextAuthor.isEmpty) {
      nextAuthor = remaining.join(' / ');
    } else if (nextPublisher.isEmpty) {
      nextPublisher = remaining.join(' / ');
    }
  }

  return (author: nextAuthor, publisher: nextPublisher, year: nextYear);
}

bool _looksLikeYear(String text) =>
    RegExp(r'^\d{4}(?:[-/.]\d{1,2}(?:[-/.]\d{1,2})?)?$').hasMatch(text.trim());

bool _looksLikePublisher(String text) => RegExp(
  r'(出版社|出版|书局|书店|印书馆|Press|Publishing|公司)',
  caseSensitive: false,
).hasMatch(text);

bool _isNoiseMetaSegment(String text) {
  final t = text.trim();
  if (t.isEmpty) return true;
  if (RegExp(
    r'^(平装|精装|盒装|软精装|简装|线装|电子书|Kindle版)$',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (RegExp(
    r'^(?:CNY|USD|HKD|RMB|NT\$|US\$|￥|\$)?\s*\d+(?:\.\d+)?\s*(?:元|美元|港元|台币)?$',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  return false;
}
