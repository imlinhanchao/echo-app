import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../api/models.dart';

/// 解析后的电子书结构（EPUB / TXT 统一输出）。
class ParsedBook {
  const ParsedBook({
    required this.title,
    required this.format,
    required this.chapters,
    this.authors = const <String>[],
    this.publisher = '',
    this.language = '',
    this.year = '',
    this.description = '',
    this.coverBytes,
    this.coverExt = 'jpg',
  });

  final String title;
  final String format;
  final List<String> authors;
  final String publisher;
  final String language;
  final String year;
  final String description;
  final Uint8List? coverBytes;
  final String coverExt;
  final List<ChapterPreview> chapters;
}

/// 纯 Dart EPUB 解析器（支持 EPUB 2 NCX 与 EPUB 3 Nav、封面提取与正文清洗）。
class EpubParser {
  const EpubParser();

  ParsedBook parse(Uint8List bytes, {String fallbackTitle = '未命名书籍'}) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final fileMap = <String, ArchiveFile>{};
    for (final file in archive.files) {
      if (file.isFile) {
        fileMap[_normalizeZipPath(file.name)] = file;
      }
    }

    final opfPath = _findOpfPath(fileMap);
    if (opfPath == null) {
      throw const FormatException('无效的 EPUB 文件：缺少 OPF 清单');
    }
    final opfFile = fileMap[_normalizeZipPath(opfPath)];
    if (opfFile == null) {
      throw FormatException('无效的 EPUB 文件：找不到 $opfPath');
    }
    final opfDir = p.posix.dirname(opfPath);
    final opfXml = XmlDocument.parse(_decodeXml(opfFile.content));

    // 1. 提取元数据
    final title = _firstText(opfXml, 'title').isNotEmpty
        ? _firstText(opfXml, 'title')
        : fallbackTitle;
    final authors = _allTexts(opfXml, 'creator');
    final publisher = _firstText(opfXml, 'publisher');
    final language = _firstText(opfXml, 'language');
    final description = _stripHtmlTags(_firstText(opfXml, 'description'));
    final rawDate = _firstText(opfXml, 'date');
    final yearMatch = RegExp(r'\b(1\d{3}|20\d{2})\b').firstMatch(rawDate);
    final year = yearMatch?.group(1) ?? '';

    // 2. 解析 Manifest
    final manifest = <String, _ManifestItem>{};
    for (final item in _elementsByLocalName(opfXml, 'item')) {
      final id = item.getAttribute('id') ?? '';
      final href = item.getAttribute('href') ?? '';
      final mediaType = item.getAttribute('media-type') ?? '';
      final properties = item.getAttribute('properties') ?? '';
      if (id.isNotEmpty && href.isNotEmpty) {
        manifest[id] = _ManifestItem(
          id: id,
          href: Uri.decodeFull(href),
          mediaType: mediaType,
          properties: properties,
        );
      }
    }

    // 3. 提取封面
    final coverData = _extractCover(opfXml, manifest, opfDir, fileMap);

    // 4. 提取目录标题映射（href -> title）
    final tocTitles = _extractTocTitles(opfXml, manifest, opfDir, fileMap);

    // 5. 遍历 Spine 提取章节正文
    final chapters = <ChapterPreview>[];
    final spineItems = _elementsByLocalName(opfXml, 'itemref');
    for (final itemRef in spineItems) {
      final idref = itemRef.getAttribute('idref') ?? '';
      final item = manifest[idref];
      if (item == null) continue;
      final resolvedPath = _resolveRelative(opfDir, item.href);
      final chapterFile = fileMap[resolvedPath];
      if (chapterFile == null) continue;

      final htmlStr = _decodeText(chapterFile.content);
      final extracted = _extractHtmlText(htmlStr);
      final cleanText = extracted.text.trim();
      if (cleanText.isEmpty) continue;

      final chapterTitle =
          tocTitles[resolvedPath] ??
          tocTitles[p.posix.basename(resolvedPath)] ??
          (extracted.heading.isNotEmpty
              ? extracted.heading
              : '第 ${chapters.length + 1} 章');
      final preview = cleanText.length > 160
          ? cleanText.substring(0, 160)
          : cleanText;
      chapters.add(
        ChapterPreview(
          index: chapters.length,
          title: chapterTitle,
          chars: cleanText.length,
          preview: preview,
          text: cleanText,
        ),
      );
    }

