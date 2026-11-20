import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/reader/reading_store.dart';
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
            for (var i = 0; i < 3; i++)
              <String, dynamic>{
                'index': i,
                'title': '第 ${i + 1} 章',
                'chars': 300,
                'preview': '预览$i',
                'text': List<String>.generate(
                  6,
                  (p) => '第${i + 1}章第${p + 1}段：${'内容' * 40}',
                ).join('\n\n'),
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

  group('阅读器分页', () {
    test('按段落分页：长文本被切成多页且保留全部内容', () {
      final pages = paginateChapter(
        List<String>.generate(20, (i) => '第$i段内容' * 30).join('\n\n'),
        500,
      );
      expect(pages.length, greaterThan(1));
      final joined = pages.join();
      expect(joined.contains('第0段内容'), isTrue);
      expect(joined.contains('第19段内容'), isTrue);
    });

    test('超长单段硬切，不丢字', () {
      final long = 'x' * 1200;
      final pages = paginateChapter(long, 500);
      expect(pages.length, 3);
      expect(pages.join().length, 1200);
    });
  });

  testWidgets('阅读器：左右滑翻页 + 记住位置 + 从当前位置听书入口',
      (WidgetTester tester) async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_reader');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _ReaderStubAdapter();
    final api = EchoApi(dio: dio, tokenStore: tokenStore);
    final readingStore = MemoryReadingStore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          echoApiProvider.overrideWithValue(api),
          readingStoreProvider.overrideWithValue(readingStore),
        ],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const ReaderPageView(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reader_page')), findsOneWidget);
    expect(find.byKey(const Key('reader_pageview')), findsOneWidget);
    expect(find.byKey(const Key('reader_page_text_0')), findsOneWidget);

    // 衬线正文
    final text = tester.widget<Text>(find.byKey(const Key('reader_page_text_0')));
    expect(text.style?.fontFamily, 'serif');
    expect(
      tester.widget<Scaffold>(find.byKey(const Key('reader_page'))).backgroundColor,
      darkTokens.paperWarm,
    );

    // 左右滑动翻页（PageView 手势）
    await tester.drag(find.byKey(const Key('reader_pageview')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader_page_text_1')), findsOneWidget);

    // 阅读位置已持久化
    final saved = await readingStore.read(42);
    expect(saved, isNotNull);
    expect(saved!.globalPage, 1);
  });

  testWidgets('恢复上次阅读位置：打开即回到上次页', (WidgetTester tester) async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_reader');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _ReaderStubAdapter();
    final api = EchoApi(dio: dio, tokenStore: tokenStore);
    final readingStore = MemoryReadingStore();
    await readingStore.write(const ReadingPosition(bookId: 42, globalPage: 2));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          echoApiProvider.overrideWithValue(api),
          readingStoreProvider.overrideWithValue(readingStore),
        ],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const ReaderPageView(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reader_page_text_2')), findsOneWidget);
    expect(find.byKey(const Key('reader_page_text_0')), findsNothing);
  });
}
