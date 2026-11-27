import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/api/provider_token_store.dart';
import 'package:echo/core/book_sources/book_source_manager.dart';
import 'package:echo/core/book_sources/book_source_models.dart';
import 'package:echo/core/book_sources/book_source_stores.dart';
import 'package:echo/core/book_sources/bundled_book_sources.dart';
import 'package:echo/core/book_sources/rule_extractor.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _MockRouteHandler = ({int status, String body, Map<String, List<String>>? headers}) Function(RequestOptions options);

class _RouteMockAdapter implements HttpClientAdapter {
  _RouteMockAdapter(this.handler);

  final _MockRouteHandler handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    requests.add(options);
    final res = handler(options);
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

void main() {
  group('Bundled book sources & schema validation', () {
    test('assets/bundled-book-sources.json matches kBundledBookSourcesJson cleanly', () async {
      final file = File('assets/bundled-book-sources.json');
      expect(file.existsSync(), isTrue);
      final assetRaw = await file.readAsString();
      expect(assetRaw.trim(), kBundledBookSourcesJson.trim());

      final bundle = loadBundledBookSourcesFallback();
      expect(validateBookSourceBundle(bundle), isNull);
      expect(bundle.sources.map((s) => s.id), <String>[
        'gutendex',
        'standard_ebooks',
        'wenshuoge',
      ]);

      final gutendex = bundle.sources[0];
      expect(gutendex.driver, BookSourceDriverType.rule);
      expect(gutendex.auth?.requiresAuthForSearch, isFalse);
      expect(gutendex.auth?.requiresAuthForDownload, isFalse);

      final std = bundle.sources[1];
      expect(std.driver, BookSourceDriverType.rule);
      expect(std.search?.response.mode, 'html');
      expect(std.search?.filters.supportsOrder, isTrue);
      expect(std.search?.filters.supportsExtensions, isFalse);

      final wsg = bundle.sources[2];
      expect(wsg.driver, BookSourceDriverType.rule);
      expect(wsg.auth?.requiresAuthForSearch, isFalse);
      expect(wsg.auth?.requiresAuthForDownload, isTrue);
      expect(wsg.search?.filters.hasAnyFilter, isFalse);
    });

    test('parseBookSourceInput supports both single source object and bundle', () {
      final singleRaw = jsonEncode(<String, dynamic>{
        'schema_version': 1,
        'id': 'single_opds',
        'name': '单条 OPDS',
        'driver': 'opds',
        'domains': <String>['https://opds.example.org/'],
      });
      final parsedSingle = parseBookSourceInput(singleRaw);
      expect(parsedSingle.sources, hasLength(1));
      expect(parsedSingle.sources.first.id, 'single_opds');
      expect(parsedSingle.sources.first.domains, <String>['https://opds.example.org']);
      expect(validateBookSourceBundle(parsedSingle), isNull);

      final bundleRaw = jsonEncode(<String, dynamic>{
        'schema_version': 1,
        'config_version': '2026.11.27.9',
        'config_ttl_hours': 12,
        'name': '订阅合集',
        'sources': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'opds_a',
            'name': 'OPDS A',
            'driver': 'opds',
            'domains': <String>['https://a.example.org'],
          },
        ],
      });
      final parsedBundle = parseBookSourceInput(bundleRaw);
      expect(parsedBundle.configVersion, '2026.11.27.9');
      expect(parsedBundle.configTtlHours, 12);
      expect(parsedBundle.sources.single.schemaVersion, 1);
      expect(validateBookSourceBundle(parsedBundle), isNull);
    });

    test('validateBookSourceBundle catches schema, driver, domain, and rule gaps', () {
      String? validateMap(Map<String, dynamic> raw) {
        final bundle = parseBookSourceInput(jsonEncode(raw));
        return validateBookSourceBundle(bundle, rawJson: raw);
      }

      expect(
        validateMap(<String, dynamic>{
          'schema_version': 2,
          'id': 'x',
          'name': 'X',
          'driver': 'opds',
          'domains': <String>['https://x.example.org'],
        }),
        contains('schema_version'),
      );

      expect(
        validateMap(<String, dynamic>{
          'schema_version': 1,
          'id': 'bad id with spaces',
          'name': 'X',
          'driver': 'opds',
          'domains': <String>['https://x.example.org'],
        }),
        contains('id'),
      );

      expect(
        validateMap(<String, dynamic>{
          'schema_version': 1,
          'id': 'x',
          'name': 'X',
          'driver': 'js_plugin',
          'domains': <String>['https://x.example.org'],
        }),
        contains('不受支持'),
      );

      expect(
        validateMap(<String, dynamic>{
          'schema_version': 1,
          'id': 'x',
          'name': 'X',
          'driver': 'opds',
          'domains': <String>['javascript:alert(1)'],
        }),
        contains('domains'),
      );

      expect(
        validateMap(<String, dynamic>{
          'schema_version': 1,
          'id': 'html_missing_sel',
          'name': 'HTML',
          'driver': 'rule',
          'domains': <String>['https://x.example.org'],
          'search': <String, dynamic>{
            'request': <String, dynamic>{'path': '/s'},
            'response': <String, dynamic>{
              'mode': 'html',
              'fields': <String, dynamic>{
                'ref': <String, dynamic>{'attr': 'href'},
                'title': <String, dynamic>{'selector': 'h2'},
              },
            },
          },
          'download': <String, dynamic>{
            'file_request': <String, dynamic>{'path': '/dl'},
          },
        }),
        contains('items_selector'),
      );

      expect(
        validateMap(<String, dynamic>{
          'schema_version': 1,
          'sources': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'dup',
              'name': 'One',
              'driver': 'opds',
              'domains': <String>['https://one.example.org'],
            },
            <String, dynamic>{
              'id': 'dup',
              'name': 'Two',
              'driver': 'opds',
              'domains': <String>['https://two.example.org'],
            },
          ],
        }),
        contains('重复'),
      );
    });

    test('resolveSafeBookSourceUrl blocks dangerous schemes and resolves relative links', () {
      expect(resolveSafeBookSourceUrl('javascript:alert(1)', 'https://a.org'), isEmpty);
      expect(resolveSafeBookSourceUrl('data:text/html,hi', 'https://a.org'), isEmpty);
      expect(resolveSafeBookSourceUrl('ftp://a.org/f.epub', 'https://a.org'), isEmpty);
      expect(
        resolveSafeBookSourceUrl('/books/1.epub?k=1', 'https://a.org/search'),
        'https://a.org/books/1.epub?k=1',
      );
      expect(
        resolveSafeBookSourceUrl('https://cdn.b.org/1.epub', 'https://a.org'),
        'https://cdn.b.org/1.epub',
      );
    });
  });

  group('RuleExtractor', () {
    test('supports random generators, templates, path_segments, first_of, when_present, and Set-Cookie', () {
      final extractor = RuleExtractor();
      final randCache = <String, String>{};
      final uuid1 = extractor.renderTemplate('{{rand.uuid}}', const {}, randCache: randCache);
      final uuid2 = extractor.renderTemplate('{{rand.uuid}}', const {}, randCache: randCache);
      expect(uuid1, equals(uuid2));
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(uuid1),
        isTrue,
      );

      final id24 = extractor.generateId24();
      expect(id24, hasLength(24));
      expect(RegExp(r'^[A-Za-z0-9]{24}$').hasMatch(id24), isTrue);

      final cookies = RuleExtractor.parseSetCookieHeaders(<String>[
        'wenshuoge_csrf=abc123; Path=/; HttpOnly; SameSite=Lax',
        'wenshuoge_session=sess=xyz; Path=/; Secure',
      ]);
      expect(cookies['wenshuoge_csrf'], 'abc123');
      expect(cookies['wenshuoge_session'], 'sess=xyz');

      final item = <String, dynamic>{
        'id': 42,
        'formats': <String, dynamic>{
          'text/plain; charset=utf-8': '/files/42.txt',
        },
        'author': '曹雪芹，高鹗',
      };

      final fallbackFormat = extractor.extractSingle(
        item,
        const BookSourceExtractRule(
          firstOf: <BookSourceExtractRule>[
            BookSourceExtractRule(
              whenPresent: BookSourceExtractRule(
                pathSegments: <String>['formats', 'application/epub+zip'],
              ),
              constValue: 'epub',
            ),
            BookSourceExtractRule(
              whenPresent: BookSourceExtractRule(
                pathSegments: <String>['formats', 'text/plain; charset=utf-8'],
              ),
              constValue: 'txt',
            ),
          ],
        ),
        mode: 'json',
        baseUrl: 'https://example.org',
      );
      expect(fallbackFormat, 'txt');

      final dlUrl = extractor.extractSingle(
        item,
        const BookSourceExtractRule(
          pathSegments: <String>['formats', 'text/plain; charset=utf-8'],
          resolveUrl: true,
        ),
        mode: 'json',
        baseUrl: 'https://example.org',
      );
      expect(dlUrl, 'https://example.org/files/42.txt');

      final authors = extractor.extractList(
        item,
        const BookSourceExtractRule(
          path: 'author',
          splitRegex: r'\s*[,、，;]\s*',
        ),
        mode: 'json',
        baseUrl: 'https://example.org',
      );
      expect(authors, <String>['曹雪芹', '高鹗']);
    });

    test('supports HTML JSON-LD, after_heading, next_sibling, and regex transforms', () {
      final extractor = RuleExtractor();
      const html = '''
      <html>
        <head>
          <script type="application/ld+json">
            {"@type":"Book","description":"红楼梦简介内容","image":"/covers/hlm.jpg"}
          </script>
        </head>
        <body>
          <div class="meta">
            <h3>内容提要</h3>
            <div class="summary"><p>第一段。</p><p>第二段。</p></div>
            <dt class="lbl">ISBN</dt>
            <dd class="val">ISBN: 978-7-02-000220-7 (精装)</dd>
          </div>
        </body>
      </html>
      ''';
      final root = extractor.parseRoot(html, mode: 'html');

      final descJsonLd = extractor.extractSingle(
        root,
        const BookSourceExtractRule(
          selector: "script[type='application/ld+json']",
          jsonPath: 'description',
        ),
        mode: 'html',
        baseUrl: 'https://example.org',
      );
      expect(descJsonLd, '红楼梦简介内容');

      final coverJsonLd = extractor.extractSingle(
        root,
        const BookSourceExtractRule(
          selector: "script[type='application/ld+json']",
          jsonPath: 'image',
          resolveUrl: true,
        ),
        mode: 'html',
        baseUrl: 'https://example.org',
      );
      expect(coverJsonLd, 'https://example.org/covers/hlm.jpg');

      final afterHeadingDesc = extractor.extractSingle(
        root,
        const BookSourceExtractRule(
          afterHeading: '内容提要',
          preserveParagraphs: true,
        ),
        mode: 'html',
        baseUrl: 'https://example.org',
      );
      expect(afterHeadingDesc, '第一段。\n\n第二段。');

      final dtRoot = extractor.parseRoot('<dl><dt>编号</dt><dd>ID-9981</dd></dl>', mode: 'html');
      final dtEl = extractor.extractItems('<dl><dt>编号</dt><dd>ID-9981</dd></dl>', mode: 'html', itemsSelector: 'dt').first;
      expect(dtRoot, isNotNull);
      final siblingVal = extractor.extractSingle(
        dtEl,
        const BookSourceExtractRule(
          nextSibling: 'dd',
          stripPrefix: 'ID-',
        ),
        mode: 'html',
        baseUrl: 'https://example.org',
      );
      expect(siblingVal, '9981');
    });
  });

  group('BookSourceManager 3-tier isolation, export, and legacy migration', () {
    test('subscription refresh updates rule definitions without overwriting overlays or credentials', () async {
      var version = 1;
      final adapter = _RouteMockAdapter((options) {
        if (options.uri.toString() == 'https://ghfast.top/https://raw.githubusercontent.com/user/repo/main/sources.json') {
          return (
            status: 502,
            body: 'mirror down',
            headers: null,
          );
        }
        return (
          status: 200,
          body: jsonEncode(<String, dynamic>{
            'schema_version': 1,
            'config_version': 'v$version',
            'config_ttl_hours': 24,
            'name': '测试订阅合集',
            'sources': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'sub_lib',
                'name': version == 1 ? '订阅书源 v1' : '订阅书源 v2',
                'description': 'desc-$version',
                'driver': 'opds',
                'enabled': true,
                'domains': <String>[
                  version == 1
                      ? 'https://mirror1.example.org'
                      : 'https://mirror2.example.org',
                ],
              },
            ],
          }),
          headers: null,
        );
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final regStore = MemoryBookSourceRegistryStore();
      final userStore = MemoryBookSourceUserStateStore();
      final credStore = MemoryBookSourceCredentialStore();

      final manager = BookSourceManager(
        registryStore: regStore,
        userStateStore: userStore,
        credentialStore: credStore,
        legacyTokenStore: MemoryProviderTokenStore(),
        readStandaloneConfig: () => const StandaloneConfig(
          ttsDownloadMirror: 'ghfast',
        ),
        dio: dio,
      );

      final res1 = await manager.importFromUrl(
        'https://raw.githubusercontent.com/user/repo/main/sources.json',
        asSubscription: true,
      );
      expect(res1.addedCount, 1);
      // Confirm GitHub mirror fallback happened!
      expect(
        adapter.requests.map((r) => r.uri.toString()).toList(),
        <String>[
          'https://ghfast.top/https://raw.githubusercontent.com/user/repo/main/sources.json',
          'https://raw.githubusercontent.com/user/repo/main/sources.json',
        ],
      );

      // Apply user overlay (disable source, set custom domain & proxy) + active source + secret creds.
      await manager.setActiveSource('gutendex');
      await manager.setSourceEnabled('sub_lib', false);
      await manager.updateNetworkOverlay(
        'sub_lib',
        preferredDomain: 'https://pref.example.org',
        customDomain: 'https://my-private-mirror.example.org/',
        proxyPrefix: 'https://my-proxy.example.org/?url={url}',
      );
      await credStore.write(
        const BookSourceCredentials(
          sourceId: 'sub_lib',
          modeId: 'basic',
          values: <String, String>{
            'username': 'secret-user',
            'password': 'super-secret-password',
          },
          account: BookSourceAccountStatus(
            configured: true,
            status: 'ok',
            email: 'secret-user',
          ),
        ),
      );

      // Trigger subscription refresh to v2.
      version = 2;
      final subId = manager.currentState.subscriptions.single.id;
      final res2 = await manager.refreshSubscription(subId);
      expect(res2.updatedCount, 1);

      final updated = manager.currentState.sourceById('sub_lib')!;
      // Rule tier updated:
      expect(updated.name, '订阅书源 v2');
      expect(updated.definition.domains, <String>['https://mirror2.example.org']);
      // User overlay tier strictly preserved:
      expect(updated.isEnabled, isFalse);
      expect(updated.customDomain, 'https://my-private-mirror.example.org');
      expect(updated.preferredDomain, 'https://pref.example.org');
      expect(updated.proxyPrefix, 'https://my-proxy.example.org/?url={url}');
      expect(manager.currentState.activeSourceId, 'gutendex');
      // Credentials tier strictly preserved:
      expect(updated.hasCredentials, isTrue);
      expect(updated.credentials!.values['password'], 'super-secret-password');

      // Sanitized single-source export excludes credentials and user overlays:
      final exportedRaw = manager.exportSanitizedJson('sub_lib');
      expect(exportedRaw, isNot(contains('secret-user')));
      expect(exportedRaw, isNot(contains('super-secret-password')));
      expect(exportedRaw, isNot(contains('my-private-mirror')));
      expect(exportedRaw, isNot(contains('my-proxy.example.org')));
      final exportedMap = jsonDecode(exportedRaw) as Map<String, dynamic>;
      expect(exportedMap['domains'], <String>['https://mirror2.example.org']);
      expect(exportedMap['enabled'], isTrue);
    });

    test('migrates legacy StandaloneConfig ebook-api and ProviderTokenStore once on load', () async {
      final regStore = MemoryBookSourceRegistryStore();
      final userStore = MemoryBookSourceUserStateStore();
      final credStore = MemoryBookSourceCredentialStore();
      final legacyTokens = MemoryProviderTokenStore();
      await legacyTokens.write(
        StoredProviderCredential(
          providerId: 'zlib',
          credentialToken: 'sealed-legacy-token',
          account: const ProviderAccountInfo(
            configured: true,
            status: 'ok',
            email: 'legacy@example.org',
            dailyUsed: 2,
            dailyLimit: 10,
            dailyRemaining: 8,
            quotaKnown: true,
          ),
          savedAt: DateTime.utc(2026, 11, 20),
        ),
      );

      final manager = BookSourceManager(
        registryStore: regStore,
        userStateStore: userStore,
        credentialStore: credStore,
        legacyTokenStore: legacyTokens,
        readStandaloneConfig: () => const StandaloneConfig(
          ebookApiBaseUrl: 'http://192.168.1.9:8091/',
          ebookApiKey: 'legacy-api-key',
        ),
        dio: Dio(),
      );

      await manager.ensureLoaded();

      final migrated = manager.currentState.sourceById('ebook_api_legacy');
      expect(migrated, isNotNull);
      expect(migrated!.driver, BookSourceDriverType.ebookApi);
      expect(migrated.effectiveDomains, <String>['http://192.168.1.9:8091']);
      expect(migrated.credentials?.values['api_key'], 'legacy-api-key');
      expect(migrated.credentials?.values['credential_token'], 'sealed-legacy-token');
      expect(migrated.account?.email, 'legacy@example.org');
      expect(migrated.account?.dailyRemaining, 8);
      expect(manager.currentState.activeSourceId, 'ebook_api_legacy');

      final regAfter = await regStore.read();
      expect(regAfter.legacyMigrated, isTrue);

      // Removing the migrated source does not trigger re-migration on next load.
      await manager.removeSource('ebook_api_legacy');
      final managerReloaded = BookSourceManager(
        registryStore: regStore,
        userStateStore: userStore,
        credentialStore: credStore,
        legacyTokenStore: legacyTokens,
        readStandaloneConfig: () => const StandaloneConfig(
          ebookApiBaseUrl: 'http://192.168.1.9:8091/',
          ebookApiKey: 'legacy-api-key',
        ),
        dio: Dio(),
      );
      await managerReloaded.ensureLoaded();
      expect(managerReloaded.currentState.sourceById('ebook_api_legacy'), isNull);
    });

    test('file stores round-trip & quick add/disable/enable bundled operations work', () async {
      final tempDir = await Directory.systemTemp.createTemp('echo_bs_store_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final regStore = FileBookSourceRegistryStore(directoryProvider: () async => tempDir);
      final userStore = FileBookSourceUserStateStore(directoryProvider: () async => tempDir);
      final credStore = MemoryBookSourceCredentialStore();

      final manager = BookSourceManager(
        registryStore: regStore,
        userStateStore: userStore,
        credentialStore: credStore,
        legacyTokenStore: MemoryProviderTokenStore(),
        readStandaloneConfig: () => const StandaloneConfig(),
        dio: Dio(),
      );
      await manager.ensureLoaded();
      expect(manager.currentState.enabledSources, hasLength(3));

      await manager.addQuickOpds(
        name: 'Calibre Home',
        catalogUrl: 'https://calibre.example.org/opds/',
        username: 'reader',
        password: 'pw',
      );
      expect(
        manager.currentState.sources.any((s) => s.name == 'Calibre Home' && s.hasCredentials),
        isTrue,
      );

      await manager.disableAllSources();
      expect(manager.currentState.enabledSources, isEmpty);

      await manager.enableBundledSources();
      expect(manager.currentState.enabledSources.map((s) => s.id), <String>[
        'gutendex',
        'standard_ebooks',
        'wenshuoge',
      ]);

      // Verify files actually landed on disk and deserialize identically.
      final regFile = File('${tempDir.path}/book_sources/registry.json');
      final overlayFile = File('${tempDir.path}/book_sources/overlays.json');
      expect(regFile.existsSync(), isTrue);
      expect(overlayFile.existsSync(), isTrue);

      final regRead = await FileBookSourceRegistryStore(
        directoryProvider: () async => tempDir,
      ).read();
      final userRead = await FileBookSourceUserStateStore(
        directoryProvider: () async => tempDir,
      ).read();
      expect(regRead.localSources.any((s) => s.name == 'Calibre Home'), isTrue);
      expect(userRead.overlays['gutendex']?.enabled, isTrue);
    });
  });
}