    if (chapters.isEmpty) {
      throw const FormatException('EPUB 中未解析到可读文本章节');
    }

    return ParsedBook(
      title: title,
      format: 'epub',
      authors: authors,
      publisher: publisher,
      language: language,
      year: year,
      description: description,
      coverBytes: coverData?.$1,
      coverExt: coverData?.$2 ?? 'jpg',
      chapters: chapters,
    );
  }

  String? _findOpfPath(Map<String, ArchiveFile> fileMap) {
    final container = fileMap['meta-inf/container.xml'];
    if (container != null) {
      try {
        final doc = XmlDocument.parse(_decodeXml(container.content));
        for (final el in _elementsByLocalName(doc, 'rootfile')) {
          final fullPath = el.getAttribute('full-path');
          if (fullPath != null && fullPath.isNotEmpty) {
            return fullPath;
          }
        }
      } catch (_) {}
    }
    for (final key in fileMap.keys) {
      if (key.endsWith('.opf')) return fileMap[key]!.name;
    }
    return null;
  }

  (Uint8List, String)? _extractCover(
    XmlDocument opfXml,
    Map<String, _ManifestItem> manifest,
    String opfDir,
    Map<String, ArchiveFile> fileMap,
  ) {
    _ManifestItem? coverItem;
    // EPUB 3: properties="cover-image"
    for (final item in manifest.values) {
      if (item.properties.split(RegExp(r'\s+')).contains('cover-image')) {
        coverItem = item;
        break;
      }
    }
    // EPUB 2: <meta name="cover" content="cover-id"/>
    if (coverItem == null) {
      for (final meta in _elementsByLocalName(opfXml, 'meta')) {
        if (meta.getAttribute('name')?.toLowerCase() == 'cover') {
          final contentId = meta.getAttribute('content') ?? '';
          if (manifest.containsKey(contentId)) {
            coverItem = manifest[contentId];
            break;
          }
        }
      }
    }
    // 兜底：manifest 里 id/href 含 cover 的图片
    coverItem ??= manifest.values.cast<_ManifestItem?>().firstWhere(
      (item) =>
          item != null &&
          item.mediaType.startsWith('image/') &&
          (item.id.toLowerCase().contains('cover') ||
              item.href.toLowerCase().contains('cover')),
      orElse: () => null,
    );

    if (coverItem == null) return null;
    final path = _resolveRelative(opfDir, coverItem.href);
    final file = fileMap[path];
    if (file == null) return null;
    final bytes = _asBytes(file.content);
    if (bytes.isEmpty) return null;
    final ext = coverItem.mediaType.contains('png')
        ? 'png'
        : coverItem.mediaType.contains('webp')
        ? 'webp'
        : 'jpg';
    return (bytes, ext);
  }

  Map<String, String> _extractTocTitles(
    XmlDocument opfXml,
    Map<String, _ManifestItem> manifest,
    String opfDir,
    Map<String, ArchiveFile> fileMap,
  ) {
    final map = <String, String>{};
    // 1. 尝试 EPUB 3 nav
    final navItem = manifest.values.cast<_ManifestItem?>().firstWhere(
      (item) =>
          item != null &&
          item.properties.split(RegExp(r'\s+')).contains('nav'),
      orElse: () => null,
    );
    if (navItem != null) {
      final navPath = _resolveRelative(opfDir, navItem.href);
      final navFile = fileMap[navPath];
      if (navFile != null) {
        final navDir = p.posix.dirname(navPath);
        final doc = html_parser.parse(_decodeText(navFile.content));
        for (final a in doc.querySelectorAll('nav a')) {
          final href = a.attributes['href'] ?? '';
          final text = a.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (href.isEmpty || text.isEmpty) continue;
          final cleanHref = Uri.decodeFull(href.split('#').first);
          if (cleanHref.isEmpty) continue;
          final resolved = _resolveRelative(navDir, cleanHref);
          map.putIfAbsent(resolved, () => text);
        }
      }
    }

    // 2. 尝试 EPUB 2 NCX
    final ncxItem = manifest.values.cast<_ManifestItem?>().firstWhere(
      (item) =>
          item != null &&
          (item.mediaType == 'application/x-dtbncx+xml' ||
              item.href.toLowerCase().endsWith('.ncx')),
      orElse: () => null,
    );
    if (ncxItem != null) {
      final ncxPath = _resolveRelative(opfDir, ncxItem.href);
      final ncxFile = fileMap[ncxPath];
      if (ncxFile != null) {
        final ncxDir = p.posix.dirname(ncxPath);
        try {
          final doc = XmlDocument.parse(_decodeXml(ncxFile.content));
          for (final navPoint in _elementsByLocalName(doc, 'navPoint')) {
            final labelEl = _elementsByLocalName(navPoint, 'text').firstOrNull;
            final contentEl = _elementsByLocalName(
              navPoint,
              'content',
            ).firstOrNull;
            final title = labelEl?.innerText.trim().replaceAll(
              RegExp(r'\s+'),
              ' ',
            );
            final src = contentEl?.getAttribute('src') ?? '';
            if (title != null && title.isNotEmpty && src.isNotEmpty) {
              final cleanSrc = Uri.decodeFull(src.split('#').first);
              final resolved = _resolveRelative(ncxDir, cleanSrc);
              map.putIfAbsent(resolved, () => title);
            }
          }
        } catch (_) {}
      }
    }
    return map;
  }

  ({String heading, String text}) _extractHtmlText(String htmlStr) {
    final doc = html_parser.parse(htmlStr);
    // 移除脚本与样式节点
    for (final el in doc.querySelectorAll('script, style, svg, head')) {
      el.remove();
    }
    final headingEl = doc.querySelector('h1, h2, h3');
    final heading =
        headingEl?.text.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';

    final body = doc.body;
    if (body == null) {
      return (heading: heading, text: doc.documentElement?.text.trim() ?? '');
    }

    final buffer = StringBuffer();
    _walkDom(body, buffer);
    final raw = buffer.toString();
    final lines = raw
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return (heading: heading, text: lines.join('\n\n'));
  }

  static const Set<String> _blockTags = <String>{
    'p',
    'div',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'blockquote',
    'section',
    'article',
    'tr',
    'pre',
  };

  void _walkDom(dom.Node node, StringBuffer out) {
    if (node is dom.Text) {
      out.write(node.text);
      return;
    }
    if (node is dom.Element) {
      final tag = node.localName?.toLowerCase() ?? '';
      if (tag == 'br') {
        out.write('\n');
        return;
      }
      final isBlock = _blockTags.contains(tag);
      if (isBlock) out.write('\n');
      for (final child in node.nodes) {
        _walkDom(child, out);
      }
      if (isBlock) out.write('\n');
    }
  }

  String _stripHtmlTags(String raw) {
    if (!raw.contains('<')) return raw.trim();
    return html_parser.parse(raw).body?.text.trim() ?? raw.trim();
  }

  Iterable<XmlElement> _elementsByLocalName(XmlNode root, String localName) {
    final target = localName.toLowerCase();
    return root.descendants.whereType<XmlElement>().where(
      (e) => e.name.local.toLowerCase() == target,
    );
  }

  String _firstText(XmlDocument doc, String localName) {
    for (final el in _elementsByLocalName(doc, localName)) {
      final t = el.innerText.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  List<String> _allTexts(XmlDocument doc, String localName) {
    final out = <String>[];
    for (final el in _elementsByLocalName(doc, localName)) {
      final t = el.innerText.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  String _resolveRelative(String baseDir, String href) {
    final combined = (baseDir == '.' || baseDir.isEmpty)
        ? href
        : p.posix.normalize(p.posix.join(baseDir, href));
    return _normalizeZipPath(combined);
  }

  String _normalizeZipPath(String raw) {
    var s = raw.replaceAll('\\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    return p.posix.normalize(s).toLowerCase();
  }

  Uint8List _asBytes(dynamic content) {
    if (content is Uint8List) return content;
    if (content is List<int>) return Uint8List.fromList(content);
    return Uint8List(0);
  }

  String _decodeXml(dynamic content) => _decodeText(content);

  String _decodeText(dynamic content) {
    final bytes = _asBytes(content);
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.properties,
  });

  final String id;
  final String href;
  final String mediaType;
  final String properties;
}
