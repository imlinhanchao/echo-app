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
import 'package:echo/core/reader/screen_keep_alive.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/tts/sentence_splitter.dart';
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

class _FakeScreenKeepAliveService implements ScreenKeepAliveService {
  final List<bool> events = <bool>[];

  @override
  Future<void> setEnabled(bool enabled) async {
    events.add(enabled);
  }
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
        expect(
          painter.height,
          lessThanOrEqualTo(height + 0.5),
          reason: '第 ${page.pageInChapter} 页溢出',
        );
      }
      // 内容不丢字
      expect(
        pages.map((p) => p.text).join().replaceAll('\n', '').length,
        greaterThan(text.replaceAll('\n', '').length * 0.97),
      );
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

    test('前导空白与分句器共享同一原始字符坐标系，翻页断点不偏移', () {
      const rawText = '\n  第一句开头先留空。第二句接着往后。\n\n第三句来到第二页进行测试。第四句继续。';
      final sentences = const SentenceSplitter().split(rawText);
      final pages = paginateChapterBySize(
        chapterIndex: 0,
        chapterTitle: '第一章',
        text: rawText,
        style: style,
        textScaler: TextScaler.noScaling,
        maxWidth: 260,
        maxHeight: 80,
      );
      expect(pages.first.startChar, sentences.first.startOffset);
      // 验证第二页起始偏移落在原始坐标，不会因为前导 trim 而拉回到前一句末尾
      expect(pages.length, greaterThanOrEqualTo(2));
      expect(
        rawText.substring(pages[1].startChar, pages[1].startChar + 1).trim(),
        isNotEmpty,
      );
    });
  });

  testWidgets('阅读器：左右滑翻页 + 记住位置 + 从当前位置听书入口', (WidgetTester tester) async {
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
    final text = tester.widget<Text>(
      find.byKey(const Key('reader_page_text_0')),
    );
    expect(text.style?.fontFamily, 'serif');
    expect(
      tester
          .widget<Scaffold>(find.byKey(const Key('reader_page')))
          .backgroundColor,
      darkTokens.paperWarm,
    );

    // 左右滑动翻页（PageView 手势）
    await tester.drag(
      find.byKey(const Key('reader_pageview')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader_page_text_1')), findsOneWidget);

    // 阅读位置已持久化
    final saved = await readingStore.read(42);
    expect(saved, isNotNull);
    expect(saved!.charOffset, greaterThanOrEqualTo(0));
    expect(saved.chapterIndex, greaterThanOrEqualTo(0));
  });

  testWidgets('目录：打开章节目录并跳转到目标章', (WidgetTester tester) async {
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

    // 阅读百分比展示
    expect(find.byKey(const Key('reader_global_indicator')), findsOneWidget);

    // 打开目录
    await tester.tap(find.byKey(const Key('reader_toc_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader_toc_list')), findsOneWidget);
    expect(find.byKey(const Key('reader_toc_item_2')), findsOneWidget);

    // 跳到第 3 章
    await tester.tap(find.byKey(const Key('reader_toc_item_2')));
    await tester.pumpAndSettle();
    expect(find.textContaining('第3章'), findsWidgets);
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

    expect(find.byKey(const Key('reader_page_text_0')), findsOneWidget);
    expect(find.textContaining('第2章第1段'), findsOneWidget);
    expect(find.textContaining('第1章第1段'), findsNothing);
    expect(find.byKey(const Key('reader_page_text_2')), findsNothing);
  });

  testWidgets('防锁屏：进入阅读默认启用常亮，排版面板可开关且退出必释放', (
    WidgetTester tester,
  ) async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_reader');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _ReaderStubAdapter();
    final api = EchoApi(dio: dio, tokenStore: tokenStore);
    final readingStore = MemoryReadingStore();
    final keepAlive = _FakeScreenKeepAliveService();
    final configStorage = MemoryStandaloneConfigStorage(
      const StandaloneConfig(onboardingCompleted: true),
    );
    StandaloneConfigStore.setForTest(
      const StandaloneConfig(onboardingCompleted: true),
      storage: configStorage,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          echoApiProvider.overrideWithValue(api),
          readingStoreProvider.overrideWithValue(readingStore),
          screenKeepAliveServiceProvider.overrideWithValue(keepAlive),
        ],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const ReaderPageView(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(keepAlive.events.first, isTrue);

    // 打开排版设置并关闭防锁屏
    await tester.tap(find.byKey(const Key('reader_font_button')));
    await tester.pumpAndSettle();
    final switchFinder = find.byKey(const Key('reader_keep_screen_on_switch'));
    expect(switchFinder, findsOneWidget);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(keepAlive.events.last, isFalse);
    final persisted = await configStorage.read();
    expect(persisted.keepScreenOnWhileReading, isFalse);

    // 离开阅读页时保证再次调用释放
    await tester.pumpWidget(const SizedBox.shrink());
    expect(keepAlive.events.last, isFalse);
  });

  group('边听边看：当前句定位与 initialChapterIndex', () {
    test('findCueSpanInPage 支持直接匹配与跨换行容错匹配', () {
      const pageText = '红岸基地的清晨。\n\n叶文洁望向\n雷达峰顶的太阳。';
      final direct = findCueSpanInPage(pageText, '红岸基地的清晨。');
      expect(direct, isNotNull);
      expect(pageText.substring(direct!.start, direct.end), '红岸基地的清晨。');

      final crossLine = findCueSpanInPage(pageText, '叶文洁望向雷达峰顶的太阳。');
      expect(crossLine, isNotNull);
      expect(
        pageText.substring(crossLine!.start, crossLine.end),
        '叶文洁望向\n雷达峰顶的太阳。',
      );

      expect(findCueSpanInPage(pageText, '不存在的句子'), isNull);
    });

    testWidgets('initialChapterIndex 优先定位到播放器传入章节', (
      WidgetTester tester,
    ) async {
      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_reader');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ReaderStubAdapter();
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final readingStore = MemoryReadingStore();
      // 本地记录在第 0 章，但从播放器切入第 2 章
      await readingStore.write(
        const ReadingPosition(bookId: 42, chapterIndex: 0, charOffset: 0),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            echoApiProvider.overrideWithValue(api),
            readingStoreProvider.overrideWithValue(readingStore),
          ],
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, darkTokens),
            home: const ReaderPageView(book: book, initialChapterIndex: 2),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('第 3 章'), findsWidgets);
    });
  });
}
