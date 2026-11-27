import 'dart:convert';
import 'dart:math';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'book_source_models.dart';

/// Pure-Dart template interpolation, cookie extraction, and JSON/HTML/XML field extractor.
class RuleExtractor {
  RuleExtractor({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

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

  static const String _idChars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// Generates a UUID v4 string without external dependencies.
  String generateUuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Generates a 24-character URL-safe alphanumeric ID (`visitorId` format).
  String generateId24() {
    return List<String>.generate(
      24,
      (_) => _idChars[_random.nextInt(_idChars.length)],
    ).join();
  }

  /// Interpolates `{{path.to.value}}` placeholders against [context].
  String renderTemplate(
    String template,
    Map<String, Object?> context, {
    Map<String, String>? randCache,
  }) {
    if (!template.contains('{{')) return template;
    return template.replaceAllMapped(RegExp(r'\{\{([a-zA-Z0-9_.-]+)\}\}'), (
      match,
    ) {
      final key = match.group(1) ?? '';
      if (key == 'rand.uuid') {
        return randCache?.putIfAbsent('rand.uuid', generateUuidV4) ??
            generateUuidV4();
      }
      if (key == 'rand.id_24') {
        return randCache?.putIfAbsent('rand.id_24', generateId24) ??
            generateId24();
      }
      final val = resolveJsonPath(context, key);
      if (val == null) return '';
      return val.toString();
    });
  }

  /// Recursively renders string templates inside Maps/Lists for JSON request bodies.
  Object? renderTemplateObject(
    Object? raw,
    Map<String, Object?> context, {
    Map<String, String>? randCache,
  }) {
    if (raw is String) {
      return renderTemplate(raw, context, randCache: randCache);
    }
    if (raw is List) {
      return raw
          .map(
            (e) => renderTemplateObject(e, context, randCache: randCache),
          )
          .toList(growable: false);
    }
    if (raw is Map) {
      final out = <String, dynamic>{};
      for (final entry in raw.entries) {
        out[entry.key.toString()] = renderTemplateObject(
          entry.value,
          context,
          randCache: randCache,
        );
      }
      return out;
    }
    return raw;
  }

  /// Parses `Set-Cookie` headers into `name -> value`.
  static Map<String, String> parseSetCookieHeaders(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) {
      return const <String, String>{};
    }
    final out = <String, String>{};
    for (final header in setCookies) {
      final firstSemi = header.indexOf(';');
      final pair = (firstSemi >= 0 ? header.substring(0, firstSemi) : header)
          .trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isNotEmpty) {
        out[name] = value;
      }
    }
    return out;
  }

  /// Traverses dot-separated [path] on decoded JSON / Map / List structures.
  static Object? resolveJsonPath(Object? root, String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return root;
    return resolveJsonPathSegments(root, trimmed.split('.'));
  }

