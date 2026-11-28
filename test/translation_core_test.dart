import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/audio/live_tts_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/notes/reading_annotation_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/translation/bilingual_phrase_aligner.dart';
import 'package:echo/core/translation/language_detector.dart';
import 'package:echo/core/translation/translation_cache_store.dart';
import 'package:echo/core/translation/translation_engine.dart';
import 'package:echo/core/translation/translation_model_manager.dart';
import 'package:echo/core/translation/translation_models.dart';
import 'package:echo/core/translation/translation_scheduler.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/tts/sherpa_tts_engine.dart';
import 'package:echo/core/tts/tts_model_catalog.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/reader/reader_page.dart';

import 'tokens_fixtures.dart';

class _FakeKeepAlive implements DownloadKeepAliveService {
  final List<String> logs = <String>[];

  @override
  Future<void> startOrUpdate({
    required String title,
    required String text,
    int progress = 0,
    int max = 100,
  }) async {
    logs.add('$title|$text|$progress/$max');
  }

  @override
  Future<void> stop() async {
    logs.add('stop');
  }
}

class _FakeTranslationEngine implements TranslationEngine {
  _FakeTranslationEngine({
    this.delay = Duration.zero,
    this.loadError,
    this.responder,
  });

  final Duration delay;
  Object? loadError;
  final String Function(String prompt)? responder;

  bool _loaded = false;
  String? _modelPath;
  bool _cancelFlag = false;
  final List<String> callPrompts = <String>[];

  @override
  bool get isLoaded => _loaded;

  @override
  String? get loadedModelPath => _modelPath;

  @override
  Future<void> ensureLoaded(
    String modelPath, {
    int nThreads = 4,
    int nCtx = 2048,
  }) async {
    if (loadError != null) {
      throw loadError!;
    }
    _loaded = true;
    _modelPath = modelPath;
  }

  @override
  Future<String> translate(String prompt, {int maxTokens = 512}) async {
    _cancelFlag = false;
    callPrompts.add(prompt);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (_cancelFlag) {
      throw const TranslationCancelledException();
    }
    if (responder != null) {
      return responder!(prompt);
    }
    final idx = prompt.indexOf('\n\n');
    final body = idx >= 0 ? prompt.substring(idx + 2).trim() : prompt;
    return '[译]$body';
  }

  @override
  void cancelCurrent() {
    _cancelFlag = true;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
    _modelPath = null;
  }

  @override
  Future<void> dispose() => unload();
}

class _StubTranslationModelManager extends TranslationModelManager {
  _StubTranslationModelManager(
    StandaloneConfigController cfg,
    String fakeModelPath,
  ) : super(configController: cfg) {
    state = TranslationModelManagerState(
      initialized: true,
      activeModelId: TranslationModelCatalog.modelId125Bit,
      entries: <String, TranslationModelEntry>{
        TranslationModelCatalog.modelId125Bit: TranslationModelEntry(
          spec: TranslationModelCatalog.hyMt125Bit,
          status: TranslationModelInstallStatus.installed,
          progress: 1.0,
          localPath: fakeModelPath,
          installedBytes: TranslationModelCatalog.hyMt125Bit.estimatedSizeBytes,
          totalBytes: TranslationModelCatalog.hyMt125Bit.estimatedSizeBytes,
        ),
      },
    );
  }

  @override
  Future<void> refreshAll() async {}
}

class _ForeignBookStubAdapter implements HttpClientAdapter {
  _ForeignBookStubAdapter(this.chapterText, {this.chaptersOverride});

