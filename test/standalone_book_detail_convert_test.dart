import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:echo/core/api/ebook_api_client.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/api/provider_token_store.dart';
import 'package:echo/core/api/standalone_echo_api.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/audio/live_tts_player_controller.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/core/tts/audio_encoder_service.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/tts/local_convert_service.dart';
import 'package:echo/core/tts/sherpa_tts_engine.dart';
import 'package:echo/core/tts/system_tts_engine.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/library/book_detail_page.dart';
import 'package:echo/features/library/convert_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tokens_fixtures.dart';

void main() {
  group('Standalone BookDetailPage & ConvertSheet', () {
    late Directory libDir;
    late Directory modelsDir;
    late LocalLibraryStore libStore;
    late LibraryBook txtBook;
    late MemoryStandaloneConfigStorage configStorage;
    late TtsModelManager modelManager;
    late StandaloneEchoApi api;

    setUp(() async {
      libDir = await Directory.systemTemp.createTemp('echo_detail_lib_');
      modelsDir = await Directory.systemTemp.createTemp('echo_detail_models_');
      libStore = LocalLibraryStore(rootDir: libDir);
      await libStore.ensureLoaded();
      txtBook = await libStore.importBytes(
        Uint8List.fromList(utf8.encode('第一章 初章\n\n这是 TXT 本地书籍正文内容。')),
        filename: 'story.txt',
      );

      configStorage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(onboardingCompleted: true),
      );
      StandaloneConfigStore.setForTest(
        const StandaloneConfig(onboardingCompleted: true),
        storage: configStorage,
      );
      final configCtrl = StandaloneConfigController(
        configStorage,
        const StandaloneConfig(onboardingCompleted: true),
      );
      modelManager = TtsModelManager(
        configCtrl,
        rootDirOverride: modelsDir,
      );
      await modelManager.refresh();

      final ttsEngine = FakeOnDeviceTtsEngine();
      final convertSvc = LocalConvertService(
        libraryStore: libStore,
        ttsEngine: ttsEngine,
        encoderService: const PlatformAudioEncoderService(),
      );
      api = StandaloneEchoApi(
        libraryStore: libStore,
        readEbookApi: () => EbookApiClient(baseUrl: ''),
        tokenStore: MemoryProviderTokenStore(),
        ttsModelManager: modelManager,
        convertService: convertSvc,
        readConfig: () => const StandaloneConfig(onboardingCompleted: true),
      );
    });

    tearDown(() async {
      if (await libDir.exists()) await libDir.delete(recursive: true);
      if (await modelsDir.exists()) await modelsDir.delete(recursive: true);
    });

    testWidgets(
      'TXT book supports live TTS trigger, reader and convert sheet',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final theme = buildEchoTheme(
          Brightness.dark,
          EchoTokens.fromColors(darkColors, Brightness.dark),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              standaloneConfigStorageProvider.overrideWithValue(configStorage),
              providerTokenStoreProvider.overrideWithValue(
                MemoryProviderTokenStore(),
              ),
              echoApiProvider.overrideWithValue(api),
              localLibraryStoreProvider.overrideWithValue(libStore),
              ttsModelManagerProvider.overrideWith((_) => modelManager),
              audioEngineProvider.overrideWithValue(FakeAudioEngine()),
              onDeviceTtsEngineProvider.overrideWithValue(
                FakeOnDeviceTtsEngine(),
              ),
              progressStoreProvider.overrideWithValue(MemoryProgressStore()),
              readingStoreProvider.overrideWithValue(MemoryReadingStore()),
            ],
            child: MaterialApp(
              theme: theme,
              home: BookDetailPage(book: txtBook),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // TXT 书籍同样展示底部操作栏（转有声书 + 开始阅读）与实时朗读入口
        expect(find.byKey(const Key('detail_bottom_bar')), findsOneWidget);
        expect(find.byKey(const Key('detail_convert')), findsOneWidget);
        expect(find.byKey(const Key('detail_read')), findsOneWidget);
        expect(find.byKey(const Key('detail_live_tts')), findsOneWidget);

        // 无模型时点实时朗读弹出提示并带「去下载模型」入口
        await tester.ensureVisible(find.byKey(const Key('detail_live_tts')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('detail_live_tts')));
        await tester.pumpAndSettle();
        expect(find.text('去下载模型'), findsOneWidget);

        // 打开 ConvertSheet 且无模型时不崩溃，展示下载模型引导
        await tester.tap(find.byKey(const Key('detail_convert')));
        await tester.pumpAndSettle();
        expect(find.byType(ConvertSheet), findsOneWidget);
        expect(find.byKey(const Key('convert_no_local_models')), findsOneWidget);
        expect(
          find.byKey(const Key('convert_goto_models_button')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'tapping detail_live_tts with installed voice enters ReaderPageView and starts live playback',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fakeBridge = FakeSystemTtsBridge(isSupported: true);
        final sysConfigCtrl = StandaloneConfigController(
          configStorage,
          const StandaloneConfig(onboardingCompleted: true),
        );
        final readyManager = await tester.runAsync(() async {
          final m = TtsModelManager(
            sysConfigCtrl,
            rootDirOverride: modelsDir,
            keepAliveService: const NoopDownloadKeepAliveService(),
            systemTtsBridge: fakeBridge,
          );
          await m.refresh();
          return m;
        });

        final theme = buildEchoTheme(
          Brightness.dark,
          EchoTokens.fromColors(darkColors, Brightness.dark),
        );
        final readingStore = MemoryReadingStore();
        final audioEngine = FakeAudioEngine();
        addTearDown(audioEngine.dispose);
        final chunkedAudioEngine = FakeAudioEngine();
        final liveCacheDir = Directory('${modelsDir.path}/live_cache');
        final liveController = LiveTtsPlayerController(
          libraryStore: libStore,
          ttsEngine: FakeOnDeviceTtsEngine(),
          audioEngine: audioEngine,
          resolveActiveModel: () => readyManager!.activeModelPaths,
          readConfig: () => sysConfigCtrl.state,
          readingStore: readingStore,
          cacheDirOverride: liveCacheDir,
        );

        await tester.runAsync(() => libStore.listChapters(txtBook.id));

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              standaloneConfigStorageProvider.overrideWithValue(configStorage),
              providerTokenStoreProvider.overrideWithValue(
                MemoryProviderTokenStore(),
              ),
              echoApiProvider.overrideWithValue(api),
              localLibraryStoreProvider.overrideWithValue(libStore),
              systemTtsBridgeProvider.overrideWithValue(fakeBridge),
              ttsModelManagerProvider.overrideWith((_) => readyManager!),
              audioEngineProvider.overrideWithValue(chunkedAudioEngine),
              onDeviceTtsEngineProvider.overrideWithValue(
                FakeOnDeviceTtsEngine(),
              ),
              liveTtsPlayerProvider.overrideWith((_) => liveController),
              progressStoreProvider.overrideWithValue(MemoryProgressStore()),
              readingStoreProvider.overrideWithValue(readingStore),
            ],
            child: MaterialApp(
              theme: theme,
              home: BookDetailPage(book: txtBook),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.ensureVisible(find.byKey(const Key('detail_live_tts')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('detail_live_tts')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump();

        expect(find.byKey(const Key('reader_page')), findsOneWidget);
        expect(liveController.state.hasBook, isTrue);
        expect(liveController.state.book?.id, txtBook.id);

        final stopFinder = find.byKey(const Key('reader_live_stop'));
        if (stopFinder.evaluate().isNotEmpty) {
          await tester.tap(stopFinder);
        } else {
          await liveController.stop();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(audioEngine.stopCount, greaterThanOrEqualTo(1));
        expect(liveController.state.hasBook, isFalse);
      },
    );
  });
}
