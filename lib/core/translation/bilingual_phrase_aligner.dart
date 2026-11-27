import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../notes/reading_annotation_store.dart'
    show ReadingAnnotation, ReadingAnnotationTarget;
import 'translation_models.dart';

/// 单句中/外文对齐输入单元，记录原句在章节正文中的精确字符区间。
@immutable
class SentenceAlignmentPair {
  const SentenceAlignmentPair({
    required this.origStartChar,
    required this.origEndChar,
    required this.origText,
    required this.transText,
  });

  final int origStartChar;
  final int origEndChar;
  final String origText;
  final String transText;
}

/// 译文划线向原文章节偏移的对齐结果。
@immutable
class PhraseAlignmentResult {
  const PhraseAlignmentResult({
    required this.alignedOrigStart,
    required this.alignedOrigEnd,
    required this.isSubSentenceMatch,
    required this.usedModel,
    required this.confidence,
  });

  final int alignedOrigStart;
  final int alignedOrigEnd;
  final bool isSubSentenceMatch;
  final bool usedModel;
  final double confidence;
}

typedef BackTranslatePhraseFn =
    Future<String?> Function(
      String phrase,
      TranslationTargetLanguage targetLanguage,
    );

final RegExp _kPunctAndWsRegex = RegExp(
  r'[\s。！？；，、：“”‘’「」『』（）().,!?;:\x27"\-—…\[\]{}]+',
);

final RegExp _kClauseSepRegex = RegExp(r'[,;，；。！？!?]');

final RegExp _kLatinTokenRegex = RegExp(
  r"[A-Za-z0-9]+(?:['’\-][A-Za-z0-9]+)*",
);

const Set<String> _kEnglishStopwords = <String>{
  'a',
  'an',
  'the',
  'and',
  'or',
  'but',
  'nor',
  'so',
  'yet',
  'for',
  'of',
  'in',
  'on',
  'at',
  'to',
  'from',
  'by',
  'with',
  'as',
  'into',
  'onto',
  'upon',
  'out',
  'up',
  'down',
  'over',
  'under',
  'about',
  'after',
  'before',
  'between',
  'through',
  'during',
  'without',
  'within',
  'against',
  'is',
  'am',
  'are',
  'was',
  'were',
  'be',
  'been',
  'being',
  'have',
  'has',
  'had',
  'do',
  'does',
  'did',
  'will',
  'would',
  'shall',
  'should',
  'can',
  'could',
  'may',
  'might',
  'must',
  'that',
  'which',
  'who',
  'whom',
  'whose',
  'this',
  'these',
  'those',
  'it',
  'its',
  'he',
  'him',
  'his',
  'she',
  'her',
  'hers',
  'they',
  'them',
  'their',
  'theirs',
  'we',
  'us',
  'our',
  'i',
  'me',
  'my',
  'you',
  'your',
  'there',
  'here',
  'than',
  'then',
  'if',
  'when',
  'where',
  'while',
  'not',
  'no',
};

const Map<String, String> _kIrregularLemmas = <String, String>{
  'am': 'be',
  'is': 'be',
  'are': 'be',
  'was': 'be',
  'were': 'be',
  'been': 'be',
  'being': 'be',
  'has': 'have',
  'had': 'have',
  'having': 'have',
  'does': 'do',
  'did': 'do',
  'done': 'do',
  'went': 'go',
  'gone': 'go',
  'came': 'come',
  'saw': 'see',
  'seen': 'see',
  'took': 'take',
  'taken': 'take',
  'made': 'make',
  'gave': 'give',
  'given': 'give',
  'got': 'get',
  'gotten': 'get',
  'found': 'find',
  'told': 'tell',
  'said': 'say',
  'knew': 'know',
  'known': 'know',
  'thought': 'think',
  'kept': 'keep',
  'held': 'hold',
  'heard': 'hear',
  'ran': 'run',
  'brought': 'bring',
  'wrote': 'write',
  'written': 'write',
  'stood': 'stand',
  'lost': 'lose',
  'hung': 'hang',
  'grown': 'grow',
  'grew': 'grow',
  'lying': 'lie',
  'lay': 'lie',
  'lain': 'lie',
  'drew': 'draw',
  'drawn': 'draw',
  'slept': 'sleep',
  'fell': 'fall',
  'fallen': 'fall',
  'felt': 'feel',
  'left': 'leave',
  'spoke': 'speak',
  'spoken': 'speak',
  'broke': 'break',
  'broken': 'break',
  'began': 'begin',
  'begun': 'begin',
  'sent': 'send',
  'built': 'build',
  'caught': 'catch',
  'taught': 'teach',
  'bought': 'buy',
  'spent': 'spend',
  'wore': 'wear',
  'worn': 'wear',
  'driven': 'drive',
  'drove': 'drive',
  'rode': 'ride',
  'ridden': 'ride',
  'ate': 'eat',
  'eaten': 'eat',
  'drank': 'drink',
  'drunk': 'drink',
  'men': 'man',
  'women': 'woman',
  'children': 'child',
  'feet': 'foot',
  'teeth': 'tooth',
};

