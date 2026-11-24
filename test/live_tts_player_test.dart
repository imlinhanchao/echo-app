import 'dart:async';
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

class _FlickeringFakeAudioEngine extends FakeAudioEngine {
  @override
  Future<void> setSource(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration initialPosition = Duration.zero,
    String? mediaTitle,
    String? mediaArtist,
    Duration? mediaDuration,
    String? mediaArtUrl,
  }) async {
    await pause();
    await Future<void>.delayed(Duration.zero);
    await super.setSource(
      uri,
      headers: headers,
      initialPosition: initialPosition,
      mediaTitle: mediaTitle,
      mediaArtist: mediaArtist,
      mediaDuration: mediaDuration,
      mediaArtUrl: mediaArtUrl,
    );
  }
}

void main() {
  group('LiveTtsPlayerController', () {
    late Directory tempRoot;
    late Directory cacheDir;
    late LocalLibraryStore libraryStore;
    late FakeOnDeviceTtsEngine ttsEngine;
    late FakeAudioEngine audioEngine;

    const fakeModelPaths = ResolvedTtsModelPaths(
      spec: TtsModelCatalog.meloTtsZhEn,
      rootDir: '/tmp/fake_melo',
      modelPath: '/tmp/fake_melo/model.onnx',
      tokensPath: '/tmp/fake_melo/tokens.txt',
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
          activeTtsModelId: 'vits-melo-tts-zh_en',
          activeTtsSpeakerId: 0,
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
      expect(ttsEngine.loadedModelId, 'vits-melo-tts-zh_en');

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
          activeTtsModelId: 'vits-melo-tts-zh_en',
          activeTtsSpeakerId: 0,
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

    test('stop() clears state before stopping engine and ignores late completion events', () async {
      final book = await libraryStore.importBytes(
        Uint8List.fromList(utf8.encode('第一章\n第一句测试朗读。第二句紧接出现。')),
        filename: 'stop_clean.txt',
      );
      final controller = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: ttsEngine,
        audioEngine: audioEngine,
        resolveActiveModel: () => fakeModelPaths,
        readConfig: () => const StandaloneConfig(
          activeTtsModelId: 'vits-melo-tts-zh_en',
          activeTtsSpeakerId: 0,
        ),
        cacheDirOverride: cacheDir,
      );
      addTearDown(controller.dispose);

      await controller.playBookChapter(book, chapterIndex: 0);
      expect(controller.state.hasBook, isTrue);
      expect(controller.state.isPlaying, isTrue);

      await controller.stop();
      expect(audioEngine.stopCount, 1);
      expect(controller.state.hasBook, isFalse);
      expect(controller.state.isPlaying, isFalse);

      // 停止后若底层播放器晚到触发 completed/playing 事件，不应重新唤醒朗读状态
      audioEngine.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.state.hasBook, isFalse);
      expect(controller.state.isPlaying, isFalse);
    });

    test(
      'keeps isPlaying steady across sentence transitions and only pauses on explicit togglePlayPause',
      () async {
        final flickerEngine = _FlickeringFakeAudioEngine();
        addTearDown(flickerEngine.dispose);
        final book = await libraryStore.importBytes(
          Uint8List.fromList(utf8.encode('第一章\n第一句开始朗读。第二句紧密衔接。')),
          filename: 'steady_state.txt',
        );
        final controller = LiveTtsPlayerController(
          libraryStore: libraryStore,
          ttsEngine: ttsEngine,
          audioEngine: flickerEngine,
          resolveActiveModel: () => fakeModelPaths,
          readConfig: () => const StandaloneConfig(
            activeTtsModelId: 'vits-melo-tts-zh_en',
            activeTtsSpeakerId: 0,
          ),
          cacheDirOverride: cacheDir,
        );
        addTearDown(controller.dispose);

        final playingHistory = <bool>[];
        final removeListener = controller.addListener((s) {
          if (s.hasBook) {
            playingHistory.add(s.isPlaying);
          }
        }, fireImmediately: false);
        addTearDown(removeListener);

        await controller.playBookChapter(book, chapterIndex: 0);
        flickerEngine.emitCompleted();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(controller.state.sentenceIndex, 1);
        expect(controller.state.isPlaying, isTrue);
        expect(
          playingHistory.every((v) => v),
          isTrue,
          reason: '切句过渡期间 isPlaying 不应抖动为 false：$playingHistory',
        );

        await controller.togglePlayPause();
        expect(controller.state.isPlaying, isFalse);
        await controller.togglePlayPause();
        expect(controller.state.isPlaying, isTrue);
      },
    );

    test('pausing mid-synthesis stays paused and resumes cleanly', () async {
      final slowTts = FakeOnDeviceTtsEngine(
        syntheticDelay: const Duration(milliseconds: 60),
      );
      addTearDown(slowTts.dispose);
      final book = await libraryStore.importBytes(
        Uint8List.fromList(utf8.encode('第一章\n合成耗时期间测试主动暂停。第二句紧接出现。')),
        filename: 'mid_synth_pause.txt',
      );
      final controller = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: slowTts,
        audioEngine: audioEngine,
        resolveActiveModel: () => fakeModelPaths,
        readConfig: () => const StandaloneConfig(
          activeTtsModelId: 'vits-melo-tts-zh_en',
          activeTtsSpeakerId: 0,
        ),
        cacheDirOverride: cacheDir,
      );
      addTearDown(controller.dispose);

      unawaited(controller.playBookChapter(book, chapterIndex: 0));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.state.isSynthesizing, isTrue);
      expect(controller.state.isPlaying, isTrue);

      await controller.togglePlayPause();
      expect(controller.state.isPlaying, isFalse);
      expect(controller.state.isSynthesizing, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(controller.state.isPlaying, isFalse);
      expect(controller.state.isSynthesizing, isFalse);

      await controller.togglePlayPause();
      expect(controller.state.isPlaying, isTrue);
      expect(controller.state.isSynthesizing, isFalse);
    });

    test('headphone pause and resume mid-sentence updates state cleanly', () async {
      final book = await libraryStore.importBytes(
        Uint8List.fromList(utf8.encode('第一章\n第一句正常播放期间按耳机暂停，再按耳机恢复。')),
        filename: 'headset_mid_sentence.txt',
      );
      final controller = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: ttsEngine,
        audioEngine: audioEngine,
        resolveActiveModel: () => fakeModelPaths,
        readConfig: () => const StandaloneConfig(
          activeTtsModelId: 'vits-melo-tts-zh_en',
          activeTtsSpeakerId: 0,
        ),
        cacheDirOverride: cacheDir,
      );
      addTearDown(controller.dispose);

      await controller.playBookChapter(book, chapterIndex: 0);
      expect(controller.state.isPlaying, isTrue);
      expect(controller.state.isSynthesizing, isFalse);

      // 模拟耳机按键暂停（仅作用于底层 handler，不经过 UI togglePlayPause）
      await audioEngine.pause();
      audioEngine.emitExternalPause();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.isPlaying, isFalse);

      // 模拟再次按耳机按键恢复播放
      await audioEngine.play();
      audioEngine.emitExternalPlay();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.isPlaying, isTrue);
    });

    test('headphone pause mid-synthesis cancels synthesis and headphone resume re-synthesizes cleanly', () async {
      final slowTts = FakeOnDeviceTtsEngine(
        syntheticDelay: const Duration(milliseconds: 60),
      );
      addTearDown(slowTts.dispose);
      final book = await libraryStore.importBytes(
        Uint8List.fromList(utf8.encode('第一章\n耳机按键测试合成中暂停与恢复朗读。第二句紧接出现。')),
        filename: 'headset_mid_synth.txt',
      );
      final controller = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: slowTts,
        audioEngine: audioEngine,
        resolveActiveModel: () => fakeModelPaths,
        readConfig: () => const StandaloneConfig(
          activeTtsModelId: 'vits-melo-tts-zh_en',
          activeTtsSpeakerId: 0,
        ),
        cacheDirOverride: cacheDir,
      );
      addTearDown(controller.dispose);

      unawaited(controller.playBookChapter(book, chapterIndex: 0));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.state.isSynthesizing, isTrue);
      expect(controller.state.isPlaying, isTrue);

      // 耳机按键在合成尚未结束时暂停
      await audioEngine.pause();
      audioEngine.emitExternalPause();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.isPlaying, isFalse);
      expect(controller.state.isSynthesizing, isFalse);

      // 等待旧合成回调落盘完毕，不应重新自动播放
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(controller.state.isPlaying, isFalse);
      expect(controller.state.isSynthesizing, isFalse);

      // 再次按耳机恢复播放，应触发重新合成并正常进入播放状态
      audioEngine.emitExternalPlay();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(controller.state.isPlaying, isTrue);
      expect(controller.state.isSynthesizing, isFalse);
    });

    test(
      'applies defaultTtsSpeed, updates speed immediately without re-synthesis, persists, and preserves across chapters',
      () async {
        const sampleTxt =
            '第一章 启程\n\n第一句测试实时调速内容。第二句紧接出现用于预合成。\n\n第二章 抵达\n\n这是第二章的测试句子。';
        final book = await libraryStore.importBytes(
          Uint8List.fromList(utf8.encode(sampleTxt)),
          filename: 'speed_control.txt',
        );
        final persistedSpeeds = <double>[];
        final controller = LiveTtsPlayerController(
          libraryStore: libraryStore,
          ttsEngine: ttsEngine,
          audioEngine: audioEngine,
          resolveActiveModel: () => fakeModelPaths,
          readConfig: () => const StandaloneConfig(
            activeTtsModelId: 'vits-melo-tts-zh_en',
            activeTtsSpeakerId: 0,
            defaultTtsSpeed: 1.25,
          ),
          onSpeedChanged: (speed) async => persistedSpeeds.add(speed),
          cacheDirOverride: cacheDir,
        );
        addTearDown(controller.dispose);

        await controller.playBookChapter(book, chapterIndex: 0);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(controller.state.speed, 1.25);
        expect(audioEngine.speed, 1.25);
        final cachedFiles = cacheDir.listSync().whereType<File>().toList();
        expect(cachedFiles, isNotEmpty);
        expect(
          cachedFiles.every((f) => f.path.endsWith('_v100.wav')),
          isTrue,
          reason: '缓存 WAV 应统一按 1.0x 生成，由底层播放器实时变速',
        );

        final synthCountBefore = ttsEngine.synthesizedTexts.length;
        await controller.setSpeed(1.5);
        expect(controller.state.speed, 1.5);
        expect(audioEngine.speed, 1.5);
        expect(controller.state.isPlaying, isTrue);
        expect(controller.state.sentenceIndex, 0);
        expect(
          ttsEngine.synthesizedTexts.length,
          synthCountBefore,
          reason: '调速不应中断当前句或清空缓存重新合成',
        );
        expect(persistedSpeeds, <double>[1.5]);

        await controller.setSpeed(9.9);
        expect(controller.state.speed, 2.5);
        expect(audioEngine.speed, 2.5);

        await controller.setSpeed(0.1);
        expect(controller.state.speed, 0.5);
        expect(audioEngine.speed, 0.5);

        await controller.setSpeed(1.75);
        await controller.nextChapter();
        expect(controller.state.chapterIndex, 1);
        expect(controller.state.speed, 1.75);
        expect(audioEngine.speed, 1.75);
      },
    );
  });
}
