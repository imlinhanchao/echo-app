import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/shell/echo_shell.dart';
import 'package:echo/main.dart';

import 'stub_adapter.dart';
import 'tokens_fixtures.dart';

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);
  const user = EchoUser(id: 7, email: 'hancel@example.com');

  late StubAdapter adapter;
  late EchoApi api;
  late MemoryTokenStore tokenStore;
  late MemoryProgressStore progressStore;
  late MemoryReadingStore readingStore;
  late FakeAudioEngine engine;

  setUp(() async {
    tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_test');
    adapter = StubAdapter(<String, Responder Function()>{
      '/api/audiobooks': () =>
          okResponse(<String, dynamic>{'audiobooks': <dynamic>[]}),
      '/api/library': () => okResponse(<String, dynamic>{'books': <dynamic>[]}),
      '/api/sync/progress': () =>
          okResponse(<String, dynamic>{'progresses': <dynamic>[]}),
      '/api/sync/notes': () =>
          okResponse(<String, dynamic>{'notes': <dynamic>[]}),
    });
    api = EchoApi(dio: stubDio(adapter), tokenStore: tokenStore);
    progressStore = MemoryProgressStore();
    readingStore = MemoryReadingStore();
    engine = FakeAudioEngine();
  });

  Widget buildTestShell() {
    return ProviderScope(
      overrides: <Override>[
        tokenStoreProvider.overrideWithValue(tokenStore),
        echoApiProvider.overrideWithValue(api),
        audioEngineProvider.overrideWithValue(engine),
        progressStoreProvider.overrideWithValue(progressStore),
        readingStoreProvider.overrideWithValue(readingStore),
      ],
      child: EchoApp(
        theme: buildEchoTheme(Brightness.dark, darkTokens),
        home: const EchoHome(user: user),
      ),
    );
  }

  group('EchoShell 响应式三断点布局与组件切换', () {
    testWidgets('Compact 紧凑屏幕 (< 600dp) 渲染底部 NavigationBar', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildTestShell());
      await tester.pumpAndSettle();

      // 验证底部导航栏出现，侧边栏与 NavigationRail 不显示
      expect(find.byKey(const Key('echo_nav_bar')), findsOneWidget);
      expect(find.byKey(const Key('echo_nav_rail')), findsNothing);
      expect(find.byKey(const Key('desktop_sidebar')), findsNothing);
    });

    testWidgets('Compact 紧凑屏幕：无 AppBar 的 Tab 内容避开状态栏安全区', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      await tester.pumpWidget(buildTestShell());
      await tester.pumpAndSettle();

      // 书架列表整体落在状态栏下方（工具条/问候语不被状态栏压住）。
      expect(
        tester.getTopLeft(find.byKey(const Key('bookshelf_scroll'))).dy,
        greaterThanOrEqualTo(24),
      );

      // 「我的」Tab 同样避开状态栏（该页有转圈动画，不能 pumpAndSettle）。
      await tester.tap(find.byTooltip('我的'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('profile_page')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('profile_page'))).dy,
        greaterThanOrEqualTo(24),
      );
    });

    testWidgets('Medium 平板屏幕 (600–1024dp) 渲染左侧 NavigationRail', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildTestShell());
      await tester.pumpAndSettle();

      // 验证 NavigationRail 出现，底部导航栏与桌面侧边栏不显示
      expect(find.byKey(const Key('echo_nav_rail')), findsOneWidget);
      expect(find.byKey(const Key('echo_nav_bar')), findsNothing);
      expect(find.byKey(const Key('desktop_sidebar')), findsNothing);
    });

    testWidgets('Expanded 桌面屏幕 (> 1024dp) 渲染完整 DesktopSidebar 且支持抽屉联动', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildTestShell());
      await tester.pumpAndSettle();

      // 验证 DesktopSidebar 出现，移动/平板导航不显示
      expect(find.byKey(const Key('desktop_sidebar')), findsOneWidget);
      expect(find.byKey(const Key('echo_nav_bar')), findsNothing);
      expect(find.byKey(const Key('echo_nav_rail')), findsNothing);

      // 验证 Tab 切换 (例如切换到发现探索)
      await tester.tap(find.text('发现探索'));
      await tester.pumpAndSettle();
      expect(find.text('发现探索'), findsWidgets);

      // 验证笔记抽屉展开与关闭联动
      expect(find.byKey(const Key('desktop_notes_drawer')), findsNothing);
      EchoShell.shellKey.currentState?.toggleNotes();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('desktop_notes_drawer')), findsOneWidget);
      expect(find.text('时间戳笔记'), findsOneWidget);

      // 关闭笔记抽屉
      EchoShell.shellKey.currentState?.toggleNotes();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop_notes_drawer')), findsNothing);
    });
  });
}
