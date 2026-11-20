import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/audio/srt_parser.dart';

void main() {
  const sampleSrt = '''
1
00:00:00,000 --> 00:00:04,200
叶文洁打开了红岸基地的监听终端。

2
00:00:05,000 --> 00:00:09,500
宇宙的回声穿过漫长的光年，
在寂静的夜里悄然抵达。

3
00:00:12.000 --> 00:00:16.000
不要回答！不要回答！不要回答！
''';

  group('SrtParser 句级字幕解析与高亮定位', () {
    test('解析标准 SRT（兼容逗号与小数点毫秒及多行正文）', () {
      final cues = SrtParser.parse(sampleSrt);
      expect(cues.length, 3);
      expect(cues[0].index, 1);
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 4200);
      expect(cues[0].text, '叶文洁打开了红岸基地的监听终端。');

      expect(cues[1].startMs, 5000);
      expect(cues[1].endMs, 9500);
      expect(cues[1].text, contains('宇宙的回声穿过漫长的光年'));

      expect(cues[2].startMs, 12000);
      expect(cues[2].endMs, 16000);
    });

    test('activeCueIndex：句内命中、句间短暂停顿保持高亮、超出范围返回 -1', () {
      final cues = SrtParser.parse(sampleSrt);

      expect(SrtParser.activeCueIndex(cues, 2000), 0);
      // 4200ms ~ 5000ms 为句间 800ms 停顿（≤1500ms），保持第 0 句高亮不闪烁
      expect(SrtParser.activeCueIndex(cues, 4600), 0);
      expect(SrtParser.activeCueIndex(cues, 6000), 1);
      // 9500ms 之后超过 1500ms（如 11500ms），且第 2 句尚未开始 -> -1
      expect(SrtParser.activeCueIndex(cues, 11500), -1);
      expect(SrtParser.activeCueIndex(cues, 13000), 2);
    });
  });
}
