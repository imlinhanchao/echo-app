import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/main.dart';

import 'tokens_fixtures.dart';

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);

  test('深色 Token 主题装配（dark-first 基准态）', () {
    final theme = buildEchoTheme(Brightness.dark, darkTokens);
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, darkTokens.surfaceBase);
    expect(theme.extension<EchoTokens>(), same(darkTokens));
    expect(theme.colorScheme.primary, darkTokens.primary);
    expect(theme.colorScheme.onSurface, darkTokens.textPrimary);
    expect(theme.colorScheme.error, darkTokens.error);
  });

  test('亮色对偶模式由同一构建函数产出', () {
    final lightTokens = EchoTokens.fromColors(lightColors, Brightness.light);
    final theme = buildEchoTheme(Brightness.light, lightTokens);
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, lightTokens.surfaceBase);
    expect(theme.extension<EchoTokens>(), same(lightTokens));
  });

  testWidgets('EchoApp 注入首页基础渲染', (WidgetTester tester) async {
    await tester.pumpWidget(
      EchoApp(
        theme: buildEchoTheme(Brightness.dark, darkTokens),
        home: const Scaffold(
          key: Key('echo_home'),
          body: Center(child: Text('Echo', key: Key('echo_title'))),
        ),
      ),
    );
    expect(find.byKey(const Key('echo_title')), findsOneWidget);
    expect(find.byKey(const Key('echo_home')), findsOneWidget);
  });
}
