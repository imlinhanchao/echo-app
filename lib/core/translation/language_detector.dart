import 'package:flutter/foundation.dart';

import 'translation_models.dart';

/// 章节内切分片段（段落或句子），严格记录在章节正文中的原字符偏移 [startChar, endChar)。
@immutable
class ParagraphSegment {
  const ParagraphSegment({
    required this.index,
    required this.startChar,
    required this.endChar,
    required this.text,
    required this.hash,
    this.isParagraphEnd = true,
  });

  final int index;
  final int startChar;
  final int endChar;
  final String text;
  final String hash;

  /// 是否为所属自然段的最后一个片段（用于双语排版区分句间距与段间距）。
  final bool isParagraphEnd;
}

/// 计算确定性 FNV-1a 64-bit 哈希并与长度拼接（跨进程/重启完全稳定）。
String stableParagraphHash(String text) {
  const int fnvOffset = 0xcbf29ce484222325;
  const int fnvPrime = 0x100000001b3;
  var hash = fnvOffset;
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    hash ^= units[i] & 0xff;
    hash = (hash * fnvPrime) & 0x7fffffffffffffff;
    hash ^= (units[i] >> 8) & 0xff;
    hash = (hash * fnvPrime) & 0x7fffffffffffffff;
  }
  return '${hash.toRadixString(16)}_${text.length}';
}

/// 按换行符切分章节段落，保持每个非空片段的原文起止偏移严格准确。
List<ParagraphSegment> splitChapterParagraphs(String chapterText) {
  final segments = <ParagraphSegment>[];
  if (chapterText.isEmpty) return segments;

  var lineStart = 0;
  var segIdx = 0;

  void emitLine(int rawStart, int rawEnd) {
    var s = rawStart;
    var e = rawEnd;
    while (s < e && chapterText[s].trim().isEmpty) {
      s++;
    }
    while (e > s && chapterText[e - 1].trim().isEmpty) {
      e--;
    }
    if (e <= s) return;
    final slice = chapterText.substring(s, e);
    segments.add(
      ParagraphSegment(
        index: segIdx++,
        startChar: s,
        endChar: e,
        text: slice,
        hash: stableParagraphHash(slice),
      ),
    );
  }

  for (var i = 0; i < chapterText.length; i++) {
    if (chapterText.codeUnitAt(i) == 0x0A /* \n */) {
      emitLine(lineStart, i);
      lineStart = i + 1;
    }
  }
  if (lineStart < chapterText.length) {
    emitLine(lineStart, chapterText.length);
  }
  return segments;
}

const Set<String> _kSentenceTerminators = <String>{
  '。',
  '！',
  '？',
  '!',
  '?',
};

const Set<String> _kStrictClosingPunctuation = <String>{
  '”',
  '’',
  ')',
  ']',
  '」',
  '』',
  '）',
  '》',
  '】',
};

bool _isClosingQuoteAt(String text, int idx, int paraStart, int paraEnd) {
  if (idx < paraStart || idx >= paraEnd) return false;
  final ch = text[idx];
  if (_kStrictClosingPunctuation.contains(ch)) return true;
  final code = ch.codeUnitAt(0);
  if (code == 0x22 /* " */) {
    var openCount = 0;
    for (var k = paraStart; k < idx; k++) {
      if (text.codeUnitAt(k) == 0x22) openCount++;
    }
    if (openCount.isOdd) return true;
    return idx + 1 >= paraEnd ||
        text[idx + 1].trim().isEmpty ||
        _kStrictClosingPunctuation.contains(text[idx + 1]);
  }
  if (code == 0x27 /* ' */) {
    return idx + 1 >= paraEnd ||
        text[idx + 1].trim().isEmpty ||
        _kStrictClosingPunctuation.contains(text[idx + 1]);
  }
  return false;
}

const Set<String> _kSoftDelimiters = <String>{
  ';',
  '；',
  ',',
  '，',
  '—',
  ' ',
};

const Set<String> _kEnglishAbbreviations = <String>{
  'mr',
  'mrs',
  'ms',
  'dr',
  'prof',
  'rev',
  'hon',
  'pres',
  'gov',
  'gen',
  'col',
  'maj',
  'capt',
  'lt',
  'sgt',
  'st',
  'sr',
  'jr',
  'vs',
  'etc',
  'no',
  'ch',
  'sec',
  'vol',
  'fig',
  'eq',
  'ref',
  'inc',
  'ltd',
  'co',
  'corp',
  'dept',
  'est',
  'approx',
  'ed',
  'eds',
  'trans',
  'pp',
  'pg',
  'al',
  'cf',
  'viz',
  'op',
  'cit',
  'jan',
  'feb',
  'mar',
  'apr',
  'jun',
  'jul',
  'aug',
  'sep',
  'sept',
  'oct',
  'nov',
  'dec',
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
  'sat',
  'sun',
};

