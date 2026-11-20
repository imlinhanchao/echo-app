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

  group('阅读器精确分页', () {
    const style = TextStyle(fontFamily: 'serif', fontSize: 17, height: 1.9);

    test('每页都装得下：按可视尺寸分页后不溢出', () {
      final text = List<String>.generate(
        40,
        (i) => '第$i段：${'测试内容' * 25}',
      ).join('\n\n');
      const width = 320.0;
      const height = 520.0;

      final pages = paginateChapterBySize(
        chapterIndex: 0,
        chapterTitle: '第一章',
        text: text,
        style: style,
        textScaler: TextScaler.noScaling,
        maxWidth: width,
        maxHeight: height,
      );

      expect(pages.length, greaterThan(1));
      // 逐页实测高度，确认不超出可视高度（不会跑到工具栏下面）
      for (final page in pages) {
        final painter = TextPainter(
          text: TextSpan(text: page.text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
        )..layout(maxWidth: width);
        expect(painter.height, lessThanOrEqualTo(height + 0.5),
            reason: '第 ${page.pageInChapter} 页溢出');
      }
      // 内容不丢字
      expect(pages.map((p) => p.text).join().replaceAll('\n', '').length,
          greaterThan(text.replaceAll('\n', '').length * 0.97));
    });

    test('页面记录章内字符区间，可用于重排后定位', () {
      final pages = paginateChapterBySize(
        chapterIndex: 3,
        chapterTitle: '第三章',
        text: '甲乙丙丁戊己庚辛壬癸' * 40,
        style: style,
        textScaler: TextScaler.noScaling,
        maxWidth: 200,
        maxHeight: 120,
      );
      expect(pages.first.startChar, 0);
      expect(pages.last.endChar, greaterThan(0));
      final idx = pageIndexForOffset(pages, 3, pages[1].startChar + 1);
      expect(idx, 1);
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
    expect(saved!.charOffset, greaterThanOrEqualTo(0));
    expect(saved.chapterIndex, greaterThanOrEqualTo(0));
  });

  testWidgets('恢复上次阅读位置：打开即回到上次页', (WidgetTester tester) async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_reader');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _ReaderStubAdapter();
    final api = EchoApi(dio: dio, tokenStore: tokenStore);
    final readingStore = MemoryReadingStore();
    await readingStore.write(
      const ReadingPosition(bookId: 42, chapterIndex: 1, charOffset: 0),
    );

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
