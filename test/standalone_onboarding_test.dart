import 'dart:io';

import 'package:echo/core/api/provider_token_store.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tokens_fixtures.dart';

void main() {
  group('StandaloneGate & OnboardingPage', () {
    late Directory tmpModelsDir;
    late Directory tmpLibDir;
    late LocalLibraryStore libStore;

    setUp(() async {
      tmpModelsDir = await Directory.systemTemp.createTemp('echo_onb_models_');
      tmpLibDir = await Directory.systemTemp.createTemp('echo_onb_lib_');
      libStore = LocalLibraryStore(rootDir: tmpLibDir);
      await libStore.ensureLoaded();
    });

    tearDown(() async {
      if (await tmpModelsDir.exists()) await tmpModelsDir.delete(recursive: true);
      if (await tmpLibDir.exists()) await tmpLibDir.delete(recursive: true);
    });

    testWidgets('shows onboarding on first launch and enters EchoHome after skipping', (
      tester,
    ) async {
      final storage = MemoryStandaloneConfigStorage(const StandaloneConfig());
      StandaloneConfigStore.setForTest(
        const StandaloneConfig(),
        storage: storage,
      );

      final theme = buildEchoTheme(
        Brightness.dark,
        EchoTokens.fromColors(darkColors, Brightness.dark),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            standaloneConfigStorageProvider.overrideWithValue(storage),
            localLibraryStoreProvider.overrideWithValue(libStore),
            providerTokenStoreProvider.overrideWithValue(
              MemoryProviderTokenStore(),
            ),
            progressStoreProvider.overrideWithValue(MemoryProgressStore()),
            readingStoreProvider.overrideWithValue(MemoryReadingStore()),
            audioEngineProvider.overrideWithValue(FakeAudioEngine()),
            ttsModelManagerProvider.overrideWith(
              (ref) => TtsModelManager(
                ref.read(standaloneConfigProvider.notifier),
                rootDirOverride: tmpModelsDir,
              ),
            ),
          ],
          child: EchoApp(theme: theme),
        ),
      );
      await tester.pumpAndSettle();

      // 首次启动应停在两步引导页，而不是旧版登录页
      expect(find.byKey(const Key('standalone_onboarding_page')), findsOneWidget);
      expect(find.byKey(const Key('onboarding_url_field')), findsOneWidget);

      // 第 1 步：填写一个自定义 ebook-api 地址后进入第 2 步
      await tester.enterText(
        find.byKey(const Key('onboarding_url_field')),
        'http://192.168.1.99:8091',
      );
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();

      // 第 2 步：展示离线语音模型卡片，滚动到底部点击跳过进入书架
      expect(find.text('选择一个离线语音模型'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('onboarding_finish_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding_finish_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('echo_home')), findsOneWidget);
      final saved = await storage.read();
      expect(saved.onboardingCompleted, isTrue);
      expect(saved.ebookApiBaseUrl, 'http://192.168.1.99:8091');
    });
  });
}