bool _isAsciiLetterCode(int code) =>
    (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);

bool _isDigitCode(int code) => code >= 0x30 && code <= 0x39;

bool _isSentenceDotBoundary(String text, int dotIdx, int paraStart, int paraEnd) {
  final prevIsDigit =
      dotIdx > paraStart && _isDigitCode(text.codeUnitAt(dotIdx - 1));
  final nextIsDigit =
      dotIdx + 1 < paraEnd && _isDigitCode(text.codeUnitAt(dotIdx + 1));
  if (prevIsDigit && nextIsDigit) {
    return false; // 小数/版本号如 3.14, 0.4.3
  }

  // 省略号 `...`：仅当紧跟引号、段落结尾或空格+大写/汉字时视为句末
  if (dotIdx + 1 < paraEnd && text.codeUnitAt(dotIdx + 1) == 0x2E) {
    var endDots = dotIdx + 1;
    while (endDots < paraEnd && text.codeUnitAt(endDots) == 0x2E) {
      endDots++;
    }
    if (endDots < paraEnd &&
        _isClosingQuoteAt(text, endDots, paraStart, paraEnd)) {
      return true;
    }
    if (endDots >= paraEnd) return true;
    if (text[endDots].trim().isNotEmpty) return false;
    var k = endDots;
    while (k < paraEnd && text[k].trim().isEmpty) {
      k++;
    }
    if (k >= paraEnd) return true;
    final nextCode = text.codeUnitAt(k);
    return (nextCode >= 0x41 && nextCode <= 0x5A) || _isCjkHan(nextCode);
  }

  final nextAllowed =
      dotIdx + 1 >= paraEnd ||
      text[dotIdx + 1].trim().isEmpty ||
      _isClosingQuoteAt(text, dotIdx + 1, paraStart, paraEnd);
  if (!nextAllowed) {
    return false;
  }

  // 提取点号前紧邻的 ASCII 英文词，避免误切常见缩写（Mr./Mrs./Dr./No./etc.）与姓名首字母缩写
  var wordStart = dotIdx;
  while (wordStart > paraStart &&
      _isAsciiLetterCode(text.codeUnitAt(wordStart - 1))) {
    wordStart--;
  }
  if (wordStart < dotIdx) {
    final word = text.substring(wordStart, dotIdx);
    final lower = word.toLowerCase();
    if (_kEnglishAbbreviations.contains(lower)) {
      return false;
    }
    if (word.length == 1) {
      // 如 `U.S.`, `e.g.`, `i.e.`（前缀就是 `.`）或 `J. K.`（后接单字母+`.` 或小写词）
      if (wordStart > paraStart && text.codeUnitAt(wordStart - 1) == 0x2E) {
        return false;
      }
      var k = dotIdx + 1;
      while (k < paraEnd && text[k].trim().isEmpty) {
        k++;
      }
      if (k < paraEnd) {
        final c = text.codeUnitAt(k);
        if ((c >= 0x61 && c <= 0x7A) ||
            (_isAsciiLetterCode(c) &&
                k + 1 < paraEnd &&
                text.codeUnitAt(k + 1) == 0x2E)) {
          return false;
        }
      }
    }
  }
  return true;
}

({int start, int end})? _trimSpan(String text, int start, int end) {
  var s = start;
  var e = end;
  while (s < e && text[s].trim().isEmpty) {
    s++;
  }
  while (e > s && text[e - 1].trim().isEmpty) {
    e--;
  }
  if (s >= e) return null;
  return (start: s, end: e);
}

