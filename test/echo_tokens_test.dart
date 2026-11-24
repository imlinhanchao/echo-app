import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/design/echo_tokens.dart';

import 'tokens_fixtures.dart';

void main() {
  group('EchoTokens 解析', () {
    test('dark：解析 #RRGGBB 与 rgba()', () {
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);
      expect(tokens.primary, const Color(0xFFD4AE74));
      expect(tokens.primaryHover, const Color(0xFFE2C28F));
      expect(tokens.surfaceBase, const Color(0xFF0D0E10));
      expect(tokens.surfaceElevated, const Color(0xFF16171B));
      expect(tokens.textOnPrimary, const Color(0xFF14120F));
      expect(
        tokens.readingHighlight,
        const Color.fromRGBO(212, 174, 116, 0.20),
      );
      expect(tokens.paperWarm, const Color(0xFF12110F));
      expect(tokens.paperText, const Color(0xFFEAE4D8));
    });

    test('light：无 reading 节时降级为合理默认值', () {
      final tokens = EchoTokens.fromColors(lightColors, Brightness.light);
      expect(tokens.primary, const Color(0xFF8F6836));
      expect(tokens.surfaceBase, const Color(0xFFF8F5F0));
      expect(
        tokens.readingHighlight,
        tokens.primary.withValues(alpha: 0.24),
        reason: '阅读高亮降级为 primary 24% 透明度',
      );
      expect(tokens.paperWarm, tokens.surfaceBase);
      expect(tokens.paperText, tokens.textPrimary);
    });

    testWidgets('资产载入：assets/design-tokens.json 与解析器闭环', (
      WidgetTester tester,
    ) async {
      final tokens = await EchoTokens.load(Brightness.dark);
      expect(tokens.surfaceBase, const Color(0xFF0D0E10));
      expect(tokens.primary, const Color(0xFFD4AE74));
    });
  });
}
