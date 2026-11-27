import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/api/provider_token_store.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/book_sources/book_source_manager.dart';
import 'package:echo/core/book_sources/book_source_models.dart';
import 'package:echo/core/book_sources/book_source_stores.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/library/bookshelf_tab.dart';
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
      final regStore = MemoryBookSourceRegistryStore();
      final userStore = MemoryBookSourceUserStateStore();
      final credStore = MemoryBookSourceCredentialStore();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            standaloneConfigStorageProvider.overrideWithValue(storage),
            localLibraryStoreProvider.overrideWithValue(libStore),
            providerTokenStoreProvider.overrideWithValue(
              MemoryProviderTokenStore(),
            ),
            bookSourceRegistryStoreProvider.overrideWithValue(regStore),
            bookSourceUserStateStoreProvider.overrideWithValue(userStore),
            bookSourceCredentialStoreProvider.overrideWithValue(credStore),
            bookSourceDioProvider.overrideWithValue(Dio()),
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

      // 首次启动应停在两步引导页，展示内置公版书源与快捷导入/自建入口
      expect(find.byKey(const Key('standalone_onboarding_page')), findsOneWidget);
      expect(find.byKey(const Key('onboarding_import_source_button')), findsOneWidget);
      expect(find.byKey(const Key('onboarding_ebook_api_button')), findsOneWidget);
      expect(find.byKey(const Key('onboarding_next_button')), findsOneWidget);

      // 第 1 步：点击「启用书源并继续」进入第 2 步
      await tester.ensureVisible(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();

      // 第 2 步：展示离线语音模型卡片，滚动到底部进入书架
      expect(find.text('选择一个离线语音模型'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('onboarding_finish_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding_finish_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('echo_home')), findsOneWidget);
      final homeElem = tester.element(find.byKey(const Key('echo_home')));
      final container = ProviderScope.containerOf(homeElem);
      expect(container.read(onlineSearchAvailableProvider), isTrue);
      expect(
        container.read(bookSourceControllerProvider).enabledSources.map((s) => s.id),
        containsAll(<String>['gutendex', 'standard_ebooks', 'wenshuoge']),
      );
      final saved = await storage.read();
      expect(saved.onboardingCompleted, isTrue);
    });

    testWidgets(
      'skipping book source disables online search and keeps local book import working',
      (tester) async {
        tester.view.physicalSize = const Size(360, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final sampleBook = File('${tmpModelsDir.path}/跳过书源测试.txt');
        sampleBook.writeAsBytesSync(
          utf8.encode('第一章 初见\n\n这是跳过书源配置后依然可以直接导入阅读的本地书籍正文。'),
        );

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
              localBookFilePickerProvider.overrideWithValue(
                () async => sampleBook.path,
              ),
              providerTokenStoreProvider.overrideWithValue(
                MemoryProviderTokenStore(),
              ),
              bookSourceRegistryStoreProvider.overrideWithValue(
                MemoryBookSourceRegistryStore(),
              ),
              bookSourceUserStateStoreProvider.overrideWithValue(
                MemoryBookSourceUserStateStore(),
              ),
              bookSourceCredentialStoreProvider.overrideWithValue(
                MemoryBookSourceCredentialStore(),
              ),
              bookSourceDioProvider.overrideWithValue(Dio()),
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

        // Step 1：跳过书源配置
        await tester.ensureVisible(
          find.byKey(const Key('onboarding_skip_api_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('onboarding_skip_api_button')));
        await tester.pumpAndSettle();

        // Step 2：进入书架
        await tester.ensureVisible(
          find.byKey(const Key('onboarding_finish_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('onboarding_finish_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('echo_home')), findsOneWidget);
        final saved = await storage.read();
        expect(saved.onboardingCompleted, isTrue);
        expect(saved.ebookApiBaseUrl, isEmpty);

        // 书架应隐藏搜索入口，直接展示本地导入引导
        expect(find.byKey(const Key('bookshelf_go_discover')), findsNothing);
        expect(
          find.byKey(const Key('bookshelf_empty_import_button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('bookshelf_configure_source_button')),
          findsOneWidget,
        );

        // 底层 API 调用 search 也应被明确拦截
        final homeElem = tester.element(find.byKey(const Key('echo_home')));
        await expectLater(
          ProviderScope.containerOf(homeElem)
              .read(echoApiProvider)
              .search(query: '三体'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'EBOOK_API_NOT_CONFIGURED',
            ),
          ),
        );

        // 切换到「发现」页：搜索框不可用，仅提示配置或直接导入本地书
        await tester.tap(find.text('发现'));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('search_field')), findsNothing);
        expect(
          find.byKey(const Key('search_source_disabled_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('search_disabled_import_button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('search_disabled_configure_button')),
          findsOneWidget,
        );

        // 从禁用态卡片直接导入本地书，应入库并切回书架展示
        await tester.ensureVisible(
          find.byKey(const Key('search_disabled_import_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('search_disabled_import_button')));
        for (var i = 0; i < 60; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (find.text('1 册藏书').evaluate().isNotEmpty) break;
        }
        await tester.pumpAndSettle();

        final books = (await tester.runAsync(() => libStore.listBooks()))!;
        expect(books.length, 1);
        expect(find.text('跳过书源测试'), findsAtLeastNWidgets(1));
      },
    );

    testWidgets(
      'enabling book source in BookSourcesPage unlocks search and disabling via ProfilePage locks it again',
      (tester) async {
        const initialCfg = StandaloneConfig(onboardingCompleted: true);
        final storage = MemoryStandaloneConfigStorage(initialCfg);
        StandaloneConfigStore.setForTest(initialCfg, storage: storage);

        const disabledOverlays = BookSourceUserState(
          overlays: <String, BookSourceUserOverlay>{
            'gutendex': BookSourceUserOverlay(
              sourceId: 'gutendex',
              enabled: false,
            ),
            'standard_ebooks': BookSourceUserOverlay(
              sourceId: 'standard_ebooks',
              enabled: false,
            ),
            'wenshuoge': BookSourceUserOverlay(
              sourceId: 'wenshuoge',
              enabled: false,
            ),
          },
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
              bookSourceRegistryStoreProvider.overrideWithValue(
                MemoryBookSourceRegistryStore(),
              ),
              bookSourceUserStateStoreProvider.overrideWithValue(
                MemoryBookSourceUserStateStore(disabledOverlays),
              ),
              bookSourceCredentialStoreProvider.overrideWithValue(
                MemoryBookSourceCredentialStore(),
              ),
              bookSourceDioProvider.overrideWithValue(Dio()),
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

        // 切到发现页确认处于禁用搜索态
        await tester.tap(find.text('发现'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('search_source_disabled_card')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('search_field')), findsNothing);

        // 点击「管理 / 启用书源」进入书源管理页并启用 Standard Ebooks，返回后搜索立即解锁
        await tester.ensureVisible(
          find.byKey(const Key('search_disabled_configure_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('search_disabled_configure_button')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('book_sources_page')), findsOneWidget);
        final stdSwitch = find.byKey(
          const Key('book_source_switch_standard_ebooks'),
        );
        await tester.ensureVisible(stdSwitch);
        await tester.pumpAndSettle();
        await tester.tap(stdSwitch);
        await tester.pumpAndSettle();

        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('search_source_disabled_card')),
          findsNothing,
        );
        expect(find.byKey(const Key('search_field')), findsOneWidget);

        // 通过「我的 → 书源管理」关闭最后一个已启用书源，返回发现页后恢复禁用态
        await tester.tap(find.text('我的'));
        await tester.pumpAndSettle();
        final profileEntry = find.byKey(const Key('profile_book_sources'));
        await tester.scrollUntilVisible(
          profileEntry,
          200,
          scrollable: find.descendant(
            of: find.byKey(const Key('profile_page')),
            matching: find.byType(Scrollable),
          ).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(profileEntry);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('book_sources_page')), findsOneWidget);
        await tester.scrollUntilVisible(
          stdSwitch,
          200,
          scrollable: find.descendant(
            of: find.byKey(const Key('book_sources_page')),
            matching: find.byType(Scrollable),
          ).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(stdSwitch);
        await tester.pumpAndSettle();

        await tester.pageBack();
        await tester.pumpAndSettle();

        await tester.tap(find.text('发现'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_field')), findsNothing);
        expect(
          find.byKey(const Key('search_source_disabled_card')),
          findsOneWidget,
        );
      },
    );
  });
}
