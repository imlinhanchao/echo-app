import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/design/echo_tokens.dart';

import 'tokens_fixtures.dart';

void main() {
  group('EchoTokens 解析', () {
    test('dark：解析 #RRGGBB 与 rgba()', () {
      final tokens =
          EchoTokens.fromColors(darkColors, Brightness.dark);
      expect(tokens.primary, const Color(0xFF6366F1));
      expect(tokens.primaryHover, const Color(0xFF818CF8));
      expect(tokens.surfaceBase, const Color(0xFF020617));
      expect(tokens.surfaceElevated, const Color(0xFF0F172A));
      expect(tokens.textOnPrimary, const Color(0xFFFFFFFF));
      expect(tokens.readingHighlight, const Color.fromRGBO(99, 102, 241, 0.24));
      expect(tokens.paperWarm, const Color(0xFF0B1220));
      expect(tokens.paperText, const Color(0xFFE8E3D8));
    });

    test('light：无 reading 节时降级为合理默认值', () {
      final tokens = EchoTokens.fromColors(lightColors, Brightness.light);
      expect(tokens.primary, const Color(0xFF4F46E5));
      expect(tokens.surfaceBase, const Color(0xFFF8FAFC));
      expect(
        tokens.readingHighlight,
        tokens.primary.withValues(alpha: 0.24),
        reason: '阅读高亮降级为 primary 24% 透明度',
      );
      expect(tokens.paperWarm, tokens.surfaceBase);
      expect(tokens.paperText, tokens.textPrimary);
    });

    testWidgets('资产载入：assets/design-tokens.json 与解析器闭环',
        (WidgetTester tester) async {
      final tokens = await EchoTokens.load(Brightness.dark);
      expect(tokens.surfaceBase, const Color(0xFF020617));
      expect(tokens.primary, const Color(0xFF6366F1));
    });
  });
}
