import 'package:dio/dio.dart';
import 'package:echo/core/api/ebook_api_client.dart';
import 'package:echo/core/api/provider_token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stub_adapter.dart';

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
            'status': 'ok',
            'email': 'reader@example.com',
            'daily_remaining': 8,
            'daily_limit': 10,
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
      expect(adapter.requestsTo('/health').first.headers['X-API-Key'], 'my-secret-key');

      final page = await client.search(
        query: '三体',
        provider: 'zlib',
        extensions: const <String>['EPUB'],
      );
      expect(page.books, hasLength(1));
      expect(page.books.first.title, '三体');
      expect(adapter.requestsTo('/v1/search').first.headers['X-API-Key'], 'my-secret-key');
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
      expect(loginRes.account?.dailyRemaining, 8);
    });
  });
}
