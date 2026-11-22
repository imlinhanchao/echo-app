import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/features/search/search_controller.dart';

import 'stub_adapter.dart';

void main() {
  StubAdapter buildAdapter() {
    var searchCalls = 0;
    return StubAdapter(<String, Responder Function()>{
      '/api/search': () {
        searchCalls++;
        final page = searchCalls;
        final firstRef = page == 1 ? '100:hash-a' : '102:hash-c';
        final secondRef = page == 1 ? '101:hash-b' : '103:hash-d';
        return okResponse(<String, dynamic>{
          'books': <Map<String, dynamic>>[
            <String, dynamic>{
              'provider': 'zlib',
              'ref': firstRef,
              'title': '三体 ${page == 1 ? 'I' : 'III'}',
              'authors': <String>['刘慈欣'],
              'format': 'EPUB',
            },
            <String, dynamic>{
              'provider': 'zlib',
              'ref': secondRef,
              'title': '三体 ${page == 1 ? 'II · 黑暗森林' : 'IV'}',
              'authors': <String>['刘慈欣'],
              'format': 'EPUB',
            },
          ],
          'page': page,
          'total_pages': 2,
          'provider': 'zlib',
        });
      },
    });
  }

  group('SearchController（Stub 传输层）', () {
    test('搜索：查询参数正确（q/page/limit/ext）并解析结果页', () async {
      final adapter = buildAdapter();
      final controller = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
        filters: const SearchFilters(extensions: ['EPUB']),
      );

      await controller.search('三体');

      expect(controller.state.books, hasLength(2));
      expect(controller.state.hasMore, isTrue);
      expect(controller.state.lastQuery, '三体');

      final request = adapter.requestsTo('/api/search').single;
      expect(request.uri.queryParameters['q'], '三体');
      expect(request.uri.queryParameters['page'], '1');
      expect(request.uri.queryParameters['ext'], 'EPUB');
    });

    test('loadMore：追加下一页并携带 page=2', () async {
      final adapter = buildAdapter();
      final controller = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );

      await controller.search('三体');
      await controller.loadMore();

      expect(controller.state.books, hasLength(4));
      expect(controller.state.page, 2);
      final second = adapter.requestsTo('/api/search')[1];
      expect(second.uri.queryParameters['page'], '2');
    });

    test('空关键词不触发请求', () async {
      final adapter = buildAdapter();
      final controller = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );

      await controller.search('   ');
      expect(adapter.requestsTo('/api/search'), isEmpty);
      expect(controller.state.books, isEmpty);
    });

    test('搜索历史：置顶去重并可删除', () async {
      final adapter = buildAdapter();
      final controller = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );

      await controller.search('三体');
      await controller.search('kafka');
      await controller.search('三体');

      expect(controller.state.history.first, '三体', reason: '重复搜索应置顶去重');
      expect(controller.state.history, hasLength(2));

      controller.removeHistory('三体');
      expect(controller.state.history, <String>['kafka']);
    });

    test('搜索失败：错误态直显服务端文案（如书源未配置）', () async {
      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/search': () =>
            errorResponse(409, 'PROVIDER_NOT_CONFIGURED', '请先配置该图书源账号'),
      });
      final controller = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );

      await controller.search('三体');

      expect(controller.state.books, isEmpty);
      expect(controller.state.error, '请先配置该图书源账号');
    });

    test('持久化：SearchHistoryStore 跨实例恢复与删除同步', () async {
      final store = MemorySearchHistoryStore(<String>['历史1', '历史2']);
      final adapter = buildAdapter();
      final controller1 = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
        historyStore: store,
      );

      await Future<void>.delayed(Duration.zero);
      expect(controller1.state.history, <String>['历史1', '历史2']);

      await controller1.search('三体');
      expect(controller1.state.history, <String>['三体', '历史1', '历史2']);
      expect(await store.load(), <String>['三体', '历史1', '历史2']);

      final controller2 = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
        historyStore: store,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller2.state.history, <String>['三体', '历史1', '历史2']);

      controller2.removeHistory('历史1');
      expect(await store.load(), <String>['三体', '历史2']);
    });

    test('发起新搜索时保持原有 books 列表防闪烁，返回后原子替换', () async {
      final adapter = buildAdapter();
      final controller = SearchController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
        historyStore: MemorySearchHistoryStore(),
      );

      await controller.search('三体');
      expect(controller.state.books, hasLength(2));
      final firstBookRef = controller.state.books.first.ref;

      final future = controller.search('三体 2');
      expect(controller.state.isLoading, isTrue);
      expect(controller.state.books, hasLength(2), reason: '加载过程中应保持旧数据避免白屏闪烁');

      await future;
      expect(controller.state.isLoading, isFalse);
      expect(controller.state.books, hasLength(2));
      expect(controller.state.books.first.ref, isNot(firstBookRef));
    });
  });
}
