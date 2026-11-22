import 'package:echo/design/echo_splash_screen.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tokens_fixtures.dart';

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);

  testWidgets('EchoSplashScreen 渲染品牌声波徽章、字标与状态提示，并支持减少动效模式', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const EchoSplashScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('echo_splash_screen')), findsOneWidget);
    expect(find.text('回 声'), findsOneWidget);
    expect(find.text('ECHO · 听看一体有声书'), findsOneWidget);
    expect(find.text('正在唤醒你的书架…'), findsOneWidget);
  });
}
