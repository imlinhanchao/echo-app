import 'package:flutter/foundation.dart';

/// 切分后的单句文本及其在章节正文中的精确字符区间。
@immutable
class TextSentence {
  const TextSentence({
    required this.index,
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });

  final int index;
  final String text;
  final int startOffset;
  final int endOffset;
}

/// 中英文智能分句器（供端侧 TTS 实时流式朗读与精确 SRT 生成共用）。
///
/// 策略：
/// 1. 先按段落换行与句末标点（`。！？；!?`）切分，保留紧随其后的右引号/右括号；
/// 2. 过短碎句（< [minChars]）向前合并（不跨段落合并，避免停顿失真）；
/// 3. 过长无句末标点的句子（> [maxChars]）按逗号/顿号/冒号二次切分，仍超长则按字数硬切。
class SentenceSplitter {
  const SentenceSplitter({this.minChars = 8, this.maxChars = 110});

  final int minChars;
  final int maxChars;

  static const Set<String> _sentenceEnds = <String>{
    '。',
    '！',
    '？',
    '；',
    '!',
    '?',
    ';',
    '…',
  };

  static const Set<String> _closingQuotes = <String>{
    '”',
    '’',
    '」',
    '』',
    '》',
    '）',
    ')',
    '"',
    "'",
    ']',
    '】',
  };

  static const Set<String> _softBreaks = <String>{
    '，',
    '、',
    '：',
    ',',
    ':',
    '—',
    ' ',
  };

  List<TextSentence> split(String chapterText) {
    if (chapterText.trim().isEmpty) return const <TextSentence>[];

    final rawSpans = <_RawSpan>[];
    var i = 0;
    final len = chapterText.length;

    while (i < len) {
      // 跳过前导空白
      while (i < len && _isWhitespace(chapterText[i])) {
        i++;
      }
      if (i >= len) break;

      final paraStart = i;
      var paraEnd = chapterText.indexOf('\n', paraStart);
      if (paraEnd < 0) paraEnd = len;

      final paraRawSpans = _splitParagraph(chapterText, paraStart, paraEnd);
      rawSpans.addAll(_mergeShortSpans(chapterText, paraRawSpans));

      i = paraEnd + 1;
    }

    final result = <TextSentence>[];
    for (final span in rawSpans) {
      final pieces = _splitIfTooLong(chapterText, span);
      for (final p in pieces) {
        final text = chapterText.substring(p.start, p.end).trim();
        if (text.isEmpty || !_hasSpeakableContent(text)) continue;
        result.add(
          TextSentence(
            index: result.length,
            text: text,
            startOffset: p.start,
            endOffset: p.end,
          ),
        );
      }
    }
    return result;
  }

  List<_RawSpan> _splitParagraph(String source, int start, int end) {
    final spans = <_RawSpan>[];
    var segStart = start;
    var i = start;

    while (i < end) {
      final ch = source[i];
      var isEnd = _sentenceEnds.contains(ch);

      // 英文句号：避免切分小数（3.14）或缩写
      if (ch == '.') {
        final prevIsDigit = i > start && _isDigit(source[i - 1]);
        final nextIsDigit = i + 1 < end && _isDigit(source[i + 1]);
        final nextIsSpaceOrEnd =
            i + 1 >= end ||
            _isWhitespace(source[i + 1]) ||
            _closingQuotes.contains(source[i + 1]);
        if (!prevIsDigit && !nextIsDigit && nextIsSpaceOrEnd) {
          isEnd = true;
        }
      }

      if (isEnd) {
        var segEnd = i + 1;
        // 吞并连续的省略号/感叹号以及右引号
        while (segEnd < end &&
            (_sentenceEnds.contains(source[segEnd]) ||
                _closingQuotes.contains(source[segEnd]))) {
          segEnd++;
        }
        _addTrimmedSpan(source, spans, segStart, segEnd);
        segStart = segEnd;
        i = segEnd;
      } else {
        i++;
      }
    }

    if (segStart < end) {
      _addTrimmedSpan(source, spans, segStart, end);
    }
    return spans;
  }

  List<_RawSpan> _mergeShortSpans(String source, List<_RawSpan> spans) {
    if (spans.length <= 1) return spans;
    final merged = <_RawSpan>[];
    for (final span in spans) {
      if (merged.isEmpty) {
        merged.add(span);
        continue;
      }
      final prev = merged.last;
      final prevLen = prev.end - prev.start;
      final curLen = span.end - span.start;
      if ((curLen < minChars || prevLen < minChars) &&
          (span.end - prev.start) <= maxChars) {
        merged[merged.length - 1] = _RawSpan(prev.start, span.end);
      } else {
        merged.add(span);
      }
    }
    return merged;
  }

  List<_RawSpan> _splitIfTooLong(String source, _RawSpan span) {
    if (span.end - span.start <= maxChars) return <_RawSpan>[span];

    final out = <_RawSpan>[];
    var cursor = span.start;
    while (cursor < span.end) {
      while (cursor < span.end && _isWhitespace(source[cursor])) {
        cursor++;
      }
      if (cursor >= span.end) break;

      if (span.end - cursor <= maxChars) {
        _addTrimmedSpan(source, out, cursor, span.end);
        break;
      }

      final limit = cursor + maxChars;
      var breakAt = -1;
      for (var k = limit; k > cursor + minChars; k--) {
        if (_softBreaks.contains(source[k - 1])) {
          breakAt = k;
          break;
        }
      }
      breakAt = breakAt > cursor ? breakAt : limit;
      _addTrimmedSpan(source, out, cursor, breakAt);
      cursor = breakAt;
    }
    return out;
  }

  void _addTrimmedSpan(
    String source,
    List<_RawSpan> out,
    int start,
    int end,
  ) {
    var s = start;
    var e = end;
    while (s < e && _isWhitespace(source[s])) {
      s++;
    }
    while (e > s && _isWhitespace(source[e - 1])) {
      e--;
    }
    if (s < e) {
      out.add(_RawSpan(s, e));
    }
  }

  bool _isWhitespace(String ch) => ch.trim().isEmpty;

  bool _isDigit(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }

  bool _hasSpeakableContent(String text) {
    // 至少包含一个中英文字符或数字，避免纯标点送入 TTS 导致空音频
    return RegExp(r'[\u4e00-\u9fffA-Za-z0-9]').hasMatch(text);
  }
}

class _RawSpan {
  const _RawSpan(this.start, this.end);

  final int start;
  final int end;
}
