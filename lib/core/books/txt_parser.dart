import 'dart:convert';
import 'dart:typed_data';

import '../api/models.dart';
import 'epub_parser.dart' show ParsedBook;

/// 纯 Dart TXT 解析器：支持 UTF-8 / UTF-16 BOM 识别与中英文章节智能切分。
class TxtParser {
  const TxtParser({this.fallbackChunkChars = 5000});

  /// 无明显章节标题时的自动分段字数上限。
  final int fallbackChunkChars;

  static final RegExp _chapterHeadingRegex = RegExp(
    r'^\s*(第[零一二三四五六七八九十百千万两〇0-9]{1,9}[章节回卷集部篇](?:[\s：:·\-—]+.*|$)|'
    r'(?:Chapter|CHAPTER|Part|PART)\s+[0-9IVXLCDM]+(?:[\s：:.\-—]+.*|$)|'
    r'(?:序[章言幕]?|楔子|引子|尾声|后记|前言|番外(?:[\s：:·\-—]+.*)?))\s*$',
  );

  ParsedBook parse(Uint8List bytes, {String fallbackTitle = '未命名文本'}) {
    final text = _decodeText(bytes)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (text.isEmpty) {
      throw const FormatException('TXT 文件内容为空');
    }

    final chapters = _splitChapters(text);
    return ParsedBook(
      title: fallbackTitle,
      format: 'txt',
      chapters: chapters,
      description: chapters.first.preview,
    );
  }

  List<ChapterPreview> _splitChapters(String text) {
    final lines = text.split('\n');
    final headingIndices = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.length > 60) continue;
      if (_chapterHeadingRegex.hasMatch(line)) {
        headingIndices.add(i);
      }
    }

    // 检测到 2 个及以上明确章节标题时按标题分章
    if (headingIndices.length >= 2) {
      final out = <ChapterPreview>[];
      // 保留首章前的导语/序言（若有效内容超过 40 字）
      final preface = _cleanParagraphs(
        lines.sublist(0, headingIndices.first).join('\n'),
      );
      if (preface.length >= 40) {
        out.add(_buildChapter(out.length, '前言', preface));
      }

      for (var i = 0; i < headingIndices.length; i++) {
        final start = headingIndices[i];
        final end = i + 1 < headingIndices.length
            ? headingIndices[i + 1]
            : lines.length;
        final heading = lines[start].trim();
        final body = _cleanParagraphs(lines.sublist(start + 1, end).join('\n'));
        final combined = body.isEmpty ? heading : '$heading\n\n$body';
        out.add(_buildChapter(out.length, heading, combined));
      }
      if (out.isNotEmpty) return out;
    }

    // 否则按段落边界均分固定长度，避免单章过长影响分页与 TTS
    final paragraphs = text
        .split(RegExp(r'\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final out = <ChapterPreview>[];
    final buf = StringBuffer();
    for (final para in paragraphs) {
      if (buf.isNotEmpty && buf.length + para.length > fallbackChunkChars) {
        final chunk = buf.toString().trim();
        out.add(_buildChapter(out.length, '第 ${out.length + 1} 节', chunk));
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(para);
    }
    if (buf.isNotEmpty) {
      final chunk = buf.toString().trim();
      out.add(_buildChapter(out.length, '第 ${out.length + 1} 节', chunk));
    }
    return out;
  }

  ChapterPreview _buildChapter(int index, String title, String text) {
    final preview = text.length > 160 ? text.substring(0, 160) : text;
    return ChapterPreview(
      index: index,
      title: title,
      chars: text.length,
      preview: preview,
      text: text,
    );
  }

  String _cleanParagraphs(String raw) {
    return raw
        .split(RegExp(r'\n+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join('\n\n');
  }

  String _decodeText(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      // UTF-16 LE BOM
      final codeUnits = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(codeUnits);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      // UTF-16 BE BOM
      final codeUnits = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(codeUnits);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}