  final String chapterText;
  final List<Map<String, dynamic>>? chaptersOverride;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    Map<String, dynamic> body;
    final path = options.uri.path;
    if (RegExp(r'^/api/library/\d+/chapters$').hasMatch(path)) {
      body = <String, dynamic>{
        'chapters':
            chaptersOverride ??
            <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 0,
                'title': 'Chapter 1',
                'chars': chapterText.length,
                'preview': 'Alice...',
                'text': chapterText,
              },
            ],
      };
    } else if (path == '/api/audiobooks') {
      body = <String, dynamic>{'audiobooks': <dynamic>[]};
    } else if (path == '/api/library') {
      body = <String, dynamic>{'books': <dynamic>[]};
    } else {
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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HY-MT1.5 Prompt & Mirror Catalog', () {
    test('buildHyMtPrompt selects ZH<=>XX or XX<=>XX templates properly', () {
      final enToZh = buildHyMtPrompt(
        sourceText: 'Hello world.',
        targetLanguage: TranslationTargetLanguage.zhHans,
      );
      expect(enToZh, startsWith('将以下文本翻译为中文'));
      expect(enToZh, endsWith('Hello world.'));

      final zhToEn = buildHyMtPrompt(
        sourceText: '你好，世界。',
        targetLanguage: TranslationTargetLanguage.en,
      );
      expect(zhToEn, startsWith('将以下文本翻译为英语'));

      final enToJa = buildHyMtPrompt(
        sourceText: 'Good morning.',
        targetLanguage: TranslationTargetLanguage.ja,
      );
      expect(
        enToJa,
        startsWith(
          'Translate the following segment into Japanese, without additional explanation.',
        ),
      );
    });

    test('resolve mirror download URLs for 1.25bit and Q4_K_M', () {
      final hfMirrorUrl = TranslationModelCatalog.hyMt125Bit
          .downloadUrlForMirror(
            mirrorId: TranslationModelCatalog.mirrorHfMirror,
          );
      expect(
        hfMirrorUrl,
        'https://hf-mirror.com/AngelSlim/Hy-MT1.5-1.8B-1.25bit-GGUF/resolve/main/Hy-MT1.5-1.8B-1.25bit.gguf',
      );

      final officialUrl = TranslationModelCatalog.hyMtQ4Km.downloadUrlForMirror(
        mirrorId: TranslationModelCatalog.mirrorHuggingFace,
      );
      expect(
        officialUrl,
        'https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/main/HY-MT1.5-1.8B-Q4_K_M.gguf',
      );
    });
  });

  group('Language Detection & Paragraph Splitting', () {
    test('splitChapterParagraphs maintains exact substring offsets', () {
      const chapter =
          '  First paragraph here.\n\nSecond paragraph has more words.\n   \nThird line.';
      final segs = splitChapterParagraphs(chapter);
      expect(segs.length, 3);
      for (final seg in segs) {
        expect(chapter.substring(seg.startChar, seg.endChar), seg.text);
        expect(seg.hash, stableParagraphHash(seg.text));
      }
      expect(segs[0].text, 'First paragraph here.');
      expect(segs[1].text, 'Second paragraph has more words.');
      expect(segs[2].text, 'Third line.');
    });

    test('splitChapterSentences splits English/CJK sentences without breaking abbreviations', () {
      const sample =
          'Mr. Jones, of the Manor Farm, was drunk. With his lantern (e.g. bright), Mrs. Jones snored.\n'
          '版本v3.14继续运行！难道这里真的能独立断句吗？"Yes!" she shouted.';
      final segs = splitChapterSentences(sample);
      expect(segs.length, 5);
      for (final seg in segs) {
        expect(sample.substring(seg.startChar, seg.endChar), seg.text);
        expect(seg.hash, stableParagraphHash(seg.text));
      }
      expect(segs[0].text, 'Mr. Jones, of the Manor Farm, was drunk.');
      expect(segs[0].isParagraphEnd, isFalse);
      expect(segs[1].text, 'With his lantern (e.g. bright), Mrs. Jones snored.');
      expect(segs[1].isParagraphEnd, isTrue);
      expect(segs[2].text, '版本v3.14继续运行！');
      expect(segs[2].isParagraphEnd, isFalse);
      expect(segs[3].text, '难道这里真的能独立断句吗？');
      expect(segs[3].isParagraphEnd, isFalse);
      expect(segs[4].text, '"Yes!" she shouted.');
      expect(segs[4].isParagraphEnd, isTrue);
    });

    test('isForeignBookForTarget distinguishes foreign vs native books', () {
      expect(
        isForeignBookForTarget(
          const [
            'Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.',
          ],
          TranslationTargetLanguage.zhHans,
        ),
        isTrue,
      );
      expect(
        isForeignBookForTarget(
          const [
            '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。',
          ],
          TranslationTargetLanguage.zhHans,
        ),
        isTrue,
      );
      expect(
        isForeignBookForTarget(
          const [
            '在 Flutter 框架中使用 Widget 与 RenderObject 可以构建高性能界面，Dart 语言支持 Isolate 并发模型来避免主线程阻塞。',
          ],
          TranslationTargetLanguage.zhHans,
        ),
        isFalse,
      );
      expect(
        isForeignBookForTarget(
          const [
            'Le petit prince est un livre merveilleux dans lequel la rose et les étoiles parlent pour tous les enfants et les grands.',
          ],
          TranslationTargetLanguage.en,
        ),
        isTrue,
      );
    });
  });

  group('Translation Cache Store & Priority Scheduler', () {
    test('FileTranslationCacheStore persists translations and book prefs', () async {
      final tempDir = await Directory.systemTemp.createTemp('echo_mt_cache_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final store = FileTranslationCacheStore(
        rootDirResolver: () async => tempDir,
      );
      await store.saveParagraphTranslation(
        bookId: 42,
        chapterIndex: 0,
        targetLangCode: 'zh-Hans',
        modelId: TranslationModelCatalog.modelId125Bit,
        paragraphHash: 'abc_12',
        translatedText: '你好世界',
      );
      await store.writeBookPrefs(
        42,
        const BookTranslationPrefs(
          displayMode: BilingualDisplayMode.bilingual,
          dismissedForeignPrompt: true,
        ),
      );

      final loadedMap = await store.readChapterTranslations(
        bookId: 42,
        chapterIndex: 0,
        targetLangCode: 'zh-Hans',
        modelId: TranslationModelCatalog.modelId125Bit,
      );
      expect(loadedMap['abc_12'], '你好世界');

      final loadedPrefs = await store.readBookPrefs(42);
      expect(loadedPrefs.displayMode, BilingualDisplayMode.bilingual);
      expect(loadedPrefs.dismissedForeignPrompt, isTrue);
      expect(await store.computeTotalCacheBytes(), greaterThan(0));

      await store.clearAllCaches();
      expect(await store.computeTotalCacheBytes(), 0);
    });

    test('TranslationScheduler prioritizes visible P0 ahead of P1 & P2 and skips cached', () async {
      final cache = MemoryTranslationCacheStore();
      final engine = _FakeTranslationEngine(
        delay: const Duration(milliseconds: 10),
      );
      final keepAlive = _FakeKeepAlive();
      const config = StandaloneConfig();

      final segs = splitChapterParagraphs(
        'Para Zero\nPara One\nPara Two\nPara Three',
      );
      await cache.saveParagraphTranslation(
        bookId: 1,
        chapterIndex: 0,
        targetLangCode: config.translationTargetLang,
        modelId: config.activeTranslationModelId,
        paragraphHash: segs[0].hash,
        translatedText: '已有缓存零段',
      );

      final scheduler = TranslationScheduler(
        engine: engine,
        cacheStore: cache,
        readConfig: () => config,
        readActiveModelPath: () => '/tmp/fake.gguf',
        keepAlive: keepAlive,
      );
      addTearDown(scheduler.dispose);

      await scheduler.startPretranslate(
        bookId: 1,
        bookTitle: 'TestBook',
        chapterIndices: <int>[0],
        loadChapterContent: (_) async =>
            'Para Zero\nPara One\nPara Two\nPara Three',
      );
      await scheduler.enqueuePageAndPrefetch(
        bookId: 1,
        chapterIndex: 0,
        visibleSegments: <ParagraphSegment>[segs[3]],
        chapterSegments: segs,
        prefetchCount: 0,
      );

      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(
        scheduler.state.translationOf(
          bookId: 1,
          chapterIndex: 0,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: segs[0].hash,
        ),
        '已有缓存零段',
      );
      expect(
        scheduler.state.translationOf(
          bookId: 1,
          chapterIndex: 0,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: segs[3].hash,
        ),
        '[译]Para Three',
      );
      expect(engine.callPrompts.any((p) => p.contains('Para Zero')), isFalse);
      expect(engine.callPrompts.any((p) => p.contains('Para Three')), isTrue);
    });

    test('TranslationScheduler awaits ensureActiveModelPath on cold start when readActiveModelPath is initially null', () async {
      final cache = MemoryTranslationCacheStore();
      final engine = _FakeTranslationEngine();
      final keepAlive = _FakeKeepAlive();
      const config = StandaloneConfig();
      String? resolvedPath;

      final segs = splitChapterParagraphs('Cold start paragraph.');
      final scheduler = TranslationScheduler(
        engine: engine,
        cacheStore: cache,
        readConfig: () => config,
        readActiveModelPath: () => resolvedPath,
        ensureActiveModelPath: () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          resolvedPath = '/tmp/cold_start.gguf';
          return resolvedPath;
        },
        keepAlive: keepAlive,
      );
      addTearDown(scheduler.dispose);

      await scheduler.enqueuePageAndPrefetch(
        bookId: 9,
        chapterIndex: 0,
        visibleSegments: segs,
        chapterSegments: segs,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(engine.loadedModelPath, '/tmp/cold_start.gguf');
      expect(scheduler.state.lastError, isNull);
      expect(
        scheduler.state.translationOf(
          bookId: 9,
          chapterIndex: 0,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: segs.first.hash,
        ),
        '[译]Cold start paragraph.',
      );
    });

    test('pauseLiveQueue and chapter switch drop cancelled live P0/P1 without requeueing while requeuing preempted P2 and preserving running visible P1', () async {
      final cache = MemoryTranslationCacheStore();
      final engine = _FakeTranslationEngine(
        delay: const Duration(milliseconds: 50),
      );
      final keepAlive = _FakeKeepAlive();
      const config = StandaloneConfig();

      final ch0Segs = splitChapterSentences('Chapter zero sentence.');
      final ch1Segs = splitChapterSentences('Chapter one visible. Chapter one next.');
      final ch2Segs = splitChapterSentences('Chapter two pretranslate.');

      final scheduler = TranslationScheduler(
        engine: engine,
        cacheStore: cache,
        readConfig: () => config,
        readActiveModelPath: () => '/tmp/fake.gguf',
        keepAlive: keepAlive,
      );
      addTearDown(scheduler.dispose);

      // 1. pauseLiveQueue() 打断正在运行的 P0，不得将其放回队列恢复执行
      await scheduler.enqueuePageAndPrefetch(
        bookId: 10,
        chapterIndex: 0,
        visibleSegments: ch0Segs,
        chapterSegments: ch0Segs,
        prefetchCount: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      scheduler.pauseLiveQueue();

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(scheduler.state.activeParagraphKeys, isEmpty);
      expect(engine.callPrompts.length, 1);
      expect(
        scheduler.state.translationOf(
          bookId: 10,
          chapterIndex: 0,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: ch0Segs.first.hash,
        ),
        isNull,
      );

      // 2. 切章入队新章 P0：打断旧章 P0，旧章不重排插队，新章立即翻译
      engine.callPrompts.clear();
      await scheduler.enqueuePageAndPrefetch(
        bookId: 10,
        chapterIndex: 0,
        visibleSegments: ch0Segs,
        chapterSegments: ch0Segs,
        prefetchCount: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await scheduler.enqueuePageAndPrefetch(
        bookId: 10,
        chapterIndex: 1,
        visibleSegments: <ParagraphSegment>[ch1Segs[0]],
        chapterSegments: ch1Segs,
        prefetchCount: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(
        scheduler.state.translationOf(
          bookId: 10,
          chapterIndex: 0,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: ch0Segs.first.hash,
        ),
        isNull,
      );
      expect(
        scheduler.state.translationOf(
          bookId: 10,
          chapterIndex: 1,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: ch1Segs[0].hash,
        ),
        '[译]Chapter one visible.',
      );

      // 3. 目标可见页包含当前正在预翻的 P1 时不得中断它
      engine.callPrompts.clear();
      await scheduler.enqueuePageAndPrefetch(
        bookId: 10,
        chapterIndex: 1,
        visibleSegments: <ParagraphSegment>[ch1Segs[0]], // 已缓存，直接推进到 ch1Segs[1] (P1)
        chapterSegments: ch1Segs,
        prefetchCount: 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await scheduler.enqueuePageAndPrefetch(
        bookId: 10,
        chapterIndex: 1,
        visibleSegments: <ParagraphSegment>[ch1Segs[1]],
        chapterSegments: ch1Segs,
        prefetchCount: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(
        engine.callPrompts.where((p) => p.contains('Chapter one next.')).length,
        1,
      );
      expect(
        scheduler.state.translationOf(
          bookId: 10,
          chapterIndex: 1,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: ch1Segs[1].hash,
        ),
        '[译]Chapter one next.',
      );

      // 4. P2 后台预翻被新章 P0 抢占后，仍会在 P0 结束后重入队列完成
      await scheduler.startPretranslate(
        bookId: 10,
        bookTitle: 'Test',
        chapterIndices: <int>[2],
        loadChapterContent: (_) async => 'Chapter two pretranslate.',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await scheduler.enqueuePageAndPrefetch(
        bookId: 10,
        chapterIndex: 3,
        visibleSegments: splitChapterSentences('Chapter three urgent.'),
        chapterSegments: splitChapterSentences('Chapter three urgent.'),
        prefetchCount: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(
        scheduler.state.translationOf(
          bookId: 10,
          chapterIndex: 2,
          targetLangCode: config.translationTargetLang,
          modelId: config.activeTranslationModelId,
          paragraphHash: ch2Segs.first.hash,
        ),
        '[译]Chapter two pretranslate.',
      );
    });
  });

  group('Bilingual Pagination & Anchor Stability', () {
    test('paginateBilingualChapterBySizeAsync preserves offsets and keeps page anchor on repagination', () async {
      final rawText = List<String>.generate(
        10,
        (i) =>
            'Paragraph $i is an interesting sentence in this foreign novel about adventures.',
      ).join('\n');
      final segs = splitChapterParagraphs(rawText);

      final pagesBefore = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Chapter 1',
        segments: segs,
        translationsByHash: const <String, String>{},
        activeTranslatingHashes: <String>{segs[0].hash},
        mode: BilingualDisplayMode.bilingual,
        style: const TextStyle(fontSize: 17, height: 1.8),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 320,
        maxHeight: 420,
      );
      expect(pagesBefore.length, greaterThan(1));

      final anchorOffset = pagesBefore[1].startChar;
      final anchorBlockOrigText = pagesBefore[1].blocks!.first.originalText;

      final translations = <String, String>{
        for (var i = 0; i < segs.length; i++)
          segs[i].hash: '这是第 $i 段的详细中文翻译，阐述了这部外文小说中引人入胜的冒险情节与人物心理活动。',
      };
      final pagesAfter = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Chapter 1',
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: const TextStyle(fontSize: 17, height: 1.8),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 320,
        maxHeight: 420,
      );

      final relocatedPageIdx = pageIndexForOffset(pagesAfter, 0, anchorOffset);
      final relocatedPage = pagesAfter[relocatedPageIdx];
      expect(relocatedPage.containsOffset(anchorOffset), isTrue);
      expect(
        relocatedPage.blocks!.any((b) => b.originalText == anchorBlockOrigText),
        isTrue,
      );

      final firstBlock = relocatedPage.blocks!.first;
      expect(firstBlock.hasTranslation, isTrue);
      expect(firstBlock.transDisplayStart, lessThan(firstBlock.origDisplayStart));

      final firstOrigRun = relocatedPage.displayRuns!.firstWhere(
        (r) =>
            r.kind == BilingualRunKind.origSubtitle &&
            r.paragraphIndex == firstBlock.paragraphIndex,
      );
      final origMapped = resolveOriginalSelectionForPage(
        relocatedPage,
        firstBlock.origDisplayStart,
        firstBlock.origDisplayStart + 9,
      );
      expect(origMapped.startOffset, firstOrigRun.origStartChar);
      expect(
        rawText.substring(origMapped.startOffset, origMapped.endOffset),
        relocatedPage.text.substring(
          firstBlock.origDisplayStart,
          firstBlock.origDisplayStart + 9,
        ),
      );

      final anchorBlock = relocatedPage.blocks!.firstWhere(
        (b) => b.originalText == anchorBlockOrigText,
      );
      final anchorOrigMapped = resolveOriginalSelectionForPage(
        relocatedPage,
        anchorBlock.origDisplayStart,
        anchorBlock.origDisplayStart + 9,
      );
      expect(anchorOrigMapped.startOffset, anchorBlock.origStartChar);
      expect(anchorOrigMapped.endOffset, anchorBlock.origStartChar + 9);

      final transMapped = resolveOriginalSelectionForPage(
        relocatedPage,
        firstBlock.transDisplayStart,
        firstBlock.transDisplayEnd,
      );
      expect(transMapped.startOffset, firstBlock.origStartChar);
      expect(transMapped.endOffset, firstBlock.origEndChar);
    });

    test('interleaves Chinese lines and English subtitles continuously within multi-sentence paragraphs without breaking words', () async {
      const p0s0 =
          'Old Major (so he was always called) was so highly regarded on the farm.';
      const p0s1 =
          'At one end of the big barn, Major was already ensconced on his bed of straw.';
      const chapter = '$p0s0 $p0s1';
      final segs = splitChapterSentences(chapter);
      expect(segs.length, 2);
      expect(segs[0].isParagraphEnd, isFalse);
      expect(segs[1].isParagraphEnd, isTrue);

      final translations = <String, String>{
        segs[0].hash: '老少校（大家一直这么叫他）在农场里享有很高的声望。',
        segs[1].hash: '在大谷仓一端的高台上，少校已经舒舒服服地躺在了稻草床上。',
      };

      final pages = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Chapter 1',
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: const TextStyle(fontSize: 17, height: 1.9),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 320,
        maxHeight: 1600,
      );
      expect(pages.length, 1);
      final runs = pages.first.displayRuns!;
      expect(runs, isNotEmpty);

      // 行对严格按 transPrimary -> innerBreak -> origSubtitle -> pairGapBreak 交替出现
      final nonBreakKinds = runs
          .where((r) => !r.isBreak)
          .map((r) => r.kind)
          .toList(growable: false);
      for (var i = 0; i < nonBreakKinds.length - 1; i++) {
        if (nonBreakKinds[i] == BilingualRunKind.transPrimary) {
          // 同段一句收尾紧接下一句可能在同行分成两个 transPrimary 片段，之后必须跟 origSubtitle 或下句
          expect(
            nonBreakKinds[i + 1] == BilingualRunKind.origSubtitle ||
                nonBreakKinds[i + 1] == BilingualRunKind.transPrimary,
            isTrue,
          );
        }
      }

      // 两句中文无缝拼接且字符完全保留，两句英文副标完整不截断且不劈开单词
      final pageText = pages.first.text;
      final joinedZh = runs
          .where((r) => r.kind == BilingualRunKind.transPrimary)
          .map((r) => pageText.substring(r.displayStart, r.displayEnd))
          .join();
      expect(joinedZh, '${translations[segs[0].hash]}${translations[segs[1].hash]}');

      final enLines = <String>[];
      var curEn = StringBuffer();
      for (final r in runs) {
        if (r.kind == BilingualRunKind.origSubtitle) {
          curEn.write(pageText.substring(r.displayStart, r.displayEnd));
        } else if (curEn.isNotEmpty) {
          enLines.add(curEn.toString());
          curEn = StringBuffer();
        }
      }
      if (curEn.isNotEmpty) enLines.add(curEn.toString());
      expect(enLines.length, greaterThanOrEqualTo(2));
      expect(enLines.join(' '), '$p0s0 $p0s1');
      final wordRe = RegExp(r'^[A-Za-z0-9().,]+$');
      for (final line in enLines) {
        for (final token in line.split(' ')) {
          expect(wordRe.hasMatch(token), isTrue);
        }
      }
    });

    test('splits long single paragraphs cleanly across pages without dropping content', () async {
      final sentences = List<String>.generate(
        6,
        (i) => 'Sentence number $i describes the barn and animals in vivid detail.',
      );
      final chapter = sentences.join(' ');
      final segs = splitChapterSentences(chapter);
      expect(segs.length, 6);
      final translations = <String, String>{
        for (var i = 0; i < segs.length; i++)
          segs[i].hash: '第$i句话生动地描绘了老谷仓与农场里所有动物们在月光下的热闹集会情景。',
      };

      final pages = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Long Para',
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: const TextStyle(fontSize: 17, height: 1.9),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 320,
        maxHeight: 220,
      );
      expect(pages.length, greaterThan(1));

      // 原文章节坐标严格单调，无跳失字符；整段中文与英文全量无遗漏分布在多页中
      for (var i = 0; i + 1 < pages.length; i++) {
        expect(pages[i].endChar, lessThanOrEqualTo(pages[i + 1].startChar));
      }
      expect(pages.first.startChar, 0);
      expect(pages.last.endChar, segs.last.endChar);

      final allZh = pages
          .expand(
            (p) => p.displayRuns!
                .where((r) => r.kind == BilingualRunKind.transPrimary)
                .map((r) => p.text.substring(r.displayStart, r.displayEnd)),
          )
          .join();
      expect(allZh, segs.map((s) => translations[s.hash]!).join());

      final allEn = pages
          .expand(
            (p) => p.displayRuns!
                .where((r) => r.kind == BilingualRunKind.origSubtitle)
                .map((r) => p.text.substring(r.displayStart, r.displayEnd)),
          )
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      expect(allEn, chapter);
    });

    test('resolveOriginalSelectionForPage cleans interleaved English from Chinese multi-line quotes and maps subtitle offsets exactly', () async {
      const s0 =
          'Mr. Jones of the Manor Farm locked the hen-houses for the night.';
      const s1 = 'With his lantern dancing he made his way up to bed.';
      const chapter = '$s0 $s1';
      final segs = splitChapterSentences(chapter);
      final translations = <String, String>{
        segs[0].hash: '庄园农场的琼斯先生在夜幕降临时锁好了鸡舍的门窗。',
        segs[1].hash: '随着手中提灯的光圈左右晃动，他晃晃悠悠地走上楼准备睡觉。',
      };

      final pages = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Chapter 1',
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: const TextStyle(fontSize: 17, height: 1.9),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 300,
        maxHeight: 1600,
      );
      final page = pages.first;
      final runs = page.displayRuns!;
      final zhRuns = runs
          .where((r) => r.kind == BilingualRunKind.transPrimary)
          .toList();
      expect(zhRuns.length, greaterThanOrEqualTo(2));

      // 跨多组行间选区从第一行中文拖到末尾中文：摘录应剔除中间的英文副标，并准确锁定覆盖的原句偏移
      final fullMapped = resolveOriginalSelectionForPage(
        page,
        zhRuns.first.displayStart,
        zhRuns.last.displayEnd,
      );
      expect(fullMapped.startOffset, segs.first.startChar);
      expect(fullMapped.endOffset, segs.last.endChar);
      expect(
        fullMapped.quote,
        '${translations[segs[0].hash]}${translations[segs[1].hash]}',
      );
      expect(fullMapped.quote, isNot(contains('Manor')));

      // 纯粹选中某一英文副标词组时应精确映射回原文字符区间
      final subRun = runs.firstWhere(
        (r) =>
            r.kind == BilingualRunKind.origSubtitle &&
            r.exactOrigMapping &&
            (r.displayEnd - r.displayStart) >= 8,
      );
      final subSliceStart = subRun.displayStart + 2;
      final subSliceEnd = subRun.displayStart + 8;
      final enMapped = resolveOriginalSelectionForPage(
        page,
        subSliceStart,
        subSliceEnd,
      );
      expect(
        chapter.substring(enMapped.startOffset, enMapped.endOffset),
        page.text.substring(subSliceStart, subSliceEnd),
      );
      expect(enMapped.quote, page.text.substring(subSliceStart, subSliceEnd));
    });

    test('bilingual selection and annotation projection match exact selected Chinese, repeated words, multi-line Chinese, and English subtitles', () async {
      const s0 =
          'He looked at his own reflection and felt proud on the old manor farm.';
      const s1 = 'Meanwhile every animal listened quietly under the lantern light.';
      const chapter = '$s0 $s1';
      final segs = splitChapterSentences(chapter);
      expect(segs.length, 2);

      const zh0 = '他看着他自己的影子，在古老的庄园农场里感到无比自豪。';
      const zh1 = '与此同时，所有的动物都在提灯微光下静静聆听着演讲。';
      final translations = <String, String>{
        segs[0].hash: zh0,
        segs[1].hash: zh1,
      };

      final pages = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Chapter 1',
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: const TextStyle(fontSize: 17, height: 1.9),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 260,
        maxHeight: 1600,
      );
      final page = pages.first;
      final runs = page.displayRuns!;
      final now = DateTime.utc(2026, 11, 27, 12, 0);

      String extractProjectedText(
        ReaderPage targetPage,
        ReadingAnnotation ann, {
        bool companion = false,
      }) {
        final projected = projectBilingualAnnotationsForPage(
          page: targetPage,
          annotations: <ReadingAnnotation>[ann],
        );
        return projected
            .where((p) => p.isCompanion == companion)
            .map((p) => targetPage.text.substring(p.start, p.end))
            .join();
      }

      // 1. 仅选中句中第 2 个重复词“他”（句内偏移 [3, 4)）：主高亮绝不高亮第 1 个“他”或整句；
      // 未缓存短语对齐时伴随高亮安全兜底整句英文，存在 alignedOrigStart/End 后精确收缩到对应英文短语
      final firstZhRun = runs.firstWhere(
        (r) => r.kind == BilingualRunKind.transPrimary,
      );
      final secondHeIdx = page.text.indexOf('他', firstZhRun.displayStart + 1);
      expect(secondHeIdx, firstZhRun.displayStart + 3);
      final secondHeSel = resolveOriginalSelectionForPage(
        page,
        secondHeIdx,
        secondHeIdx + 1,
      );
      expect(secondHeSel.isTranslation, isTrue);
      expect(secondHeSel.quote, '他');
      expect(secondHeSel.transStartInFirst, 3);
      expect(secondHeSel.transEndInLast, 4);

      final secondHeAnn = ReadingAnnotation(
        id: 'ann_he2',
        bookId: 1,
        chapterIndex: 0,
        startOffset: secondHeSel.startOffset,
        endOffset: secondHeSel.endOffset,
        quote: secondHeSel.quote,
        target: ReadingAnnotationTarget.translation,
        transStartInFirst: secondHeSel.transStartInFirst,
        transEndInLast: secondHeSel.transEndInLast,
        createdAt: now,
        updatedAt: now,
      );
      final heProjected = projectBilingualAnnotationsForPage(
        page: page,
        annotations: <ReadingAnnotation>[secondHeAnn],
      );
      final hePrimary = heProjected.where((p) => !p.isCompanion).toList();
      final heCompanion = heProjected.where((p) => p.isCompanion).toList();
      expect(hePrimary.length, 1);
      expect(hePrimary.first.start, secondHeIdx);
      expect(hePrimary.first.end, secondHeIdx + 1);
      expect(extractProjectedText(page, secondHeAnn), '他');
      expect(heCompanion, isNotEmpty);
      expect(
        extractProjectedText(page, secondHeAnn, companion: true),
        contains('looked at his'),
      );

      final manorStartInCh0 = chapter.indexOf('manor farm');
      expect(manorStartInCh0, greaterThanOrEqualTo(0));
      final alignedSecondHeAnn = secondHeAnn.copyWith(
        alignedOrigStart: manorStartInCh0,
        alignedOrigEnd: manorStartInCh0 + 'manor farm'.length,
      );
      expect(extractProjectedText(page, alignedSecondHeAnn), '他');
      final alignedComp = extractProjectedText(
        page,
        alignedSecondHeAnn,
        companion: true,
      ).replaceAll(RegExp(r'\s+'), '');
      expect(alignedComp, 'manorfarm');

      // 2. 跨两行中文划选（中间跨越英文副标）：主高亮仅覆盖两行内的选中中文，伴随高亮覆盖对应英文副标
      final zhRuns = runs
          .where((r) => r.kind == BilingualRunKind.transPrimary)
          .toList();
      expect(zhRuns.length, greaterThanOrEqualTo(3));
      final multiLineStart = zhRuns[0].displayStart + 4;
      final multiLineEnd = zhRuns[1].displayStart + 3;
      final multiLineSel = resolveOriginalSelectionForPage(
        page,
        multiLineStart,
        multiLineEnd,
      );
      final multiLineAnn = ReadingAnnotation(
        id: 'ann_ml_zh',
        bookId: 1,
        chapterIndex: 0,
        startOffset: multiLineSel.startOffset,
        endOffset: multiLineSel.endOffset,
        quote: multiLineSel.quote,
        target: ReadingAnnotationTarget.translation,
        transStartInFirst: multiLineSel.transStartInFirst,
        transEndInLast: multiLineSel.transEndInLast,
        createdAt: now,
        updatedAt: now,
      );
      final mlProjected = projectBilingualAnnotationsForPage(
        page: page,
        annotations: <ReadingAnnotation>[multiLineAnn],
      );
      expect(extractProjectedText(page, multiLineAnn), multiLineSel.quote);
      expect(extractProjectedText(page, multiLineAnn), isNot(contains('looked')));
      for (final p in mlProjected.where((p) => !p.isCompanion)) {
        expect(
          runs.any(
            (r) =>
                r.kind == BilingualRunKind.origSubtitle &&
                p.start < r.displayEnd &&
                p.end > r.displayStart,
          ),
          isFalse,
        );
      }
      for (final p in mlProjected.where((p) => p.isCompanion)) {
        expect(
          runs.any(
            (r) =>
                r.kind == BilingualRunKind.origSubtitle &&
                p.start >= r.displayStart &&
                p.end <= r.displayEnd,
          ),
          isTrue,
        );
      }

      // 3. 跨两句中文末尾->下一句中文开头：仅亮第1句尾 + 第2句头，不整两句全亮
      final s0Runs = zhRuns
          .where((r) => r.origStartChar == segs[0].startChar)
          .toList();
      final s1Runs = zhRuns
          .where((r) => r.origStartChar == segs[1].startChar)
          .toList();
      final crossStart = s0Runs.last.displayStart + 2;
      final crossEnd = s1Runs.first.displayStart + 4;
      final crossSel = resolveOriginalSelectionForPage(page, crossStart, crossEnd);
      final crossAnn = ReadingAnnotation(
        id: 'ann_cross_zh',
        bookId: 1,
        chapterIndex: 0,
        startOffset: crossSel.startOffset,
        endOffset: crossSel.endOffset,
        quote: crossSel.quote,
        target: ReadingAnnotationTarget.translation,
        transStartInFirst: crossSel.transStartInFirst,
        transEndInLast: crossSel.transEndInLast,
        createdAt: now,
        updatedAt: now,
      );
      expect(extractProjectedText(page, crossAnn), crossSel.quote);
      expect(extractProjectedText(page, crossAnn).length, lessThan(zh0.length + zh1.length));

      // 4. 选中跨两行的英文副标词组（中间跨着中文主行）：仅高亮该英文副标区间，不产生伴随范围也不亮上方中文
      final subRuns = runs
          .where(
            (r) => r.kind == BilingualRunKind.origSubtitle && r.exactOrigMapping,
          )
          .toList();
      expect(subRuns.length, greaterThanOrEqualTo(2));
      final subStart = subRuns[0].displayStart + 3;
      final subEnd = subRuns[1].displayStart + 5;
      final subSel = resolveOriginalSelectionForPage(page, subStart, subEnd);
      expect(subSel.isTranslation, isFalse);
      expect(subSel.quote, isNot(contains('他')));
      final subAnn = ReadingAnnotation(
        id: 'ann_sub_en',
        bookId: 1,
        chapterIndex: 0,
        startOffset: subSel.startOffset,
        endOffset: subSel.endOffset,
        quote: subSel.quote,
        target: ReadingAnnotationTarget.original,
        createdAt: now,
        updatedAt: now,
      );
      final subProjected = projectBilingualAnnotationsForPage(
        page: page,
        annotations: <ReadingAnnotation>[subAnn],
      );
      expect(subProjected, isNotEmpty);
      expect(subProjected.every((p) => !p.isCompanion), isTrue);
      expect(
        chapter.substring(subAnn.startOffset, subAnn.endOffset),
        subSel.quote,
      );
      for (final p in subProjected) {
        expect(
          runs.any(
            (r) =>
                r.kind == BilingualRunKind.origSubtitle &&
                p.start >= r.displayStart &&
                p.end <= r.displayEnd,
          ),
          isTrue,
        );
      }

      // 5. 切到「仅译文」模式时，原文划线退化高亮对应中文句，中文划线不产生英文伴随高亮
      final transOnlyPages = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Chapter 1',
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.translatedOnly,
        style: const TextStyle(fontSize: 17, height: 1.9),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 260,
        maxHeight: 1600,
      );
      final transOnlyProjected = projectBilingualAnnotationsForPage(
        page: transOnlyPages.first,
        annotations: <ReadingAnnotation>[subAnn],
      );
      expect(transOnlyProjected, isNotEmpty);
      expect(transOnlyProjected.every((p) => !p.isCompanion), isTrue);
      final zhTransOnlyProjected = projectBilingualAnnotationsForPage(
        page: transOnlyPages.first,
        annotations: <ReadingAnnotation>[secondHeAnn],
      );
      expect(zhTransOnlyProjected.where((p) => !p.isCompanion), isNotEmpty);
      expect(zhTransOnlyProjected.where((p) => p.isCompanion), isEmpty);

      // 6. 未译时划选英文单词，待译文到达后仍精准落在该句子下方英文副标的同一单词上
      final untransPages = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Chapter 1',
        segments: segs,
        translationsByHash: const <String, String>{},
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: const TextStyle(fontSize: 17, height: 1.9),
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: 260,
        maxHeight: 1600,
      );
      final proudIdx = untransPages.first.text.indexOf('proud');
      expect(proudIdx, greaterThanOrEqualTo(0));
      final untransSel = resolveOriginalSelectionForPage(
        untransPages.first,
        proudIdx,
        proudIdx + 5,
      );
      expect(untransSel.isTranslation, isFalse);
      expect(untransSel.quote, 'proud');
      final untransAnn = ReadingAnnotation(
        id: 'ann_untrans',
        bookId: 1,
        chapterIndex: 0,
        startOffset: untransSel.startOffset,
        endOffset: untransSel.endOffset,
        quote: untransSel.quote,
        target: ReadingAnnotationTarget.original,
        createdAt: now,
        updatedAt: now,
      );
      expect(extractProjectedText(untransPages.first, untransAnn), 'proud');
      expect(extractProjectedText(page, untransAnn), 'proud');
    });

    group('BilingualPhraseAligner & phrase back-translation queue', () {
      const sentenceText =
          "Old Major (so he was always called, though the name under which he had been exhibited was Willingdon Beauty) was so highly regarded on the farm that everyone was quite ready to lose an hour's sleep in order to hear what he had to say.";
      const zhText =
          '老少校（因此他一直被这么称呼，尽管他被展示时的名字是威灵顿·贝蒂）在农场里享有极高的声望，以至于大家都愿意为了听他说什么而牺牲一个小时的睡眠。';

      const singlePair = SentenceAlignmentPair(
        origStartChar: 0,
        origEndChar: sentenceText.length,
        origText: sentenceText,
        transText: zhText,
      );

      ReadingAnnotation makeZhAnn({
        required String quote,
        int? transStart,
        int? transEnd,
        List<SentenceAlignmentPair> pairs = const [singlePair],
        ReadingAnnotationTarget target = ReadingAnnotationTarget.translation,
      }) {
        final now = DateTime.utc(2026, 11, 27, 13, 0);
        return ReadingAnnotation(
          id: 'ann_${quote.hashCode}',
          bookId: 1,
          chapterIndex: 0,
          startOffset: pairs.first.origStartChar,
          endOffset: pairs.last.origEndChar,
          quote: quote,
          target: target,
          transStartInFirst: transStart,
          transEndInLast: transEnd,
          createdAt: now,
          updatedAt: now,
        );
      }

      test('Tier 0 full-sentence and Tier 1 parenthetical/entity align with 0 model calls', () async {
        var modelCalls = 0;
        Future<String?> failIfCalled(
          String _,
          TranslationTargetLanguage _,
        ) async {
          modelCalls++;
          return null;
        }

        // 整句划线 -> 直接命中整句原文
        final fullRes = await alignChineseAnnotationToOriginal(
          annotation: makeZhAnn(
            quote: zhText,
            transStart: 0,
            transEnd: zhText.length,
          ),
          sentences: const [singlePair],
          backTranslatePhrase: failIfCalled,
        );
        expect(fullRes, isNotNull);
        expect(fullRes!.alignedOrigStart, 0);
        expect(fullRes.alignedOrigEnd, sentenceText.length);
        expect(fullRes.isSubSentenceMatch, isFalse);
        expect(fullRes.usedModel, isFalse);

        // 唯一括号注释 -> Tier 1 零模型推理精准定位英文括号内容
        const parenZh = '（因此他一直被这么称呼，尽管他被展示时的名字是威灵顿·贝蒂）';
        final parenStart = zhText.indexOf(parenZh);
        final parenRes = await alignChineseAnnotationToOriginal(
          annotation: makeZhAnn(
            quote: parenZh,
            transStart: parenStart,
            transEnd: parenStart + parenZh.length,
          ),
          sentences: const [singlePair],
          backTranslatePhrase: failIfCalled,
        );
        expect(parenRes, isNotNull);
        expect(parenRes!.isSubSentenceMatch, isTrue);
        expect(parenRes.usedModel, isFalse);
        expect(
          sentenceText.substring(
            parenRes.alignedOrigStart,
            parenRes.alignedOrigEnd,
          ),
          '(so he was always called, though the name under which he had been exhibited was Willingdon Beauty)',
        );

        // 字面英文人名实体 -> Tier 1 零模型推理直接命中
        const mrOrig = 'Mrs. Jones was already snoring in the bedroom.';
        const mrZh = 'Mrs. Jones 已经在卧室里打呼噜了。';
        const mrPair = SentenceAlignmentPair(
          origStartChar: 0,
          origEndChar: mrOrig.length,
          origText: mrOrig,
          transText: mrZh,
        );
        final mrRes = await alignChineseAnnotationToOriginal(
          annotation: makeZhAnn(
            quote: 'Mrs. Jones',
            transStart: 0,
            transEnd: 'Mrs. Jones'.length,
            pairs: const [mrPair],
          ),
          sentences: const [mrPair],
          backTranslatePhrase: failIfCalled,
        );
        expect(mrRes, isNotNull);
        expect(
          mrOrig.substring(mrRes!.alignedOrigStart, mrRes.alignedOrigEnd),
          'Mrs. Jones',
        );
        expect(modelCalls, 0);
      });

      test('Tier 2 handles word-order inversion, possessives, fuzzy transliteration, synonym gap, and low-confidence fallback', () async {
        Future<String?> runAlign(
          String zhSlice,
          String fakeBack, {
          SentenceAlignmentPair pair = singlePair,
        }) async {
          final start = pair.transText.indexOf(zhSlice);
          expect(start, greaterThanOrEqualTo(0));
          final res = await alignChineseAnnotationToOriginal(
            annotation: makeZhAnn(
              quote: zhSlice,
              transStart: start,
              transEnd: start + zhSlice.length,
              pairs: <SentenceAlignmentPair>[pair],
            ),
            sentences: <SentenceAlignmentPair>[pair],
            backTranslatePhrase: (_, _) async => fakeBack,
          );
          expect(res, isNotNull);
          return pair.origText.substring(
            res!.alignedOrigStart - pair.origStartChar,
            res.alignedOrigEnd - pair.origStartChar,
          );
        }

        // 1. 中英文语序倒装
        expect(await runAlign('在农场里', 'on the farm'), 'on the farm');

        // 2. 所有格 / 词形变化
        expect(
          await runAlign('牺牲一个小时的睡眠', 'sacrifice an hour of sleep'),
          "an hour's sleep",
        );

        // 3. 音译偏差模糊容错
        expect(
          await runAlign('威灵顿·贝蒂', 'Willingdon Betty'),
          'Willingdon Beauty',
        );

        // 4. 跨同义词（lying vs ensconced）桥接连续短语
        const barnOrig =
            'At one end of the big barn, on a sort of raised platform, Major was already ensconced on his bed of straw, under a lantern which hung from a beam.';
        const barnZh = '在大谷仓的一端，有一个类似高台的平台上，少校已经躺在他的稻草床上，上面挂着一盏灯笼。';
        const barnPair = SentenceAlignmentPair(
          origStartChar: 0,
          origEndChar: barnOrig.length,
          origText: barnOrig,
          transText: barnZh,
        );
        expect(
          await runAlign(
            '少校已经躺在他的稻草床上',
            'Major was already lying on his bed of straw',
            pair: barnPair,
          ),
          'Major was already ensconced on his bed of straw',
        );

        // 5. 低置信度乱译安全回退整句（绝不误标错误英文词）
        expect(
          await runAlign('在农场里', 'completely unrelated banana'),
          sentenceText,
        );
      });

      test('multi-sentence partial start/end trims only boundaries skipping >12%', () async {
        const s0 = 'Old Major looked around the barn with solemn eyes.';
        const s1 = 'At last he cleared his throat and began to speak softly.';
        const zh0 = '老少校用庄严的目光环顾谷仓四周。';
        const zh1 = '最后他清了清嗓子并开始轻声讲话。';
        const pairs = <SentenceAlignmentPair>[
          SentenceAlignmentPair(
            origStartChar: 0,
            origEndChar: s0.length,
            origText: s0,
            transText: zh0,
          ),
          SentenceAlignmentPair(
            origStartChar: s0.length + 1,
            origEndChar: s0.length + 1 + s1.length,
            origText: s1,
            transText: zh1,
          ),
        ];
        final startInS0 = zh0.indexOf('环顾谷仓四周');
        final endInS1 = '最后他清了清嗓子'.length;
        final res = await alignChineseAnnotationToOriginal(
          annotation: makeZhAnn(
            quote: '环顾谷仓四周。\n最后他清了清嗓子',
            transStart: startInS0,
            transEnd: endInS1,
            pairs: pairs,
          ),
          sentences: pairs,
          backTranslatePhrase: (phrase, _) async {
            if (phrase.contains('环顾')) return 'looked around the barn';
            if (phrase.contains('清了清嗓子')) return 'At last he cleared his throat';
            return null;
          },
        );
        expect(res, isNotNull);
        expect(res!.isSubSentenceMatch, isTrue);
        const fullTwo = '$s0 $s1';
        expect(
          fullTwo.substring(res.alignedOrigStart, res.alignedOrigEnd),
          'looked around the barn with solemn eyes. At last he cleared his throat',
        );
      });

      test('TranslationScheduler.translatePhraseForAlignment caches hits and handles missing model silently', () async {
        final cache = MemoryTranslationCacheStore();
        final cfgController = StandaloneConfigController(
          MemoryStandaloneConfigStorage(),
          const StandaloneConfig(),
        );
        final engine = _FakeTranslationEngine(
          responder: (_) => 'on the farm',
        );
        final keepAlive = _FakeKeepAlive();
        String? activeModel = '/tmp/fake.gguf';

        final scheduler = TranslationScheduler(
          engine: engine,
          cacheStore: cache,
          readConfig: () => cfgController.state,
          readActiveModelPath: () => activeModel,
          keepAlive: keepAlive,
        );
        addTearDown(scheduler.dispose);

        final first = await scheduler.translatePhraseForAlignment(
          phrase: '在农场里',
          targetLang: TranslationTargetLanguage.en,
        );
        final second = await scheduler.translatePhraseForAlignment(
          phrase: '在农场里',
          targetLang: TranslationTargetLanguage.en,
        );
        expect(first, 'on the farm');
        expect(second, 'on the farm');
        expect(engine.callPrompts.length, 1);

        // 无模型时静默返回 null 且绝不写入 lastError 干扰阅读器 banner
        activeModel = null;
        final missing = await scheduler.translatePhraseForAlignment(
          phrase: '另一个未缓存短语',
          targetLang: TranslationTargetLanguage.en,
        );
        expect(missing, isNull);
        expect(scheduler.state.lastError, isNull);
      });
    });

    test('binary-search pagination packs multi-page mixed chapters strictly within height bounds and cache signatures differentiate translation state', () async {
      BilingualChapterPaginationCache.instance.clear();
      addTearDown(BilingualChapterPaginationCache.instance.clear);

      final sentences = List<String>.generate(
        32,
        (i) =>
            'Sentence number $i tells how the animals worked together on Manor Farm.',
      );
      final chapter = sentences.join('\n\n');
      final segs = splitChapterSentences(chapter);
      expect(segs.length, 32);

      final translations = <String, String>{
        for (var i = 0; i < segs.length; i += 2)
          segs[i].hash: '第$i句中文译文生动记录了动物们在庄园农场齐心协力劳作的场景。',
      };

      const style = TextStyle(fontSize: 17, height: 1.9);
      const maxWidth = 320.0;
      const maxHeight = 360.0;
      final pages = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Farm Chapter',
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHashes: <String>{segs[1].hash},
        mode: BilingualDisplayMode.bilingual,
        style: style,
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );

      expect(pages.length, greaterThan(3));
      for (var i = 0; i + 1 < pages.length; i++) {
        expect(pages[i].endChar, lessThanOrEqualTo(pages[i + 1].startChar));
        expect(pages[i].pageInChapter, i + 1);
        expect(pages[i].pageCountInChapter, pages.length);
      }
      expect(pages.first.startChar, 0);
      expect(pages.last.endChar, segs.last.endChar);

      // 逐页重测行间 TextSpan 实际渲染高度，确认二分装箱不溢出页面高度
      final styles = bilingualTypographyStyles(
        origStyle: style,
        secondaryColor: Colors.grey,
      );
      final verifyPainter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      );
      addTearDown(verifyPainter.dispose);
      for (final page in pages) {
        final spans = <InlineSpan>[
          for (final r in page.displayRuns!)
            TextSpan(
              text: page.text.substring(r.displayStart, r.displayEnd),
              style: switch (r.kind) {
                BilingualRunKind.transPrimary => styles.transPrimaryStyle,
                BilingualRunKind.origSubtitle => styles.origSubtitleStyle,
                BilingualRunKind.untranslatedOrig => styles.untranslatedOrigStyle,
                BilingualRunKind.innerBreak => styles.innerBreakStyle,
                BilingualRunKind.pairGapBreak => styles.pairGapBreakStyle,
                BilingualRunKind.sentenceBreak => styles.sentenceBreakStyle,
                BilingualRunKind.paragraphBreak => styles.paragraphBreakStyle,
              },
            ),
        ];
        verifyPainter.text = TextSpan(style: style, children: spans);
        verifyPainter.layout(maxWidth: maxWidth);
        expect(
          verifyPainter.height,
          lessThanOrEqualTo(maxHeight + 0.5),
          reason: '双语第 ${page.pageInChapter} 页高度溢出',
        );
      }

      // 译文与未译原句完整覆盖不丢句
      final allJoined = pages.map((p) => p.text).join('\n');
      for (var i = 0; i < segs.length; i++) {
        if (i.isEven) {
          expect(allJoined, contains('第$i句中文译文'));
        } else {
          expect(allJoined, contains('Sentence number $i'));
        }
      }

      // 验证缓存指纹精准区分译文增加与活跃句变化
      final sig1 = computeBilingualPaginationSignature(
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHash: segs[1].hash,
      );
      final key1 = BilingualChapterPaginationKey(
        bookId: 5,
        chapterIndex: 0,
        mode: BilingualDisplayMode.bilingual,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontSize: 17,
        lineHeight: 1.9,
        textScaleFactor: 1.0,
        sigA: sig1.sigA,
        sigB: sig1.sigB,
        translatedCount: sig1.translatedCount,
      );
      BilingualChapterPaginationCache.instance.put(key1, pages);
      expect(BilingualChapterPaginationCache.instance.get(key1), isNotNull);

      final updatedTranslations = Map<String, String>.from(translations)
        ..[segs[1].hash] = '第1句新增中文译文。';
      final sig2 = computeBilingualPaginationSignature(
        segments: segs,
        translationsByHash: updatedTranslations,
        activeTranslatingHash: segs[1].hash,
      );
      final key2 = BilingualChapterPaginationKey(
        bookId: 5,
        chapterIndex: 0,
        mode: BilingualDisplayMode.bilingual,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontSize: 17,
        lineHeight: 1.9,
        textScaleFactor: 1.0,
        sigA: sig2.sigA,
        sigB: sig2.sigB,
        translatedCount: sig2.translatedCount,
      );
      expect(key2, isNot(equals(key1)));
      expect(BilingualChapterPaginationCache.instance.get(key2), isNull);

      final sig3 = computeBilingualPaginationSignature(
        segments: segs,
        translationsByHash: translations,
        activeTranslatingHash: segs[3].hash,
      );
      final key3 = BilingualChapterPaginationKey(
        bookId: 5,
        chapterIndex: 0,
        mode: BilingualDisplayMode.bilingual,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        fontSize: 17,
        lineHeight: 1.9,
        textScaleFactor: 1.0,
        sigA: sig3.sigA,
        sigB: sig3.sigB,
        translatedCount: sig3.translatedCount,
      );
      expect(key3, isNot(equals(key1)));
    });

    test('anchorCharOffset keeps current page top lines anchored when bottom half finishes translating', () async {
      BilingualChapterPaginationCache.instance.clear();
      addTearDown(BilingualChapterPaginationCache.instance.clear);

      final sentences = List<String>.generate(
        10,
        (i) =>
            'Long paragraph sentence $i describes the bright lantern moving steadily across Manor Farm.',
      );
      final chapter = sentences.join(' ');
      final segs = splitChapterSentences(chapter);
      expect(segs.length, 10);

      final fullTranslations = <String, String>{
        for (var i = 0; i < segs.length; i++)
          segs[i].hash: '第$i句是一段比较长的中文翻译，用来描写夜晚提灯光圈在庄园院子里缓缓晃动并照亮四周的情景。',
      };
      final partialTranslations = <String, String>{
        for (var i = 0; i < 3; i++) segs[i].hash: fullTranslations[segs[i].hash]!,
      };

      const style = TextStyle(fontSize: 17, height: 1.9);
      const maxWidth = 320.0;
      const maxHeight = 320.0;

      final pagesBefore = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Anchor Chapter',
        segments: segs,
        translationsByHash: partialTranslations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: style,
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );
      expect(pagesBefore.length, greaterThanOrEqualTo(2));

      final halfPageIdx = pagesBefore.indexWhere(
        (p) =>
            p.displayRuns!.any((r) => r.kind == BilingualRunKind.transPrimary) &&
            p.displayRuns!.any((r) => r.kind == BilingualRunKind.untranslatedOrig),
      );
      expect(halfPageIdx, greaterThanOrEqualTo(1));

      final anchor = pagesBefore[halfPageIdx].startChar;
      expect(anchor, greaterThan(0));
      final firstTransRunBefore = pagesBefore[halfPageIdx].displayRuns!.firstWhere(
        (r) => r.kind == BilingualRunKind.transPrimary,
      );
      final topZhBefore = pagesBefore[halfPageIdx].text.substring(
        firstTransRunBefore.displayStart,
        firstTransRunBefore.displayEnd,
      );

      final pagesAfter = await paginateBilingualChapterBySizeAsync(
        chapterIndex: 0,
        chapterTitle: 'Anchor Chapter',
        segments: segs,
        translationsByHash: fullTranslations,
        activeTranslatingHashes: const <String>{},
        mode: BilingualDisplayMode.bilingual,
        style: style,
        secondaryColor: Colors.grey,
        textScaler: TextScaler.noScaling,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        anchorCharOffset: anchor,
      );

      final idx = pageIndexForOffset(pagesAfter, 0, anchor);
      expect(pagesAfter[idx].startChar, anchor);

      final firstTransRunAfter = pagesAfter[idx].displayRuns!.firstWhere(
        (r) => r.kind == BilingualRunKind.transPrimary,
      );
      final topZhAfter = pagesAfter[idx].text.substring(
        firstTransRunAfter.displayStart,
        firstTransRunAfter.displayEnd,
      );
      expect(topZhAfter, topZhBefore);

      // 校验全章不溢出、偏移单调且中英文内容零丢失/零重复
      final styles = bilingualTypographyStyles(
        origStyle: style,
        secondaryColor: Colors.grey,
      );
      final verifyPainter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      );
      addTearDown(verifyPainter.dispose);
      for (var i = 0; i < pagesAfter.length; i++) {
        if (i + 1 < pagesAfter.length) {
          expect(pagesAfter[i].endChar, lessThanOrEqualTo(pagesAfter[i + 1].startChar));
        }
        final spans = <InlineSpan>[
          for (final r in pagesAfter[i].displayRuns!)
            TextSpan(
              text: pagesAfter[i].text.substring(r.displayStart, r.displayEnd),
              style: switch (r.kind) {
                BilingualRunKind.transPrimary => styles.transPrimaryStyle,
                BilingualRunKind.origSubtitle => styles.origSubtitleStyle,
                BilingualRunKind.untranslatedOrig => styles.untranslatedOrigStyle,
                BilingualRunKind.innerBreak => styles.innerBreakStyle,
                BilingualRunKind.pairGapBreak => styles.pairGapBreakStyle,
                BilingualRunKind.sentenceBreak => styles.sentenceBreakStyle,
                BilingualRunKind.paragraphBreak => styles.paragraphBreakStyle,
              },
            ),
        ];
        verifyPainter.text = TextSpan(style: style, children: spans);
        verifyPainter.layout(maxWidth: maxWidth);
        expect(verifyPainter.height, lessThanOrEqualTo(maxHeight + 0.5));
      }
      expect(pagesAfter.first.startChar, 0);
      expect(pagesAfter.last.endChar, segs.last.endChar);

      final allZh = pagesAfter
          .expand(
            (p) => p.displayRuns!
                .where((r) => r.kind == BilingualRunKind.transPrimary)
                .map((r) => p.text.substring(r.displayStart, r.displayEnd)),
          )
          .join();
      expect(allZh, segs.map((s) => fullTranslations[s.hash]!).join());

      final allEn = pagesAfter
          .expand(
            (p) => p.displayRuns!
                .where((r) => r.kind == BilingualRunKind.origSubtitle)
                .map((r) => p.text.substring(r.displayStart, r.displayEnd)),
          )
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      expect(allEn, chapter);
    });
  });

  group('LiveTtsPlayerController Bilingual Language Switching', () {
    test('switches between speaking translated text and original text', () async {
      final tmpLib = await Directory.systemTemp.createTemp('echo_mt_lib_');
      final tmpAudio = await Directory.systemTemp.createTemp('echo_mt_wav_');
      addTearDown(() {
        if (tmpLib.existsSync()) tmpLib.deleteSync(recursive: true);
        if (tmpAudio.existsSync()) tmpAudio.deleteSync(recursive: true);
      });

      final libStore = LocalLibraryStore(rootDir: tmpLib);
      final book = await libStore.importBytes(
        Uint8List.fromList(
          utf8.encode('First English sentence.\nSecond English sentence.'),
        ),
        filename: 'bilingual.txt',
      );
      final chapters = await libStore.listChapters(book.id);
      final segs = splitChapterSentences(chapters.first.text);
      final translations = <String, String>{
        segs[0].hash: '第一句中文译文。',
        segs[1].hash: '第二句中文译文。',
      };

      final ttsEngine = FakeOnDeviceTtsEngine();
      final audioEngine = FakeAudioEngine();
      addTearDown(audioEngine.dispose);
      addTearDown(ttsEngine.dispose);
      final ctrl = LiveTtsPlayerController(
        libraryStore: libStore,
        ttsEngine: ttsEngine,
        audioEngine: audioEngine,
        cacheDirOverride: tmpAudio,
        readConfig: () => const StandaloneConfig(),
        resolveActiveModel: () => const ResolvedTtsModelPaths(
          spec: TtsModelCatalog.meloTtsZhEn,
          rootDir: '/tmp',
          modelPath: '/tmp/m.onnx',
          tokensPath: '/tmp/t.txt',
        ),
        loadChapterTranslations: (_, _) async => translations,
      );
      addTearDown(ctrl.dispose);

      await ctrl.playBookChapter(book, speakTranslated: true);
      expect(ctrl.state.speakTranslated, isTrue);
      expect(ctrl.state.currentCueText, '第一句中文译文。');
      expect(ttsEngine.synthesizedTexts.first, '第一句中文译文。');

      await ctrl.setSpeakTranslated(false);
      expect(ctrl.state.speakTranslated, isFalse);
      expect(ctrl.state.currentCueText, 'First English sentence.');
    });
  });

  group('Reader Foreign Book & Bilingual UI Integration', () {
    testWidgets('shows foreign book banner, enables bilingual mode, and translates visible paragraphs',
        (tester) async {
      final cache = MemoryTranslationCacheStore();
      final engine = _FakeTranslationEngine();
      final keepAlive = _FakeKeepAlive();
      final cfgController = StandaloneConfigController(
        MemoryStandaloneConfigStorage(),
        const StandaloneConfig(),
      );

      const chapterText =
          'Alice was beginning to get very tired of sitting by her sister on the bank.\n'
          'So she was considering in her own mind whether the pleasure of making a daisy-chain would be worth the trouble.';

      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_foreign');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ForeignBookStubAdapter(chapterText);
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

      final container = ProviderContainer(
        overrides: [
          echoApiProvider.overrideWithValue(api),
          standaloneConfigProvider.overrideWith((_) => cfgController),
          readingStoreProvider.overrideWithValue(MemoryReadingStore()),
          translationCacheStoreProvider.overrideWithValue(cache),
          translationEngineProvider.overrideWithValue(engine),
          translationModelManagerProvider.overrideWith(
            (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
          ),
          translationSchedulerProvider.overrideWith(
            (ref) => TranslationScheduler(
              engine: engine,
              cacheStore: cache,
              readConfig: () => cfgController.state,
              readActiveModelPath: () => '/tmp/fake.gguf',
              keepAlive: keepAlive,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const book = LibraryBook(
        id: 77,
        title: "Alice's Adventures",
        format: 'epub',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, tokens),
            home: const ReaderPageView(book: book),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 外文书自动弹出顶部提示横条，工具栏默认隐藏
      expect(find.byKey(const Key('reader_foreign_prompt_banner')), findsOneWidget);
      expect(find.byKey(const Key('reader_translate_button')), findsNothing);

      // 点击「开启双语」
      await tester.tap(find.byKey(const Key('reader_foreign_enable_button')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // 横条隐藏，正文按电影字幕顺序展示：译文居上、英文副标居下
      expect(find.byKey(const Key('reader_foreign_prompt_banner')), findsNothing);
      final textWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final rendered = textWidget.textSpan?.toPlainText() ?? textWidget.data ?? '';
      expect(rendered, contains('[译]Alice was beginning'));
      expect(rendered, contains('Alice was beginning'));
      expect(
        rendered.indexOf('[译]Alice was beginning'),
        lessThan(rendered.indexOf('Alice was beginning')),
      );
      expect(rendered, isNot(contains('等待翻译')));

      // 点击正文唤起工具栏，再点击「双语」按钮打开控制面板并切换至「仅译文」
      await tester.tap(find.byKey(const Key('reader_pageview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reader_translate_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader_translation_sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('reader_mode_translatedOnly')));
      await tester.pumpAndSettle();

      final transOnlyWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final transOnlyRendered =
          transOnlyWidget.textSpan?.toPlainText() ?? transOnlyWidget.data ?? '';
      expect(transOnlyRendered, startsWith('[译]Alice was beginning'));
    });

    testWidgets('surfaces translation error banner and retries cleanly in bilingual mode',
        (tester) async {
      final cache = MemoryTranslationCacheStore();
      final engine = _FakeTranslationEngine(
        loadError: StateError('failed to load GGUF model: incompatible type'),
      );
      final keepAlive = _FakeKeepAlive();
      final cfgController = StandaloneConfigController(
        MemoryStandaloneConfigStorage(),
        const StandaloneConfig(),
      );

      const chapterText =
          'Alice was beginning to get very tired of sitting by her sister on the bank.\n'
          'So she was considering in her own mind whether the pleasure of making a daisy-chain would be worth the trouble.';

      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_foreign_err');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ForeignBookStubAdapter(chapterText);
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

      final container = ProviderContainer(
        overrides: [
          echoApiProvider.overrideWithValue(api),
          standaloneConfigProvider.overrideWith((_) => cfgController),
          readingStoreProvider.overrideWithValue(MemoryReadingStore()),
          translationCacheStoreProvider.overrideWithValue(cache),
          translationEngineProvider.overrideWithValue(engine),
          translationModelManagerProvider.overrideWith(
            (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
          ),
          translationSchedulerProvider.overrideWith(
            (ref) => TranslationScheduler(
              engine: engine,
              cacheStore: cache,
              readConfig: () => cfgController.state,
              readActiveModelPath: () => '/tmp/fake.gguf',
              keepAlive: keepAlive,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const book = LibraryBook(
        id: 78,
        title: "Alice's Adventures",
        format: 'epub',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, tokens),
            home: const ReaderPageView(book: book),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reader_foreign_enable_button')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('reader_translation_error_banner')),
        findsOneWidget,
      );
      expect(
        find.textContaining('failed to load GGUF model: incompatible type'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('reader_translation_retry_button')),
        findsOneWidget,
      );

      // 恢复引擎并点击重试，应清除错误横条并完成可见段翻译
      engine.loadError = null;
      await tester.tap(find.byKey(const Key('reader_translation_retry_button')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('reader_translation_error_banner')),
        findsNothing,
      );
      final textWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final rendered = textWidget.textSpan?.toPlainText() ?? textWidget.data ?? '';
      expect(rendered, contains('[译]Alice was beginning'));
    });

    testWidgets('progressively transforms sentences and shows progress strip while translating',
        (tester) async {
      final cache = MemoryTranslationCacheStore();
      final engine = _FakeTranslationEngine(
        delay: const Duration(milliseconds: 80),
      );
      final keepAlive = _FakeKeepAlive();
      final cfgController = StandaloneConfigController(
        MemoryStandaloneConfigStorage(),
        const StandaloneConfig(),
      );

      const chapterText =
          'First sentence of Animal Farm. Second sentence with Mrs. Jones snoring.';

      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_progressive');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ForeignBookStubAdapter(chapterText);
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

      final container = ProviderContainer(
        overrides: [
          echoApiProvider.overrideWithValue(api),
          standaloneConfigProvider.overrideWith((_) => cfgController),
          readingStoreProvider.overrideWithValue(MemoryReadingStore()),
          translationCacheStoreProvider.overrideWithValue(cache),
          translationEngineProvider.overrideWithValue(engine),
          translationModelManagerProvider.overrideWith(
            (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
          ),
          translationSchedulerProvider.overrideWith(
            (ref) => TranslationScheduler(
              engine: engine,
              cacheStore: cache,
              readConfig: () => cfgController.state,
              readActiveModelPath: () => '/tmp/fake.gguf',
              keepAlive: keepAlive,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const book = LibraryBook(
        id: 79,
        title: 'Animal Farm',
        format: 'epub',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, tokens),
            home: const ReaderPageView(book: book),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reader_foreign_enable_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      // 翻译进行中（第 1 句未完）：显示顶部极细进度条，正文不出现“等待翻译…”占位词
      expect(
        find.byKey(const Key('reader_bilingual_progress_strip')),
        findsOneWidget,
      );
      expect(find.textContaining('逐句翻译中 · 0/2 句'), findsOneWidget);
      final earlyWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final earlyRendered =
          earlyWidget.textSpan?.toPlainText() ?? earlyWidget.data ?? '';
      expect(earlyRendered, contains('First sentence of Animal Farm.'));
      expect(earlyRendered, contains('Second sentence with Mrs. Jones snoring.'));
      expect(earlyRendered, isNot(contains('等待翻译')));

      // 第 1 句完成后，第 1 句立刻变为“译文在上、原文在下”，第 2 句仍干净显示英文原文
      await tester.pump(const Duration(milliseconds: 70));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      expect(find.textContaining('逐句翻译中 · 1/2 句'), findsOneWidget);
      final midWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final midRendered =
          midWidget.textSpan?.toPlainText() ?? midWidget.data ?? '';
      expect(midRendered, contains('[译]First sentence of Animal Farm.'));
      expect(
        midRendered.indexOf('[译]First sentence of Animal Farm.'),
        lessThan(midRendered.indexOf('First sentence of Animal Farm.')),
      );
      expect(midRendered, isNot(contains('[译]Second sentence')));
      expect(midRendered, contains('Second sentence with Mrs. Jones snoring.'));

      // 全部译完后进度条自动消失，两句在同段内无缝衔接呈逐行紧贴交错结构
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('reader_bilingual_progress_strip')),
        findsNothing,
      );
      final doneWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final doneRendered =
          doneWidget.textSpan?.toPlainText() ?? doneWidget.data ?? '';
      expect(
        doneRendered,
        allOf(
          contains('[译]Second sentence with Mrs. Jones'),
          contains('Second sentence with Mrs. Jones'),
          contains('snoring.'),
        ),
      );
      expect(
        doneRendered.indexOf('[译]Second sentence with Mrs. Jones'),
        lessThan(doneRendered.indexOf('Second sentence with Mrs. Jones')),
      );
    });

    testWidgets('highlights Chinese primary lines when speakTranslated is true and English subtitles when false',
        (tester) async {
      final tmpLib = Directory.systemTemp.createTempSync('echo_mt_tts_ui_');
      final tmpAudio = Directory.systemTemp.createTempSync('echo_mt_tts_wav_');
      addTearDown(() {
        if (tmpLib.existsSync()) tmpLib.deleteSync(recursive: true);
        if (tmpAudio.existsSync()) tmpAudio.deleteSync(recursive: true);
      });

      const chapterText =
          'Alice was beginning to get very tired. Suddenly a White Rabbit ran close by her.';
      final libStore = LocalLibraryStore(rootDir: tmpLib);
      final book = (await tester.runAsync(
        () => libStore.importBytes(
          Uint8List.fromList(utf8.encode(chapterText)),
          filename: 'alice_interlinear.txt',
        ),
      ))!;
      final chapters = (await tester.runAsync(
        () => libStore.listChapters(book.id),
      ))!;
      final segs = splitChapterSentences(chapters.first.text);
      expect(segs.length, 2);

      const zh0 = '爱丽丝开始感到非常疲倦，觉得无聊极了。';
      const zh1 = '突然一只长着粉红眼睛的白兔从她身边跑过。';

      final cache = MemoryTranslationCacheStore();
      await cache.writeBookPrefs(
        book.id,
        const BookTranslationPrefs(
          displayMode: BilingualDisplayMode.bilingual,
          dismissedForeignPrompt: true,
        ),
      );
      await cache.saveChapterTranslations(
        bookId: book.id,
        chapterIndex: chapters.first.index,
        targetLangCode: TranslationTargetLanguage.zhHans.code,
        modelId: TranslationModelCatalog.modelId125Bit,
        entries: <String, String>{
          segs[0].hash: zh0,
          segs[1].hash: zh1,
        },
      );

      final engine = _FakeTranslationEngine();
      final keepAlive = _FakeKeepAlive();
      final cfgController = StandaloneConfigController(
        MemoryStandaloneConfigStorage(),
        const StandaloneConfig(),
      );
      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_tts_hl');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ForeignBookStubAdapter(chapterText);
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

      final ttsEngine = FakeOnDeviceTtsEngine();
      final audioEngine = FakeAudioEngine();
      addTearDown(audioEngine.dispose);
      addTearDown(ttsEngine.dispose);
      final liveCtrl = LiveTtsPlayerController(
        libraryStore: libStore,
        ttsEngine: ttsEngine,
        audioEngine: audioEngine,
        cacheDirOverride: tmpAudio,
        readConfig: () => cfgController.state,
        resolveActiveModel: () => const ResolvedTtsModelPaths(
          spec: TtsModelCatalog.meloTtsZhEn,
          rootDir: '/tmp',
          modelPath: '/tmp/m.onnx',
          tokensPath: '/tmp/t.txt',
        ),
        loadChapterTranslations: (_, _) async => <String, String>{
          segs[0].hash: zh0,
          segs[1].hash: zh1,
        },
      );

      await tester.runAsync(
        () => liveCtrl.playBookChapter(book, speakTranslated: true),
      );

      final container = ProviderContainer(
        overrides: [
          echoApiProvider.overrideWithValue(api),
          standaloneConfigProvider.overrideWith((_) => cfgController),
          readingStoreProvider.overrideWithValue(MemoryReadingStore()),
          translationCacheStoreProvider.overrideWithValue(cache),
          translationEngineProvider.overrideWithValue(engine),
          translationModelManagerProvider.overrideWith(
            (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
          ),
          translationSchedulerProvider.overrideWith(
            (ref) => TranslationScheduler(
              engine: engine,
              cacheStore: cache,
              readConfig: () => cfgController.state,
              readActiveModelPath: () => '/tmp/fake.gguf',
              keepAlive: keepAlive,
            ),
          ),
          liveTtsPlayerProvider.overrideWith((_) => liveCtrl),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, tokens),
            home: ReaderPageView(book: book),
          ),
        ),
      );
      await tester.pumpAndSettle();

      List<String> highlightedStrings(TextSpan? root) {
        final hits = <String>[];
        void visit(InlineSpan span) {
          if (span is TextSpan) {
            if (span.style?.backgroundColor == tokens.readingHighlight &&
                (span.text ?? '').isNotEmpty) {
              hits.add(span.text!);
            }
            for (final child in span.children ?? const <InlineSpan>[]) {
              visit(child);
            }
          }
        }

        if (root != null) visit(root);
        return hits;
      }

      // 1. 朗读译文时：仅高亮第 1 句对应的中文主行，不高亮英文副标也不误亮第 2 句
      final textWhenZh = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final zhHighlights = highlightedStrings(textWhenZh.textSpan as TextSpan?);
      expect(zhHighlights, isNotEmpty);
      expect(zhHighlights.join(), contains('爱丽丝开始感到非常疲倦'));
      expect(zhHighlights.join(), isNot(contains('Alice was beginning')));
      expect(zhHighlights.join(), isNot(contains('突然一只')));

      // 2. 切换朗读原文时：精确高亮第 1 句对应的英文副标，不再高亮中文主行
      await tester.runAsync(() => liveCtrl.setSpeakTranslated(false));
      await tester.pumpAndSettle();
      final textWhenEn = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final enHighlights = highlightedStrings(textWhenEn.textSpan as TextSpan?);
      expect(enHighlights, isNotEmpty);
      expect(enHighlights.join(' '), contains('Alice was beginning'));
      expect(enHighlights.join(), isNot(contains('爱丽丝')));
      expect(enHighlights.join(), isNot(contains('White Rabbit')));
    });

    testWidgets('bilingual last-page fling and 1-page chapter swipe transition smoothly without deadlock while translating',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      BilingualChapterPaginationCache.instance.clear();
      addTearDown(BilingualChapterPaginationCache.instance.clear);

      final ch0Text = List<String>.generate(
        22,
        (i) =>
            'Chapter one sentence $i describes the bright lantern moving slowly across the courtyard.',
      ).join('\n\n');
      const ch1Text =
          'Second chapter is concise enough to fit cleanly on a single screen.';
      const ch2Text =
          'Third chapter opens immediately when swiping past chapter two.';

      final chaptersJson = <Map<String, dynamic>>[
        <String, dynamic>{
          'index': 0,
          'title': 'Chapter One',
          'chars': ch0Text.length,
          'preview': ch0Text.substring(0, 40),
          'text': ch0Text,
        },
        <String, dynamic>{
          'index': 1,
          'title': 'Chapter Two',
          'chars': ch1Text.length,
          'preview': ch1Text,
          'text': ch1Text,
        },
        <String, dynamic>{
          'index': 2,
          'title': 'Chapter Three',
          'chars': ch2Text.length,
          'preview': ch2Text,
          'text': ch2Text,
        },
      ];

      final cache = MemoryTranslationCacheStore();
      final engine = _FakeTranslationEngine(
        delay: const Duration(milliseconds: 80),
      );
      final keepAlive = _FakeKeepAlive();
      final cfgController = StandaloneConfigController(
        MemoryStandaloneConfigStorage(),
        const StandaloneConfig(),
      );

      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_ch_swipe');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ForeignBookStubAdapter(
          ch0Text,
          chaptersOverride: chaptersJson,
        );
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

      final container = ProviderContainer(
        overrides: [
          echoApiProvider.overrideWithValue(api),
          standaloneConfigProvider.overrideWith((_) => cfgController),
          readingStoreProvider.overrideWithValue(MemoryReadingStore()),
          translationCacheStoreProvider.overrideWithValue(cache),
          translationEngineProvider.overrideWithValue(engine),
          translationModelManagerProvider.overrideWith(
            (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
          ),
          translationSchedulerProvider.overrideWith(
            (ref) => TranslationScheduler(
              engine: engine,
              cacheStore: cache,
              readConfig: () => cfgController.state,
              readActiveModelPath: () => '/tmp/fake.gguf',
              keepAlive: keepAlive,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const book = LibraryBook(
        id: 80,
        title: 'Animal Farm Multi',
        format: 'epub',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, tokens),
            home: const ReaderPageView(book: book),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 开启双语，触发后台逐句翻译
      await tester.tap(find.byKey(const Key('reader_foreign_enable_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));

      // 翻到第一章末页（不等待全部翻译完成）
      for (var step = 0; step < 14; step++) {
        final indicator = tester.widget<Text>(
          find.byKey(const Key('reader_page_indicator')),
        );
        final m = RegExp(r'(\d+)/(\d+)\s*页').firstMatch(indicator.data ?? '');
        if (m != null && m.group(1) == m.group(2)) {
          // 让当前末页正在进行的可见句翻译与防抖重排先完成，避免甩动瞬间末页再分裂
          for (var settle = 0; settle < 5; settle++) {
            await tester.pump(const Duration(milliseconds: 90));
          }
          final recheck = tester.widget<Text>(
            find.byKey(const Key('reader_page_indicator')),
          );
          final rm = RegExp(r'(\d+)/(\d+)\s*页').firstMatch(recheck.data ?? '');
          if (rm != null && rm.group(1) == rm.group(2)) {
            break;
          }
        }
        await tester.drag(
          find.byKey(const Key('reader_pageview')),
          const Offset(-300, 0),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      final lastPageIndicator = tester.widget<Text>(
        find.byKey(const Key('reader_page_indicator')),
      );
      final ch0Match = RegExp(
        r'(\d+)/(\d+)\s*页',
      ).firstMatch(lastPageIndicator.data ?? '');
      expect(ch0Match, isNotNull);
      expect(ch0Match!.group(1), ch0Match.group(2));

      // 翻译仍在进行时在末页快速向左甩动：应立即切换至第二章（不卡死、不阻塞）
      await tester.fling(
        find.byKey(const Key('reader_pageview')),
        const Offset(-180, 0),
        900,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.text('Chapter Two'), findsWidgets);
      final ch1Widget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final ch1Rendered =
          ch1Widget.textSpan?.toPlainText() ?? ch1Widget.data ?? '';
      expect(ch1Rendered, contains('Second chapter is concise'));

      // 第二章仅 1 页（1/1 页）：继续向左甩动应顺利切换到第三章
      await tester.pumpAndSettle();
      expect(find.textContaining('1/1 页'), findsOneWidget);
      await tester.fling(
        find.byKey(const Key('reader_pageview')),
        const Offset(-180, 0),
        900,
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter Three'), findsWidgets);
      final ch2Widget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_0')),
      );
      final ch2Rendered =
          ch2Widget.textSpan?.toPlainText() ?? ch2Widget.data ?? '';
      expect(ch2Rendered, contains('Third chapter opens immediately'));

      // 从第三章首页向右拖过阈值：应回到第二章
      await tester.drag(
        find.byKey(const Key('reader_pageview')),
        const Offset(180, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter Two'), findsWidgets);

      // 等待 ProgressSyncService 的 2s 防抖定时器自然触发并清空
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('translating bottom half of a half-translated page keeps top line on current page and maintains constant viewport height',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      BilingualChapterPaginationCache.instance.clear();
      addTearDown(BilingualChapterPaginationCache.instance.clear);

      final sentences = List<String>.generate(
        12,
        (i) =>
            'Paragraph flow sentence $i describes how the animals gathered silently in the big barn under the yellow lantern light.',
      );
      final chapterText = sentences.join(' ');
      final segs = splitChapterSentences(chapterText);
      expect(segs.length, 12);

      final cache = MemoryTranslationCacheStore();
      await cache.writeBookPrefs(
        81,
        const BookTranslationPrefs(
          displayMode: BilingualDisplayMode.bilingual,
          dismissedForeignPrompt: true,
        ),
      );
      // 预缓存前 7 句，使其刚好跨第 1 页进入第 2 页上半部，而第 2 页下半部为待译英文句
      await cache.saveChapterTranslations(
        bookId: 81,
        chapterIndex: 0,
        targetLangCode: TranslationTargetLanguage.zhHans.code,
        modelId: TranslationModelCatalog.modelId125Bit,
        entries: <String, String>{
          for (var i = 0; i < 7; i++)
            segs[i].hash:
                '第${i + 1}句译文细致描绘了动物们在黄色提灯光束下悄悄走进大谷仓并找好各自位置准备聆听演讲的场景。',
        },
      );

      final engine = _FakeTranslationEngine(
        delay: const Duration(milliseconds: 500),
      );
      final keepAlive = _FakeKeepAlive();
      final cfgController = StandaloneConfigController(
        MemoryStandaloneConfigStorage(),
        const StandaloneConfig(),
      );

      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_half_page');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ForeignBookStubAdapter(chapterText);
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

      final container = ProviderContainer(
        overrides: [
          echoApiProvider.overrideWithValue(api),
          standaloneConfigProvider.overrideWith((_) => cfgController),
          readingStoreProvider.overrideWithValue(MemoryReadingStore()),
          translationCacheStoreProvider.overrideWithValue(cache),
          translationEngineProvider.overrideWithValue(engine),
          translationModelManagerProvider.overrideWith(
            (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
          ),
          translationSchedulerProvider.overrideWith(
            (ref) => TranslationScheduler(
              engine: engine,
              cacheStore: cache,
              readConfig: () => cfgController.state,
              readActiveModelPath: () => '/tmp/fake.gguf',
              keepAlive: keepAlive,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const book = LibraryBook(
        id: 81,
        title: 'Animal Farm Anchor',
        format: 'epub',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, tokens),
            home: const ReaderPageView(book: book),
          ),
        ),
      );
      for (var w = 0;
          w < 20 && find.byKey(const Key('reader_pageview')).evaluate().isEmpty;
          w++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const Key('reader_pageview')), findsOneWidget);

      // 翻到第 2 页（上半部分已有译文，下半部分尚未翻译）
      await tester.drag(
        find.byKey(const Key('reader_pageview')),
        const Offset(-320, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final initialPageIndicator = tester
          .widget<Text>(find.byKey(const Key('reader_page_indicator')))
          .data!;
      expect(initialPageIndicator, contains('2/'));

      final initialPageViewHeight = tester
          .getSize(find.byKey(const Key('reader_pageview')))
          .height;

      final p2InitialText = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_1')),
      );
      final p2InitialPlain =
          p2InitialText.textSpan?.toPlainText() ?? p2InitialText.data ?? '';
      final topZhPrefix = p2InitialPlain.split('\n').first;
      expect(topZhPrefix, isNotEmpty);
      expect(p2InitialPlain, contains('sentence'));
      expect(p2InitialPlain, isNot(contains('[译]')));

      // 逐步等待第 2 页下半部分全部翻译完成，检查不跳页、顶行不被推回上一页、视口高度零跳变
      for (var step = 0; step < 8; step++) {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();

        final indicator = tester
            .widget<Text>(find.byKey(const Key('reader_page_indicator')))
            .data!;
        expect(indicator, startsWith('第 1/1 章 · 2/'));
        expect(
          tester.getSize(find.byKey(const Key('reader_pageview'))).height,
          initialPageViewHeight,
        );

        final p2StepWidget = tester.widget<Text>(
          find.byKey(const Key('reader_page_text_1')),
        );
        final p2StepPlain =
            p2StepWidget.textSpan?.toPlainText() ?? p2StepWidget.data ?? '';
        expect(p2StepPlain.split('\n').first, topZhPrefix);
      }

      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('reader_bilingual_progress_strip')),
        findsNothing,
      );
      expect(
        tester.getSize(find.byKey(const Key('reader_pageview'))).height,
        initialPageViewHeight,
      );
      final finalIndicator = tester
          .widget<Text>(find.byKey(const Key('reader_page_indicator')))
          .data!;
      expect(finalIndicator, startsWith('第 1/1 章 · 2/'));

      final p2FinalWidget = tester.widget<Text>(
        find.byKey(const Key('reader_page_text_1')),
      );
      final p2FinalPlain =
          p2FinalWidget.textSpan?.toPlainText() ?? p2FinalWidget.data ?? '';
      expect(p2FinalPlain.split('\n').first, topZhPrefix);
      expect(p2FinalPlain, contains('[译]'));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('bilingual ReaderPageView highlights only exact selected Chinese phrase or English subtitle word',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      BilingualChapterPaginationCache.instance.clear();
      addTearDown(BilingualChapterPaginationCache.instance.clear);

      const chapterText =
          'Old Major was so highly regarded on the Manor Farm that everyone was ready to hear him speak.';
      final segs = splitChapterSentences(chapterText);
      expect(segs.length, 1);
      const zhText = '老少校，在庄园农场里享有极高的声望，以至于大家都愿意认真聆听他的讲话。';

      final cache = MemoryTranslationCacheStore();
      await cache.writeBookPrefs(
        82,
        const BookTranslationPrefs(
          displayMode: BilingualDisplayMode.bilingual,
          dismissedForeignPrompt: true,
        ),
      );
      await cache.saveChapterTranslations(
        bookId: 82,
        chapterIndex: 0,
        targetLangCode: TranslationTargetLanguage.zhHans.code,
        modelId: TranslationModelCatalog.modelId125Bit,
        entries: <String, String>{segs.first.hash: zhText},
      );

      final annotationStore = MemoryReadingAnnotationStore();
      final engine = _FakeTranslationEngine();
      final keepAlive = _FakeKeepAlive();
      final cfgController = StandaloneConfigController(
        MemoryStandaloneConfigStorage(),
        const StandaloneConfig(),
      );

      final tokenStore = MemoryTokenStore();
      await tokenStore.write('echo_pat_bi_hl');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
        ..httpClientAdapter = _ForeignBookStubAdapter(chapterText);
      final api = EchoApi(dio: dio, tokenStore: tokenStore);
      final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

      final container = ProviderContainer(
        overrides: [
          echoApiProvider.overrideWithValue(api),
          standaloneConfigProvider.overrideWith((_) => cfgController),
          readingStoreProvider.overrideWithValue(MemoryReadingStore()),
          readingAnnotationStoreProvider.overrideWithValue(annotationStore),
          translationCacheStoreProvider.overrideWithValue(cache),
          translationEngineProvider.overrideWithValue(engine),
          translationModelManagerProvider.overrideWith(
            (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
          ),
          translationSchedulerProvider.overrideWith(
            (ref) => TranslationScheduler(
              engine: engine,
              cacheStore: cache,
              readConfig: () => cfgController.state,
              readActiveModelPath: () => '/tmp/fake.gguf',
              keepAlive: keepAlive,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const book = LibraryBook(
        id: 82,
        title: 'Animal Farm Highlight',
        format: 'epub',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, tokens),
            home: const ReaderPageView(book: book),
          ),
        ),
      );
      await tester.pumpAndSettle();

      List<String> underlinedStrings() {
        final rich = tester.widget<Text>(
          find.byKey(const Key('reader_page_text_0')),
        );
        final hits = <String>[];
        void visit(InlineSpan span) {
          if (span is TextSpan) {
            if (span.style?.decoration == TextDecoration.underline &&
                (span.text ?? '').isNotEmpty) {
              hits.add(span.text!);
            }
            for (final child in span.children ?? const <InlineSpan>[]) {
              visit(child);
            }
          }
        }

        if (rich.textSpan != null) visit(rich.textSpan!);
        return hits;
      }

      List<String> companionHighlightedStrings() {
        final rich = tester.widget<Text>(
          find.byKey(const Key('reader_page_text_0')),
        );
        final hits = <String>[];
        void visit(InlineSpan span) {
          if (span is TextSpan) {
            if (span.style?.decoration != TextDecoration.underline &&
                span.style?.backgroundColor != null &&
                (span.text ?? '').isNotEmpty) {
              hits.add(span.text!);
            }
            for (final child in span.children ?? const <InlineSpan>[]) {
              visit(child);
            }
          }
        }

        if (rich.textSpan != null) visit(rich.textSpan!);
        return hits;
      }

      // 通过页面 RenderParagraph 实测坐标，真实模拟长按拖选“庄园农场”四个字并点划线
      final pageTextFinder = find.byKey(const Key('reader_page_text_0'));
      final renderParagraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: pageTextFinder, matching: find.byType(RichText)),
      );
      final plainText = renderParagraph.text.toPlainText();
      final zhTargetStart = plainText.indexOf('庄园农场');
      expect(zhTargetStart, greaterThanOrEqualTo(0));
      final zhStartBox = renderParagraph
          .getBoxesForSelection(
            TextSelection(
              baseOffset: zhTargetStart,
              extentOffset: zhTargetStart + 1,
            ),
          )
          .first;
      final zhEndBox = renderParagraph
          .getBoxesForSelection(
            TextSelection(
              baseOffset: zhTargetStart + 3,
              extentOffset: zhTargetStart + 4,
            ),
          )
          .first;

      final gesture = await tester.startGesture(
        renderParagraph.localToGlobal(zhStartBox.toRect().center),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await gesture.moveTo(
        renderParagraph.localToGlobal(zhEndBox.toRect().center),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('selection_action_highlight')), findsOneWidget);
      await tester.tap(find.byKey(const Key('selection_action_highlight')));
      await tester.pumpAndSettle();

      final zhSaved = await annotationStore.listForBook(82);
      expect(zhSaved.length, 1);
      expect(zhSaved.first.target, ReadingAnnotationTarget.translation);
      expect(zhSaved.first.quote, contains('庄园农场'));
      final zhUnderlines = underlinedStrings();
      expect(zhUnderlines.join(), contains('庄园农场'));
      // 严禁把同句其他未选中文字画上线，同时对应英文副标采用无下划线的伴随柔和高亮
      expect(zhUnderlines.join(), zhSaved.first.quote);
      expect(zhUnderlines.join(), isNot(contains('老少校')));
      expect(zhUnderlines.join(), isNot(contains('声望')));
      expect(zhUnderlines.join(), isNot(contains('讲话')));
      expect(zhUnderlines.join(), isNot(contains('Manor')));
      final companionAfterZh = companionHighlightedStrings()
          .join()
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(companionAfterZh, contains('Manor'));

      // 再长按英文副标中的单词“Manor”并点划线：主下划线应精准落到 Manor（覆盖伴随底色），绝不亮上方中文
      final manorIdx = plainText.indexOf('Manor');
      expect(manorIdx, greaterThanOrEqualTo(0));
      final manorBox = renderParagraph
          .getBoxesForSelection(
            TextSelection(baseOffset: manorIdx, extentOffset: manorIdx + 5),
          )
          .first;
      await tester.longPressAt(
        renderParagraph.localToGlobal(manorBox.toRect().center),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selection_action_highlight')), findsOneWidget);
      await tester.tap(find.byKey(const Key('selection_action_highlight')));
      await tester.pumpAndSettle();

      final bothSaved = await annotationStore.listForBook(82);
      expect(bothSaved.length, 2);
      final enSaved = bothSaved.firstWhere(
        (a) => a.target == ReadingAnnotationTarget.original,
      );
      expect(enSaved.quote, 'Manor');

      final allUnderlines = underlinedStrings();
      expect(allUnderlines, contains('Manor'));
      expect(allUnderlines.join(), isNot(contains('Old Major')));
      expect(allUnderlines.join(), isNot(contains('老少校')));
      expect(allUnderlines.join(), isNot(contains('讲话')));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('bilingual phrase alignment highlights only aligned English phrase, opens editor on tap, and auto-aligns pre-saved highlights',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      BilingualChapterPaginationCache.instance.clear();
      addTearDown(BilingualChapterPaginationCache.instance.clear);

      const chapterText =
          'Old Major was so highly regarded on the Manor Farm that everyone was ready to hear him speak.\n\n'
          'Everyone respected the old boar and listened quietly.';
      final segs = splitChapterSentences(chapterText);
      expect(segs.length, 2);
      const zh0 = '老少校，在庄园农场里享有极高的声望，以至于大家都愿意认真聆听他的讲话。';
      const zh1 = '所有动物都很敬重这头老猪，安静地听着。';

      Future<void> runScenario({required bool preloadAnnotation}) async {
        BilingualChapterPaginationCache.instance.clear();
        final cache = MemoryTranslationCacheStore();
        final bookId = preloadAnnotation ? 84 : 83;
        await cache.writeBookPrefs(
          bookId,
          const BookTranslationPrefs(
            displayMode: BilingualDisplayMode.bilingual,
            dismissedForeignPrompt: true,
          ),
        );
        await cache.saveChapterTranslations(
          bookId: bookId,
          chapterIndex: 0,
          targetLangCode: TranslationTargetLanguage.zhHans.code,
          modelId: TranslationModelCatalog.modelId125Bit,
          entries: <String, String>{
            segs[0].hash: zh0,
            segs[1].hash: zh1,
          },
        );

        final annotationStore = MemoryReadingAnnotationStore();
        if (preloadAnnotation) {
          final startInZh0 = zh0.indexOf('在庄园农场里');
          final now = DateTime.utc(2026, 11, 27, 14, 0);
          await annotationStore.upsert(
            ReadingAnnotation(
              id: 'pre_zh_1',
              bookId: bookId,
              chapterIndex: 0,
              startOffset: segs[0].startChar,
              endOffset: segs[0].endChar,
              quote: '在庄园农场里',
              target: ReadingAnnotationTarget.translation,
              transStartInFirst: startInZh0,
              transEndInLast: startInZh0 + '在庄园农场里'.length,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        final engine = _FakeTranslationEngine(
          responder: (prompt) {
            if (prompt.contains('庄园农场')) {
              return 'on the Manor Farm';
            }
            return 'Old Major was revered on the Manor Farm';
          },
        );
        final keepAlive = _FakeKeepAlive();
        final cfgController = StandaloneConfigController(
          MemoryStandaloneConfigStorage(),
          const StandaloneConfig(),
        );
        final tokenStore = MemoryTokenStore();
        await tokenStore.write('echo_pat_bi_align');
        final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
          ..httpClientAdapter = _ForeignBookStubAdapter(chapterText);
        final api = EchoApi(dio: dio, tokenStore: tokenStore);
        final tokens = EchoTokens.fromColors(darkColors, Brightness.dark);

        final container = ProviderContainer(
          overrides: [
            echoApiProvider.overrideWithValue(api),
            standaloneConfigProvider.overrideWith((_) => cfgController),
            readingStoreProvider.overrideWithValue(MemoryReadingStore()),
            readingAnnotationStoreProvider.overrideWithValue(annotationStore),
            translationCacheStoreProvider.overrideWithValue(cache),
            translationEngineProvider.overrideWithValue(engine),
            translationModelManagerProvider.overrideWith(
              (_) => _StubTranslationModelManager(cfgController, '/tmp/fake.gguf'),
            ),
            translationSchedulerProvider.overrideWith(
              (ref) => TranslationScheduler(
                engine: engine,
                cacheStore: cache,
                readConfig: () => cfgController.state,
                readActiveModelPath: () => '/tmp/fake.gguf',
                keepAlive: keepAlive,
              ),
            ),
          ],
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            key: ValueKey<int>(bookId),
            container: container,
            child: MaterialApp(
              theme: buildEchoTheme(Brightness.dark, tokens),
              home: ReaderPageView(
                key: ValueKey<int>(bookId),
                book: LibraryBook(
                  id: bookId,
                  title: 'Aligned Bilingual Book $bookId',
                  format: 'epub',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        List<String> companionStrings() {
          final rich = tester.widget<Text>(
            find.byKey(const Key('reader_page_text_0')),
          );
          final hits = <String>[];
          void visit(InlineSpan span) {
            if (span is TextSpan) {
              if (span.style?.decoration != TextDecoration.underline &&
                  span.style?.backgroundColor != null &&
                  (span.text ?? '').isNotEmpty) {
                hits.add(span.text!);
              }
              for (final child in span.children ?? const <InlineSpan>[]) {
                visit(child);
              }
            }
          }

          if (rich.textSpan != null) visit(rich.textSpan!);
          return hits;
        }

        final pageTextFinder = find.byKey(const Key('reader_page_text_0'));
        final renderParagraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: pageTextFinder, matching: find.byType(RichText)),
        );
        final plainText = renderParagraph.text.toPlainText();

        if (!preloadAnnotation) {
          final zhTargetStart = plainText.indexOf('在庄园农场里');
          expect(zhTargetStart, greaterThanOrEqualTo(0));
          final zhStartBox = renderParagraph
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: zhTargetStart,
                  extentOffset: zhTargetStart + 1,
                ),
              )
              .first;
          final zhEndBox = renderParagraph
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: zhTargetStart + '在庄园农场里'.length - 1,
                  extentOffset: zhTargetStart + '在庄园农场里'.length,
                ),
              )
              .first;
          final gesture = await tester.startGesture(
            renderParagraph.localToGlobal(zhStartBox.toRect().center),
          );
          await tester.pump(const Duration(milliseconds: 650));
          await gesture.moveTo(
            renderParagraph.localToGlobal(zhEndBox.toRect().center),
          );
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('selection_action_highlight')));
          await tester.pumpAndSettle();
        }

        final saved = await annotationStore.listForBook(bookId);
        expect(saved.length, 1);
        expect(saved.first.hasAlignedOrigRange, isTrue);
        final expectedSub = chapterText.substring(
          saved.first.alignedOrigStart!,
          saved.first.alignedOrigEnd!,
        );
        expect(expectedSub, 'on the Manor Farm');

        final companionText = companionStrings()
            .join()
            .replaceAll(RegExp(r'\s+'), ' ');
        expect(companionText, contains('on the Manor Farm'));
        expect(companionText, isNot(contains('Old Major')));
        expect(companionText, isNot(contains('everyone')));
        expect(companionText, isNot(contains('respected')));

        // 点击高亮后的对应英文副标，应可直接弹出批注编辑抽屉
        final freshParagraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(const Key('reader_page_text_0')),
            matching: find.byType(RichText),
          ),
        );
        final farmIdx = freshParagraph.text.toPlainText().indexOf('Farm');
        expect(farmIdx, greaterThanOrEqualTo(0));
        final farmGlyphBox = freshParagraph
            .getBoxesForSelection(
              TextSelection(baseOffset: farmIdx, extentOffset: farmIdx + 1),
            )
            .first;
        await tester.tapAt(
          freshParagraph.localToGlobal(farmGlyphBox.toRect().center),
        );
        await tester.pumpAndSettle();
        expect(find.text('编辑笔记与划线'), findsOneWidget);
        expect(find.byKey(const Key('annotation_note_input')), findsOneWidget);

        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        container.dispose();
      }

      await runScenario(preloadAnnotation: false);
      await runScenario(preloadAnnotation: true);
    });
  });
}
