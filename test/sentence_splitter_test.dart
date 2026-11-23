import 'package:echo/core/tts/sentence_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SentenceSplitter', () {
    const splitter = SentenceSplitter(minChars: 8, maxChars: 60);

    test('splits Chinese sentences and keeps closing quotes attached', () {
      const text = '他说：“今天天气真好，我们去公园散步吧！”说完便笑了。\n\n天空湛蓝如洗，微风拂面而来。';
      final sentences = splitter.split(text);

      expect(sentences, hasLength(2));
      expect(sentences[0].text, '他说：“今天天气真好，我们去公园散步吧！”说完便笑了。');
      expect(sentences[1].text, '天空湛蓝如洗，微风拂面而来。');
      for (final s in sentences) {
        expect(text.substring(s.startOffset, s.endOffset).trim(), s.text);
      }
    });

    test('preserves decimal numbers in English text', () {
      const text =
          'The value of pi is approximately 3.14159 in math. Next sentence starts here.';
      final sentences = splitter.split(text);

      expect(sentences, hasLength(2));
      expect(sentences[0].text, contains('3.14159'));
      expect(sentences[1].text, 'Next sentence starts here.');
    });

    test('splits overly long unpunctuated sentences by soft breaks or maxChars', () {
      final longSentence =
          '第一段很长很长的话语描述着风景，第二段继续延伸没有句号，第三段依然在绵延不断，第四段终于快到长度上限了，第五段继续补充更多细节。';
      final sentences = splitter.split(longSentence);

      expect(sentences.length, greaterThanOrEqualTo(2));
      for (final s in sentences) {
        expect(s.text.length, lessThanOrEqualTo(60));
      }
    });

    test('skips pure punctuation or blank lines', () {
      const text = '\n\n   。。。  \n---\n真正需要朗读的完整中文句子在这里。';
      final sentences = splitter.split(text);
      expect(sentences, hasLength(1));
      expect(sentences.first.text, '真正需要朗读的完整中文句子在这里。');
    });
  });
}
