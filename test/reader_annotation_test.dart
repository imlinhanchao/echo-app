import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/notes/reading_annotation_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/design/echo_metrics.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/reader/reader_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tokens_fixtures.dart';

class _AnnotationReaderStubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    Map<String, dynamic> body;
    switch (options.uri.path) {
      case '/api/library/77/chapters':
        body = <String, dynamic>{
          'chapters': <Map<String, dynamic>>[
            for (var i = 0; i < 3; i++)
              <String, dynamic>{
                'index': i,
                'title': '第 ${i + 1} 章',
                'chars': 300,
                'preview': '第${i + 1}章预览',
                'text': List<String>.generate(
                  6,
                  (p) => '第${i + 1}章第${p + 1}段：乱哄哄的教室里惟有一个认真诵读课文的女生，故事由此展开。',
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

bool _containsUnderlineSpan(InlineSpan span) {
  if (span is TextSpan) {
    if (span.style?.decoration == TextDecoration.underline) {
      return true;
    }
    final children = span.children;
    if (children != null) {
      for (final child in children) {
        if (_containsUnderlineSpan(child)) return true;
      }
    }
  }
  return false;
}

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);
  const book = LibraryBook(id: 77, title: '一地鸡毛', format: 'epub');

  Future<EchoApi> makeApi() async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_annotation_test');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _AnnotationReaderStubAdapter();
    return EchoApi(dio: dio, tokenStore: tokenStore);
  }

  Widget buildReaderApp({
    required EchoApi api,
    required MemoryReadingStore readingStore,
    required MemoryReadingAnnotationStore annotationStore,
  }) {
    return ProviderScope(
      overrides: <Override>[
        echoApiProvider.overrideWithValue(api),
        readingStoreProvider.overrideWithValue(readingStore),
        readingAnnotationStoreProvider.overrideWithValue(annotationStore),
      ],
      child: MaterialApp(
        theme: buildEchoTheme(Brightness.dark, darkTokens),
        home: const ReaderPageView(book: book),
      ),
    );
  }

  group('Reader text selection, highlighting, and notes', () {
    testWidgets('long press opens selection toolbar and quick underline persists', (
      WidgetTester tester,
    ) async {
      ChapterPaginationCache.instance.clear();
      final api = await makeApi();
      final readingStore = MemoryReadingStore();
      final annotationStore = MemoryReadingAnnotationStore();

      await tester.pumpWidget(
        buildReaderApp(
          api: api,
          readingStore: readingStore,
          annotationStore: annotationStore,
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.byKey(const Key('reader_page_text_0'));
      expect(textFinder, findsOneWidget);
      final textRect = tester.getRect(textFinder);

      await tester.longPressAt(Offset(textRect.left + 48, textRect.top + 18));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reader_selection_toolbar')), findsOneWidget);
      expect(
        find.byKey(const Key('selection_action_highlight')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('selection_action_note')), findsOneWidget);
      expect(find.byKey(const Key('selection_action_copy')), findsOneWidget);

      await tester.tap(find.byKey(const Key('selection_action_highlight')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reader_selection_toolbar')), findsNothing);
      final saved = await annotationStore.listForBook(book.id);
      expect(saved.length, 1);
      expect(saved.first.chapterIndex, 0);
      expect(saved.first.quote, isNotEmpty);

      final richText = tester.widget<Text>(textFinder);
      expect(richText.textSpan, isNotNull);
      expect(_containsUnderlineSpan(richText.textSpan!), isTrue);
    });

    testWidgets('writing note, filtering notes sheet, and deleting annotation work cleanly', (
      WidgetTester tester,
    ) async {
      ChapterPaginationCache.instance.clear();
      final api = await makeApi();
      final readingStore = MemoryReadingStore();
      final annotationStore = MemoryReadingAnnotationStore();
      final now = DateTime.utc(2026, 11, 24, 12, 0);
      await annotationStore.upsert(
        ReadingAnnotation(
          id: 'pure_hl',
          bookId: book.id,
          chapterIndex: 0,
          startOffset: 0,
          endOffset: 7,
          quote: '第1章第1段',
          chapterTitle: '第 1 章',
          createdAt: now,
          updatedAt: now,
        ),
      );

      await tester.pumpWidget(
        buildReaderApp(
          api: api,
          readingStore: readingStore,
          annotationStore: annotationStore,
        ),
      );
      await tester.pumpAndSettle();

      final textRect = tester.getRect(
        find.byKey(const Key('reader_page_text_0')),
      );
      await tester.longPressAt(Offset(textRect.left + 90, textRect.top + 54));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reader_selection_toolbar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('selection_action_note')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('annotation_note_input')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('annotation_note_input')),
        '精彩细节',
      );
      await tester.tap(find.byKey(const Key('annotation_save_button')));
      await tester.pumpAndSettle();

      final afterSave = await annotationStore.listForBook(book.id);
      expect(afterSave.length, 2);
      final noteItem = afterSave.firstWhere((a) => a.hasNote);
      expect(noteItem.note, '精彩细节');

      await tester.tap(find.byKey(const Key('reader_notes_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader_notes_sheet')), findsOneWidget);
      expect(find.byKey(const Key('annotation_item_pure_hl')), findsOneWidget);
      expect(
        find.byKey(Key('annotation_item_${noteItem.id}')),
        findsOneWidget,
      );

      // Filter: notes only
      await tester.tap(find.byKey(const Key('notes_filter_notes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('annotation_item_pure_hl')), findsNothing);
      expect(
        find.byKey(Key('annotation_item_${noteItem.id}')),
        findsOneWidget,
      );

      // Filter: highlights only
      await tester.tap(find.byKey(const Key('notes_filter_highlights')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('annotation_item_pure_hl')), findsOneWidget);
      expect(find.byKey(Key('annotation_item_${noteItem.id}')), findsNothing);

      // Back to all & delete note
      await tester.tap(find.byKey(const Key('notes_filter_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('annotation_delete_${noteItem.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('annotation_item_${noteItem.id}')), findsNothing);
      expect((await annotationStore.listForBook(book.id)).length, 1);
    });

    testWidgets('jumping to chapter annotation and keeping TextPainter layout height bounds', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ChapterPaginationCache.instance.clear();

      final api = await makeApi();
      final readingStore = MemoryReadingStore();
      final annotationStore = MemoryReadingAnnotationStore();
      final now = DateTime.utc(2026, 11, 24, 12, 0);
      await annotationStore.upsert(
        ReadingAnnotation(
          id: 'ann_ch0',
          bookId: book.id,
          chapterIndex: 0,
          startOffset: 0,
          endOffset: 10,
          quote: '第1章第1段：乱哄',
          note: '开篇点题',
          color: ReadingHighlightColor.sage,
          chapterTitle: '第 1 章',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await annotationStore.upsert(
        ReadingAnnotation(
          id: 'ann_ch2',
          bookId: book.id,
          chapterIndex: 2,
          startOffset: 0,
          endOffset: 10,
          quote: '第3章第1段：乱哄',
          chapterTitle: '第 3 章',
          createdAt: now,
          updatedAt: now,
        ),
      );

      await tester.pumpWidget(
        buildReaderApp(
          api: api,
          readingStore: readingStore,
          annotationStore: annotationStore,
        ),
      );
      await tester.pumpAndSettle();

      // Verify annotated Text.rich keeps TextPainter height within available layout height
      final pageViewSize = tester.getSize(
        find.byKey(const Key('reader_pageview')),
      );
      final pageTextWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      expect(pageTextWidget.textSpan, isNotNull);
      final maxTextWidth = pageViewSize.width - EchoMetrics.space3 * 2;
      final maxTextHeight = pageViewSize.height - EchoMetrics.space2 * 2;
      final measured = TextPainter(
        text: pageTextWidget.textSpan!,
        textDirection: TextDirection.ltr,
        textHeightBehavior: pageTextWidget.textHeightBehavior,
      )..layout(maxWidth: maxTextWidth);
      expect(measured.height, lessThanOrEqualTo(maxTextHeight));

      // Open notes sheet and tap chapter 3 annotation to jump there
      await tester.tap(find.byKey(const Key('reader_notes_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('annotation_item_ann_ch2')), findsOneWidget);

      await tester.tap(find.byKey(const Key('annotation_item_ann_ch2')));
      await tester.pumpAndSettle();

      expect(find.textContaining('第3章第1段'), findsOneWidget);
    });
  });
}