/// 按自然句切分章节文本（支持英文缩写过滤、短句合并、超长句按从句软切与精确原字符偏移）。
List<ParagraphSegment> splitChapterSentences(String chapterText) {
  final segments = <ParagraphSegment>[];
  if (chapterText.isEmpty) return segments;

  const minSentenceChars = 10;
  const maxMergedChars = 280;
  const maxSentenceChars = 360;

  void processParagraph(int rawStart, int rawEnd) {
    final trimmedPara = _trimSpan(chapterText, rawStart, rawEnd);
    if (trimmedPara == null) return;

    final pStart = trimmedPara.start;
    final pEnd = trimmedPara.end;

    final rawSpans = <({int start, int end})>[];
    var segStart = pStart;
    var i = pStart;
    while (i < pEnd) {
      final ch = chapterText[i];
      var isEnd = _kSentenceTerminators.contains(ch);
      if (!isEnd && ch == '.') {
        isEnd = _isSentenceDotBoundary(chapterText, i, pStart, pEnd);
      }
      if (isEnd) {
        var segEnd = i + 1;
        while (segEnd < pEnd &&
            (_kSentenceTerminators.contains(chapterText[segEnd]) ||
                chapterText.codeUnitAt(segEnd) == 0x2E)) {
          segEnd++;
        }
        while (segEnd < pEnd &&
            _isClosingQuoteAt(chapterText, segEnd, pStart, pEnd)) {
          segEnd++;
        }
        final trimmed = _trimSpan(chapterText, segStart, segEnd);
        if (trimmed != null) rawSpans.add(trimmed);
        segStart = segEnd;
        i = segEnd;
      } else {
        i++;
      }
    }
    if (segStart < pEnd) {
      final trimmed = _trimSpan(chapterText, segStart, pEnd);
      if (trimmed != null) rawSpans.add(trimmed);
    }

    // 合并同段内过短碎句（< 10 字）：优先向后合并以保留引号/惊叹引语完整（如 `"Yes!" she shouted.`），仅末尾短句向前合并
    final merged = <({int start, int end})>[];
    for (final span in rawSpans) {
      if (merged.isEmpty) {
        merged.add(span);
        continue;
      }
      final prev = merged.last;
      final prevLen = prev.end - prev.start;
      if (prevLen < minSentenceChars &&
          (span.end - prev.start) <= maxMergedChars) {
        merged[merged.length - 1] = (start: prev.start, end: span.end);
      } else {
        merged.add(span);
      }
    }
    if (merged.length >= 2) {
      final tail = merged.last;
      final prev = merged[merged.length - 2];
      if ((tail.end - tail.start) < minSentenceChars &&
          (tail.end - prev.start) <= maxMergedChars) {
        merged[merged.length - 2] = (start: prev.start, end: tail.end);
        merged.removeLast();
      }
    }

    // 切分超长单句（> 360 字），保证单句离线推理速度与首句即时渲染
    final finalSpans = <({int start, int end})>[];
    for (final span in merged) {
      if (span.end - span.start <= maxSentenceChars) {
        finalSpans.add(span);
        continue;
      }
      var cursor = span.start;
      while (cursor < span.end) {
        while (cursor < span.end && chapterText[cursor].trim().isEmpty) {
          cursor++;
        }
        if (cursor >= span.end) break;
        if (span.end - cursor <= maxSentenceChars) {
          final tail = _trimSpan(chapterText, cursor, span.end);
          if (tail != null) finalSpans.add(tail);
          break;
        }
        final limit = cursor + maxSentenceChars;
        var breakAt = -1;
        for (var k = limit; k > cursor + 40; k--) {
          if (_kSoftDelimiters.contains(chapterText[k - 1])) {
            breakAt = k;
            break;
          }
        }
        breakAt = breakAt > cursor ? breakAt : limit;
        final piece = _trimSpan(chapterText, cursor, breakAt);
        if (piece != null) finalSpans.add(piece);
        cursor = breakAt;
      }
    }

    for (var sIdx = 0; sIdx < finalSpans.length; sIdx++) {
      final sp = finalSpans[sIdx];
      final slice = chapterText.substring(sp.start, sp.end);
      segments.add(
        ParagraphSegment(
          index: segments.length,
          startChar: sp.start,
          endChar: sp.end,
          text: slice,
          hash: stableParagraphHash(slice),
          isParagraphEnd: sIdx == finalSpans.length - 1,
        ),
      );
    }
  }

  var lineStart = 0;
  for (var i = 0; i < chapterText.length; i++) {
    if (chapterText.codeUnitAt(i) == 0x0A /* \n */) {
      processParagraph(lineStart, i);
      lineStart = i + 1;
    }
  }
  if (lineStart < chapterText.length) {
    processParagraph(lineStart, chapterText.length);
  }
  return segments;
}

