import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/audio/live_tts_player_controller.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/tts/sherpa_tts_engine.dart';
import 'package:echo/core/tts/tts_model_catalog.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LiveTtsPlayerController', () {
    late Directory tempRoot;
    late Directory cacheDir;
    late LocalLibraryStore libraryStore;
    late FakeOnDeviceTtsEngine ttsEngine;
    late FakeAudioEngine audioEngine;

    const fakeModelPaths = ResolvedTtsModelPaths(
      spec: TtsModelCatalog.kokoroZhV11,
      rootDir: '/tmp/fake_kokoro',
      modelPath: '/tmp/fake_kokoro/model.int8.onnx',
      tokensPath: '/tmp/fake_kokoro/tokens.txt',
      voicesPath: '/tmp/fake_kokoro/voices.bin',
    );

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('echo_live_tts_lib_');
      cacheDir = await Directory.systemTemp.createTemp('echo_live_tts_cache_');
      libraryStore = LocalLibraryStore(rootDir: tempRoot);
      ttsEngine = FakeOnDeviceTtsEngine();
      audioEngine = FakeAudioEngine();
    });

    tearDown(() async {
      await audioEngine.dispose();
      await ttsEngine.dispose();
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
    });

    test('synthesizes, prefetches upcoming sentences, and advances on completion', () async {
      const sampleTxt =
          '第一章 启程\n\n第一句非常清晰的中文测试内容在这里。第二句紧接着出现用于测试预合成。第三句用于测试自动推进播放。\n\n第二章 抵达\n\n这是第二章的第一句话。';
      final book = await libraryStore.importBytes(
        Uint8List.fromList(utf8.encode(sampleTxt)),
        filename: 'journey.txt',
      );

      final controller = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: ttsEngine,
        audioEngine: audioEngine,
        resolveActiveModel: () => fakeModelPaths,
        readConfig: () => const StandaloneConfig(
          activeTtsModelId: 'kokoro-int8-multi-lang-v1_1',
          activeTtsSpeakerId: 45,
          defaultTtsSpeed: 1.0,
        ),
        cacheDirOverride: cacheDir,
      );
      addTearDown(controller.dispose);

      await controller.playBookChapter(book, chapterIndex: 0);
      expect(controller.state.hasBook, isTrue);
      expect(controller.state.isPlaying, isTrue);
      expect(controller.state.sentenceIndex, 0);
      expect(controller.state.currentCueText, contains('启程'));
      expect(ttsEngine.loadedModelId, 'kokoro-int8-multi-lang-v1_1');

      // 等待后台预合成完成
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ttsEngine.synthesizedTexts.length, greaterThanOrEqualTo(2));

      // 模拟当前句播放完毕 -> 自动切到下一句
      audioEngine.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state.sentenceIndex, 1);

      // 锁屏快进 -> 跳到下一句
      audioEngine.emitFastForward();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state.sentenceIndex, 2);

      // 下一章
      await controller.nextChapter();
      expect(controller.state.chapterIndex, 1);
      expect(controller.state.currentCueText, contains('抵达'));

      // 清理临时缓存
      final freed = await controller.clearTempCache();
      expect(freed, greaterThan(0));
      expect(await controller.tempCacheBytes(), 0);
    });

    test('starts from first sentence of visible page rather than previous page tail when boundary aligns', () async {
      const sampleTxt =
          '第一章 启程\n\n  第一页前句内容在这里结束。\n\n第二页第一句话从这里开始朗读。第二页第二句紧随其后。';
      final book = await libraryStore.importBytes(
        Uint8List.fromList(utf8.encode(sampleTxt)),
        filename: 'align.txt',
      );
      final chapters = await libraryStore.listChapters(book.id);
      final rawText = chapters.first.text;
      final p2Offset = rawText.indexOf('第二页第一句话');
      expect(p2Offset, greaterThan(0));

      final controller = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: ttsEngine,
        audioEngine: audioEngine,
        resolveActiveModel: () => fakeModelPaths,
        readConfig: () => const StandaloneConfig(
          activeTtsModelId: 'kokoro-int8-multi-lang-v1_1',
          activeTtsSpeakerId: 45,
          defaultTtsSpeed: 1.0,
        ),
        cacheDirOverride: cacheDir,
      );
      addTearDown(controller.dispose);

      // 传上一句紧邻的 endOffset（模拟上一页恰好在句号换行处翻页）
      final prevEndOffset = rawText.indexOf('。', rawText.indexOf('第一页前句')) + 1;
      await controller.playBookChapter(
        book,
        chapterIndex: 0,
        startCharOffset: prevEndOffset,
      );
      expect(controller.state.currentCueText, contains('第二页第一句话'));
      expect(controller.state.currentCueText, isNot(contains('第一页前句')));

      // 再直接传第二页首字偏移验证同一结果
      await controller.playBookChapter(
        book,
        chapterIndex: 0,
        startCharOffset: p2Offset,
      );
      expect(controller.state.currentCueText, contains('第二页第一句话'));
    });

    test('reports friendly error when no TTS model is installed', () async {
      final book = await libraryStore.importBytes(
        Uint8List.fromList(utf8.encode('第一章\n这是一段正文内容用于朗读测试。')),
        filename: 'empty_model.txt',
      );
      final controller = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: ttsEngine,
        audioEngine: audioEngine,
        resolveActiveModel: () => null,
        readConfig: () => const StandaloneConfig(),
        cacheDirOverride: cacheDir,
      );
      addTearDown(controller.dispose);

      await controller.playBookChapter(book);
      expect(controller.state.error, contains('语音模型'));
      expect(controller.state.isPlaying, isFalse);
    });
  });
}
