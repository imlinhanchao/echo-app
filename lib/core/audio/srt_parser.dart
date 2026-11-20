import 'package:flutter/foundation.dart';

/// 单条 SRT 句级字幕（时间轴已按当前分块 rebase 为块内毫秒偏移）。
@immutable
class SrtCue {
  const SrtCue({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int index;
  final int startMs;
  final int endMs;
  final String text;
}

/// SRT 字幕解析与当前朗读句定位器。
///
/// 对应 echo-service `internal/audiobook/split.go` 生成的分块字幕
/// （`variant=chapter_srt&n=N`）。
abstract final class SrtParser {
  static final RegExp _timingLine = RegExp(
    r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
  );

  /// 解析 SRT 文本为按起始时间升序排列的 [SrtCue] 列表。
  static List<SrtCue> parse(String raw) {
    if (raw.trim().isEmpty) return const <SrtCue>[];
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n\s*\n'));
    final cues = <SrtCue>[];

    for (final block in blocks) {
      final lines = block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;

      int timingIdx = -1;
      RegExpMatch? match;
      for (var i = 0; i < lines.length; i++) {
        final m = _timingLine.firstMatch(lines[i]);
        if (m != null) {
          timingIdx = i;
          match = m;
          break;
        }
      }
      if (timingIdx == -1 || match == null) continue;

      final cueIndex = timingIdx > 0
          ? (int.tryParse(lines[0]) ?? (cues.length + 1))
          : (cues.length + 1);
      final startMs = _toMs(
        match.group(1)!,
        match.group(2)!,
        match.group(3)!,
        match.group(4)!,
      );
      final endMs = _toMs(
        match.group(5)!,
        match.group(6)!,
        match.group(7)!,
        match.group(8)!,
      );
      final text = lines.sublist(timingIdx + 1).join('\n').trim();
      if (text.isEmpty) continue;

      cues.add(
        SrtCue(
          index: cueIndex,
          startMs: startMs,
          endMs: endMs >= startMs ? endMs : startMs,
          text: text,
        ),
      );
    }
    return cues;
  }

  /// 根据块内播放位置 [positionMs] 定位当前高亮句下标（无匹配返回 -1）。
  ///
  /// 句间留白（≤1500ms）内保持上一句高亮，避免朗读停顿时高亮闪烁。
  static int activeCueIndex(List<SrtCue> cues, int positionMs) {
    if (cues.isEmpty || positionMs < 0) return -1;
    int lastStarted = -1;
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (positionMs >= cue.startMs && positionMs <= cue.endMs) {
        return i;
      }
      if (positionMs >= cue.startMs) {
        lastStarted = i;
      } else {
        break;
      }
    }
    if (lastStarted != -1 && positionMs - cues[lastStarted].endMs <= 1500) {
      return lastStarted;
    }
    return -1;
  }

  static int _toMs(String h, String m, String s, String ms) {
    final hours = int.parse(h);
    final minutes = int.parse(m);
    final seconds = int.parse(s);
    final millis = int.parse(ms.padRight(3, '0').substring(0, 3));
    return (((hours * 60 + minutes) * 60) + seconds) * 1000 + millis;
  }
}