/// 根据原文章节样本粗略识别原著语种，供短语回译对齐确定目标语种。
TranslationTargetLanguage detectLikelySourceLanguage(String sample) {
  if (sample.trim().isEmpty) return TranslationTargetLanguage.en;
  var cjkHan = 0;
  var kana = 0;
  var hangul = 0;
  var cyrillic = 0;
  var latin = 0;
  final latinBuf = StringBuffer();

  for (final r in sample.runes) {
    if ((r >= 0x3040 && r <= 0x309F) || (r >= 0x30A0 && r <= 0x30FF)) {
      kana++;
    } else if ((r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF)) {
      hangul++;
    } else if (r >= 0x0400 && r <= 0x04FF) {
      cyrillic++;
    } else if ((r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3400 && r <= 0x4DBF) ||
        (r >= 0xF900 && r <= 0xFAFF)) {
      cjkHan++;
    } else if ((r >= 0x41 && r <= 0x5A) ||
        (r >= 0x61 && r <= 0x7A) ||
        (r >= 0x00C0 && r <= 0x024F)) {
      latin++;
      latinBuf.writeCharCode(r);
    } else {
      latinBuf.write(' ');
    }
  }

  final total = cjkHan + kana + hangul + cyrillic + latin;
  if (total == 0) return TranslationTargetLanguage.en;
  if (kana / total >= 0.08) return TranslationTargetLanguage.ja;
  if (hangul / total >= 0.20) return TranslationTargetLanguage.ko;
  if (cyrillic / total >= 0.30) return TranslationTargetLanguage.ru;
  if (cjkHan / total >= 0.35 && latin / total < 0.35) {
    return TranslationTargetLanguage.zhHans;
  }

  final words = latinBuf
      .toString()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  const enStop = {'the', 'and', 'of', 'to', 'in', 'is', 'that', 'was', 'for'};
  const frStop = {'le', 'la', 'les', 'des', 'une', 'est', 'dans', 'pour', 'que'};
  const deStop = {'der', 'die', 'das', 'und', 'ist', 'ein', 'nicht', 'mit', 'ich'};
  const esStop = {'el', 'los', 'las', 'una', 'por', 'con', 'para', 'que', 'es'};
  int hits(Set<String> set) => words.where(set.contains).length;
  final enHits = hits(enStop);
  final candidates = <(TranslationTargetLanguage, int)>[
    (TranslationTargetLanguage.fr, hits(frStop)),
    (TranslationTargetLanguage.de, hits(deStop)),
    (TranslationTargetLanguage.es, hits(esStop)),
  ];
  var bestLang = TranslationTargetLanguage.en;
  var bestScore = enHits;
  for (final c in candidates) {
    if (c.$2 >= 2 && c.$2 > bestScore) {
      bestLang = c.$1;
      bestScore = c.$2;
    }
  }
  return bestLang;
}

String _stripPunctAndWs(String text) => text.replaceAll(_kPunctAndWsRegex, '');

({int start, int end})? _findQuoteInText(String haystack, String query) {
  final raw = query.replaceAll('\n', '').trim();
  if (raw.isEmpty) return null;
  final direct = haystack.indexOf(raw);
  if (direct >= 0) {
    return (start: direct, end: direct + raw.length);
  }
  final cleanQuery = query.replaceAll(RegExp(r'\s+'), '');
  if (cleanQuery.isEmpty) return null;
  final normBuf = StringBuffer();
  final idxMap = <int>[];
  for (var i = 0; i < haystack.length; i++) {
    final ch = haystack[i];
    if (ch.trim().isNotEmpty) {
      normBuf.write(ch);
      idxMap.add(i);
    }
  }
  final normIdx = normBuf.toString().indexOf(cleanQuery);
  if (normIdx >= 0 && normIdx + cleanQuery.length <= idxMap.length) {
    return (
      start: idxMap[normIdx],
      end: idxMap[normIdx + cleanQuery.length - 1] + 1,
    );
  }
  return null;
}

bool _isSingleSentenceFullCoverage(
  SentenceAlignmentPair sent,
  ({int start, int end}) sel,
) {
  final fullTrans = sent.transText.trim();
  final cleanFull = _stripPunctAndWs(fullTrans);
  if (cleanFull.isEmpty) return true;
  final cleanSel = _stripPunctAndWs(fullTrans.substring(sel.start, sel.end));
  return cleanSel.length / cleanFull.length >= 0.85;
}

