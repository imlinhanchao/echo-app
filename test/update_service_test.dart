import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/update/update_models.dart';
import 'package:echo/core/update/update_service.dart';
import 'package:echo/features/settings/update_settings_page.dart';

class _FakeUpdateDioAdapter implements HttpClientAdapter {
  _FakeUpdateDioAdapter({
    required this.handler,
  });

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Semantic Version Comparison', () {
    test('compareSemanticVersions parses and compares properly', () {
      expect(compareSemanticVersions('0.4.1', '0.4.0'), 1);
      expect(compareSemanticVersions('v0.4.0', '0.4.1'), -1);
      expect(compareSemanticVersions('v0.4.1+401', '0.4.1'), 0);
      expect(compareSemanticVersions('1.0.0', '0.9.9'), 1);
      expect(compareSemanticVersions('0.4.1-beta', '0.4.1'), 0);
    });
  });

  group('Update Download URL Resolution', () {
    const rawAsset =
        'https://github.com/imlinhanchao/echo-app/releases/download/v0.4.1/echo_v0.4.1_android_universal.apk';

    test('Auto mode with CN IP resolves to ghfast mirror', () {
      final url = UpdateService.resolveDownloadUrl(
        rawUrl: rawAsset,
        mode: UpdateMirrorMode.auto,
        detectedCountryCode: 'CN',
      );
      expect(url, startsWith('https://ghfast.top/'));
      expect(url, contains(rawAsset));
    });

    test('Auto mode with non-CN IP resolves to direct GitHub URL', () {
      final url = UpdateService.resolveDownloadUrl(
        rawUrl: rawAsset,
        mode: UpdateMirrorMode.auto,
        detectedCountryCode: 'US',
      );
      expect(url, equals(rawAsset));
    });

    test('Explicit mirror mode resolves correctly', () {
      expect(
        UpdateService.resolveDownloadUrl(
          rawUrl: rawAsset,
          mode: UpdateMirrorMode.ghfast,
        ),
        startsWith('https://ghfast.top/'),
      );
      expect(
        UpdateService.resolveDownloadUrl(
          rawUrl: rawAsset,
          mode: UpdateMirrorMode.ghProxy,
        ),
        startsWith('https://gh-proxy.com/'),
      );
      expect(
        UpdateService.resolveDownloadUrl(
          rawUrl: rawAsset,
          mode: UpdateMirrorMode.github,
        ),
        equals(rawAsset),
      );
      expect(
        UpdateService.resolveDownloadUrl(
          rawUrl: rawAsset,
          mode: UpdateMirrorMode.custom,
          customPrefix: 'https://proxy.example.com/',
        ),
        startsWith('https://proxy.example.com/'),
      );
    });
  });

  group('UpdateService Mock Tests', () {
    test('checkForUpdates returns hasUpdate = true when latest > current', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeUpdateDioAdapter(
        handler: (options) async {
          if (options.path.contains('/releases/latest')) {
            const body = '''
            {
              "tag_name": "v0.5.0",
              "name": "Echo v0.5.0",
              "body": "新功能发布",
              "html_url": "https://github.com/imlinhanchao/echo-app/releases/tag/v0.5.0",
              "assets": [
                {
                  "name": "echo_v0.5.0_android_arm64-v8a.apk",
                  "size": 104857600,
                  "browser_download_url": "https://github.com/imlinhanchao/echo-app/releases/download/v0.5.0/echo_v0.5.0_android_arm64-v8a.apk"
                }
              ]
            }
            ''';
            return ResponseBody.fromString(body, 200, headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            });
          }
          if (options.path.contains('country.is')) {
            return ResponseBody.fromString('{"ip":"1.1.1.1","country":"CN"}', 200, headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            });
          }
          return ResponseBody.fromString('{}', 404);
        },
      );

      final service = UpdateService(dio: dio);
      final info = await service.checkForUpdates(
        currentVersion: '0.4.1',
        config: const StandaloneConfig(
          updateMirrorMode: 'auto',
        ),
      );

      expect(info.hasUpdate, isTrue);
      expect(info.latestVersion, 'v0.5.0');
      expect(info.detectedCountryCode, 'CN');
      expect(info.effectiveDownloadUrl, startsWith('https://ghfast.top/'));
    });
  });

  group('UpdateSettingsPage Widget Tests', () {
    testWidgets('Renders update settings, allows switching mirror and triggers check',
        (tester) async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeUpdateDioAdapter(
        handler: (options) async {
          if (options.path.contains('/releases/latest')) {
            const body = '''
            {
              "tag_name": "v0.4.1",
              "name": "Echo v0.4.1",
              "body": "当前是最新版本",
              "html_url": "https://github.com/imlinhanchao/echo-app/releases/tag/v0.4.1",
              "assets": []
            }
            ''';
            return ResponseBody.fromString(body, 200, headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            });
          }
          if (options.path.contains('country.is')) {
            return ResponseBody.fromString('{"ip":"1.1.1.1","country":"CN"}', 200, headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            });
          }
          return ResponseBody.fromString('{}', 404);
        },
      );

      final container = ProviderContainer(
        overrides: [
          updateServiceProvider.overrideWithValue(UpdateService(dio: dio)),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: UpdateSettingsPage(currentVersion: '0.4.1'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('软件更新与镜像设置'), findsOneWidget);
      expect(find.text('当前版本：v0.4.1'), findsOneWidget);
      expect(find.byKey(const Key('check_update_now_button')), findsOneWidget);

      // 点击立即检查更新
      await tester.tap(find.byKey(const Key('check_update_now_button')));
      await tester.pumpAndSettle();

      // 验证弹出弹窗
      expect(find.text('当前已是最新版本'), findsOneWidget);
      expect(find.byKey(const Key('update_dialog_cancel_button')), findsOneWidget);

      // 关闭弹窗
      await tester.tap(find.byKey(const Key('update_dialog_cancel_button')));
      await tester.pumpAndSettle();
      expect(find.text('当前已是最新版本'), findsNothing);
    });

    testWidgets('Renders Markdown release notes when update is available',
        (tester) async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeUpdateDioAdapter(
        handler: (options) async {
          if (options.path.contains('/releases/latest')) {
            const body = '''
            {
              "tag_name": "v0.5.0",
              "name": "Echo v0.5.0",
              "body": "### 新增功能\\n- **Markdown 更新说明**支持\\n- 性能优化",
              "html_url": "https://github.com/imlinhanchao/echo-app/releases/tag/v0.5.0",
              "assets": [
                {
                  "name": "echo_v0.5.0_android_universal.apk",
                  "size": 104857600,
                  "browser_download_url": "https://github.com/imlinhanchao/echo-app/releases/download/v0.5.0/echo_v0.5.0_android_universal.apk"
                }
              ]
            }
            ''';
            return ResponseBody.fromString(body, 200, headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            });
          }
          if (options.path.contains('country.is')) {
            return ResponseBody.fromString('{"ip":"1.1.1.1","country":"CN"}', 200, headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            });
          }
          return ResponseBody.fromString('{}', 404);
        },
      );

      final container = ProviderContainer(
        overrides: [
          updateServiceProvider.overrideWithValue(UpdateService(dio: dio)),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: UpdateSettingsPage(currentVersion: '0.4.2'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('check_update_now_button')));
      await tester.pumpAndSettle();

      expect(find.text('发现新版本 v0.5.0'), findsOneWidget);
      expect(find.text('更新说明：'), findsOneWidget);
      expect(find.text('新增功能', findRichText: true), findsOneWidget);
      expect(find.byKey(const Key('update_dialog_download_button')), findsOneWidget);
    });
  });
}
