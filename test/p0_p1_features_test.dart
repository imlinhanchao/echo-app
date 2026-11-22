import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/library/book_detail_page.dart';
import 'package:echo/features/notes/desktop_notes_focus_page.dart';
import 'package:echo/features/player/player_sheet.dart';
import 'package:echo/features/reader/reader_page.dart';
import 'package:echo/features/search/search_page.dart';
import 'package:echo/features/shell/echo_shell.dart';
import 'package:echo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stub_adapter.dart';
import 'tokens_fixtures.dart';

class _RichStubAdapter implements HttpClientAdapter {
  static const String _srt0 = '''
1
00:00:00,000 --> 00:00:10,000
红岸基地第一句测试字幕。
''';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    final uri = options.uri;
    if (uri.path == '/api/files/audiobooks/101' &&
        uri.queryParameters['variant'] == 'chapter_srt') {
      return ResponseBody.fromString(
        _srt0,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/plain; charset=utf-8'],
        },
      );
    }

    Map<String, dynamic> body;
    switch (uri.path) {
      case '/api/audiobooks':
        body = <String, dynamic>{
          'audiobooks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 101,
              'book_id': 42,
              'book_title': '三体',
              'model': 'qwen3-tts',
              'voice': 'zh_female',
              'status': 'done',
              'progress': 100,
              'duration_s': 120.0,
            },
          ],
        };
      case '/api/library':
        body = <String, dynamic>{
          'books': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 42,
              'title': '三体',
              'authors': <String>['刘慈欣'],
              'format': 'epub',
            },
          ],
        };
      case '/api/audiobooks/101/chapters':
        body = <String, dynamic>{
          'audiobook_id': 101,
          'format': 'mp3',
          'duration_s': 120.0,
          'chunk_seconds': 60,
          'chunks': <Map<String, dynamic>>[
            <String, dynamic>{
              'n': 0,
              'chapter_index': 0,
              'title': '第一章 科学边界',
              'start_s': 0.0,
              'end_s': 60.0,
              'duration_s': 60.0,
              'audio_url': '/api/files/audiobooks/101?variant=chapter&n=0',
              'srt_url': '/api/files/audiobooks/101?variant=chapter_srt&n=0',
            },
            <String, dynamic>{
              'n': 1,
              'chapter_index': 1,
              'title': '第二章 台球',
              'start_s': 60.0,
              'end_s': 120.0,
              'duration_s': 60.0,
              'audio_url': '/api/files/audiobooks/101?variant=chapter&n=1',
              'srt_url': '/api/files/audiobooks/101?variant=chapter_srt&n=1',
            },
          ],
        };
      case '/api/library/42/chapters':
        body = <String, dynamic>{
          'chapters': <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 0,
              'title': '第一章 科学边界',
              'chars': 200,
              'text': '第一章正文内容。' * 20,
            },
            <String, dynamic>{
              'index': 1,
              'title': '第二章 台球',
              'chars': 200,
              'text': '第二章正文内容。' * 20,
            },
          ],
        };
      case '/api/jobs':
        body = <String, dynamic>{'total': 0, 'jobs': <dynamic>[]};
      case '/api/sync/progress':
        body = <String, dynamic>{'progresses': <dynamic>[]};
      case '/api/sync/notes':
        body = <String, dynamic>{'notes': <dynamic>[]};
      default:
        if (uri.path.contains('/search')) {
          body = <String, dynamic>{
            'provider': 'zlib',
            'page': 1,
            'total_pages': 1,
            'books': <Map<String, dynamic>>[
              <String, dynamic>{
                'provider': 'zlib',
                'ref': 'book-ref-1',
                'title': '三体全集',
                'authors': <String>['刘慈欣'],
                'year': '2010',
                'format': 'epub',
                'size': '2.3 MB',
                'description': '科幻经典。',
              },
            ],
          };
        } else if (uri.path.contains('/providers/') &&
            uri.path.contains('/book')) {
          body = <String, dynamic>{
            'book': <String, dynamic>{
              'provider': 'zlib',
              'ref': 'book-ref-1',
              'title': '三体全集',
              'authors': <String>['刘慈欣'],
              'year': '2010',
              'format': 'epub',
              'size': '2.3 MB',
              'description': '科幻经典完整简介。',
            },
          };
        } else if (uri.path.contains('/download')) {
          body = <String, dynamic>{
            'job': <String, dynamic>{
              'id': 9,
              'kind': 'download',
              'status': 'queued',
              'progress': 0,
            },
          };
        } else {
          body = <String, dynamic>{};
        }
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

  Future<
    ({
      EchoApi api,
      FakeAudioEngine engine,
      MemoryProgressStore progressStore,
      MemoryReadingStore readingStore,
      MemoryTokenStore tokenStore,
    })
  >
  createDeps() async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_p0p1');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _RichStubAdapter();
    return (
      api: EchoApi(dio: dio, tokenStore: tokenStore),
      engine: FakeAudioEngine(),
      progressStore: MemoryProgressStore(),
      readingStore: MemoryReadingStore(),
      tokenStore: tokenStore,
    );
  }

  testWidgets('P0.1 & P0.2: 章节抽屉搜索 + 长按跟读句打点笔记 + 跨章略读', (
    WidgetTester tester,
  ) async {
    final deps = await createDeps();
    final container = ProviderContainer(
      overrides: <Override>[
        tokenStoreProvider.overrideWithValue(deps.tokenStore),
        echoApiProvider.overrideWithValue(deps.api),
        audioEngineProvider.overrideWithValue(deps.engine),
        progressStoreProvider.overrideWithValue(deps.progressStore),
        readingStoreProvider.overrideWithValue(deps.readingStore),
      ],
    );
    addTearDown(container.dispose);

    const audio = AudiobookInfo(
      id: 101,
      bookId: 42,
      bookTitle: '三体',
      status: 'done',
      progress: 100,
      durationS: 120.0,
    );
    await tester.runAsync(
      () => container.read(chunkedPlayerProvider.notifier).loadAudiobook(audio),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const PlayerSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // P0.1 打开章节抽屉并搜索过滤
    await tester.tap(find.byKey(const Key('player_chapters_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chapters_drag_handle')), findsOneWidget);
    expect(find.byKey(const Key('chapters_search_field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('chapters_search_field')),
      '台球',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chapter_item_1')), findsOneWidget);
    expect(find.byKey(const Key('chapter_item_0')), findsNothing);

    // 关闭抽屉
    Navigator.of(tester.element(find.byKey(const Key('chapters_search_field'))))
        .pop();
    await tester.pumpAndSettle();

    // P0.2 长按跟读句弹出笔记弹层且预填该句文本
    await tester.longPress(find.text('红岸基地第一句测试字幕。'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notes_sheet_title')), findsOneWidget);
    final input = tester.widget<TextField>(find.byKey(const Key('note_input')));
    expect(input.controller?.text, '红岸基地第一句测试字幕。');

    // 跨章略读
    await tester.runAsync(
      () => container.read(chunkedPlayerProvider.notifier).skimChapter(1),
    );
    expect(container.read(chunkedPlayerProvider).isSkimming, isTrue);
    expect(container.read(chunkedPlayerProvider).currentChunkIndex, 1);
    container.read(chunkedPlayerProvider.notifier).cancelSkim();
    expect(container.read(chunkedPlayerProvider).isSkimming, isFalse);
  });

  testWidgets('P0.3: 搜索结果展示来源标签 + 详情弹层支持下载并转有声书', (
    WidgetTester tester,
  ) async {
    final deps = await createDeps();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          tokenStoreProvider.overrideWithValue(deps.tokenStore),
          echoApiProvider.overrideWithValue(deps.api),
          audioEngineProvider.overrideWithValue(deps.engine),
          progressStoreProvider.overrideWithValue(deps.progressStore),
        ],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const Scaffold(body: SearchPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('search_field')), '三体');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // 来源标签胶囊
    expect(
      find.byKey(const Key('search_pill_provider_book-ref-1')),
      findsOneWidget,
    );

    // 点击进入详情弹层并验证「下载并转有声书」与「直接下载」双按钮
    await tester.tap(find.byKey(const Key('search_result_book-ref-1')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('search_detail_sheet')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('search_detail_download_convert')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('search_detail_download')), findsOneWidget);
  });

  testWidgets('P1.1: 阅读器排版设置面板 + 宽屏 680dp 版心约束', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final deps = await createDeps();
    const book = LibraryBook(id: 42, title: '三体', format: 'epub');
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          echoApiProvider.overrideWithValue(deps.api),
          readingStoreProvider.overrideWithValue(deps.readingStore),
        ],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const ReaderPageView(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 宽屏版心约束 <= 680dp
    final colWidth = tester
        .getSize(find.byKey(const Key('reader_column_constraint')))
        .width;
    expect(colWidth, lessThanOrEqualTo(680.0));

    // 点 Aa 打开排版面板
    await tester.tap(find.byKey(const Key('reader_font_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader_typography_sheet')), findsOneWidget);
    expect(find.byKey(const Key('reader_font_size_slider')), findsOneWidget);
    expect(find.byKey(const Key('reader_line_height_slider')), findsOneWidget);
    expect(find.byKey(const Key('reader_theme_pureBlack')), findsOneWidget);
  });

  testWidgets('P1.2: 书籍详情页底部固定操作栏 + 点击章节直达对应章节', (
    WidgetTester tester,
  ) async {
    final deps = await createDeps();
    const book = LibraryBook(id: 42, title: '三体', format: 'epub');
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          echoApiProvider.overrideWithValue(deps.api),
          progressStoreProvider.overrideWithValue(deps.progressStore),
          readingStoreProvider.overrideWithValue(deps.readingStore),
        ],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const BookDetailPage(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail_bottom_bar')), findsOneWidget);
    final chapterFinder = find.byKey(const Key('detail_chapter_1'));
    await tester.ensureVisible(chapterFinder);
    await tester.pumpAndSettle();

    await tester.tap(chapterFinder);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader_page')), findsOneWidget);
    expect(find.text('第二章 台球'), findsWidgets);
  });

  testWidgets('P1.3: 平板 Medium 渲染胶囊播放条 & 桌面双栏笔记专注模式', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final deps = await createDeps();
    final container = ProviderContainer(
      overrides: <Override>[
        tokenStoreProvider.overrideWithValue(deps.tokenStore),
        echoApiProvider.overrideWithValue(deps.api),
        audioEngineProvider.overrideWithValue(deps.engine),
        progressStoreProvider.overrideWithValue(deps.progressStore),
        readingStoreProvider.overrideWithValue(deps.readingStore),
      ],
    );
    addTearDown(container.dispose);

    const audio = AudiobookInfo(
      id: 101,
      bookId: 42,
      bookTitle: '三体',
      status: 'done',
      progress: 100,
      durationS: 120.0,
    );
    await tester.runAsync(
      () => container.read(chunkedPlayerProvider.notifier).loadAudiobook(audio),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: EchoApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const EchoHome(user: EchoUser(id: 7, email: 'a@b.com')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tablet_capsule_player_bar')), findsOneWidget);
    expect(find.byKey(const Key('tablet_quick_note')), findsOneWidget);

    // 桌面双栏笔记专注模式独立渲染验证
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const DesktopNotesFocusPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop_notes_focus_page')), findsOneWidget);
    expect(find.byKey(const Key('focus_note_input')), findsOneWidget);
  });
}