({int start, int end})? _resolveSingleSentenceSelection(
  SentenceAlignmentPair sent,
  ReadingAnnotation ann,
) {
  final fullTrans = sent.transText.trim();
  if (fullTrans.isEmpty) return null;
  if (ann.target == ReadingAnnotationTarget.translation &&
      (ann.transStartInFirst != null || ann.transEndInLast != null)) {
    final s = (ann.transStartInFirst ?? 0).clamp(0, fullTrans.length);
    final e = (ann.transEndInLast ?? fullTrans.length).clamp(s, fullTrans.length);
    if (s < e) {
      return (start: s, end: e);
    }
  }
  return _findQuoteInText(fullTrans, ann.quote);
}

bool _isLegacyAutoOriginalAnnotation(
  ReadingAnnotation ann,
  List<SentenceAlignmentPair> sentences,
) {
  if (ann.target == ReadingAnnotationTarget.original) return true;
  if (ann.target != ReadingAnnotationTarget.auto) return false;
  final concatTrans = sentences.map((s) => s.transText.trim()).join();
  if (_findQuoteInText(concatTrans, ann.quote) != null) return false;
  final concatOrig = sentences.map((s) => s.origText.trim()).join(' ');
  return _findQuoteInText(concatOrig, ann.quote) != null;
}

/// 解包成对的外层括号或引号（如 `（威灵顿·贝蒂）` / `(hello)`）。
({String open, String close, String inner})? _unwrapMatchingOuterPair(
  String text,
  List<(String, String)> pairs,
) {
  final trimmed = text.trim();
  for (final (open, close) in pairs) {
    if (trimmed.length > open.length + close.length &&
        trimmed.startsWith(open) &&
        trimmed.endsWith(close)) {
      final inner = trimmed.substring(open.length, trimmed.length - close.length);
      if (!inner.contains(open) && !inner.contains(close)) {
        return (open: open, close: close, inner: inner);
      }
    }
  }
  return null;
}

PhraseAlignmentResult? _tryDeterministicSubSentence(
  SentenceAlignmentPair sent,
  int selStart,
  int selEnd,
) {
  final fullTrans = sent.transText.trim();
  final zhSlice = fullTrans.substring(selStart, selEnd).trim();
  if (zhSlice.isEmpty) return null;

  // 1) 唯一成对括号/引语直接精确配对
  final parenUnwrap = _unwrapMatchingOuterPair(zhSlice, const [
    ('（', '）'),
    ('(', ')'),
  ]);
  if (parenUnwrap != null) {
    final parenRegex = RegExp(r'\([^()]{2,}\)|（[^（）]{2,}）');
    final origMatches = parenRegex.allMatches(sent.origText).toList();
    final transMatches = parenRegex.allMatches(fullTrans).toList();
    if (origMatches.length == 1 && transMatches.length == 1) {
      final m = origMatches.first;
      return PhraseAlignmentResult(
        alignedOrigStart: (sent.origStartChar + m.start).clamp(
          sent.origStartChar,
          sent.origEndChar,
        ),
        alignedOrigEnd: (sent.origStartChar + m.end).clamp(
          sent.origStartChar,
          sent.origEndChar,
        ),
        isSubSentenceMatch: true,
        usedModel: false,
        confidence: 0.92,
      );
    }
    if (origMatches.isNotEmpty && origMatches.length == transMatches.length) {
      final idx = transMatches.indexWhere(
        (m) => m.start >= selStart - 1 && m.end <= selEnd + 1,
      );
      if (idx >= 0) {
        final m = origMatches[idx];
        return PhraseAlignmentResult(
          alignedOrigStart: (sent.origStartChar + m.start).clamp(
            sent.origStartChar,
            sent.origEndChar,
          ),
          alignedOrigEnd: (sent.origStartChar + m.end).clamp(
            sent.origStartChar,
            sent.origEndChar,
          ),
          isSubSentenceMatch: true,
          usedModel: false,
          confidence: 0.90,
        );
      }
    }
  }

  final quoteUnwrap = _unwrapMatchingOuterPair(zhSlice, const [
    ('“', '”'),
    ('「', '」'),
    ('『', '』'),
    ('"', '"'),
  ]);
  if (quoteUnwrap != null) {
    final origQuoteRegex = RegExp(r'"[^"]{2,}"|“[^”]{2,}”|「[^」]{2,}」');
    final transQuoteRegex = RegExp(r'“[^”]{2,}”|「[^」]{2,}」|『[^』]{2,}』|"[^"]{2,}"');
    final origMatches = origQuoteRegex.allMatches(sent.origText).toList();
    final transMatches = transQuoteRegex.allMatches(fullTrans).toList();
    if (origMatches.length == 1 && transMatches.length == 1) {
      final m = origMatches.first;
      return PhraseAlignmentResult(
        alignedOrigStart: (sent.origStartChar + m.start).clamp(
          sent.origStartChar,
          sent.origEndChar,
        ),
        alignedOrigEnd: (sent.origStartChar + m.end).clamp(
          sent.origStartChar,
          sent.origEndChar,
        ),
        isSubSentenceMatch: true,
        usedModel: false,
        confidence: 0.90,
      );
    }
  }

  // 2) 字面拉丁词/数字实体（如 "Mr. Jones", "Willingdon", "1984"）免推理直接匹配
  final compact = zhSlice.replaceAll(RegExp(r'\s+'), '');
  if (compact.isNotEmpty) {
    var latinDigit = 0;
    for (final r in compact.runes) {
      if ((r >= 0x41 && r <= 0x5A) ||
          (r >= 0x61 && r <= 0x7A) ||
          (r >= 0x30 && r <= 0x39)) {
        latinDigit++;
      }
    }
    if (latinDigit / compact.runes.length >= 0.60) {
      final zhCenterRatio = ((selStart + selEnd) / 2.0) / math.max(1, fullTrans.length);
      final hit = alignEnglishSpanFromBackTranslation(
        origSentence: sent.origText,
        backTranslation: zhSlice,
        zhCenterRatio: zhCenterRatio,
        isSingleClauseZh: !_kClauseSepRegex.hasMatch(zhSlice),
      );
      if (hit != null) {
        return PhraseAlignmentResult(
          alignedOrigStart: (sent.origStartChar + hit.start).clamp(
            sent.origStartChar,
            sent.origEndChar,
          ),
          alignedOrigEnd: (sent.origStartChar + hit.end).clamp(
            sent.origStartChar,
            sent.origEndChar,
          ),
          isSubSentenceMatch:
              hit.start > 0 || hit.end < sent.origText.length,
          usedModel: false,
          confidence: hit.confidence,
        );
      }
    }
  }

  return null;
}

