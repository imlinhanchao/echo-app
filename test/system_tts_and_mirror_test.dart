import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:echo/core/api/ebook_api_client.dart';
import 'package:echo/core/api/provider_token_store.dart';
import 'package:echo/core/api/standalone_echo_api.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/audio/live_tts_player_controller.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/offline/offline_store.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/tts/audio_encoder_service.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/tts/local_convert_service.dart';
import 'package:echo/core/tts/sherpa_tts_engine.dart';
import 'package:echo/core/tts/system_tts_engine.dart';
import 'package:echo/core/tts/tts_model_catalog.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/tts/tts_model_manager_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'tokens_fixtures.dart';

void main() {
  group('Android System TTS & HybridOnDeviceTtsEngine', () {
    late Directory rootDir;
    late Directory libDir;
    late Directory offlineDir;
    late Directory workDir;
    late Directory cacheDir;
    late FakeSystemTtsBridge fakeBridge;

    setUp(() async {
      rootDir = await Directory.systemTemp.createTemp('echo_sys_tts_root_');
      libDir = await Directory.systemTemp.createTemp('echo_sys_tts_lib_');
      offlineDir = await Directory.systemTemp.createTemp('echo_sys_tts_off_');
      workDir = await Directory.systemTemp.createTemp('echo_sys_tts_work_');
      cacheDir = await Directory.systemTemp.createTemp('echo_sys_tts_cache_');
      OfflineFiles.setRootForTest(offlineDir);
      fakeBridge = FakeSystemTtsBridge(isSupported: true);
    });

    tearDown(() async {
      OfflineFiles.setRootForTest(null);
      for (final d in <Directory>[rootDir, libDir, offlineDir, workDir, cacheDir]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
    });

    test('支持系统引擎实时边听边看、切换引擎防串音缓存，以及离线转有声书', () async {
      final storage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(onboardingCompleted: true),
      );
      final configCtrl = StandaloneConfigController(
        storage,
        const StandaloneConfig(onboardingCompleted: true),
      );
      final manager = TtsModelManager(
        configCtrl,
        rootDirOverride: rootDir,
        keepAliveService: const NoopDownloadKeepAliveService(),
        systemTtsBridge: fakeBridge,
      );
      addTearDown(manager.dispose);
      await manager.refresh();

      // Android 设备下系统语音自动就绪且设为默认（无已装离线模型时）
      final sysEntry = manager.currentState.entryOf(
        TtsModelCatalog.androidSystemTts.id,
      )!;
      expect(sysEntry.isInstalled, isTrue);
      expect(
        configCtrl.state.activeTtsModelId,
        TtsModelCatalog.androidSystemTts.id,
      );
      expect(manager.currentState.systemEngines, hasLength(2));

      // 选择 MultiTTS 与对应音色
      await manager.selectSystemTtsEngine('org.nobody.multitts');
      expect(manager.currentState.systemVoices.single.name, 'multitts-xiaoxiao');
      await manager.selectSystemTtsVoice('multitts-xiaoxiao');

      final libraryStore = LocalLibraryStore(rootDir: libDir);
      final book = await libraryStore.importBytes(
        Uint8List.fromList(
          utf8.encode('第一章 初遇\n\n第一句系统语音朗读测试开始。第二句紧接出现。'),
        ),
        filename: 'sys_tts.txt',
      );

      final hybrid = HybridOnDeviceTtsEngine(
        sherpaEngine: FakeOnDeviceTtsEngine(),
        systemEngine: AndroidSystemTtsEngine(fakeBridge, tempDirOverride: workDir),
      );
      addTearDown(hybrid.dispose);

      final audioEngine = FakeAudioEngine();
      addTearDown(audioEngine.dispose);

      final liveCtrl = LiveTtsPlayerController(
        libraryStore: libraryStore,
        ttsEngine: hybrid,
        audioEngine: audioEngine,
        resolveActiveModel: () => manager.activeModelPaths,
        readConfig: () => configCtrl.state,
        cacheDirOverride: cacheDir,
      );
      addTearDown(liveCtrl.dispose);

      await liveCtrl.playBookChapter(book);
      expect(liveCtrl.state.isPlaying, isTrue);
      final multittsTag = liveCtrl.state.modelVariantTag;
      expect(multittsTag, isNotEmpty);
      expect(fakeBridge.synthesizedCalls.first.engine, 'org.nobody.multitts');
      expect(fakeBridge.synthesizedCalls.first.voice, 'multitts-xiaoxiao');

      // 切换系统引擎后 variantTag 变化，不会误命中旧引擎缓存 WAV
      await manager.selectSystemTtsEngine('com.google.android.tts');
      await liveCtrl.playBookChapter(book);
      expect(liveCtrl.state.modelVariantTag, isNot(multittsTag));
      expect(
        fakeBridge.synthesizedCalls.last.engine,
        'com.google.android.tts',
      );

      // 离线转有声书（StandaloneEchoApi + LocalConvertService + 系统 TTS）
      final api = StandaloneEchoApi(
        libraryStore: libraryStore,
        readEbookApi: () => EbookApiClient(baseUrl: 'http://127.0.0.1:8091'),
        tokenStore: MemoryProviderTokenStore(),
        ttsModelManager: manager,
        convertService: LocalConvertService(
          libraryStore: libraryStore,
          ttsEngine: hybrid,
          encoderService: const PlatformAudioEncoderService(),
          workDirOverride: workDir,
        ),
        readConfig: () => configCtrl.state,
      );
      final modelsResp = await api.ttsModels();
      expect(
        modelsResp.models.any((m) => m.id == TtsModelCatalog.androidSystemTts.id),
        isTrue,
      );
      final voices = await api.ttsVoices(TtsModelCatalog.androidSystemTts.id);
      expect(voices.first.id, 'zh-cn-x-zhe-local');

      final job = await api.createAudiobook(
        bookId: book.id,
        model: TtsModelCatalog.androidSystemTts.id,
        voice: 'zh-cn-x-zhe-local',
      );
      for (var i = 0; i < 40; i++) {
        final list = await api.listJobs();
        final cur = list.jobs.firstWhere((j) => j.id == job.id);
        if (cur.status.name == 'done') break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      final doneJob = (await api.listJobs()).jobs.firstWhere(
        (j) => j.id == job.id,
      );
      expect(doneJob.status.name, 'done');
    });
  });

  group('TtsModelManagerPage 镜像下拉框、旧模型清理与系统语音 UI', () {
    testWidgets('支持下拉切换严格镜像/保存自定义前缀、清理 Kokoro/Piper 残留与切换 MultiTTS', (
      tester,
    ) async {
      final rootDir = await Directory.systemTemp.createTemp('echo_mgr_ui_');
      addTearDown(() async {
        if (await rootDir.exists()) await rootDir.delete(recursive: true);
      });

      // 写入已下架的 Piper 残留目录
      final oldPiper = File(
        p.join(rootDir.path, 'vits-piper-zh_CN-huayan-medium', 'model.onnx'),
      );
      await oldPiper.parent.create(recursive: true);
      await oldPiper.writeAsBytes(List<int>.filled(2048, 7));

      final storage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(onboardingCompleted: true),
      );
      StandaloneConfigStore.setForTest(
        const StandaloneConfig(onboardingCompleted: true),
        storage: storage,
      );
      final fakeBridge = FakeSystemTtsBridge(isSupported: true);

      final theme = buildEchoTheme(
        Brightness.dark,
        EchoTokens.fromColors(darkColors, Brightness.dark),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            standaloneConfigStorageProvider.overrideWithValue(storage),
            systemTtsBridgeProvider.overrideWithValue(fakeBridge),
            ttsModelManagerProvider.overrideWith(
              (ref) => TtsModelManager(
                ref.read(standaloneConfigProvider.notifier),
                rootDirOverride: rootDir,
                keepAliveService: const NoopDownloadKeepAliveService(),
                systemTtsBridge: fakeBridge,
              ),
            ),
          ],
          child: MaterialApp(
            theme: theme,
            home: const TtsModelManagerPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 下架旧模型清理卡片展示并可一键清理
      expect(find.byKey(const Key('tts_legacy_cleanup_card')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tts_legacy_cleanup_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tts_legacy_cleanup_card')), findsNothing);
      expect(oldPiper.parent.existsSync(), isFalse);

      // 2. 镜像下拉框切换为自定义前缀，并保存合法前缀
      await tester.tap(find.byKey(const Key('tts_mirror_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义加速前缀').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tts_custom_mirror_field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('tts_custom_mirror_field')),
        'https://mirror.myhome.lan',
      );
      await tester.tap(find.byKey(const Key('tts_custom_mirror_save')));
      await tester.pumpAndSettle();

      final savedAfterMirror = await storage.read();
      expect(savedAfterMirror.ttsDownloadMirror, TtsModelCatalog.mirrorCustom);
      expect(
        savedAfterMirror.customTtsMirrorPrefix,
        'https://mirror.myhome.lan',
      );

      // 3. 系统语音卡片允许切换为 MultiTTS 引擎
      final sysEngFinder = find.byKey(const Key('tts_system_engine_dropdown'));
      await tester.ensureVisible(sysEngFinder);
      await tester.pumpAndSettle();
      await tester.tap(sysEngFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('MultiTTS').last);
      await tester.pumpAndSettle();

      final savedAfterSys = await storage.read();
      expect(savedAfterSys.systemTtsEngine, 'org.nobody.multitts');
      expect(
        savedAfterSys.activeTtsModelId,
        TtsModelCatalog.androidSystemTts.id,
      );
    });
  });
}