  /// Traverses exact [segments] (safe for keys containing `.` or `/`).
  static Object? resolveJsonPathSegments(Object? root, List<String> segments) {
    Object? cur = root;
    for (final segment in segments) {
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

  /// Extracts item nodes/maps according to `response.mode`.
  List<Object?> extractItems(
    String rawBody, {
    required String mode,
    String itemsPath = '',
    String itemsSelector = '',
  }) {
    final m = mode.trim().toLowerCase();
    if (m == 'json') {
      final decoded = _tryDecodeJson(rawBody);
      if (decoded == null) return const <Object?>[];
      final target = resolveJsonPath(decoded, itemsPath);
      if (target is! List) return const <Object?>[];
      return target.whereType<Map>().cast<Object?>().toList(growable: false);
    }
    if (m == 'html') {
      if (itemsSelector.isEmpty) return const <Object?>[];
      final doc = html_parser.parse(rawBody);
      return doc.querySelectorAll(itemsSelector).cast<Object?>().toList();
    }
    if (m == 'xml') {
      final doc = _tryParseXml(rawBody);
      if (doc == null) return const <Object?>[];
      if (itemsSelector.isEmpty) {
        return <Object?>[doc.rootElement];
      }
      return _queryXmlElements(doc.rootElement, itemsSelector)
          .cast<Object?>()
          .toList(growable: false);
    }
    return const <Object?>[];
  }

  /// Parses the root object for detail / login / verify / step extraction.
  Object? parseRoot(String rawBody, {required String mode, String rootPath = ''}) {
    final m = mode.trim().toLowerCase();
    if (m == 'json') {
      final decoded = _tryDecodeJson(rawBody);
      if (decoded == null) return null;
      return rootPath.isNotEmpty ? resolveJsonPath(decoded, rootPath) : decoded;
    }
    if (m == 'html') {
      final doc = html_parser.parse(rawBody);
      return doc.documentElement ?? doc.body;
    }
    if (m == 'xml') {
      final doc = _tryParseXml(rawBody);
      return doc?.rootElement;
    }
    return null;
  }

  /// Extracts a single string from [item] in [mode] (`json` | `html` | `xml`).
  String extractSingle(
    Object? item,
    BookSourceExtractRule? rule, {
    required String mode,
    required String baseUrl,
    Map<String, Object?> templateContext = const <String, Object?>{},
    Map<String, String> responseCookies = const <String, String>{},
  }) {
    if (rule == null) return '';

    if (rule.firstOf.isNotEmpty) {
      for (final candidate in rule.firstOf) {
        final v = extractSingle(
          item,
          candidate,
          mode: mode,
          baseUrl: baseUrl,
          templateContext: templateContext,
          responseCookies: responseCookies,
        );
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    if (rule.whenPresent != null) {
      final probe = extractSingle(
        item,
        rule.whenPresent,
        mode: mode,
        baseUrl: baseUrl,
        templateContext: templateContext,
        responseCookies: responseCookies,
      );
      if (probe.isEmpty) return '';
      return applyTransforms(rule.constValue, rule, baseUrl);
    }

    if (rule.cookie.isNotEmpty) {
      final val = responseCookies[rule.cookie] ?? '';
      return val.isEmpty ? '' : applyTransforms(val, rule, baseUrl);
    }

    if (rule.template.isNotEmpty) {
      final rendered = renderTemplate(rule.template, templateContext);
      return rendered.isEmpty ? '' : applyTransforms(rendered, rule, baseUrl);
    }

    if (rule.constValue.isNotEmpty && !_hasRawLocator(rule)) {
      return applyTransforms(rule.constValue, rule, baseUrl);
    }

    if (item == null) return '';

    final m = mode.trim().toLowerCase();
    if (m == 'json') {
      return _extractJsonSingle(item, rule, baseUrl);
    }
    if (m == 'html' && item is Element) {
      return _extractHtmlSingle(item, rule, baseUrl);
    }
    if (m == 'xml' && item is XmlElement) {
      return _extractXmlSingle(item, rule, baseUrl);
    }
    return '';
  }

  /// Extracts a deduplicated list of strings from [item].
  List<String> extractList(
    Object? item,
    BookSourceExtractRule? rule, {
    required String mode,
    required String baseUrl,
    Map<String, Object?> templateContext = const <String, Object?>{},
    Map<String, String> responseCookies = const <String, String>{},
  }) {
    if (rule == null) return const <String>[];

    if (rule.splitRegex.isNotEmpty) {
      final single = extractSingle(
        item,
        BookSourceExtractRule(
          selector: rule.selector,
          selectors: rule.selectors,
          attr: rule.attr,
          attrs: rule.attrs,
          nextSibling: rule.nextSibling,
          afterHeading: rule.afterHeading,
          headingSelector: rule.headingSelector,
          preserveParagraphs: rule.preserveParagraphs,
          path: rule.path,
          paths: rule.paths,
          pathSegments: rule.pathSegments,
          jsonPath: rule.jsonPath,
          cookie: rule.cookie,
          template: rule.template,
          firstOf: rule.firstOf,
          whenPresent: rule.whenPresent,
          constValue: rule.constValue,
          transform: rule.transform,
          joinWith: rule.joinWith,
          regex: rule.regex,
          regexGroup: rule.regexGroup,
          replacePattern: rule.replacePattern,
          replaceWith: rule.replaceWith,
          prefix: rule.prefix,
          stripPrefix: rule.stripPrefix,
          stripSuffix: rule.stripSuffix,
          resolveUrl: rule.resolveUrl,
        ),
        mode: mode,
        baseUrl: baseUrl,
        templateContext: templateContext,
        responseCookies: responseCookies,
      );
      if (single.isEmpty) return const <String>[];
      try {
        return single
            .split(RegExp(rule.splitRegex))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      } catch (_) {
        return <String>[single];
      }
    }

    if (item == null) {
      final s = extractSingle(
        null,
        rule,
        mode: mode,
        baseUrl: baseUrl,
        templateContext: templateContext,
        responseCookies: responseCookies,
      );
      return s.isEmpty ? const <String>[] : <String>[s];
    }

    final m = mode.trim().toLowerCase();
    if (m == 'json') {
      return _extractJsonList(item, rule, baseUrl);
    }
    if (m == 'html' && item is Element) {
      return _extractHtmlList(item, rule, baseUrl);
    }
    if (m == 'xml' && item is XmlElement) {
      return _extractXmlList(item, rule, baseUrl);
    }
    return const <String>[];
  }

  static bool _hasRawLocator(BookSourceExtractRule r) =>
      r.selector.isNotEmpty ||
      r.selectors.isNotEmpty ||
      r.attr.isNotEmpty ||
      r.attrs.isNotEmpty ||
      r.path.isNotEmpty ||
      r.paths.isNotEmpty ||
      r.pathSegments.isNotEmpty ||
      r.nextSibling.isNotEmpty ||
      r.afterHeading.isNotEmpty;

  // ---------------------------------------------------------------------------
  // JSON Extraction
  // ---------------------------------------------------------------------------

  String _extractJsonSingle(
    Object? item,
    BookSourceExtractRule rule,
    String baseUrl,
  ) {
    final candidates = <Object?>[];
    if (rule.pathSegments.isNotEmpty) {
      candidates.add(resolveJsonPathSegments(item, rule.pathSegments));
    }
    for (final p in rule.pathCandidates) {
      candidates.add(resolveJsonPath(item, p));
    }

    for (final value in candidates) {
      if (value == null) continue;
      if (value is List) {
        final parts = value
            .map(_scalarJsonText)
            .where((s) => s.isNotEmpty && !_isPlaceholderDataUri(s))
            .toList(growable: false);
        if (parts.isEmpty) continue;
        final transformed = applyTransforms(
          parts.join(rule.joinWith),
          rule,
          baseUrl,
        );
        if (transformed.isNotEmpty) return transformed;
        continue;
      }
      final text = _scalarJsonText(value);
      if (text.isEmpty || _isPlaceholderDataUri(text)) continue;
      final transformed = applyTransforms(text, rule, baseUrl);
      if (transformed.isNotEmpty) return transformed;
    }
    return '';
  }

  List<String> _extractJsonList(
    Object? item,
    BookSourceExtractRule rule,
    String baseUrl,
  ) {
    final rawCandidates = <Object?>[];
    if (rule.pathSegments.isNotEmpty) {
      rawCandidates.add(resolveJsonPathSegments(item, rule.pathSegments));
    }
    for (final p in rule.pathCandidates) {
      rawCandidates.add(resolveJsonPath(item, p));
    }

    for (final value in rawCandidates) {
      if (value == null) continue;
      final list = value is List ? value : <Object?>[value];
      final out = <String>[];
      final seen = <String>{};
      for (final entry in list) {
        final text = _scalarJsonText(entry);
        if (text.isEmpty || _isPlaceholderDataUri(text)) continue;
        final transformed = applyTransforms(text, rule, baseUrl);
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

  String _scalarJsonText(Object? value) {
    if (value == null) return '';
    if (value is Map) {
      final nested = value['name'] ?? value['title'];
      return nested == null ? '' : _normalizeWhitespace(nested.toString());
    }
    if (value is List) return '';
    return _normalizeWhitespace(value.toString());
  }

  // ---------------------------------------------------------------------------
  // HTML Extraction
  // ---------------------------------------------------------------------------

  String _extractHtmlSingle(
    Element item,
    BookSourceExtractRule rule,
    String baseUrl,
  ) {
    final elements = _locateHtmlElements(item, rule);
    if (elements.isEmpty) return '';

    for (final el in elements) {
      var raw = _readHtmlElementValue(el, rule);
      if (raw.isEmpty) continue;
      if (rule.jsonPath.isNotEmpty) {
        final decoded = _tryDecodeJson(raw);
        if (decoded == null) continue;
        final resolved = resolveJsonPath(decoded, rule.jsonPath);
        if (resolved == null) continue;
        if (resolved is List) {
          raw = resolved
              .map(_scalarJsonText)
              .where((s) => s.isNotEmpty)
              .join(rule.joinWith);
        } else {
          raw = _scalarJsonText(resolved);
        }
        if (raw.isEmpty) continue;
      }
      final transformed = applyTransforms(raw, rule, baseUrl);
      if (transformed.isNotEmpty) return transformed;
    }
    return '';
  }

  List<String> _extractHtmlList(
    Element item,
    BookSourceExtractRule rule,
    String baseUrl,
  ) {
    final elements = _locateHtmlElements(item, rule);
    if (elements.isEmpty) return const <String>[];

    final out = <String>[];
    final seen = <String>{};
    for (final el in elements) {
      final raw = _readHtmlElementValue(el, rule);
      if (raw.isEmpty) continue;
      final transformed = applyTransforms(raw, rule, baseUrl);
      if (transformed.isNotEmpty && seen.add(transformed)) {
        out.add(transformed);
        if (rule.maxItems > 0 && out.length >= rule.maxItems) break;
        if (!rule.all && rule.maxItems <= 0) break;
      }
    }
    return out;
  }

  List<Element> _queryFirstMatchingHtml(
    Element scope,
    List<String> selectorCandidates,
  ) {
    for (final sel in selectorCandidates) {
      final matches = scope.querySelectorAll(sel);
      if (matches.isNotEmpty) return matches;
    }
    return const <Element>[];
  }

  List<Element> _locateHtmlElements(Element item, BookSourceExtractRule rule) {
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
      return _queryFirstMatchingHtml(sibling, selectorCandidates);
    }
    if (rule.afterHeading.isNotEmpty) {
      final headingQuery = rule.headingSelector.isNotEmpty
          ? rule.headingSelector
          : 'h1, h2, h3, h4, .section-title';
      Element? matchedHeading;
      for (final h in item.querySelectorAll(headingQuery)) {
        final headingText = _normalizeWhitespace(
          _extractCleanHtmlText(h, preserveParagraphs: false),
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
      return _queryFirstMatchingHtml(sibling, selectorCandidates);
    }
    if (selectorCandidates.isEmpty) return <Element>[item];
    return _queryFirstMatchingHtml(item, selectorCandidates);
  }

  String _readHtmlElementValue(Element element, BookSourceExtractRule rule) {
    final attrCandidates = rule.attrCandidates;
    if (attrCandidates.isEmpty) {
      if (rule.jsonPath.isNotEmpty) {
        // Return raw text for JSON-LD scripts so JSON structure isn't disrupted.
        return element.text.trim();
      }
      return _extractCleanHtmlText(
        element,
        preserveParagraphs: rule.preserveParagraphs,
      );
    }
    for (final attr in attrCandidates) {
      final raw = element.attributes[attr];
      if (raw == null) continue;
      final trimmed = raw.trim();
      if (trimmed.isEmpty || _isPlaceholderDataUri(trimmed)) continue;
      return trimmed;
    }
    return '';
  }

  String _extractCleanHtmlText(
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
      if (line.isNotEmpty) paragraphs.add(line);
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

  // ---------------------------------------------------------------------------
  // XML Extraction
  // ---------------------------------------------------------------------------

  String _extractXmlSingle(
    XmlElement item,
    BookSourceExtractRule rule,
    String baseUrl,
  ) {
    final elements = _locateXmlElements(item, rule);
    if (elements.isEmpty) return '';
    for (final el in elements) {
      final raw = _readXmlElementValue(el, rule);
      if (raw.isEmpty) continue;
      final transformed = applyTransforms(raw, rule, baseUrl);
      if (transformed.isNotEmpty) return transformed;
    }
    return '';
  }

  List<String> _extractXmlList(
    XmlElement item,
    BookSourceExtractRule rule,
    String baseUrl,
  ) {
    final elements = _locateXmlElements(item, rule);
    if (elements.isEmpty) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final el in elements) {
      final raw = _readXmlElementValue(el, rule);
      if (raw.isEmpty) continue;
      final transformed = applyTransforms(raw, rule, baseUrl);
      if (transformed.isNotEmpty && seen.add(transformed)) {
        out.add(transformed);
        if (rule.maxItems > 0 && out.length >= rule.maxItems) break;
        if (!rule.all && rule.maxItems <= 0) break;
      }
    }
    return out;
  }

  List<XmlElement> _locateXmlElements(
    XmlElement scope,
    BookSourceExtractRule rule,
  ) {
    final candidates = rule.selectorCandidates;
    if (candidates.isEmpty) return <XmlElement>[scope];
    for (final sel in candidates) {
      final found = _queryXmlElements(scope, sel);
      if (found.isNotEmpty) return found;
    }
    return const <XmlElement>[];
  }

  List<XmlElement> _queryXmlElements(XmlElement root, String selector) {
    final trimmed = selector.trim();
    if (trimmed.isEmpty) return const <XmlElement>[];
    final parts = trimmed
        .split(RegExp(r'\s*>\s*|\s+'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return const <XmlElement>[];

    List<XmlElement> matchSegment(XmlElement parent, String token, bool deep) {
      var tag = token;
      String? attrName;
      String? attrVal;
      final bracketStart = token.indexOf('[');
      if (bracketStart >= 0 && token.endsWith(']')) {
        tag = token.substring(0, bracketStart);
        final cond = token.substring(bracketStart + 1, token.length - 1);
        final eq = cond.indexOf('=');
        if (eq > 0) {
          attrName = cond.substring(0, eq).trim();
          attrVal = cond.substring(eq + 1).trim();
          if ((attrVal.startsWith('"') && attrVal.endsWith('"')) ||
              (attrVal.startsWith("'") && attrVal.endsWith("'"))) {
            attrVal = attrVal.substring(1, attrVal.length - 1);
          }
        }
      }

      final pool = deep
          ? parent.descendants.whereType<XmlElement>()
          : parent.childElements;
      return pool.where((el) {
        if (tag.isNotEmpty &&
            tag != '*' &&
            el.name.local != tag &&
            el.name.qualified != tag) {
          return false;
        }
        if (attrName != null) {
          final actual = el.getAttribute(attrName);
          if (actual == null) return false;
          if (attrVal != null && actual != attrVal) return false;
        }
        return true;
      }).toList(growable: false);
    }

    var current = matchSegment(root, parts.first, true);
    for (var i = 1; i < parts.length; i++) {
      final next = <XmlElement>[];
      for (final node in current) {
        next.addAll(matchSegment(node, parts[i], false));
      }
      current = next;
    }
    return current;
  }

  String _readXmlElementValue(XmlElement element, BookSourceExtractRule rule) {
    final attrs = rule.attrCandidates;
    if (attrs.isEmpty) {
      return _normalizeWhitespace(element.innerText);
    }
    for (final attr in attrs) {
      final raw = element.getAttribute(attr);
      if (raw != null && raw.trim().isNotEmpty) {
        return raw.trim();
      }
    }
    return '';
  }

  // ---------------------------------------------------------------------------
  // Transforms & Utilities
  // ---------------------------------------------------------------------------

  static String applyTransforms(
    String raw,
    BookSourceExtractRule rule,
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

    if (rule.transform == 'lower') {
      value = value.toLowerCase();
    } else if (rule.transform == 'upper') {
      value = value.toUpperCase();
    } else if (rule.transform == 'trim') {
      value = value.trim();
    }

    if (rule.resolveUrl && baseUrl.isNotEmpty) {
      value = resolveSafeBookSourceUrl(value, baseUrl);
    }
    return value;
  }

  static Object? _tryDecodeJson(String rawBody) {
    var trimmed = rawBody.trim();
    if (trimmed.startsWith('\ufeff')) {
      trimmed = trimmed.substring(1).trim();
    }
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
  }

  static XmlDocument? _tryParseXml(String rawBody) {
    try {
      return XmlDocument.parse(rawBody);
    } catch (_) {
      return null;
    }
  }

  static bool _isPlaceholderDataUri(String value) =>
      value.trim().toLowerCase().startsWith('data:');

  static String _normalizeWhitespace(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _normalizeFieldWhitespace(
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
}