/// 零等待确定性对齐（覆盖整句划线、括号/引语配对与字面英文数字实体）；无法即时确定时返回 `null` 交由异步回译对齐。
PhraseAlignmentResult? tryInstantPhraseAlign({
  required ReadingAnnotation annotation,
  required List<SentenceAlignmentPair> sentences,
}) {
  final valid =
      sentences
          .where((s) => s.origText.trim().isNotEmpty && s.transText.trim().isNotEmpty)
          .toList()
        ..sort((a, b) => a.origStartChar.compareTo(b.origStartChar));
  if (valid.isEmpty) return null;
  if (_isLegacyAutoOriginalAnnotation(annotation, valid)) return null;

  if (valid.length == 1) {
    final sent = valid.single;
    final sel = _resolveSingleSentenceSelection(sent, annotation);
    if (sel == null) {
      return PhraseAlignmentResult(
        alignedOrigStart: sent.origStartChar,
        alignedOrigEnd: sent.origEndChar,
        isSubSentenceMatch: false,
        usedModel: false,
        confidence: 1.0,
      );
    }
    if (_isSingleSentenceFullCoverage(sent, sel)) {
      return PhraseAlignmentResult(
        alignedOrigStart: sent.origStartChar,
        alignedOrigEnd: sent.origEndChar,
        isSubSentenceMatch: false,
        usedModel: false,
        confidence: 1.0,
      );
    }
    return _tryDeterministicSubSentence(sent, sel.start, sel.end);
  }

  // 多句选择：检查首尾残句是否跳过 > 12%
  final first = valid.first;
  final last = valid.last;
  final firstFull = first.transText.trim();
  final lastFull = last.transText.trim();

  var needHeadAlign = false;
  var headStart = 0;
  if (annotation.target == ReadingAnnotationTarget.translation &&
      annotation.transStartInFirst != null) {
    headStart = annotation.transStartInFirst!.clamp(0, firstFull.length);
    final skippedHead = _stripPunctAndWs(firstFull.substring(0, headStart)).length;
    final cleanFirst = _stripPunctAndWs(firstFull).length;
    if (cleanFirst > 0 && skippedHead / cleanFirst > 0.12) {
      needHeadAlign = true;
    }
  }

  var needTailAlign = false;
  var tailEnd = lastFull.length;
  if (annotation.target == ReadingAnnotationTarget.translation &&
      annotation.transEndInLast != null) {
    tailEnd = annotation.transEndInLast!.clamp(0, lastFull.length);
    final skippedTail = _stripPunctAndWs(lastFull.substring(tailEnd)).length;
    final cleanLast = _stripPunctAndWs(lastFull).length;
    if (cleanLast > 0 && skippedTail / cleanLast > 0.12) {
      needTailAlign = true;
    }
  }

  if (!needHeadAlign && !needTailAlign) {
    return PhraseAlignmentResult(
      alignedOrigStart: first.origStartChar,
      alignedOrigEnd: last.origEndChar,
      isSubSentenceMatch: false,
      usedModel: false,
      confidence: 1.0,
    );
  }

  int alignedStart = first.origStartChar;
  if (needHeadAlign) {
    final res = _tryDeterministicSubSentence(first, headStart, firstFull.length);
    if (res == null) return null;
    alignedStart = res.alignedOrigStart;
  }

  int alignedEnd = last.origEndChar;
  if (needTailAlign) {
    final res = _tryDeterministicSubSentence(last, 0, tailEnd);
    if (res == null) return null;
    alignedEnd = res.alignedOrigEnd;
  }

  if (alignedStart >= alignedEnd) {
    return PhraseAlignmentResult(
      alignedOrigStart: first.origStartChar,
      alignedOrigEnd: last.origEndChar,
      isSubSentenceMatch: false,
      usedModel: false,
      confidence: 1.0,
    );
  }

  return PhraseAlignmentResult(
    alignedOrigStart: alignedStart,
    alignedOrigEnd: alignedEnd,
    isSubSentenceMatch:
        alignedStart > first.origStartChar || alignedEnd < last.origEndChar,
    usedModel: false,
    confidence: 0.90,
  );
}

