import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/reader/reader_page.dart';

import 'tokens_fixtures.dart';

class _ReaderStubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    Map<String, dynamic> body;
    switch (options.uri.path) {
      case '/api/library/42/chapters':
        body = <String, dynamic>{
          'chapters': <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 0,
              'title': '第一章 科学边界',
              'chars': 1200,
              'preview': '红岸工程……',
              'text': '叶文洁抬头望着雷达峰的方向，红岸的天线在夜色里缓缓转动。',
            },
            <String, dynamic>{
              'index': 1,
              'title': '第二章 台球',
              'chars': 980,
              'preview': '两个物理学家……',
              'text': '台球在绿色呢面上滚动，白雾般的景象逐渐清晰起来。',
            },
          ],
        };
      case '/api/audiobooks':
        body = <String, dynamic>{'audiobooks': <dynamic>[]};
      case '/api/library':
        body = <String, dynamic>{'books': <dynamic>[]};
      default:
        body = <String, dynamic>{};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);
  const book = LibraryBook(id: 42, title: '三体 · 地球往事', format: 'epub');

  Future<EchoApi> buildApi() async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_reader_test');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _ReaderStubAdapter();
    return EchoApi(dio: dio, tokenStore: tokenStore);
  }

  testWidgets('阅读器：载入正文、衬线排版、翻章与字号调节',
      (WidgetTester tester) async {
    final api = await buildApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[echoApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const ReaderPage(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 首章标题与正文渲染。
    expect(find.byKey(const Key('reader_page')), findsOneWidget);
    expect(find.byKey(const Key('reader_book_title')), findsOneWidget);
    expect(find.text('第一章 科学边界'), findsWidgets);
    expect(find.textContaining('红岸的天线在夜色里'), findsOneWidget);

    // 正文字号 = 17 * 1.0，衬线字体，暖纸底色。
    final textWidget =
        tester.widget<Text>(find.byKey(const Key('reader_chapter_text')));
    expect(textWidget.style?.fontFamily, 'serif');
    expect(textWidget.style?.fontSize, 17.0);
    expect(
      tester
          .widget<Scaffold>(find.byKey(const Key('reader_page')))
          .backgroundColor,
      darkTokens.paperWarm,
      reason: '阅读器背景应取阅读专用 Token paper.warm',
    );

    // 翻章：下一章内容出现。
    await tester.tap(find.byKey(const Key('reader_next_chapter')));
    await tester.pumpAndSettle();
    expect(find.textContaining('台球在绿色呢面上'), findsOneWidget);
    expect(find.byKey(const Key('reader_prev_chapter')), findsOneWidget);

    // 翻回上一章。
    await tester.tap(find.byKey(const Key('reader_prev_chapter')));
    await tester.pumpAndSettle();
    expect(find.textContaining('红岸的天线在夜色里'), findsOneWidget);

    // 字号循环：1.0 → 1.15。
    await tester.tap(find.byKey(const Key('reader_font_button')));
    await tester.pumpAndSettle();
    final scaled =
        tester.widget<Text>(find.byKey(const Key('reader_chapter_text')));
    expect(scaled.style?.fontSize, 17.0 * 1.15);
  });
}
