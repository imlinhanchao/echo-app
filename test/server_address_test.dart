import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/settings/server_address_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/auth/login_page.dart';
import 'package:echo/main.dart';

import 'tokens_fixtures.dart';

void main() {
  group('服务地址规范化', () {
    test('省略 scheme 时补 http://', () {
      expect(
        ServerAddressStore.normalize('192.168.50.200:8090'),
        'http://192.168.50.200:8090',
      );
      expect(ServerAddressStore.normalize('example.com'), 'http://example.com');
    });

    test('保留 https 与子路径，去掉尾部斜杠与空白', () {
      expect(
        ServerAddressStore.normalize(' https://echo.example.com/api/ '),
        'https://echo.example.com/api',
      );
      expect(
        ServerAddressStore.normalize('http://10.0.2.2:8090//'),
        'http://10.0.2.2:8090',
      );
    });

    test('非法地址返回 null', () {
      expect(ServerAddressStore.normalize(null), isNull);
      expect(ServerAddressStore.normalize('   '), isNull);
      expect(ServerAddressStore.normalize('http://'), isNull);
      expect(ServerAddressStore.normalize('ftp://example.com'), isNull);
      expect(ServerAddressStore.normalize('http://example.com:99999'), isNull);
    });
  });

  group('历史地址', () {
    test('去重并最近使用优先', () {
      final list = ServerAddressStore.upsert(<String>[
        'http://a:8090',
        'http://b:8090',
      ], 'http://a:8090');
      expect(list, <String>['http://a:8090', 'http://b:8090']);
    });

    test('超出上限时截断为最新 maxHistory 条', () {
      var list = <String>[];
      for (var i = 0; i < 12; i++) {
        list = ServerAddressStore.upsert(list, 'http://host$i:8090');
      }
      expect(list.length, ServerAddressStore.maxHistory);
      expect(list.first, 'http://host11:8090');
      expect(list.contains('http://host0:8090'), isFalse);
    });

    test('解析持久化 JSON：忽略坏数据并规范化', () {
      expect(ServerAddressStore.parseHistory(null), isEmpty);
      expect(ServerAddressStore.parseHistory('not json'), isEmpty);
      expect(
        ServerAddressStore.parseHistory(
          '["192.168.50.200:8090","http://10.0.2.2:8090/",42,""]',
        ),
        <String>['http://192.168.50.200:8090', 'http://10.0.2.2:8090'],
      );
    });
  });

  testWidgets('登录页有服务地址入口：可进入设置页并保存', (tester) async {
    final api = EchoApi(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090')),
      tokenStore: MemoryTokenStore(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
          echoApiProvider.overrideWithValue(api),
        ],
        child: EchoApp(
          theme: buildEchoTheme(
            Brightness.dark,
            EchoTokens.fromColors(darkColors, Brightness.dark),
          ),
          home: const LoginPage(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('login_server_settings')), findsOneWidget);
    await tester.tap(find.byKey(const Key('login_server_settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server_address_page')), findsOneWidget);
    expect(find.byKey(const Key('server_history_list')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('server_address_input')),
      '192.168.50.200:8090',
    );
    await tester.tap(find.byKey(const Key('server_address_save')));
    await tester.pumpAndSettle();

    // 保存后回到登录页，当前地址已生效并写入历史。
    expect(find.byKey(const Key('login_page')), findsOneWidget);
    expect(ServerAddressStore.current.value, 'http://192.168.50.200:8090');
    expect(
      ServerAddressStore.history.value,
      contains('http://192.168.50.200:8090'),
    );

    // 让 SnackBar 的自动消失计时器走完，避免 Timer 残留告警。
    await tester.pump(const Duration(seconds: 5));
    ServerAddressStore.current.value = kEchoDefaultBaseUrl;
    ServerAddressStore.history.value = const <String>[];
  });
}