class _AlignedToken {
  const _AlignedToken({
    required this.raw,
    required this.norm,
    required this.stem,
    required this.subParts,
    required this.start,
    required this.end,
    required this.isStopword,
    required this.isCapitalizedProper,
    required this.weight,
  });

  final String raw;
  final String norm;
  final String stem;
  final List<String> subParts;
  final int start;
  final int end;
  final bool isStopword;
  final bool isCapitalizedProper;
  final double weight;
}

String _stemEnglishWord(String norm) {
  final irregular = _kIrregularLemmas[norm];
  if (irregular != null) return irregular;
  if (norm.length <= 3) return norm;
  if (norm.endsWith('ies') && norm.length > 4) {
    return '${norm.substring(0, norm.length - 3)}y';
  }
  if (norm.endsWith('ied') && norm.length > 4) {
    return '${norm.substring(0, norm.length - 3)}y';
  }
  if (norm.endsWith('ing') && norm.length >= 6) {
    return norm.substring(0, norm.length - 3);
  }
  if (norm.endsWith('ed') && norm.length >= 5) {
    return norm.substring(0, norm.length - 2);
  }
  if (norm.endsWith('ly') && norm.length >= 5) {
    return norm.substring(0, norm.length - 2);
  }
  if (norm.endsWith('es') && norm.length >= 5) {
    return norm.substring(0, norm.length - 2);
  }
  if (norm.endsWith('s') && !norm.endsWith('ss') && norm.length >= 4) {
    return norm.substring(0, norm.length - 1);
  }
  return norm;
}

List<_AlignedToken> _tokenizeLatinWithOffsets(String text) {
  final tokens = <_AlignedToken>[];
  for (final m in _kLatinTokenRegex.allMatches(text)) {
    final raw = m.group(0)!;
    var norm = raw.toLowerCase();
    if (norm.endsWith("'s") || norm.endsWith('’s')) {
      norm = norm.substring(0, norm.length - 2);
    } else if (norm.endsWith("'") || norm.endsWith('’')) {
      norm = norm.substring(0, norm.length - 1);
    }
    if (norm.isEmpty) continue;
    final subParts = norm
        .split(RegExp(r"[-'’]"))
        .where((p) => p.isNotEmpty)
        .map(_stemEnglishWord)
        .toList(growable: false);
    final stem = _stemEnglishWord(norm);
    final isStop = _kEnglishStopwords.contains(norm) ||
        _kEnglishStopwords.contains(stem);
    final isCap = raw.length >= 4 &&
        raw.codeUnitAt(0) >= 0x41 &&
        raw.codeUnitAt(0) <= 0x5A &&
        !isStop;
    final weight = isStop
        ? 0.35
        : (2.0 + math.min(stem.length, 8) * 0.15 + (isCap ? 0.6 : 0.0));
    tokens.add(
      _AlignedToken(
        raw: raw,
        norm: norm,
        stem: stem,
        subParts: subParts,
        start: m.start,
        end: m.end,
        isStopword: isStop,
        isCapitalizedProper: isCap,
        weight: weight,
      ),
    );
  }
  return tokens;
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (j) => j);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    final ac = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ac == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}

