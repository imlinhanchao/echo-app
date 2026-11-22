import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/features/providers/providers_controller.dart';

import 'stub_adapter.dart';

void main() {
  StubAdapter buildAdapter() => StubAdapter(<String, Responder Function()>{
    '/api/providers': () => okResponse(<String, dynamic>{
      'providers': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'zlib',
          'name': 'Z-Library',
          'default_domain': 'z-library.sk',
          'domains': <String>['z-library.sk', '1lib.sk'],
          'credential_keys': <String>['remix_userid', 'remix_userkey'],
          'account': <String, dynamic>{
            'configured': true,
            'status': 'ok',
            'email': 'hancel@example.com',
            'daily_used': 3,
            'daily_limit': 10,
            'daily_remaining': 7,
            'quota_known': true,
          },
        },
      ],
    }),
    '/api/providers/zlib/account': () => okResponse(<String, dynamic>{
      'account': <String, dynamic>{
        'configured': true,
        'status': 'ok',
        'email': 'hancel@example.com',
        'daily_used': 3,
        'daily_limit': 10,
        'daily_remaining': 7,
        'quota_known': true,
      },
    }),
    '/api/providers/zlib/account/verify': () => okResponse(<String, dynamic>{
      'account': <String, dynamic>{
        'configured': true,
        'status': 'ok',
        'daily_used': 4,
        'daily_limit': 10,
        'daily_remaining': 6,
        'quota_known': true,
      },
    }),
  });

  group('ProvidersController 书源账号（Stub 传输层）', () {
    test('刷新读取账号状态与配额', () async {
      final adapter = buildAdapter();
      final controller = ProvidersController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );

      await controller.refresh();
      expect(controller.state.providers.single.id, 'zlib');
      expect(controller.state.providers.single.account?.dailyRemaining, 7);
      expect(controller.state.providers.single.account?.needsLogin, isFalse);
    });

    test('保存账号（password 模式）：提交完整凭据体并刷新状态', () async {
      final adapter = buildAdapter();
      final controller = ProvidersController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );

      final error = await controller.saveAccount(
        providerId: 'zlib',
        mode: 'password',
        domain: '1lib.sk',
        email: 'hancel@example.com',
        password: 'secret-pw',
      );

      expect(error, isNull);
      final body = adapter.requestBodyAt('/api/providers/zlib/account');
      expect(body?['mode'], 'password');
      expect(body?['domain'], '1lib.sk');
      expect(body?['email'], 'hancel@example.com');
      expect(body?['password'], 'secret-pw');
    });

    test('保存账号（cookies 模式）：提交 remix 凭据', () async {
      final adapter = buildAdapter();
      final controller = ProvidersController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );

      final error = await controller.saveAccount(
        providerId: 'zlib',
        mode: 'cookies',
        domain: 'z-library.sk',
        remixUserId: '123456',
        remixUserKey: 'abcdef-key',
      );

      expect(error, isNull);
      final body = adapter.requestBodyAt('/api/providers/zlib/account');
      expect(body?['mode'], 'cookies');
      expect(body?['remix_userid'], '123456');
      expect(body?['remix_userkey'], 'abcdef-key');
    });

    test('验证账号失败（会话过期）：返回文案并保持状态', () async {
      final adapter = buildAdapter();
      // 覆盖 verify 路由为失败响应。
      adapter.routes['/api/providers/zlib/account/verify'] = () =>
          errorResponse(409, 'PROVIDER_NOT_CONFIGURED', '请先配置该图书源账号');
      final controller = ProvidersController(
        EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
      );
      await controller.refresh();

      final error = await controller.verify('zlib');
      expect(error, '请先配置该图书源账号');
    });
  });
}
