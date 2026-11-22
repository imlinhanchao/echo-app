import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/features/auth/auth_controller.dart';

/// 单一响应描述：状态码 + JSON 体。
typedef Responder = ({int status, Map<String, dynamic> body});

Responder _ok(Map<String, dynamic> body) => (status: 200, body: body);

Responder _error(int status, String code, String message) => (
  status: status,
  body: {
    'error': {'code': code, 'message': message},
  },
);

/// 记录所有请求并按路由返回预设响应的传输层 Stub。
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.routes);

  final Map<String, Responder Function()> routes;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    requests.add(options);
    final respond =
        routes[options.uri.path] ?? () => _error(404, 'not_found', '路由未配置');
    final response = respond();
    return ResponseBody.fromString(
      jsonEncode(response.body),
      response.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _stubDio(StubAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = adapter;

void main() {
  group('认证状态机（Stub 传输层）', () {
    test('无 Token 引导 → 登录成功 → 持久化并携带 Bearer 头', () async {
      final store = MemoryTokenStore();
      final adapter = StubAdapter({
        '/api/auth/token': () => _ok(<String, dynamic>{
          'token': 'echo_pat_t1',
          'token_type': 'Bearer',
          'user': {'id': 7, 'email': 'hancel@example.com'},
        }),
        '/api/auth/me': () => _ok(<String, dynamic>{
          'user': {'id': 7, 'email': 'hancel@example.com', 'name': 'Echo'},
          'registration_open': true,
        }),
      });
      final api = EchoApi(dio: _stubDio(adapter), tokenStore: store);
      final controller = AuthController(api, store);

      await controller.bootstrap();
      expect(controller.state, isA<AuthLoggedOut>());

      final error = await controller.login('hancel@example.com', 'pw');
      expect(error, isNull);
      expect(controller.state, isA<AuthLoggedIn>());
      expect(await store.read(), 'echo_pat_t1');

      // 登录后的 me() 请求自动携带 Bearer 头。
      final meRequests = adapter.requests
          .where((r) => r.uri.path == '/api/auth/me')
          .toList();
      expect(meRequests.single.headers['Authorization'], 'Bearer echo_pat_t1');
    });

    test('登录失败：直显服务端错误文案', () async {
      final store = MemoryTokenStore();
      final adapter = StubAdapter({
        '/api/auth/token': () => _error(401, 'invalid_credentials', '邮箱或密码错误'),
      });
      final api = EchoApi(dio: _stubDio(adapter), tokenStore: store);
      final controller = AuthController(api, store);
      await controller.bootstrap();

      final error = await controller.login('hancel@example.com', 'bad-pw');
      expect(error, '邮箱或密码错误');
      expect(controller.state, isA<AuthLoggedOut>());
    });

    test('me 401 → 自动 refresh → 以新 Token 重放并恢复会话', () async {
      final store = MemoryTokenStore();
      await store.write('echo_pat_t1');

      var meCalls = 0;
      final adapter = StubAdapter({
        '/api/auth/me': () {
          meCalls++;
          return meCalls == 1
              ? _error(401, 'unauthorized', '未授权')
              : _ok(<String, dynamic>{
                  'user': {'id': 7, 'email': 'hancel@example.com'},
                  'registration_open': true,
                });
        },
        '/api/auth/token/refresh': () => _ok(<String, dynamic>{
          'token': 'echo_pat_t2',
          'token_type': 'Bearer',
        }),
      });
      final api = EchoApi(dio: _stubDio(adapter), tokenStore: store);
      final controller = AuthController(api, store);

      await controller.bootstrap();
      expect(
        controller.state,
        isA<AuthLoggedIn>(),
        reason: '401 后应刷新 Token 并恢复会话',
      );
      expect(await store.read(), 'echo_pat_t2');

      final meRequests = adapter.requests
          .where((r) => r.uri.path == '/api/auth/me')
          .toList();
      expect(meRequests.last.headers['Authorization'], 'Bearer echo_pat_t2');
    });

    test('refresh 也失败 → 清理 Token 并触发会话过期', () async {
      final store = MemoryTokenStore();
      await store.write('echo_pat_t1');

      final adapter = StubAdapter({
        '/api/auth/me': () => _error(401, 'unauthorized', '未授权'),
        '/api/auth/token/refresh': () => _error(401, 'unauthorized', '未授权'),
      });
      var expired = 0;
      final api = EchoApi(
        dio: _stubDio(adapter),
        tokenStore: store,
        onSessionExpired: () => expired++,
      );
      final controller = AuthController(api, store);

      await controller.bootstrap();
      expect(expired, 1, reason: 'refresh 失败应通知会话过期');
      expect(await store.read(), isNull, reason: '失效凭据应被清理');
      expect(controller.state, isA<AuthLoggedOut>());
    });

    test('登出：先 revoke 再清理，回到登录态', () async {
      final store = MemoryTokenStore();
      await store.write('echo_pat_t1');
      var revoked = false;
      final adapter = StubAdapter({
        '/api/auth/me': () => _ok(<String, dynamic>{
          'user': {'id': 7, 'email': 'hancel@example.com'},
        }),
        '/api/auth/token/revoke': () {
          revoked = true;
          return _ok(<String, dynamic>{});
        },
      });
      final api = EchoApi(dio: _stubDio(adapter), tokenStore: store);
      final controller = AuthController(api, store);

      await controller.bootstrap();
      expect(controller.state, isA<AuthLoggedIn>());

      await controller.logout();
      expect(revoked, isTrue);
      expect(await store.read(), isNull);
      expect(controller.state, isA<AuthLoggedOut>());
    });

    test('并发 401 请求：共享同一次 refresh 且均成功重放', () async {
      final store = MemoryTokenStore();
      await store.write('echo_pat_old');
      var refreshCount = 0;
      late final StubAdapter adapter;
      adapter = StubAdapter({
        '/api/library': () {
          final lastReq = adapter.requests.last;
          if (lastReq.headers['Authorization'] == 'Bearer echo_pat_new') {
            return _ok(<String, dynamic>{'books': <dynamic>[]});
          }
          return _error(401, 'unauthorized', 'Token 已失效');
        },
        '/api/audiobooks': () {
          final lastReq = adapter.requests.last;
          if (lastReq.headers['Authorization'] == 'Bearer echo_pat_new') {
            return _ok(<String, dynamic>{'audiobooks': <dynamic>[]});
          }
          return _error(401, 'unauthorized', 'Token 已失效');
        },
        '/api/auth/token/refresh': () {
          refreshCount++;
          return _ok(<String, dynamic>{
            'token': 'echo_pat_new',
            'token_type': 'Bearer',
          });
        },
      });
      final api = EchoApi(dio: _stubDio(adapter), tokenStore: store);

      final results = await Future.wait([
        api.listBooks(),
        api.listAudiobooks(),
      ]);

      expect(results[0], isEmpty);
      expect(results[1], isEmpty);
      expect(refreshCount, 1, reason: '并发 401 应被互斥锁折叠为 1 次刷新');
      expect(await store.read(), 'echo_pat_new');
    });
  });
}