/// 启发式语言检测结果与抽样判断是否相对目标语言属于「外文图书」。
bool isForeignBookForTarget(
  List<String> sampleTexts,
  TranslationTargetLanguage targetLang,
) {
  if (sampleTexts.isEmpty) return false;

  var cjkCount = 0;
  var kanaCount = 0;
  var hangulCount = 0;
  var latinCount = 0;
  var cyrillicCount = 0;
  var otherAlphaCount = 0;

  final latinBuffer = StringBuffer();
  var sampled = 0;

  for (final raw in sampleTexts) {
    if (raw.isEmpty) continue;
    for (final rune in raw.runes) {
      if (sampled >= 4500) break;
      if (_isCjkHan(rune)) {
        cjkCount++;
        sampled++;
      } else if (_isKana(rune)) {
        kanaCount++;
        sampled++;
      } else if (_isHangul(rune)) {
        hangulCount++;
        sampled++;
      } else if (_isLatinLetter(rune)) {
        latinCount++;
        sampled++;
        if (latinBuffer.length < 3000) {
          latinBuffer.writeCharCode(rune);
        }
      } else if (_isCyrillic(rune)) {
        cyrillicCount++;
        sampled++;
      } else if (_isArabicOrIndicOrThai(rune)) {
        otherAlphaCount++;
        sampled++;
      } else {
        if (latinBuffer.length < 3000 && rune == 0x20) {
          latinBuffer.write(' ');
        }
      }
    }
    if (sampled >= 4500) break;
  }

  if (sampled < 25) return false;

  final total = cjkCount +
      kanaCount +
      hangulCount +
      latinCount +
      cyrillicCount +
      otherAlphaCount;
  if (total == 0) return false;

  switch (targetLang) {
    case TranslationTargetLanguage.zhHans:
    case TranslationTargetLanguage.zhHant:
      // 含假名显著比例视为日语书；汉字占比不足 35% 且非中文文字 >= 45% 视为外文书
      if (kanaCount / total >= 0.08) return true;
      final nonZh = latinCount + hangulCount + cyrillicCount + otherAlphaCount;
      return (cjkCount / total) < 0.35 && (nonZh / total) >= 0.45;
    case TranslationTargetLanguage.ja:
      return (kanaCount / total) < 0.08;
    case TranslationTargetLanguage.ko:
      return (hangulCount / total) < 0.20;
    case TranslationTargetLanguage.ru:
      return (cyrillicCount / total) < 0.30;
    case TranslationTargetLanguage.en:
    case TranslationTargetLanguage.fr:
    case TranslationTargetLanguage.de:
    case TranslationTargetLanguage.es:
      // 若主体为非拉丁文字，必然属于外文
      if ((latinCount / total) < 0.50) return true;
      return _isDifferentLatinLanguage(latinBuffer.toString(), targetLang);
  }
}

bool _isCjkHan(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0xF900 && r <= 0xFAFF);

bool _isKana(int r) => (r >= 0x3040 && r <= 0x309F) || (r >= 0x30A0 && r <= 0x30FF);

bool _isHangul(int r) =>
    (r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF);

bool _isLatinLetter(int r) =>
    (r >= 0x41 && r <= 0x5A) ||
    (r >= 0x61 && r <= 0x7A) ||
    (r >= 0x00C0 && r <= 0x024F);

bool _isCyrillic(int r) => r >= 0x0400 && r <= 0x04FF;

bool _isArabicOrIndicOrThai(int r) =>
    (r >= 0x0600 && r <= 0x06FF) ||
    (r >= 0x0900 && r <= 0x097F) ||
    (r >= 0x0E00 && r <= 0x0E7F);

/// 轻量停用词辨识常见拉丁语种（避免英文目标把法/德/西图书误判为母语）。
bool _isDifferentLatinLanguage(
  String text,
  TranslationTargetLanguage targetLang,
) {
  final words = text
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  if (words.length < 15) return false;

  const enStop = {'the', 'and', 'of', 'to', 'in', 'is', 'that', 'was', 'for'};
  const frStop = {'le', 'la', 'les', 'des', 'une', 'est', 'dans', 'pour', 'que'};
  const deStop = {'der', 'die', 'das', 'und', 'ist', 'ein', 'nicht', 'mit', 'ich'};
  const esStop = {'el', 'los', 'las', 'una', 'por', 'con', 'para', 'que', 'es'};

  int countHits(Set<String> set) => words.where(set.contains).length;

  final scores = <TranslationTargetLanguage, int>{
    TranslationTargetLanguage.en: countHits(enStop),
    TranslationTargetLanguage.fr: countHits(frStop),
    TranslationTargetLanguage.de: countHits(deStop),
    TranslationTargetLanguage.es: countHits(esStop),
  };

  final targetScore = scores[targetLang] ?? 0;
  var bestLang = targetLang;
  var bestScore = targetScore;
  scores.forEach((lang, score) {
    if (score > bestScore) {
      bestScore = score;
      bestLang = lang;
    }
  });

  // 仅当显著命中另一语种停用词时才认为是外文
  return bestLang != targetLang && bestScore >= 4 && bestScore > targetScore * 2;
}