double _tokenSimilarity(_AlignedToken a, _AlignedToken b) {
  if (a.norm == b.norm || a.stem == b.stem) return 1.0;

  if (a.subParts.length > 1 || b.subParts.length > 1) {
    for (final pa in a.subParts) {
      for (final pb in b.subParts) {
        if (pa == pb) return 0.90;
      }
    }
  }

  final minLen = math.min(a.stem.length, b.stem.length);
  final maxLen = math.max(a.stem.length, b.stem.length);
  if (minLen >= 4) {
    var prefix = 0;
    while (prefix < minLen && a.stem[prefix] == b.stem[prefix]) {
      prefix++;
    }
    final ratio = prefix / maxLen;
    if (prefix >= 4 && ratio >= 0.55) {
      return 0.65 + 0.30 * ratio;
    }

    if (a.norm.codeUnitAt(0) == b.norm.codeUnitAt(0)) {
      final lenMax = math.max(a.norm.length, b.norm.length);
      final dist = _levenshtein(a.norm, b.norm);
      final editSim = 1.0 - (dist / lenMax);
      if (editSim >= 0.65) {
        return 0.82 * editSim;
      }
    }
  }

  return 0.0;
}

String cleanBackTranslationOutput(String raw) {
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return '';
  var text = lines.first.trim();
  const quotes = [('"', '"'), ('“', '”'), ("'", "'"), ('`', '`')];
  for (final (open, close) in quotes) {
    if (text.length > open.length + close.length &&
        text.startsWith(open) &&
        text.endsWith(close)) {
      text = text.substring(open.length, text.length - close.length).trim();
    }
  }
  return text;
}

/// 语序无关的回译词元滑窗对齐器：在 [origSentence] 中定位与 [backTranslation] 语义最契合的连续英文短语。
/// 若置信度不足（或无法可靠收敛）则返回 `null`，由调用方安全回退整句。
({int start, int end, double confidence})? alignEnglishSpanFromBackTranslation({
  required String origSentence,
  required String backTranslation,
  double zhCenterRatio = 0.5,
  bool isSingleClauseZh = false,
}) {
  final cleanBack = cleanBackTranslationOutput(backTranslation);
  if (cleanBack.isEmpty || origSentence.trim().isEmpty) return null;

  final origTokens = _tokenizeLatinWithOffsets(origSentence);
  final backTokens = _tokenizeLatinWithOffsets(cleanBack);

  // 非拉丁原著（如日/韩/俄等缺少空格分隔的场景）降级为字符 2-gram 匹配
  if (origTokens.isEmpty || backTokens.isEmpty) {
    final direct = _findQuoteInText(origSentence, cleanBack);
    if (direct != null) {
      return (start: direct.start, end: direct.end, confidence: 0.90);
    }
    return null;
  }

  final n = origTokens.length;
  final m = backTokens.length;

  // 预计算相似度矩阵 sim[b][o]
  final simMatrix = List<List<double>>.generate(
    m,
    (bi) => List<double>.generate(
      n,
      (oi) => _tokenSimilarity(backTokens[bi], origTokens[oi]),
      growable: false,
    ),
    growable: false,
  );

  final origMaxSim = List<double>.generate(n, (oi) {
    var best = 0.0;
    for (var bi = 0; bi < m; bi++) {
      if (simMatrix[bi][oi] > best) best = simMatrix[bi][oi];
    }
    return best;
  }, growable: false);

  final totalBackWeight = backTokens.fold<double>(0.0, (s, t) => s + t.weight);
  final totalBackContentWeight = backTokens
      .where((t) => !t.isStopword)
      .fold<double>(0.0, (s, t) => s + t.weight);
  if (totalBackWeight <= 0) return null;

  final maxWinTokens = math.min(n, math.max(m * 2 + 4, 6));
  final trimmedOrig = origSentence.trim();
  final origNonWsLen = math.max(1, trimmedOrig.replaceAll(RegExp(r'\s+'), '').length);

  double bestScore = -1.0;
  int? bestStart;
  int? bestEnd;
  double bestConfidence = 0.0;

  for (var i = 0; i < n; i++) {
    if (origMaxSim[i] < 0.50) continue;
    for (var j = i; j < math.min(n, i + maxWinTokens); j++) {
      if (origMaxSim[j] < 0.50) continue;

      final winLen = j - i + 1;
      // 收集窗口内所有 >= 0.50 的候选词对，按相似度降序做 1-to-1 贪心匹配
      final pairs = <({int bi, int oi, double sim})>[];
      for (var bi = 0; bi < m; bi++) {
        for (var oi = i; oi <= j; oi++) {
          final sim = simMatrix[bi][oi];
          if (sim >= 0.50) {
            pairs.add((bi: bi, oi: oi, sim: sim));
          }
        }
      }
      if (pairs.isEmpty) continue;
      pairs.sort((a, b) {
        final cmp = b.sim.compareTo(a.sim);
        if (cmp != 0) return cmp;
        return backTokens[b.bi].weight.compareTo(backTokens[a.bi].weight);
      });

      final usedBack = List<bool>.filled(m, false);
      final usedOrig = List<bool>.filled(winLen, false);
      var matchedBackWeight = 0.0;
      var matchedOrigWeight = 0.0;
      var matchedContentWeight = 0.0;
      var strongContentHits = 0;
      var matchedCount = 0;

      for (final p in pairs) {
        if (usedBack[p.bi] || usedOrig[p.oi - i]) continue;
        usedBack[p.bi] = true;
        usedOrig[p.oi - i] = true;
        matchedCount++;

        final bt = backTokens[p.bi];
        final ot = origTokens[p.oi];
        final wBack = bt.weight * p.sim;
        final wOrig = ot.weight * p.sim;
        matchedBackWeight += wBack;
        matchedOrigWeight += wOrig;

        if (!bt.isStopword || !ot.isStopword) {
          matchedContentWeight += wBack;
          if (p.sim >= 0.72) {
            strongContentHits++;
          }
        }
      }

      // 窗口两端不能存在实际未被匹配的“虚搭”边界词
      if (!usedOrig[0] || !usedOrig[winLen - 1]) continue;

      if (totalBackContentWeight > 0) {
        final contentRecall = matchedContentWeight / totalBackContentWeight;
        if (strongContentHits < 1 || contentRecall < 0.45) continue;
      } else {
        if (m < 2 || matchedCount < m) continue;
      }

      var totalWindowWeight = 0.0;
      for (var oi = i; oi <= j; oi++) {
        totalWindowWeight += origTokens[oi].weight;
      }
      if (totalWindowWeight <= 0) continue;

      final recall = matchedBackWeight / totalBackWeight;
      final precision = matchedOrigWeight / totalWindowWeight;
      final f1 = (recall + precision) > 0
          ? (2.0 * precision * recall) / (precision + recall)
          : 0.0;
      if (f1 < 0.46) continue;

      final spanStart = origTokens[i].start;
      final spanEnd = origTokens[j].end;
      final enCenterRatio =
          ((spanStart + spanEnd) / 2.0) / math.max(1, origSentence.length);
      final posBonus =
          1.0 - 0.12 * (enCenterRatio - zhCenterRatio.clamp(0.0, 1.0)).abs();
      final spanSub = origSentence.substring(spanStart, spanEnd);
      final clauseBonus =
          (isSingleClauseZh && !RegExp(r'[,;()]').hasMatch(spanSub))
              ? 1.05
              : 1.0;

      final score = f1 * posBonus * clauseBonus;
      if (score > bestScore + 1e-6) {
        bestScore = score;
        bestStart = spanStart;
        bestEnd = spanEnd;
        bestConfidence = f1.clamp(0.0, 1.0);
      }
    }
  }

  if (bestStart == null || bestEnd == null || bestStart >= bestEnd) {
    return null;
  }

  final matchedNonWs = origSentence
      .substring(bestStart, bestEnd)
      .replaceAll(RegExp(r'\s+'), '')
      .length;
  if (matchedNonWs / origNonWsLen >= 0.92) {
    return (start: 0, end: origSentence.length, confidence: bestConfidence);
  }

  return (start: bestStart, end: bestEnd, confidence: bestConfidence);
}

