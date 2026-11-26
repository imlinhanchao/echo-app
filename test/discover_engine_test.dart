import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/discover/discover_cache.dart';
import 'package:echo/core/discover/discover_config.dart';
import 'package:echo/core/discover/discover_config_store.dart';
import 'package:echo/core/discover/discover_models.dart';
import 'package:echo/core/discover/discover_parser.dart';
import 'package:echo/core/discover/discover_repository.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/design/book_cover.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/discover/discover_book_detail_sheet.dart';
import 'package:echo/features/discover/discover_section.dart';
import 'package:echo/features/search/search_controller.dart' as search_ctrl;
import 'package:echo/features/search/search_page.dart';
import 'package:echo/features/settings/discover_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tokens_fixtures.dart';

typedef _RawHandler =
    ({int status, String body, Map<String, List<String>>? headers}) Function(
      RequestOptions options,
    );

class _RawRouterAdapter implements HttpClientAdapter {
  _RawRouterAdapter(this._onRequest);

  final _RawHandler _onRequest;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    requests.add(options);
    final res = _onRequest(options);
    return ResponseBody.fromString(
      res.body,
      res.status,
      headers:
          res.headers ??
          const <String, List<String>>{
            Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
          },
    );
  }

  @override
  void close({bool force = false}) {}
}

const String _tstrsHomeHtml = '''
<html><body>
<div id="home-trending">
  <div class="col" data-bid="1">
    <a class="card book-card book-hcard" href="/b/1984当我们再无秘密可言">
      <img class="cover-thumb" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-src="https://la-img.tstrs.me/cover_1984_360.jpg">
      <div class="book-hcard-info">
        <span class="book-hcard-title">1984：当我们再无秘密可言</span>
        <span class="book-hcard-author">乔治·奥威尔 / 赵小妮</span>
        <span class="book-hcard-press">北京慢半拍文化有限公司</span>
        <span class="book-hcard-year">2026</span>
      </div>
    </a>
  </div>
</div>
</body></html>
''';

const String _tstrsChartHtml = '''
<html><body>
<a class="search-row rank-item" href="/b/我愿埋首人间">
  <div class="search-row-cover">
    <img class="cover-thumb" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-src="/img/poem_360.jpg">
    <span class="cover-score-num">3.9</span>
  </div>
  <div class="search-row-info">
    <span class="search-row-title">我愿埋首人间：张二棍的诗</span>
    <span class="search-row-author">张二棍</span>
    <span class="search-row-press">湖南文艺出版社 · 2026</span>
    <span class="search-row-summary">“地质钻探诗人”张二棍亲选诗作，共收录160余首诗作。</span>
  </div>
</a>
</body></html>
''';

const String _tstrsBooklistsHtml = '''
<html><body>
<a class="card booklist-card-stack" href="/booklist/谁为河流买单">
  <span class="bls-head">
    <span class="bls-title">谁为河流买单：治水边缘视角</span>
    <span class="bls-meta">推荐了 10 本</span>
  </span>
  <span class="bls-blurb">水资源与河流治理的核心矛盾，往往不在工程图纸上。</span>
  <span class="bls-stack">
    <span class="bls-sheet"><img src="data:image/gif;base64,AAA" data-src="https://la-img.tstrs.me/a.jpg"></span>
    <span class="bls-sheet"><img src="data:image/gif;base64,AAA" data-src="https://la-img.tstrs.me/b.jpg"></span>
  </span>
</a>
</body></html>
''';

const String _tstrsBooklistDetailHtml = '''
<html><body>
<div class="bl-book" id="book-汤姆斯河">
  <a class="bl-book-link" href="/b/汤姆斯河">
    <img class="cover-thumb" src="data:image/gif;base64,AAA" data-src="https://la-img.tstrs.me/toms.jpg">
    <span class="bl-book-title">汤姆斯河</span>
    <span class="bl-book-score">4.5</span>
    <span class="bl-book-meta">丹·费金 / 王雯 · 上海译文出版社 · 2016</span>
    <span class="bl-book-summary">关于环境污染与科学侦探的普利策奖非虚构经典。</span>
  </a>
</div>
<p>把化学工业与社区健康放回同一时间线中追问，非常适合建立公共议题意识。</p>
</body></html>
''';

const String _doubanChartHtml = '''
<html><body>
<ul class="chart-dashed-list">
  <li class="media clearfix">
    <div class="media__img">
      <a href="https://book.douban.com/subject/38461487/">
        <img class="subject-cover" src="https://img3.doubanio.com/view/subject/s/public/s35577760.jpg"/>
      </a>
    </div>
    <div class="media__body">
      <h2 class="clearfix"><a class="fleft" href="https://book.douban.com/subject/38461487/">落在我身上的雨</a></h2>
      <p class="subject-abstract color-gray">陆庆屹 / 2026-8 / 新星出版社 / 59.00元 / 平装</p>
      <p class="clearfix w250 subject-rating"><span class="font-small fleft">9.1</span></p>
    </div>
  </li>
</ul>
</body></html>
''';

const String _doubanTop250Html = '''
<html><body>
<table><tbody>
<tr class="item">
  <td width="100" valign="top">
    <a class="nbg" href="https://book.douban.com/subject/1007305/">
      <img src="https://img3.doubanio.com/view/subject/s/public/s1070959.jpg" width="90" />
    </a>
  </td>
  <td valign="top">
    <div class="pl2">
      <a href="https://book.douban.com/subject/1007305/" title="红楼梦">红楼梦</a>
    </div>
    <p class="pl">(清)曹雪芹 / 人民文学出版社 / 1982-3 / 59.70元</p>
    <div class="star clearfix"><span class="rating_nums">9.7</span></div>
    <p class="quote"><span class="inq">都云作者痴，谁解其中味？</span></p>
  </td>
</tr>
</tbody></table>
</body></html>
''';

const String _doubanRexxarJson = '''
{
  "total": 49,
  "subject_collection_items": [
    {
      "id": "4913064",
      "title": "活着",
      "author": ["余华"],
      "press": ["作家出版社"],
      "year": ["2012-8"],
      "info": "余华/作家出版社/2012-8",
      "description": "",
      "cards": [{"content": "一部关于苦难与生存韧性的当代经典。"}],
      "rating": {"value": 9.4},
      "cover": {"url": "https://img9.doubanio.com/view/subject/l/public/s29869926.jpg"},
      "url": "https://www.douban.com/doubanapp/dispatch/book/4913064"
    }
  ]
}
''';

