import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo/core/api/ebook_api_client.dart';
import 'package:echo/core/api/provider_token_store.dart';
import 'package:echo/core/api/standalone_echo_api.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/tts/audio_encoder_service.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/tts/local_convert_service.dart';
import 'package:echo/core/tts/sherpa_tts_engine.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/providers/provider_account_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stub_adapter.dart';
import 'tokens_fixtures.dart';

void main() {
  group('EbookApiClient', () {
    test('sends X-API-Key and X-Provider-Token on search and verify', () async {
      final tokenStore = MemoryProviderTokenStore();
      await tokenStore.write(
        const StoredProviderCredential(
          providerId: 'zlib',
          credentialToken: 'ebk1.secret_token',
        ),
      );

      final adapter = StubAdapter(<String, Responder Function()>{
        '/health': () => okResponse(<String, dynamic>{
          'status': 'ok',
          'providers': <String>['zlib'],
        }),
        '/v1/search': () => okResponse(<String, dynamic>{
          'provider': 'zlib',
          'page': 1,
          'total_pages': 3,
          'books': <Map<String, dynamic>>[
            <String, dynamic>{
              'provider': 'zlib',
              'ref': '100:abc',
              'title': '三体',
              'authors': <String>['刘慈欣'],
              'format': 'epub',
            },
          ],
        }),
        '/v1/providers/zlib/login': () => okResponse(<String, dynamic>{
          'provider': 'zlib',
          'credential_token': 'ebk1.new_token',
          'account': <String, dynamic>{
            'email': 'reader@example.com',
            'daily_used': 2,
            'daily_limit': 10,
            'daily_remaining': 8,
            'premium': false,
            'quota_known': true,
          },
        }),
      });
      final dio = Dio(BaseOptions(baseUrl: 'http://ebook.local:8091'));
      dio.httpClientAdapter = adapter;

      final client = EbookApiClient(
        baseUrl: 'http://ebook.local:8091',
        apiKey: 'my-secret-key',
        dio: dio,
        tokenStore: tokenStore,
      );

      final health = await client.checkHealth();
      expect(health.ok, isTrue);
      expect(health.providers, <String>['zlib']);
      expect(
        adapter.requestsTo('/health').first.headers['X-API-Key'],
        'my-secret-key',
      );

      final page = await client.search(
        query: '三体',
        provider: 'zlib',
        extensions: const <String>['EPUB'],
      );
      expect(page.books, hasLength(1));
      expect(page.books.first.title, '三体');
      expect(
        adapter.requestsTo('/v1/search').first.headers['X-API-Key'],
        'my-secret-key',
      );
      expect(
        adapter.requestsTo('/v1/search').first.headers['X-Provider-Token'],
        'ebk1.secret_token',
      );

      final loginRes = await client.loginProvider(
        providerId: 'zlib',
        email: 'reader@example.com',
        password: 'pw',
      );
      expect(loginRes.credentialToken, 'ebk1.new_token');
      expect(loginRes.account?.status, 'ok');
      expect(loginRes.account?.dailyRemaining, 8);
    });

    test('parses login, seal and verify responses without status field and reflects unconfigured vs default providers', () async {
      final tokenStore = MemoryProviderTokenStore();
      var defaultConfigured = false;
      final adapter = StubAdapter(<String, Responder Function()>{
        '/v1/providers': () => okResponse(<String, dynamic>{
          'default_provider': 'zlib',
          'providers': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'zlib',
              'name': 'Z-Library',
              'default_domain': 'https://z-lib.gd',
              'domains': <String>['https://z-lib.gd'],
              'default_configured': defaultConfigured,
            },
          ],
        }),
        '/v1/providers/zlib/login': () => okResponse(<String, dynamic>{
          'provider': 'zlib',
          'credential_token': 'ebk1.login_tok',
          'account': <String, dynamic>{
            'email': 'u@example.com',
            'daily_used': 1,
            'daily_limit': 10,
            'daily_remaining': 9,
            'premium': false,
            'quota_known': true,
          },
        }),
        '/v1/providers/zlib/seal': () => okResponse(<String, dynamic>{
          'provider': 'zlib',
          'credential_token': 'ebk1.seal_tok',
          'account': <String, dynamic>{
            'email': 'cookie@example.com',
            'daily_used': 4,
            'daily_limit': 10,
            'daily_remaining': 6,
            'premium': false,
            'quota_known': true,
          },
        }),
        '/v1/providers/zlib/verify': () => okResponse(<String, dynamic>{
          'provider': 'zlib',
          'account': <String, dynamic>{
            'email': 'u@example.com',
            'daily_used': 3,
            'daily_limit': 10,
            'daily_remaining': 7,
            'premium': false,
            'quota_known': true,
          },
        }),
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://ebook.local:8091'));
      dio.httpClientAdapter = adapter;
      final client = EbookApiClient(
        baseUrl: 'http://ebook.local:8091',
        dio: dio,
        tokenStore: tokenStore,
      );

      // 1. default_configured: false 且本地无令牌 -> account 为 null（未配置）
      final unconfiguredList = await client.listProviders();
      expect(unconfiguredList.single.account, isNull);

      // 2. default_configured: true 且本地无令牌 -> 展示服务端默认凭据
      defaultConfigured = true;
      final defaultList = await client.listProviders();
      expect(defaultList.single.account?.configured, isTrue);
      expect(defaultList.single.account?.email, '服务端默认凭据');

      // 3. seal 不带 status 字段也能正常解析
      final sealRes = await client.sealProvider(
        providerId: 'zlib',
        credentials: const <String, String>{
          'remix_userid': '123',
          'remix_userkey': 'abc',
        },
      );
      expect(sealRes.credentialToken, 'ebk1.seal_tok');
      expect(sealRes.account?.status, 'ok');
      expect(sealRes.account?.dailyRemaining, 6);

      // 4. verify 不带 status 字段也能正常解析并更新本地缓存
      final verified = await client.verifyProvider(
        'zlib',
        credentialToken: 'ebk1.login_tok',
      );
      expect(verified.status, 'ok');
      expect(verified.dailyRemaining, 7);
      final cached = await tokenStore.read('zlib');
      expect(cached?.credentialToken, 'ebk1.login_tok');
      expect(cached?.account?.dailyRemaining, 7);
    });
  });

  group('ProviderAccountPage with ebook-api contract', () {
    late Directory libDir;
    late Directory modelsDir;
    late LocalLibraryStore libStore;
    late TtsModelManager modelManager;

    setUp(() async {
      libDir = await Directory.systemTemp.createTemp('echo_prov_lib_');
      modelsDir = await Directory.systemTemp.createTemp('echo_prov_models_');
      libStore = LocalLibraryStore(rootDir: libDir);
      await libStore.ensureLoaded();
      final cfgStorage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(
          ebookApiBaseUrl: 'http://ebook.local:8091',
          onboardingCompleted: true,
        ),
      );
      final cfgCtrl = StandaloneConfigController(
        cfgStorage,
        const StandaloneConfig(
          ebookApiBaseUrl: 'http://ebook.local:8091',
          onboardingCompleted: true,
        ),
      );
      modelManager = TtsModelManager(
        cfgCtrl,
        rootDirOverride: modelsDir,
        keepAliveService: const NoopDownloadKeepAliveService(),
      );
      await modelManager.refresh();
    });

    tearDown(() async {
      if (await libDir.exists()) await libDir.delete(recursive: true);
      if (await modelsDir.exists()) await modelsDir.delete(recursive: true);
    });

    testWidgets('saves password login when ebook-api account omits status and updates unconfigured state cleanly', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tokenStore = MemoryProviderTokenStore();
      final adapter = StubAdapter(<String, Responder Function()>{
        '/v1/providers': () => okResponse(<String, dynamic>{
          'default_provider': 'zlib',
          'providers': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'zlib',
              'name': 'Z-Library',
              'default_domain': 'https://z-lib.gd',
              'domains': <String>['https://z-lib.gd'],
              'default_configured': false,
            },
          ],
        }),
        '/v1/providers/zlib/login': () => okResponse(<String, dynamic>{
          'provider': 'zlib',
          'credential_token': 'ebk1.saved_token',
          'account': <String, dynamic>{
            'email': 'imlinhanchao@foxmail.com',
            'daily_used': 0,
            'daily_limit': 10,
            'daily_remaining': 10,
            'premium': false,
            'quota_known': true,
          },
        }),
      });
      final dio = Dio(BaseOptions(baseUrl: 'http://ebook.local:8091'));
      dio.httpClientAdapter = adapter;
      final client = EbookApiClient(
        baseUrl: 'http://ebook.local:8091',
        dio: dio,
        tokenStore: tokenStore,
      );
      final api = StandaloneEchoApi(
        libraryStore: libStore,
        readEbookApi: () => client,
        tokenStore: tokenStore,
        ttsModelManager: modelManager,
        convertService: LocalConvertService(
          libraryStore: libStore,
          ttsEngine: FakeOnDeviceTtsEngine(),
          encoderService: const PlatformAudioEncoderService(),
        ),
        readConfig: () => const StandaloneConfig(
          ebookApiBaseUrl: 'http://ebook.local:8091',
          onboardingCompleted: true,
        ),
      );

      final theme = buildEchoTheme(
        Brightness.dark,
        EchoTokens.fromColors(darkColors, Brightness.dark),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            echoApiProvider.overrideWithValue(api),
            providerTokenStoreProvider.overrideWithValue(tokenStore),
            ttsModelManagerProvider.overrideWith((_) => modelManager),
          ],
          child: MaterialApp(
            theme: theme,
            home: const ProviderAccountPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 初始未配置应显示「未配置」，不应误显示「正常」
      expect(find.byKey(const Key('provider_zlib_unconfigured')), findsOneWidget);
      expect(find.byKey(const Key('provider_zlib_status_chip')), findsNothing);

      // 填写邮箱与密码后点击「保存并验证」
      await tester.enterText(
        find.byKey(const Key('account_email_field')),
        'imlinhanchao@foxmail.com',
      );
      await tester.enterText(
        find.byKey(const Key('account_password_field')),
        'secret-pass',
      );
      await tester.ensureVisible(find.byKey(const Key('account_form_save')));
      await tester.tap(find.byKey(const Key('account_form_save')));
      await tester.pumpAndSettle();

      // 按钮恢复可点击（不再卡在转圈）、弹出成功提示、顶部变为「正常」并展示配额
      expect(find.text('账号已保存并验证通过'), findsOneWidget);
      expect(find.byKey(const Key('provider_zlib_status_chip')), findsOneWidget);
      expect(find.text('正常'), findsOneWidget);
      expect(find.byKey(const Key('provider_zlib_quota')), findsOneWidget);
      expect((await tokenStore.read('zlib'))?.credentialToken, 'ebk1.saved_token');
    });
  });
}