/// 异步短语级对齐主流程（先跑 0ms 确定性规则，再按需借用端侧模型做回译定位与滑窗校验，失败安全回退整句）。
Future<PhraseAlignmentResult?> alignChineseAnnotationToOriginal({
  required ReadingAnnotation annotation,
  required List<SentenceAlignmentPair> sentences,
  required BackTranslatePhraseFn backTranslatePhrase,
  TranslationTargetLanguage? sourceLanguageOverride,
}) async {
  final valid =
      sentences
          .where((s) => s.origText.trim().isNotEmpty && s.transText.trim().isNotEmpty)
          .toList()
        ..sort((a, b) => a.origStartChar.compareTo(b.origStartChar));
  if (valid.isEmpty) return null;
  if (_isLegacyAutoOriginalAnnotation(annotation, valid)) return null;

  final instant = tryInstantPhraseAlign(
    annotation: annotation,
    sentences: valid,
  );
  if (instant != null) return instant;

  final targetLang =
      sourceLanguageOverride ??
      detectLikelySourceLanguage(valid.map((s) => s.origText).join(' '));

  Future<({int start, int end, double confidence, bool usedModel})?> alignSlice({
    required SentenceAlignmentPair sent,
    required int selStart,
    required int selEnd,
  }) async {
    final det = _tryDeterministicSubSentence(sent, selStart, selEnd);
    if (det != null) {
      return (
        start: det.alignedOrigStart,
        end: det.alignedOrigEnd,
        confidence: det.confidence,
        usedModel: false,
      );
    }

    final fullTrans = sent.transText.trim();
    final zhSlice = fullTrans.substring(selStart, selEnd).trim();
    if (zhSlice.isEmpty) {
      return (
        start: sent.origStartChar,
        end: sent.origEndChar,
        confidence: 1.0,
        usedModel: false,
      );
    }

    final back = await backTranslatePhrase(zhSlice, targetLang);
    if (back == null || back.trim().isEmpty) {
      return null;
    }

    final zhCenterRatio =
        ((selStart + selEnd) / 2.0) / math.max(1, fullTrans.length);
    final hit = alignEnglishSpanFromBackTranslation(
      origSentence: sent.origText,
      backTranslation: back,
      zhCenterRatio: zhCenterRatio,
      isSingleClauseZh: !_kClauseSepRegex.hasMatch(zhSlice),
    );
    if (hit == null) {
      return (
        start: sent.origStartChar,
        end: sent.origEndChar,
        confidence: 0.0,
        usedModel: true,
      );
    }
    return (
      start: (sent.origStartChar + hit.start).clamp(
        sent.origStartChar,
        sent.origEndChar,
      ),
      end: (sent.origStartChar + hit.end).clamp(
        sent.origStartChar,
        sent.origEndChar,
      ),
      confidence: hit.confidence,
      usedModel: true,
    );
  }

  if (valid.length == 1) {
    final sent = valid.single;
    final sel = _resolveSingleSentenceSelection(sent, annotation);
    if (sel == null) {
      return PhraseAlignmentResult(
        alignedOrigStart: sent.origStartChar,
        alignedOrigEnd: sent.origEndChar,
        isSubSentenceMatch: false,
        usedModel: false,
        confidence: 1.0,
      );
    }
    final res = await alignSlice(
      sent: sent,
      selStart: sel.start,
      selEnd: sel.end,
    );
    if (res == null) return null;
    return PhraseAlignmentResult(
      alignedOrigStart: res.start,
      alignedOrigEnd: res.end,
      isSubSentenceMatch:
          res.start > sent.origStartChar || res.end < sent.origEndChar,
      usedModel: res.usedModel,
      confidence: res.confidence,
    );
  }

  // 多句情况：仅对跳过 > 12% 的首句/尾句端做局部回译裁剪
  final first = valid.first;
  final last = valid.last;
  final firstFull = first.transText.trim();
  final lastFull = last.transText.trim();

  var needHeadAlign = false;
  var headStart = 0;
  if (annotation.target == ReadingAnnotationTarget.translation &&
      annotation.transStartInFirst != null) {
    headStart = annotation.transStartInFirst!.clamp(0, firstFull.length);
    final skippedHead = _stripPunctAndWs(firstFull.substring(0, headStart)).length;
    final cleanFirst = _stripPunctAndWs(firstFull).length;
    if (cleanFirst > 0 && skippedHead / cleanFirst > 0.12) {
      needHeadAlign = true;
    }
  }

  var needTailAlign = false;
  var tailEnd = lastFull.length;
  if (annotation.target == ReadingAnnotationTarget.translation &&
      annotation.transEndInLast != null) {
    tailEnd = annotation.transEndInLast!.clamp(0, lastFull.length);
    final skippedTail = _stripPunctAndWs(lastFull.substring(tailEnd)).length;
    final cleanLast = _stripPunctAndWs(lastFull).length;
    if (cleanLast > 0 && skippedTail / cleanLast > 0.12) {
      needTailAlign = true;
    }
  }

  var alignedStart = first.origStartChar;
  var alignedEnd = last.origEndChar;
  var usedModel = false;
  var minConfidence = 1.0;

  if (needHeadAlign) {
    final headRes = await alignSlice(
      sent: first,
      selStart: headStart,
      selEnd: firstFull.length,
    );
    if (headRes == null) return null;
    alignedStart = headRes.start;
    usedModel = usedModel || headRes.usedModel;
    minConfidence = math.min(minConfidence, headRes.confidence);
  }

  if (needTailAlign) {
    final tailRes = await alignSlice(
      sent: last,
      selStart: 0,
      selEnd: tailEnd,
    );
    if (tailRes == null) return null;
    alignedEnd = tailRes.end;
    usedModel = usedModel || tailRes.usedModel;
    minConfidence = math.min(minConfidence, tailRes.confidence);
  }

  if (alignedStart >= alignedEnd) {
    return PhraseAlignmentResult(
      alignedOrigStart: first.origStartChar,
      alignedOrigEnd: last.origEndChar,
      isSubSentenceMatch: false,
      usedModel: usedModel,
      confidence: 0.0,
    );
  }

  return PhraseAlignmentResult(
    alignedOrigStart: alignedStart,
    alignedOrigEnd: alignedEnd,
    isSubSentenceMatch:
        alignedStart > first.origStartChar || alignedEnd < last.origEndChar,
    usedModel: usedModel,
    confidence: minConfidence,
  );
}
