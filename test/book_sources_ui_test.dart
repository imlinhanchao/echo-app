import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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
import 'package:echo/features/book_sources/book_source_detail_page.dart';
import 'package:echo/features/book_sources/book_sources_page.dart';
import 'package:echo/features/search/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tokens_fixtures.dart';

class _UiMockHttpAdapter implements HttpClientAdapter {
  _UiMockHttpAdapter(this.handler);

  final Future<({int status, String body, Map<String, List<String>>? headers})> Function(
    RequestOptions options,
  ) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    final res = await handler(options);
    return ResponseBody.fromString(
      res.body,
      res.status,
      headers: res.headers ??
          <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
    );
  }

  @override
  void close({bool force = false}) {}
}

ThemeData _testTheme() => buildEchoTheme(
  Brightness.dark,
  EchoTokens.fromColors(darkColors, Brightness.dark),
);

void main() {
  group('BookSourcesPage, BookSourceDetailPage, and Search switcher UI', () {
    late Directory tmpDir;
    late LocalLibraryStore libStore;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('echo_bs_ui_');
      libStore = LocalLibraryStore(rootDir: tmpDir);
      await libStore.ensureLoaded();
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    List<Override> baseOverrides({
      required Dio dio,
      BookSourceRegistryStore? regStore,
      BookSourceUserStateStore? userStore,
      BookSourceCredentialStore? credStore,
      Future<String?> Function()? filePicker,
    }) {
      const cfg = StandaloneConfig(onboardingCompleted: true);
      final cfgStore = MemoryStandaloneConfigStorage(cfg);
      StandaloneConfigStore.setForTest(cfg, storage: cfgStore);
      return <Override>[
        standaloneConfigStorageProvider.overrideWithValue(cfgStore),
        localLibraryStoreProvider.overrideWithValue(libStore),
        providerTokenStoreProvider.overrideWithValue(MemoryProviderTokenStore()),
        bookSourceRegistryStoreProvider.overrideWithValue(
          regStore ?? MemoryBookSourceRegistryStore(),
        ),
        bookSourceUserStateStoreProvider.overrideWithValue(
          userStore ?? MemoryBookSourceUserStateStore(),
        ),
        bookSourceCredentialStoreProvider.overrideWithValue(
          credStore ?? MemoryBookSourceCredentialStore(),
        ),
        bookSourceDioProvider.overrideWithValue(dio),
        if (filePicker != null)
          bookSourceFilePickerProvider.overrideWithValue(filePicker),
        progressStoreProvider.overrideWithValue(MemoryProgressStore()),
        readingStoreProvider.overrideWithValue(MemoryReadingStore()),
        audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        ttsModelManagerProvider.overrideWith(
          (ref) => TtsModelManager(
            ref.read(standaloneConfigProvider.notifier),
            rootDirOverride: tmpDir,
          ),
        ),
      ];
    }

    testWidgets(
      'BookSourcesPage manages toggles, URL subscriptions, file JSON import, OPDS quick add, and ebook-api quick add',
      (tester) async {
        final localJsonFile = File('${tmpDir.path}/picked_source.json');
        localJsonFile.writeAsStringSync(
          jsonEncode(<String, dynamic>{
            'schema_version': 1,
            'id': 'picked_local_opds',
            'name': '文件导入书库',
            'driver': 'opds',
            'domains': <String>['https://picked.example.org/opds'],
          }),
        );

        final dio = Dio()
          ..httpClientAdapter = _UiMockHttpAdapter((options) async {
            if (options.uri.toString() == 'https://subs.example.org/sources.json') {
              return (
                status: 200,
                body: jsonEncode(<String, dynamic>{
                  'schema_version': 1,
                  'config_version': '2026.11.27.1',
                  'name': '精选远程订阅',
                  'sources': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'remote_sub_source',
                      'name': '远程订阅源 Alpha',
                      'driver': 'opds',
                      'domains': <String>['https://alpha.example.org'],
                    },
                  ],
                }),
                headers: null,
              );
            }
            return (status: 404, body: '{}', headers: null);
          });

        await tester.pumpWidget(
          ProviderScope(
            overrides: baseOverrides(
              dio: dio,
              filePicker: () async => localJsonFile.path,
            ),
            child: MaterialApp(
              theme: _testTheme(),
              home: const BookSourcesPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('book_sources_page')), findsOneWidget);
        expect(find.byKey(const Key('book_source_item_gutendex')), findsOneWidget);
        expect(find.byKey(const Key('book_source_item_wenshuoge')), findsOneWidget);

        // 切换单个书源开关
        await tester.tap(find.byKey(const Key('book_source_switch_gutendex')));
        await tester.pumpAndSettle();
        final ctx = tester.element(find.byKey(const Key('book_sources_page')));
        final container = ProviderScope.containerOf(ctx);
        expect(
          container.read(bookSourceControllerProvider).sourceById('gutendex')?.isEnabled,
          isFalse,
        );

        // Tab 0: URL 远程订阅导入
        await tester.tap(find.byKey(const Key('book_sources_add_button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('add_source_url_field')),
          'https://subs.example.org/sources.json',
        );
        await tester.tap(find.byKey(const Key('add_source_url_submit')));
        await tester.pumpAndSettle();

        expect(find.text('精选远程订阅'), findsOneWidget);
        final listScroll = find.descendant(
          of: find.byKey(const Key('book_sources_page')),
          matching: find.byType(Scrollable),
        ).first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('book_source_item_remote_sub_source')),
          200,
          scrollable: listScroll,
        );
        expect(find.byKey(const Key('book_source_item_remote_sub_source')), findsOneWidget);

        // Tab 1: 从本地文件选择器读取 JSON 导入
        await tester.tap(find.byKey(const Key('book_sources_add_icon_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add_source_tab_json')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add_source_pick_file')));
        for (var i = 0; i < 20; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          final tf = tester.widget<TextField>(find.byKey(const Key('add_source_json_field')));
          if ((tf.controller?.text ?? '').isNotEmpty) break;
        }
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('add_source_json_submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add_source_json_submit')));
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.byKey(const Key('book_source_item_picked_local_opds')),
          200,
          scrollable: listScroll,
        );
        expect(find.byKey(const Key('book_source_item_picked_local_opds')), findsOneWidget);

        // Tab 2: 快捷添加 OPDS
        await tester.tap(find.byKey(const Key('book_sources_add_icon_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add_source_tab_opds')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('add_source_opds_name')), '家庭书库');
        await tester.enterText(
          find.byKey(const Key('add_source_opds_url')),
          'https://home.example.org/opds',
        );
        await tester.ensureVisible(find.byKey(const Key('add_source_opds_submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add_source_opds_submit')));
        await tester.pumpAndSettle();

        expect(
          container.read(bookSourceControllerProvider).sources.any((s) => s.name == '家庭书库'),
          isTrue,
        );

        // Tab 3: 快捷添加自建 ebook-api
        await tester.tap(find.byKey(const Key('book_sources_add_icon_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add_source_tab_ebook_api')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('add_source_ebook_api_url')),
          'http://192.168.1.50:8091',
        );
        await tester.ensureVisible(
          find.byKey(const Key('add_source_ebook_api_submit')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add_source_ebook_api_submit')));
        await tester.pumpAndSettle();

        expect(
          container.read(bookSourceControllerProvider).sources.any(
            (s) => s.driver == BookSourceDriverType.ebookApi,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'BookSourceDetailPage runs mirror probes, saves custom domain/proxy, executes auth/verify, and exports sanitized JSON',
      (tester) async {
        final dio = Dio()
          ..httpClientAdapter = _UiMockHttpAdapter((options) async {
            final uri = options.uri;
            if (uri.path == '/api/v2/health') {
              return (status: 200, body: '{"ok":true}', headers: null);
            }
            if (uri.path == '/api/v2/auth/csrf') {
              return (
                status: 200,
                body: '{"data":{"token":"t_1"}}',
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>['application/json'],
                  'set-cookie': <String>['wenshuoge_csrf=c_1; Path=/'],
                },
              );
            }
            if (uri.path == '/api/v2/auth/password/login') {
              return (
                status: 200,
                body: '{"data":{"user":{"email":"reader@example.org"}}}',
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>['application/json'],
                  'set-cookie': <String>['wenshuoge_session=secret_cookie_xyz; Path=/'],
                },
              );
            }
            if (uri.path == '/api/v2/downloads/quota') {
              return (
                status: 200,
                body: '{"data":{"limit":1,"used":0,"remaining":1}}',
                headers: null,
              );
            }
            if (uri.path == '/api/v2/auth/status') {
              return (
                status: 200,
                body: '{"data":{"user":{"email":"reader@example.org"}}}',
                headers: null,
              );
            }
            return (status: 404, body: '{}', headers: null);
          });

        await tester.pumpWidget(
          ProviderScope(
            overrides: baseOverrides(dio: dio),
            child: MaterialApp(
              theme: _testTheme(),
              home: const BookSourceDetailPage(sourceId: 'wenshuoge'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('book_source_detail_page')), findsOneWidget);

        // 1. 节点探针测速
        final probeBtn = find.byKey(const Key('source_detail_probe_button'));
        await tester.ensureVisible(probeBtn);
        await tester.tap(probeBtn);
        await tester.pumpAndSettle();
        expect(find.textContaining('ms'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_rounded), findsWidgets);

        // 2. 动态表单登录 + 验证额度
        final emailField = find.byKey(const Key('source_auth_field_email'));
        await tester.ensureVisible(emailField);
        await tester.enterText(emailField, 'reader@example.org');
        await tester.enterText(
          find.byKey(const Key('source_auth_field_password')),
          'my_secret_pw',
        );
        final saveAuthBtn = find.byKey(const Key('source_detail_auth_save'));
        await tester.ensureVisible(saveAuthBtn);
        await tester.tap(saveAuthBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('source_detail_quota')), findsOneWidget);
        expect(find.textContaining('已用 0/1 · 剩余 1'), findsOneWidget);

        // 3. 保存自定义镜像与反代前缀
        final customDomainField = find.byKey(
          const Key('source_detail_custom_domain_field'),
        );
        await tester.ensureVisible(customDomainField);
        await tester.enterText(customDomainField, 'https://custom-wsg.example.org');
        await tester.enterText(
          find.byKey(const Key('source_detail_proxy_prefix_field')),
          'https://proxy.example.org/?url={url}',
        );
        final saveNetBtn = find.byKey(const Key('source_detail_save_network'));
        await tester.ensureVisible(saveNetBtn);
        await tester.tap(saveNetBtn);
        await tester.pumpAndSettle();

        final ctx = tester.element(find.byKey(const Key('book_source_detail_page')));
        final container = ProviderScope.containerOf(ctx);
        final updated = container.read(bookSourceControllerProvider).sourceById('wenshuoge')!;
        expect(updated.customDomain, 'https://custom-wsg.example.org');
        expect(updated.proxyPrefix, 'https://proxy.example.org/?url={url}');

        // 4. 导出脱敏规则 JSON：不包含账号、密码、Cookie、自定义镜像或反代前缀
        await tester.tap(find.byKey(const Key('source_detail_export')));
        await tester.pumpAndSettle();

        final exportPreview = tester.widget<SelectableText>(
          find.byKey(const Key('source_detail_export_preview')),
        );
        final exportedText = exportPreview.data ?? '';
        expect(exportedText, contains('"id": "wenshuoge"'));
        expect(exportedText, isNot(contains('reader@example.org')));
        expect(exportedText, isNot(contains('my_secret_pw')));
        expect(exportedText, isNot(contains('secret_cookie_xyz')));
        expect(exportedText, isNot(contains('custom-wsg.example.org')));
        expect(exportedText, isNot(contains('proxy.example.org')));
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();

        // 5. 清除账号凭据
        final clearBtn = find.byKey(const Key('source_detail_clear_creds'));
        await tester.ensureVisible(clearBtn);
        await tester.tap(clearBtn);
        await tester.pumpAndSettle();
        expect(
          container.read(bookSourceControllerProvider).sourceById('wenshuoge')!.hasCredentials,
          isFalse,
        );
      },
    );

    testWidgets(
      'SearchPage & SearchResultsPage switch active source dynamically, gate filter chips, and prompt login on auth-required download',
      (tester) async {
        final dio = Dio()
          ..httpClientAdapter = _UiMockHttpAdapter((options) async {
            final uri = options.uri;
            if (uri.path == '/api/v2/catalog') {
              return (
                status: 200,
                body: jsonEncode(<String, dynamic>{
                  'data': <String, dynamic>{
                    'books': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'wsg_99',
                        'title': '红楼梦',
                        'author': '曹雪芹',
                        'era': '清代',
                        'category': '集部',
                      },
                    ],
                  },
                  'meta': <String, dynamic>{'total': 1, 'nextCursor': ''},
                }),
                headers: null,
              );
            }
            if (uri.path == '/books') {
              return (
                status: 200,
                body: jsonEncode(<String, dynamic>{
                  'count': 1,
                  'next': null,
                  'results': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 84,
                      'title': 'Frankenstein',
                      'authors': <Map<String, dynamic>>[
                        <String, dynamic>{'name': 'Mary Shelley'},
                      ],
                      'languages': <String>['en'],
                      'formats': <String, dynamic>{
                        'application/epub+zip': 'https://gutendex.com/dl/84.epub',
                      },
                    },
                  ],
                }),
                headers: null,
              );
            }
            return (status: 404, body: '{}', headers: null);
          });

        await tester.pumpWidget(
          ProviderScope(
            overrides: baseOverrides(dio: dio),
            child: MaterialApp(
              theme: _testTheme(),
              home: const Scaffold(
                body: SearchPage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 默认活跃源为 gutendex，聚焦搜索框后展示筛选条件与仅 EPUB 开关
        expect(find.byKey(const Key('search_source_switcher_pill')), findsOneWidget);
        expect(find.text('古登堡公版书库'), findsOneWidget);
        await tester.tap(find.byKey(const Key('search_field')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_epub_filter')), findsOneWidget);
        expect(find.byKey(const Key('search_filter_button')), findsOneWidget);

        // 切换活跃源到文硕阁：不支持的筛选项应自动隐藏
        await tester.tap(find.byKey(const Key('search_source_switcher_pill')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('switch_book_source_wenshuoge')));
        await tester.pumpAndSettle();

        expect(find.text('文硕阁'), findsOneWidget);
        expect(find.byKey(const Key('search_epub_filter')), findsNothing);
        expect(find.byKey(const Key('search_filter_button')), findsNothing);

        // 发起搜索进入 SearchResultsPage
        await tester.enterText(find.byKey(const Key('search_field')), '红楼梦');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('search_results')), findsOneWidget);
        expect(find.text('红楼梦'), findsWidgets);
        expect(find.byKey(const Key('search_results_source_switcher')), findsOneWidget);
        expect(find.byKey(const Key('search_results_epub_filter')), findsNothing);
        expect(find.byKey(const Key('search_results_filter_button')), findsNothing);

        // 未登录状态下点击文硕阁下载，应弹出「去登录」SnackBar 引导至书源详情页
        await tester.tap(find.byKey(const Key('search_download_wsg_99')));
        await tester.pumpAndSettle();
        expect(find.text('「文硕阁」下载需要先登录账号'), findsOneWidget);
        expect(find.text('去登录'), findsOneWidget);

        await tester.tap(find.text('去登录'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('book_source_detail_page')), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();

        // 在结果页单源切换 chip 切换回 gutendex：自动触发新源重搜且筛选栏恢复显示
        await tester.tap(find.byKey(const Key('search_results_source_switcher')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('switch_book_source_gutendex')));
        await tester.pumpAndSettle();

        expect(find.text('Frankenstein'), findsOneWidget);
        expect(find.byKey(const Key('search_results_epub_filter')), findsOneWidget);
        expect(find.byKey(const Key('search_results_filter_button')), findsOneWidget);
      },
    );
  });
}