void main() {
  group('HtmlDiscoverParser & JsonDiscoverParser', () {
    final config = DiscoverRulesConfig.bundledFallback();
    final tstrs = config.sourceById('tstrs')!;
    final douban = config.sourceById('douban')!;
    final htmlParser = HtmlDiscoverParser();
    final jsonParser = JsonDiscoverParser();

    test('解析 SaltyLeo 首页、榜单、书单及书单详情（跳过 data: 占位图并补全路径）', () {
      final homeBooks = htmlParser.parseBooks(
        _tstrsHomeHtml,
        tstrs,
        tstrs.feedById('home')!,
      );
      expect(homeBooks, hasLength(1));
      expect(homeBooks.first.title, '1984：当我们再无秘密可言');
      expect(homeBooks.first.author, '乔治·奥威尔 / 赵小妮');
      expect(homeBooks.first.publisher, '北京慢半拍文化有限公司');
      expect(homeBooks.first.year, '2026');
      expect(
        homeBooks.first.coverUrl,
        'https://la-img.tstrs.me/cover_1984_360.jpg',
      );
      expect(
        homeBooks.first.detailUrl,
        'https://tstrs.me/b/1984%E5%BD%93%E6%88%91%E4%BB%AC%E5%86%8D%E6%97%A0%E7%A7%98%E5%AF%86%E5%8F%AF%E8%A8%80',
      );
      expect(homeBooks.first.imageHeaders['Referer'], 'https://tstrs.me/');

      final chartBooks = htmlParser.parseBooks(
        _tstrsChartHtml,
        tstrs,
        tstrs.feedById('chart_hot')!,
      );
      expect(chartBooks, hasLength(1));
      expect(chartBooks.first.author, '张二棍');
      expect(chartBooks.first.publisher, '湖南文艺出版社');
      expect(chartBooks.first.year, '2026');
      expect(chartBooks.first.score, '3.9');
      expect(chartBooks.first.coverUrl, 'https://tstrs.me/img/poem_360.jpg');

      final booklists = htmlParser.parseBooklists(
        _tstrsBooklistsHtml,
        tstrs,
        tstrs.feedById('booklists')!,
      );
      expect(booklists, hasLength(1));
      expect(booklists.first.title, '谁为河流买单：治水边缘视角');
      expect(booklists.first.meta, '推荐了 10 本');
      expect(booklists.first.covers, <String>[
        'https://la-img.tstrs.me/a.jpg',
        'https://la-img.tstrs.me/b.jpg',
      ]);

      final detailBooks = htmlParser.parseBooklistDetail(
        _tstrsBooklistDetailHtml,
        tstrs,
        tstrs.booklistDetail!,
      );
      expect(detailBooks, hasLength(1));
      expect(detailBooks.first.title, '汤姆斯河');
      expect(detailBooks.first.author, '丹·费金 / 王雯');
      expect(detailBooks.first.publisher, '上海译文出版社');
      expect(detailBooks.first.year, '2016');
      expect(detailBooks.first.score, '4.5');
      expect(
        detailBooks.first.note,
        '把化学工业与社区健康放回同一时间线中追问，非常适合建立公共议题意识。',
      );
    });

    test('解析豆瓣读书 HTML（/chart、/top250）与 Rexxar JSON（bestseller）混排频道', () {
      final chartBooks = htmlParser.parseBooks(
        _doubanChartHtml,
        douban,
        douban.feedById('chart')!,
      );
      expect(chartBooks, hasLength(1));
      expect(chartBooks.first.title, '落在我身上的雨');
      expect(chartBooks.first.author, '陆庆屹');
      expect(chartBooks.first.publisher, '新星出版社');
      expect(chartBooks.first.year, '2026-8');
      expect(chartBooks.first.score, '9.1');
      expect(
        chartBooks.first.coverUrl,
        'https://img3.doubanio.com/view/subject/l/public/s35577760.jpg',
      );
      expect(
        chartBooks.first.imageHeaders['Referer'],
        'https://book.douban.com/',
      );

      final top250Books = htmlParser.parseBooks(
        _doubanTop250Html,
        douban,
        douban.feedById('top250')!,
      );
      expect(top250Books, hasLength(1));
      expect(top250Books.first.title, '红楼梦');
      expect(top250Books.first.author, '(清)曹雪芹');
      expect(top250Books.first.publisher, '人民文学出版社');
      expect(top250Books.first.year, '1982-3');
      expect(top250Books.first.score, '9.7');
      expect(top250Books.first.note, '都云作者痴，谁解其中味？');
      expect(
        top250Books.first.coverUrl,
        'https://img3.doubanio.com/view/subject/l/public/s1070959.jpg',
      );

      final bestsellerBooks = jsonParser.parseBooks(
        _doubanRexxarJson,
        douban,
        douban.feedById('bestseller')!,
      );
      expect(bestsellerBooks, hasLength(1));
      expect(bestsellerBooks.first.title, '活着');
      expect(bestsellerBooks.first.author, '余华');
      expect(bestsellerBooks.first.publisher, '作家出版社');
      expect(bestsellerBooks.first.year, '2012-8');
      expect(bestsellerBooks.first.score, '9.4');
      expect(bestsellerBooks.first.summary, '一部关于苦难与生存韧性的当代经典。');
      expect(
        bestsellerBooks.first.coverUrl,
        'https://img9.doubanio.com/view/subject/l/public/s29869926.jpg',
      );
    });

    test('stripJsonpWrapper 能安全剥离 JSONP 包装', () {
      expect(
        stripJsonpWrapper('/**/cb_123({"items":[{"title":"沙丘"}]});'),
        '{"items":[{"title":"沙丘"}]}',
      );
      expect(stripJsonpWrapper('{"ok":true}'), '{"ok":true}');
    });

    test('assets/discover-rules.json 与内嵌兜底规则保持一致且通过校验', () {
      final assetRaw = File('assets/discover-rules.json').readAsStringSync();
      final assetCfg = DiscoverRulesConfig.fromJsonString(assetRaw);
      final bundledCfg = DiscoverRulesConfig.bundledFallback();
      expect(validateDiscoverRulesConfig(assetCfg), isNull);
      expect(assetCfg.toJson(), bundledCfg.toJson());
    });
  });

  group('DiscoverRepository 远程配置、缓存与容灾', () {
    test('远程规则拉取、JSON 源动态切换、校验拒绝与恢复默认', () async {
      final configStore = MemoryDiscoverConfigStore();
      final cacheStore = MemoryDiscoverCacheStore();
      var currentTime = DateTime.utc(2026, 11, 26, 8, 0);
      var standaloneCfg = const StandaloneConfig(
        discoverConfigUrl: 'https://example.com/rules.json',
        ttsDownloadMirror: 'github',
      );

      var remoteMode = 'valid';
      final adapter = _RawRouterAdapter((options) {
        final url = options.uri.toString();
        if (url == 'https://example.com/rules.json') {
          if (remoteMode == 'valid') {
            return (
              status: 200,
              body: jsonEncode(<String, dynamic>{
                'schema_version': 1,
                'config_version': '2026.12.01.1',
                'default_source_id': 'custom_json',
                'sources': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'custom_json',
                    'name': '自定义 JSON 荐书源',
                    'enabled': true,
                    'mode': 'json',
                    'base_url': 'https://api.example.com',
                    'cache_ttl_hours': 6,
                    'min_request_interval_ms': 0,
                    'feeds': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'picks',
                        'title': '本周推荐',
                        'kind': 'books',
                        'url': '/picks.json',
                        'jsonp': true,
                        'items_path': 'data.list',
                        'fields': <String, dynamic>{
                          'title': <String, dynamic>{'path': 'name'},
                          'author': <String, dynamic>{'path': 'writer'},
                          'score': <String, dynamic>{'path': 'rating'},
                        },
                      },
                    ],
                  },
                ],
              }),
              headers: null,
            );
          }
          if (remoteMode == 'bad_schema') {
            return (
              status: 200,
              body: jsonEncode(<String, dynamic>{
                'schema_version': 99,
                'sources': <dynamic>[],
              }),
              headers: null,
            );
          }
          return (status: 200, body: '{broken json', headers: null);
        }
        if (url == 'https://api.example.com/picks.json') {
          return (
            status: 200,
            body:
                'cb({"data":{"list":[{"name":"基地","writer":"阿西莫夫","rating":9.2}]}});',
            headers: null,
          );
        }
        return (status: 404, body: 'not found', headers: null);
      });

      final repo = DiscoverRepository(
        dio: Dio()..httpClientAdapter = adapter,
        configStore: configStore,
        cacheStore: cacheStore,
        readStandaloneConfig: () => standaloneCfg,
        now: () => currentTime,
        delay: (_) async {},
      );

      // 1. 初始加载内置规则（包含 tstrs 与 douban 双源）
      final initial = await repo.loadActiveConfig();
      expect(initial.origin, DiscoverConfigOrigin.bundled);
      expect(initial.config.enabledSources.map((s) => s.id), [
        'tstrs',
        'douban',
      ]);

      // 2. 拉取合法远程规则后切换为远程 JSON 源
      final updateOk = await repo.refreshRemoteConfig();
      expect(updateOk.updated, isTrue);
      expect(updateOk.snapshot.origin, DiscoverConfigOrigin.remoteCache);
      expect(updateOk.snapshot.config.configVersion, '2026.12.01.1');

      final feed = await repo.loadFeed('custom_json', 'picks');
      expect(feed.books, hasLength(1));
      expect(feed.books.first.title, '基地');
      expect(feed.books.first.author, '阿西莫夫');
      expect(feed.fromCache, isFalse);

      // 3. TTL 内再次加载命中本地缓存（不新增 HTTP 请求）
      final reqCountBeforeCache = adapter.requests.length;
      final cachedFeed = await repo.loadFeed('custom_json', 'picks');
      expect(cachedFeed.fromCache, isTrue);
      expect(cachedFeed.isStale, isFalse);
      expect(adapter.requests.length, reqCountBeforeCache);

      // 4. 远程返回非法 schema 或损坏 JSON 时拒绝覆盖已有远程规则
      remoteMode = 'bad_schema';
      final badSchemaRes = await repo.refreshRemoteConfig();
      expect(badSchemaRes.updated, isFalse);
      expect(badSchemaRes.snapshot.config.configVersion, '2026.12.01.1');

      remoteMode = 'corrupt';
      final corruptRes = await repo.refreshRemoteConfig();
      expect(corruptRes.updated, isFalse);
      final stillActive = await repo.loadActiveConfig();
      expect(stillActive.config.configVersion, '2026.12.01.1');

      // 5. 缓存过期且远端失效时自动回退旧缓存（isStale=true）
      currentTime = currentTime.add(const Duration(hours: 8));
      final offlineAdapter = _RawRouterAdapter(
        (_) => (status: 503, body: 'unavailable', headers: null),
      );
      final offlineRepo = DiscoverRepository(
        dio: Dio()..httpClientAdapter = offlineAdapter,
        configStore: configStore,
        cacheStore: cacheStore,
        readStandaloneConfig: () => standaloneCfg,
        now: () => currentTime,
        delay: (_) async {},
      );
      final staleFeed = await offlineRepo.loadFeed('custom_json', 'picks');
      expect(staleFeed.fromCache, isTrue);
      expect(staleFeed.isStale, isTrue);
      expect(staleFeed.books.first.title, '基地');

      // 6. 恢复内置默认规则
      final reset = await repo.resetToBundledConfig();
      expect(reset.origin, DiscoverConfigOrigin.bundled);
      expect(reset.config.sourceById('tstrs'), isNotNull);
      expect(reset.config.sourceById('douban'), isNotNull);
    });

    test('validateDiscoverConfigUrl 与 validateDiscoverRulesConfig 拦截非法协议', () {
      expect(validateDiscoverConfigUrl(''), isNull);
      expect(validateDiscoverConfigUrl('https://example.com/a.json'), isNull);
      expect(validateDiscoverConfigUrl('file:///etc/passwd'), isNotNull);

      final bad = DiscoverRulesConfig.fromJson(<String, dynamic>{
        'schema_version': 1,
        'sources': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'bad',
            'name': 'Bad',
            'mode': 'html',
            'base_url': 'file:///tmp',
            'feeds': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'f1',
                'title': 'F1',
                'url': '/',
                'items_selector': '.item',
              },
            ],
          },
        ],
      });
      expect(validateDiscoverRulesConfig(bad), isNotNull);
    });

    test('loadFeed 支持豆瓣 {offset}/{limit} 模板与频道级 headers 覆盖', () async {
      final configStore = MemoryDiscoverConfigStore();
      final cacheStore = MemoryDiscoverCacheStore();
      final adapter = _RawRouterAdapter((options) {
        final url = options.uri.toString();
        if (url.contains('top250')) {
          return (status: 200, body: _doubanTop250Html, headers: null);
        }
        if (url.contains('book_bestseller')) {
          return (status: 200, body: _doubanRexxarJson, headers: null);
        }
        return (status: 404, body: '', headers: null);
      });

      final repo = DiscoverRepository(
        dio: Dio()..httpClientAdapter = adapter,
        configStore: configStore,
        cacheStore: cacheStore,
        readStandaloneConfig: () => const StandaloneConfig(),
        delay: (_) async {},
      );

      final top250Page2 = await repo.loadFeed('douban', 'top250', page: 2);
      expect(top250Page2.books.first.title, '红楼梦');
      expect(adapter.requests.last.uri.queryParameters['start'], '25');

      final bestseller = await repo.loadFeed('douban', 'bestseller');
      expect(bestseller.books.first.title, '活着');
      final lastReq = adapter.requests.last;
      expect(lastReq.headers['Referer'], 'https://m.douban.com/book/');
      expect(lastReq.uri.queryParameters['count'], '20');
    });
  });

  group('Discover UI 组件与设置页', () {
    final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);

    testWidgets('DiscoverSection 支持双源切换（SaltyLeo ↔ 豆瓣读书）与跳搜回调', (
      tester,
    ) async {
      final adapter = _RawRouterAdapter((options) {
        final url = options.uri.toString();
        if (url == 'https://tstrs.me/') {
          return (status: 200, body: _tstrsHomeHtml, headers: null);
        }
        if (url == 'https://book.douban.com/chart') {
          return (status: 200, body: _doubanChartHtml, headers: null);
        }
        if (url.contains('book_bestseller')) {
          return (status: 200, body: _doubanRexxarJson, headers: null);
        }
        return (status: 404, body: '', headers: null);
      });

      final cfgStorage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(discoverConfigUrl: ''),
      );
      StandaloneConfigStore.setForTest(
        const StandaloneConfig(discoverConfigUrl: ''),
        storage: cfgStorage,
      );

      String? searchedQuery;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            standaloneConfigStorageProvider.overrideWithValue(cfgStorage),
            discoverConfigStoreProvider.overrideWithValue(
              MemoryDiscoverConfigStore(),
            ),
            discoverCacheStoreProvider.overrideWithValue(
              MemoryDiscoverCacheStore(),
            ),
            discoverDioProvider.overrideWithValue(
              Dio()..httpClientAdapter = adapter,
            ),
          ],
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, darkTokens),
            home: Scaffold(
              body: SingleChildScrollView(
                child: DiscoverSection(
                  searchAvailable: true,
                  onSearchBook: (q) => searchedQuery = q,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 默认展示 SaltyLeo 首页荐书
      expect(find.text('1984：当我们再无秘密可言'), findsOneWidget);
      expect(find.byKey(const Key('discover_source_chip_douban')), findsOneWidget);

      // 切换至豆瓣读书
      await tester.tap(find.byKey(const Key('discover_source_chip_douban')));
      await tester.pumpAndSettle();
      expect(find.text('落在我身上的雨'), findsOneWidget);

      // 切换豆瓣畅销图书榜（JSON 模式）
      await tester.tap(find.byKey(const Key('discover_feed_chip_bestseller')));
      await tester.pumpAndSettle();
      expect(find.text('活着'), findsOneWidget);

      // 点击图书弹出详情并触发「在书源中搜索此书」
      await tester.tap(find.byKey(const Key('discover_book_card_0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('discover_book_detail_sheet')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('discover_detail_search_button')));
      await tester.pumpAndSettle();

      expect(searchedQuery, '活着');
    });

    testWidgets('DiscoverSettingsPage 支持远程规则更新与恢复默认规则', (tester) async {
      final adapter = _RawRouterAdapter((options) {
        final url = options.uri.toString();
        if (url == 'https://rules.example.com/rules.json') {
          return (
            status: 200,
            body: jsonEncode(<String, dynamic>{
              'schema_version': 1,
              'config_version': '2026.12.20.1',
              'default_source_id': 'remote_pick',
              'sources': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'remote_pick',
                  'name': '远端新源',
                  'enabled': true,
                  'mode': 'json',
                  'base_url': 'https://api.example.com',
                  'feeds': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'hot',
                      'title': '热榜',
                      'kind': 'books',
                      'url': '/hot.json',
                      'items_path': 'books',
                      'fields': <String, dynamic>{
                        'title': <String, dynamic>{'path': 'title'},
                      },
                    },
                  ],
                },
              ],
            }),
            headers: null,
          );
        }
        if (url == 'https://api.example.com/hot.json') {
          return (
            status: 200,
            body: jsonEncode(<String, dynamic>{
              'books': <Map<String, dynamic>>[
                <String, dynamic>{'title': '三体'},
              ],
            }),
            headers: null,
          );
        }
        return (status: 404, body: '', headers: null);
      });

      final cfgStorage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(discoverConfigUrl: ''),
      );
      StandaloneConfigStore.setForTest(
        const StandaloneConfig(discoverConfigUrl: ''),
        storage: cfgStorage,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            standaloneConfigStorageProvider.overrideWithValue(cfgStorage),
            discoverConfigStoreProvider.overrideWithValue(
              MemoryDiscoverConfigStore(),
            ),
            discoverCacheStoreProvider.overrideWithValue(
              MemoryDiscoverCacheStore(),
            ),
            discoverDioProvider.overrideWithValue(
              Dio()..httpClientAdapter = adapter,
            ),
          ],
          child: MaterialApp(
            theme: buildEchoTheme(Brightness.dark, darkTokens),
            home: const DiscoverSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('内置默认规则'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('discover_config_url_field')),
        'https://rules.example.com/rules.json',
      );
      await tester.tap(find.byKey(const Key('discover_config_refresh_button')));
      await tester.pumpAndSettle();

      expect(find.text('远程配置缓存'), findsOneWidget);
      expect(find.text('v2026.12.20.1'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('discover_config_reset_button')),
      );
      await tester.tap(find.byKey(const Key('discover_config_reset_button')));
      await tester.pumpAndSettle();

      expect(find.text('内置默认规则'), findsOneWidget);
      expect(find.text('v2026.11.26.4'), findsOneWidget);
    });

    testWidgets(
      '360x800 narrow mobile SearchPage keeps discover chrome compact and expands filters on focus',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final adapter = _RawRouterAdapter((options) {
          return (
            status: 200,
            body: jsonEncode(<String, dynamic>{
              'books': <Map<String, dynamic>>[
                for (var i = 0; i < 6; i++)
                  <String, dynamic>{
                    'title': '推荐书籍 ${i + 1}',
                    'author': '作者 ${i + 1} · 2026',
                  },
              ],
            }),
            headers: null,
          );
        });

        final cfgStorage = MemoryStandaloneConfigStorage(
          const StandaloneConfig(ebookApiBaseUrl: 'http://127.0.0.1:8091'),
        );
        StandaloneConfigStore.setForTest(
          const StandaloneConfig(ebookApiBaseUrl: 'http://127.0.0.1:8091'),
          storage: cfgStorage,
        );

        final configStore = MemoryDiscoverConfigStore(
          StoredRemoteDiscoverRules(
            rawJson: jsonEncode(<String, dynamic>{
              'schema_version': DiscoverConfigDefaults.supportedSchemaVersion,
              'version': 'v2026.12.01.1',
              'sources': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'tstrs',
                  'name': 'SaltyLeo 的书架',
                  'enabled': true,
                  'mode': 'json',
                  'base_url': 'https://tstrs.example.com',
                  'feeds': <Map<String, dynamic>>[
                    for (final feed in const [
                      ('trending', '大家都在看'),
                      ('hot', '热搜榜'),
                      ('classics', '殿堂经典'),
                      ('top', '高分佳作'),
                    ])
                      <String, dynamic>{
                        'id': feed.$1,
                        'title': feed.$2,
                        'kind': 'books',
                        'url': '/${feed.$1}.json',
                        'items_path': 'books',
                        'fields': <String, dynamic>{
                          'title': <String, dynamic>{'path': 'title'},
                          'author': <String, dynamic>{'path': 'author'},
                        },
                      },
                  ],
                },
                <String, dynamic>{
                  'id': 'douban',
                  'name': '豆瓣读书',
                  'enabled': true,
                  'mode': 'json',
                  'base_url': 'https://douban.example.com',
                  'feeds': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'weekly',
                      'title': '本周热门',
                      'kind': 'books',
                      'url': '/weekly.json',
                      'items_path': 'books',
                      'fields': <String, dynamic>{
                        'title': <String, dynamic>{'path': 'title'},
                      },
                    },
                  ],
                },
              ],
            }),
            remoteUrl: 'https://rules.example.com/rules.json',
            fetchedAt: DateTime.utc(2026, 12, 1),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              standaloneConfigStorageProvider.overrideWithValue(cfgStorage),
              echoApiProvider.overrideWithValue(
                EchoApi(
                  baseUri: Uri.parse('http://127.0.0.1:8091'),
                  tokenStore: MemoryTokenStore(),
                ),
              ),
              audioEngineProvider.overrideWithValue(FakeAudioEngine()),
              progressStoreProvider.overrideWithValue(MemoryProgressStore()),
              search_ctrl.searchControllerProvider.overrideWith(
                (ref) => search_ctrl.SearchController(
                  ref.watch(echoApiProvider),
                  historyStore: search_ctrl.MemorySearchHistoryStore(
                    const <String>['一地鸡毛', '三体'],
                  ),
                ),
              ),
              discoverConfigStoreProvider.overrideWithValue(configStore),
              discoverCacheStoreProvider.overrideWithValue(
                MemoryDiscoverCacheStore(),
              ),
              discoverDioProvider.overrideWithValue(
                Dio()..httpClientAdapter = adapter,
              ),
            ],
            child: MaterialApp(
              theme: buildEchoTheme(Brightness.dark, darkTokens),
              home: const Scaffold(body: SearchPage()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('search_epub_filter')), findsNothing);
        expect(find.byKey(const Key('search_filter_button')), findsOneWidget);
        expect(find.byKey(const Key('search_history')), findsOneWidget);
        expect(
          find.byKey(const Key('discover_source_chip_douban')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('discover_feed_chip_hot')), findsOneWidget);
        expect(find.byKey(const Key('discover_book_card_0')), findsOneWidget);

        final firstBookTop = tester
            .getTopLeft(find.byKey(const Key('discover_book_card_0')))
            .dy;
        expect(firstBookTop, lessThan(280));

        await tester.tap(find.byKey(const Key('search_field')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('search_epub_filter')), findsOneWidget);
        expect(find.byKey(const Key('search_filter_button')), findsOneWidget);
      },
    );

    test('assets/discover-rules.json 与内置兜底规则完全一致且通过校验', () {
      final assetFile = File('assets/discover-rules.json').existsSync()
          ? File('assets/discover-rules.json')
          : File('echo-app/assets/discover-rules.json');
      final assetRaw = assetFile.readAsStringSync();
      expect(jsonDecode(assetRaw), jsonDecode(kBundledDiscoverRulesJson));

      final parsed = DiscoverRulesConfig.fromJsonString(assetRaw);
      expect(validateDiscoverRulesConfig(parsed), isNull);
      expect(parsed.configVersion, '2026.11.26.4');
      expect(
        parsed.sourceById('douban')?.effectiveImageHeaders['User-Agent'],
        isNotEmpty,
      );
      expect(parsed.sourceById('tstrs')?.bookDetail?.isConfigured, isTrue);
      expect(parsed.sourceById('douban')?.bookDetail?.isConfigured, isTrue);
    });

    test('HtmlDiscoverParser.parseBookDetail 提取 SaltyLeo 内容简介与动态扩展字段', () {
      const saltyDetailHtml = '''
<html><body>
<div class="ratio ratio-book book-hero-cover" data-cover
     data-cover-src="https://la-img.tstrs.me/full.jpg"
     data-cover-thumb="https://la-img.tstrs.me/thumb_360.jpg"></div>
<span class="book-hero-score">4.8</span>
<dl class="book-meta">
  <div class="book-meta-stats">
    <div class="book-meta-item book-meta-item-split"><dt>页数</dt><dd>286</dd></div>
    <div class="book-meta-item book-meta-item-split"><dt>字数</dt><dd>2.8万字</dd></div>
    <div class="book-meta-item book-meta-item-split"><dt>章节数</dt><dd>174</dd></div>
    <div class="book-meta-item book-meta-item-split"><dt>ISBN</dt><dd>9787572624421</dd></div>
  </div>
</dl>
<div class="book-tags">
  <a class="book-tag" href="/tag/1">政治讽喻</a>
  <a class="book-tag" href="/tag/2">人性探讨</a>
</div>
<h2 class="h6 section-title"><span>内容简介</span></h2>
<div class="bg-body-secondary">
  <div class="text-body">第一段未闭合。</p><p>第二段内容。</p><p>第三段结论。</p></div>
</div>
<div class="book-editorial">深刻揭示权力与隐私议题。</div>
<div class="book-audience is-fit">
  <ul class="book-point-list">
    <li>关心反乌托邦文学的读者</li>
    <li>喜欢政治寓言的思考者</li>
  </ul>
</div>
<div class="book-audience is-unfit">
  <ul class="book-point-list">
    <li>只期待轻松娱乐的读者</li>
  </ul>
</div>
<ol class="book-advice-list">
  <li>先一口气读完故事</li>
  <li>可与动物农场对读</li>
</ol>
</body></html>
''';
      final config = DiscoverRulesConfig.bundledFallback();
      final tstrs = config.sourceById('tstrs')!;
      final parser = HtmlDiscoverParser();
      const baseBook = DiscoverBook(
        title: '1984',
        author: '乔治·奥威尔',
        publisher: '北京慢半拍',
        year: '2026',
        detailUrl: 'https://tstrs.me/b/1984',
        sourceId: 'tstrs',
      );

      final parsed = parser.parseBookDetail(
        saltyDetailHtml,
        tstrs,
        tstrs.bookDetail!,
        baseBook: baseBook,
      );

      expect(parsed.author, '乔治·奥威尔');
      expect(parsed.publisher, '北京慢半拍');
      expect(parsed.summary, '第一段未闭合。\n\n第二段内容。\n\n第三段结论。');
      expect(parsed.score, '4.8');
      expect(parsed.pages, '286');
      expect(parsed.wordCount, '2.8万字');
      expect(parsed.chapterCount, '174');
      expect(parsed.isbn, '9787572624421');
      expect(parsed.isbnSearchQuery, '9787572624421');
      final roundTrip = DiscoverBook.fromJson(parsed.toJson());
      expect(roundTrip.pages, '286');
      expect(roundTrip.wordCount, '2.8万字');
      expect(roundTrip.chapterCount, '174');
      expect(roundTrip.isbn, '9787572624421');
      expect(parsed.coverUrl, 'https://la-img.tstrs.me/thumb_360.jpg');
      expect(parsed.extraSections.length, 5);
      expect(parsed.extraSections[0].key, 'editorial');
      expect(parsed.extraSections[0].style, 'quote');
      expect(parsed.extraSections[0].text, '深刻揭示权力与隐私议题。');
      expect(parsed.extraSections[1].key, 'audience_fit');
      expect(parsed.extraSections[1].style, 'positive_list');
      expect(parsed.extraSections[1].items, <String>[
        '关心反乌托邦文学的读者',
        '喜欢政治寓言的思考者',
      ]);
      expect(parsed.extraSections[2].key, 'audience_unfit');
      expect(parsed.extraSections[2].style, 'negative_list');
      expect(parsed.extraSections[3].key, 'reading_advice');
      expect(parsed.extraSections[3].style, 'list');
      expect(parsed.extraSections[4].key, 'tags');
      expect(parsed.extraSections[4].style, 'tags');
      expect(parsed.extraSections[4].items, <String>['政治讽喻', '人性探讨']);
    });

    test('HtmlDiscoverParser.parseBookDetail 兼容豆瓣长短简介、去样式文本、短评截断及畅销榜链接改写', () {
      const doubanLongDetailHtml = '''
<html><body>
<div id="mainpic">
  <a class="nbg" href="https://img3.doubanio.com/view/subject/l/public/s999.jpg">
    <img src="https://img3.doubanio.com/view/subject/s/public/s999.jpg"/>
  </a>
</div>
<div id="info">
  <span><span class="pl">作者</span>: <a href="/author/1">余华</a></span><br/>
  <span class="pl">出版社:</span> 作家出版社<br/>
  <span class="pl">ISBN:</span> 9787513364065<br/>
  <span class="pl">页数:</span> 336<br/>
  <span class="pl">字数:</span> 12万字<br/>
</div>
<h2><span>内容简介</span></h2>
<div class="indent" id="link-report">
  <span class="short">
    <style>.intro p{text-indent:2em;}</style>
    <div class="intro"><p>节选简介(展开全部)</p></div>
  </span>
  <span class="all hidden">
    <style>.intro p{text-indent:2em;}</style>
    <div class="intro"><p>完整第一段。</p><p>完整第二段。</p></div>
  </span>
</div>
<h2><span>作者简介</span></h2>
<link rel="stylesheet" href="/author.css">
<div class="indent">
  <div>
    <style>.intro p{text-indent:2em;}</style>
    <div class="intro"><p>余华，中国当代作家。</p></div>
  </div>
</div>
<p class="comment-content"><span class="short">短评1</span></p>
<p class="comment-content"><span class="short">短评2</span></p>
<p class="comment-content"><span class="short">短评3</span></p>
<p class="comment-content"><span class="short">短评4应被截断</span></p>
</body></html>
''';
      const doubanShortDetailHtml = '''
<html><body>
<div class="indent" id="link-report">
  <div>
    <style>.intro p{text-indent:2em;}</style>
    <div class="intro"><p>简短内容简介。</p><p>(展开全部)</p></div>
  </div>
</div>
</body></html>
''';
      final config = DiscoverRulesConfig.bundledFallback();
      final douban = config.sourceById('douban')!;
      final parser = HtmlDiscoverParser();

      final longParsed = parser.parseBookDetail(
        doubanLongDetailHtml,
        douban,
        douban.bookDetail!,
        baseBook: const DiscoverBook(
          title: '活着',
          detailUrl: 'https://book.douban.com/subject/4913064/',
          sourceId: 'douban',
          extraSections: <DiscoverExtraSection>[
            DiscoverExtraSection(
              key: 'editorial_quote',
              label: '编辑荐语',
              style: 'quote',
              text: '人是为活着本身而活着的。',
            ),
          ],
        ),
      );

      expect(longParsed.summary, '完整第一段。\n\n完整第二段。');
      expect(longParsed.pages, '336');
      expect(longParsed.wordCount, '12万字');
      expect(longParsed.isbn, '9787513364065');
      expect(
        longParsed.coverUrl,
        'https://img3.doubanio.com/view/subject/l/public/s999.jpg',
      );
      expect(
        longParsed.imageHeaders['User-Agent'],
        douban.effectiveImageHeaders['User-Agent'],
      );
      expect(longParsed.extraSections.map((s) => s.key).toList(), <String>[
        'editorial_quote',
        'hot_comments',
        'author_intro',
      ]);
      expect(longParsed.extraSections[1].items, <String>['短评1', '短评2', '短评3']);
      expect(longParsed.extraSections[2].text, '余华，中国当代作家。');

      final shortParsed = parser.parseBookDetail(
        doubanShortDetailHtml,
        douban,
        douban.bookDetail!,
        baseBook: const DiscoverBook(title: '短简介书', sourceId: 'douban'),
      );
      expect(shortParsed.summary, '简短内容简介。');

      final bestsellerFeed = douban.feedById('bestseller')!;
      final jsonBooks = JsonDiscoverParser().parseBooks(
        jsonEncode(<String, dynamic>{
          'subject_collection_items': <Map<String, dynamic>>[
            <String, dynamic>{
              'title': '活着',
              'info': '余华/作家出版社/2012-8',
              'url': 'https://www.douban.com/doubanapp/dispatch/book/4913064',
              'tags': <String>['余华', '经典'],
            },
          ],
        }),
        douban,
        bestsellerFeed,
      );
      expect(jsonBooks.single.detailUrl, 'https://book.douban.com/subject/4913064');
      expect(jsonBooks.single.extraSections.single.items, <String>['余华', '经典']);
    });

    test('DiscoverRepository.loadBookDetail 命中缓存且读缓存列表时补齐图片请求头', () async {
      final cache = MemoryDiscoverCacheStore();
      final cfgStore = MemoryDiscoverConfigStore();
      var detailRequests = 0;

      final adapter = _RawRouterAdapter((options) {
        detailRequests++;
        return (
          status: 200,
          body: '''
<html><body>
<div class="indent" id="link-report">
  <div class="intro"><p>详情页缓存简介。</p></div>
</div>
<p class="comment-content"><span class="short">非常震撼</span></p>
</body></html>
''',
          headers: null,
        );
      });

      await cache.write(
        'feed_douban_chart_p1',
        DiscoverFeedData(
          sourceId: 'douban',
          feedId: 'chart',
          title: '热门图书榜',
          fetchedAt: DateTime.now().toUtc(),
          books: const <DiscoverBook>[
            DiscoverBook(
              title: '旧缓存图书',
              sourceId: 'douban',
              detailUrl: 'https://book.douban.com/subject/1001/',
              imageHeaders: <String, String>{
                'Referer': 'https://book.douban.com/',
              },
            ),
          ],
        ),
      );

      final repo = DiscoverRepository(
        dio: Dio()..httpClientAdapter = adapter,
        configStore: cfgStore,
        cacheStore: cache,
        readStandaloneConfig: () => const StandaloneConfig(),
      );

      final feedData = await repo.loadFeed('douban', 'chart');
      expect(
        feedData.books.single.imageHeaders['User-Agent'],
        isNotEmpty,
      );
      expect(detailRequests, 0);

      final first = await repo.loadBookDetail(feedData.books.single);
      expect(detailRequests, 1);
      expect(first.summary, '详情页缓存简介。');
      expect(first.extraSections.single.items, <String>['非常震撼']);

      final second = await repo.loadBookDetail(feedData.books.single);
      expect(detailRequests, 1);
      expect(second.summary, '详情页缓存简介。');
    });

    test('EchoNetworkImage 严格覆写 User-Agent 与 Referer 而不附带 Dart/UA', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const customUa =
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) CustomEchoTest/1.0';
      const customReferer = 'https://book.douban.com/';
      final pngBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );

      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        List<String>? capturedUa;
        List<String>? capturedReferer;
        server.listen((req) {
          capturedUa = req.headers[HttpHeaders.userAgentHeader];
          capturedReferer = req.headers[HttpHeaders.refererHeader];
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('image', 'png')
            ..add(pngBytes);
          unawaited(req.response.close());
        });

        final provider = EchoNetworkImage(
          'http://127.0.0.1:${server.port}/cover.png',
          headers: const <String, String>{
            'User-Agent': customUa,
            'Referer': customReferer,
          },
        );

        final completer = Completer<void>();
        final stream = provider.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            info.dispose();
            stream.removeListener(listener);
            if (!completer.isCompleted) completer.complete();
          },
          onError: (err, st) {
            stream.removeListener(listener);
            if (!completer.isCompleted) completer.completeError(err, st);
          },
        );
        stream.addListener(listener);
        await completer.future;

        expect(capturedUa, <String>[customUa]);
        expect(capturedReferer, <String>[customReferer]);
      }, _DirectHttpOverrides());
    });

    testWidgets(
      '360x800 下点击 SaltyLeo 与豆瓣书籍均能懒加载详情并动态渲染各自扩展字段',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final adapter = _RawRouterAdapter((options) {
          final url = options.uri.toString();
          if (url == 'https://tstrs.me/') {
            return (status: 200, body: _tstrsHomeHtml, headers: null);
          }
          if (url == 'https://tstrs.me/b/1984%E5%BD%93%E6%88%91%E4%BB%AC%E5%86%8D%E6%97%A0%E7%A7%98%E5%AF%86%E5%8F%AF%E8%A8%80' ||
              url == 'https://tstrs.me/b/1984当我们再无秘密可言') {
            return (
              status: 200,
              body: '''
<html><body>
<dl class="book-meta">
  <div class="book-meta-stats">
    <div class="book-meta-item book-meta-item-split"><dt>页数</dt><dd>286</dd></div>
    <div class="book-meta-item book-meta-item-split"><dt>字数</dt><dd>2.8万字</dd></div>
    <div class="book-meta-item book-meta-item-split"><dt>章节数</dt><dd>174</dd></div>
    <div class="book-meta-item book-meta-item-split"><dt>ISBN</dt><dd>9787572624421</dd></div>
  </div>
</dl>
<h2 class="h6 section-title"><span>内容简介</span></h2>
<div class="bg-body-secondary">
  <div class="text-body"><p>这是1984详情页简介第一段。</p><p>第二段补充。</p></div>
</div>
<div class="book-editorial">推荐理由：发人深省。</div>
<div class="book-audience is-fit">
  <ul class="book-point-list"><li>喜欢经典文学的读者</li></ul>
</div>
<div class="book-audience is-unfit">
  <ul class="book-point-list"><li>偏好轻松甜宠的读者</li></ul>
</div>
</body></html>
''',
              headers: null,
            );
          }
          if (url == 'https://book.douban.com/chart') {
            return (
              status: 200,
              body: '''
<html><body>
<li class="media clearfix">
  <a href="https://book.douban.com/subject/38461487/">
    <img class="subject-cover" src="https://img3.doubanio.com/view/subject/s/public/s1.jpg"/>
  </a>
  <h2><a href="https://book.douban.com/subject/38461487/">落在我身上的雨</a></h2>
  <p class="subject-abstract color-gray">陆庆屹 / 2026-8 / 新星出版社</p>
  <p class="subject-rating"><span class="font-small">9.1</span></p>
</li>
</body></html>
''',
              headers: null,
            );
          }
          if (url == 'https://book.douban.com/top250?start=0') {
            return (
              status: 200,
              body: '''
<html><body>
<table><tr class="item">
  <td><a class="nbg" href="https://book.douban.com/subject/1007305/"><img src="https://img9.doubanio.com/view/subject/s/public/s2.jpg"/></a></td>
  <td>
    <div class="pl2"><a title="红楼梦" href="https://book.douban.com/subject/1007305/">红楼梦</a></div>
    <p class="pl">曹雪芹 / 人民文学出版社 / 1996-12</p>
    <span class="rating_nums">9.6</span>
    <p class="quote"><span class="inq">都云作者痴，谁解其中味？</span></p>
  </td>
</tr></table>
</body></html>
''',
              headers: null,
            );
          }
          if (url == 'https://book.douban.com/subject/1007305/') {
            return (
              status: 200,
              body: '''
<html><body>
<div id="info">
  <span class="pl">ISBN:</span> 9787513364065<br/>
  <span class="pl">页数:</span> 336<br/>
</div>
<div class="indent" id="link-report">
  <div class="intro"><p>中国古典四大名著之首。</p></div>
</div>
<p class="comment-content"><span class="short">百读不厌。</span></p>
<h2><span>作者简介</span></h2>
<div class="indent"><div class="intro"><p>曹雪芹，清代小说家。</p></div></div>
</body></html>
''',
              headers: null,
            );
          }
          return (status: 404, body: '', headers: null);
        });

        final cfgStorage = MemoryStandaloneConfigStorage(
          const StandaloneConfig(),
        );
        StandaloneConfigStore.setForTest(
          const StandaloneConfig(),
          storage: cfgStorage,
        );
        final searchedQueries = <String>[];

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              standaloneConfigStorageProvider.overrideWithValue(cfgStorage),
              discoverConfigStoreProvider.overrideWithValue(
                MemoryDiscoverConfigStore(),
              ),
              discoverCacheStoreProvider.overrideWithValue(
                MemoryDiscoverCacheStore(),
              ),
              discoverDioProvider.overrideWithValue(
                Dio()..httpClientAdapter = adapter,
              ),
            ],
            child: MaterialApp(
              theme: buildEchoTheme(Brightness.dark, darkTokens),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: DiscoverSection(
                    searchAvailable: true,
                    onSearchBook: searchedQueries.add,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 打开 SaltyLeo 图书详情并校验基础统计信息条、简介与适合/不适合动态区块
        await tester.tap(find.byKey(const Key('discover_book_card_0')));
        await tester.pumpAndSettle();

        final sheetScrollable = find.descendant(
          of: find.byKey(const Key('discover_book_detail_sheet')),
          matching: find.byType(Scrollable),
        );

        expect(find.byKey(const Key('discover_detail_meta_strip')), findsOneWidget);
        expect(find.text('286 页'), findsOneWidget);
        expect(find.text('2.8万字'), findsOneWidget);
        expect(find.text('174 章'), findsOneWidget);
        expect(find.text('9787572624421'), findsOneWidget);
        expect(find.byKey(const Key('discover_detail_summary')), findsOneWidget);
        expect(find.textContaining('这是1984详情页简介第一段。'), findsOneWidget);
        expect(find.byKey(const Key('discover_extra_editorial')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('discover_extra_audience_fit')),
          180,
          scrollable: sheetScrollable,
        );
        expect(find.byKey(const Key('discover_extra_audience_fit')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('discover_extra_audience_unfit')),
          180,
          scrollable: sheetScrollable,
        );
        expect(find.byKey(const Key('discover_extra_audience_unfit')), findsOneWidget);
        expect(find.byKey(const Key('discover_detail_search_button')), findsOneWidget);
        expect(find.byKey(const Key('discover_detail_copy_button')), findsOneWidget);

        // 点击 SaltyLeo ISBN 触发按 ISBN 搜索且保持详情页留在返回栈中
        await tester.scrollUntilVisible(
          find.byKey(const Key('discover_detail_isbn_button')),
          -180,
          scrollable: sheetScrollable,
        );
        await tester.tap(find.byKey(const Key('discover_detail_isbn_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('discover_book_detail_sheet')),
          findsOneWidget,
        );
        expect(searchedQueries, <String>['9787572624421']);

        Navigator.of(
          tester.element(find.byKey(const Key('discover_book_detail_sheet'))),
        ).pop();
        await tester.pumpAndSettle();

        // 切换豆瓣 Top 250 检验豆瓣页数/ISBN、编辑荐语无重复、短评、作者简介与 ISBN 点击搜索
        await tester.tap(find.byKey(const Key('discover_source_chip_douban')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('discover_feed_chip_top250')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('discover_book_card_0')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('discover_detail_meta_strip')), findsOneWidget);
        expect(find.text('336 页'), findsOneWidget);
        expect(find.text('9787513364065'), findsOneWidget);
        expect(find.text('都云作者痴，谁解其中味？'), findsOneWidget);
        expect(find.byKey(const Key('discover_extra_editorial_quote')), findsOneWidget);
        expect(find.byKey(const Key('discover_detail_summary')), findsOneWidget);
        expect(find.text('中国古典四大名著之首。'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('discover_extra_hot_comments')),
          180,
          scrollable: sheetScrollable,
        );
        expect(find.byKey(const Key('discover_extra_hot_comments')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('discover_extra_author_intro')),
          180,
          scrollable: sheetScrollable,
        );
        expect(find.byKey(const Key('discover_extra_author_intro')), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const Key('discover_detail_isbn_button')),
          -180,
          scrollable: sheetScrollable,
        );
        await tester.tap(find.byKey(const Key('discover_detail_isbn_button')));
        await tester.pumpAndSettle();
        expect(searchedQueries, <String>['9787572624421', '9787513364065']);
      },
    );

    testWidgets(
      '360x800 下推荐详情、ISBN 搜索结果与搜书详情均进入路由栈且可逐级返回',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final discoverAdapter = _RawRouterAdapter((options) {
          final url = options.uri.toString();
          if (url == 'https://tstrs.me/') {
            return (status: 200, body: _tstrsHomeHtml, headers: null);
          }
          if (url == 'https://tstrs.me/b/1984%E5%BD%93%E6%88%91%E4%BB%AC%E5%86%8D%E6%97%A0%E7%A7%98%E5%AF%86%E5%8F%AF%E8%A8%80' ||
              url == 'https://tstrs.me/b/1984当我们再无秘密可言') {
            return (
              status: 200,
              body: '''
<html><body>
<dl class="book-meta">
  <div class="book-meta-stats">
    <div class="book-meta-item book-meta-item-split"><dt>ISBN</dt><dd>9787572624421</dd></div>
  </div>
</dl>
<h2 class="h6 section-title"><span>内容简介</span></h2>
<div class="bg-body-secondary">
  <div class="text-body"><p>反乌托邦经典简介。</p></div>
</div>
</body></html>
''',
              headers: null,
            );
          }
          return (status: 404, body: '', headers: null);
        });

        final apiAdapter = _RawRouterAdapter((options) {
          final path = options.uri.path;
          if (path == '/api/search') {
            final q = options.uri.queryParameters['q'] ?? '';
            return (
              status: 200,
              body: jsonEncode(<String, dynamic>{
                'books': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'provider': 'zlib',
                    'ref': 'book-ref-isbn',
                    'title': '匹配图书($q)',
                    'authors': <String>['乔治·奥威尔'],
                    'format': 'EPUB',
                    'size': '1.2 MB',
                  },
                ],
                'page': 1,
                'total_pages': 1,
                'provider': 'zlib',
              }),
              headers: const <String, List<String>>{
                Headers.contentTypeHeader: <String>[
                  'application/json; charset=utf-8',
                ],
              },
            );
          }
          if (path.startsWith('/api/providers/zlib/books/')) {
            return (
              status: 200,
              body: jsonEncode(<String, dynamic>{
                'book': <String, dynamic>{
                  'provider': 'zlib',
                  'ref': 'book-ref-isbn',
                  'title': '匹配图书',
                  'authors': <String>['乔治·奥威尔'],
                  'format': 'EPUB',
                  'size': '1.2 MB',
                  'description': '搜索详情页内容简介',
                },
              }),
              headers: const <String, List<String>>{
                Headers.contentTypeHeader: <String>[
                  'application/json; charset=utf-8',
                ],
              },
            );
          }
          return (
            status: 404,
            body: '{}',
            headers: const <String, List<String>>{
              Headers.contentTypeHeader: <String>[
                'application/json; charset=utf-8',
              ],
            },
          );
        });

        final cfgStorage = MemoryStandaloneConfigStorage(
          const StandaloneConfig(ebookApiBaseUrl: 'http://127.0.0.1:8091'),
        );
        StandaloneConfigStore.setForTest(
          const StandaloneConfig(ebookApiBaseUrl: 'http://127.0.0.1:8091'),
          storage: cfgStorage,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              standaloneConfigStorageProvider.overrideWithValue(cfgStorage),
              echoApiProvider.overrideWithValue(
                EchoApi(
                  baseUri: Uri.parse('http://127.0.0.1:8091'),
                  dio: Dio(
                    BaseOptions(baseUrl: 'http://127.0.0.1:8091'),
                  )..httpClientAdapter = apiAdapter,
                  tokenStore: MemoryTokenStore(),
                ),
              ),
              audioEngineProvider.overrideWithValue(FakeAudioEngine()),
              progressStoreProvider.overrideWithValue(MemoryProgressStore()),
              search_ctrl.searchControllerProvider.overrideWith(
                (ref) => search_ctrl.SearchController(
                  ref.watch(echoApiProvider),
                  historyStore: search_ctrl.MemorySearchHistoryStore(),
                ),
              ),
              discoverConfigStoreProvider.overrideWithValue(
                MemoryDiscoverConfigStore(),
              ),
              discoverCacheStoreProvider.overrideWithValue(
                MemoryDiscoverCacheStore(),
              ),
              discoverDioProvider.overrideWithValue(
                Dio()..httpClientAdapter = discoverAdapter,
              ),
            ],
            child: MaterialApp(
              theme: buildEchoTheme(Brightness.dark, darkTokens),
              home: const Scaffold(body: SearchPage()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. 点击推荐书籍 -> 推入 DiscoverBookDetailPage 路由页
        await tester.tap(find.byKey(const Key('discover_book_card_0')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('discover_book_detail_sheet')),
          findsOneWidget,
        );

        // 2. 点击 ISBN -> 推入 SearchResultsPage 路由页并自动按 ISBN 搜索
        await tester.tap(find.byKey(const Key('discover_detail_isbn_button')));
        await tester.pumpAndSettle();
        final resultsField = tester.widget<TextField>(
          find.byKey(const Key('search_results_field')),
        );
        expect(resultsField.controller?.text, '9787572624421');
        expect(
          find.byKey(const Key('search_result_book-ref-isbn')),
          findsOneWidget,
        );

        // 3. 点击搜索结果 -> 推入 SearchBookDetailPage 路由页
        await tester.tap(find.byKey(const Key('search_result_book-ref-isbn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_detail_sheet')), findsOneWidget);
        expect(
          find.byKey(const Key('search_detail_download_convert')),
          findsOneWidget,
        );

        // 4. 逐级返回：搜书详情页 -> 搜索结果页 -> 推荐详情页 -> 发现首页
        expect(
          await Navigator.of(
            tester.element(find.byKey(const Key('search_detail_sheet'))),
          ).maybePop(),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_results')), findsOneWidget);

        expect(
          await Navigator.of(
            tester.element(find.byKey(const Key('search_results'))),
          ).maybePop(),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('discover_book_detail_sheet')),
          findsOneWidget,
        );

        expect(
          await Navigator.of(
            tester.element(find.byKey(const Key('discover_book_detail_sheet'))),
          ).maybePop(),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_title')), findsOneWidget);
        expect(find.byKey(const Key('discover_section')), findsOneWidget);

        // 5. 在发现首页直接输入关键词提交 -> 推入搜索结果页且可返回
        await tester.enterText(find.byKey(const Key('search_field')), '三体');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        final nextResultsField = tester.widget<TextField>(
          find.byKey(const Key('search_results_field')),
        );
        expect(nextResultsField.controller?.text, '三体');
        expect(find.byKey(const Key('search_results')), findsOneWidget);

        expect(
          await Navigator.of(
            tester.element(find.byKey(const Key('search_results'))),
          ).maybePop(),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('discover_section')), findsOneWidget);
      },
    );
  });
}

class _DirectHttpOverrides extends HttpOverrides {}
